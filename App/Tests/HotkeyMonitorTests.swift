// IR-005: side-specific modifier tracking. Down/up must come from the selected
// physical key's device flag bit, so holding the matching left modifier can't
// swallow the watched right key's release.

import CoreGraphics
import XCTest
@testable import Internos

@MainActor
final class HotkeyMonitorTests: XCTestCase {
    // Left-side keycodes and device bits, for simulating "left key also held".
    private static let leftOptionKeyCode: Int64 = 58
    private static let leftOptionBit: UInt64 = 0x20   // NX_DEVICELALTKEYMASK
    private static let leftCommandKeyCode: Int64 = 55
    private static let leftCommandBit: UInt64 = 0x08  // NX_DEVICELCMDKEYMASK
    private static let leftControlKeyCode: Int64 = 59
    private static let leftControlBit: UInt64 = 0x01  // NX_DEVICELCTLKEYMASK

    private func leftInfo(for choice: HotkeyChoice) -> (keyCode: Int64, bit: UInt64) {
        switch choice {
        case .rightOption: (Self.leftOptionKeyCode, Self.leftOptionBit)
        case .rightCommand: (Self.leftCommandKeyCode, Self.leftCommandBit)
        case .rightControl: (Self.leftControlKeyCode, Self.leftControlBit)
        case .fn: (0, 0)
        }
    }

    /// Hold Left X, press and release Right X, release Left X: exactly one down and
    /// one up must be emitted for the watched right key.
    func testRightKeyReleaseWithLeftKeyHeld() {
        for choice in [HotkeyChoice.rightOption, .rightCommand, .rightControl] {
            let generic = choice.genericFlagMask
            let (leftKeyCode, leftBit) = leftInfo(for: choice)
            var held = false
            var events: [HotkeyMonitor.Transition] = []

            func feed(keyCode: Int64, flags: UInt64) {
                let (newHeld, event) = HotkeyMonitor.transition(
                    isHeld: held, watched: choice, keyCode: keyCode, flags: flags)
                held = newHeld
                if let event { events.append(event) }
            }

            // Left key goes down (generic mask set, left device bit set).
            feed(keyCode: leftKeyCode, flags: generic | leftBit)
            // Right key goes down (both device bits set).
            feed(keyCode: choice.rawValue, flags: generic | leftBit | choice.deviceFlagMask)
            // Right key released — generic mask STILL set because left is held.
            feed(keyCode: choice.rawValue, flags: generic | leftBit)
            // Left key released.
            feed(keyCode: leftKeyCode, flags: 0)

            XCTAssertEqual(events, [.down, .up], "\(choice) must see one down and one up")
            XCTAssertFalse(held)
        }
    }

    func testPlainPressAndRelease() {
        let choice = HotkeyChoice.rightOption
        var (held, event) = HotkeyMonitor.transition(
            isHeld: false, watched: choice, keyCode: choice.rawValue,
            flags: choice.genericFlagMask | choice.deviceFlagMask)
        XCTAssertEqual(event, .down)
        XCTAssertTrue(held)
        (held, event) = HotkeyMonitor.transition(
            isHeld: held, watched: choice, keyCode: choice.rawValue, flags: 0)
        XCTAssertEqual(event, .up)
        XCTAssertFalse(held)
    }

    func testDuplicateFlagsChangedProducesNoDuplicateCallbacks() {
        let choice = HotkeyChoice.rightCommand
        let downFlags = choice.genericFlagMask | choice.deviceFlagMask
        var (held, event) = HotkeyMonitor.transition(
            isHeld: false, watched: choice, keyCode: choice.rawValue, flags: downFlags)
        XCTAssertEqual(event, .down)
        // Same event again: no second down.
        (held, event) = HotkeyMonitor.transition(
            isHeld: held, watched: choice, keyCode: choice.rawValue, flags: downFlags)
        XCTAssertNil(event)
        XCTAssertTrue(held)
    }

    func testOtherKeysIgnored() {
        let choice = HotkeyChoice.rightOption
        let (held, event) = HotkeyMonitor.transition(
            isHeld: false, watched: choice, keyCode: Self.leftOptionKeyCode,
            flags: choice.genericFlagMask | Self.leftOptionBit)
        XCTAssertNil(event)
        XCTAssertFalse(held)
    }

    func testFnKeyPressAndRelease() {
        let choice = HotkeyChoice.fn
        var (held, event) = HotkeyMonitor.transition(
            isHeld: false, watched: choice, keyCode: choice.rawValue, flags: choice.deviceFlagMask)
        XCTAssertEqual(event, .down)
        (held, event) = HotkeyMonitor.transition(
            isHeld: held, watched: choice, keyCode: choice.rawValue, flags: 0)
        XCTAssertEqual(event, .up)
        XCTAssertFalse(held)
    }

    /// Tap disabled while the key is held: recording must not remain stuck (IR-005).
    func testTapDisabledWhileHeldEmitsKeyUp() {
        AppSettings.shared.hotkey = .rightOption
        let monitor = HotkeyMonitor()
        var downs = 0
        var ups = 0
        monitor.onKeyDown = { downs += 1 }
        monitor.onKeyUp = { ups += 1 }

        let choice = HotkeyChoice.rightOption
        monitor.handleFlagsChanged(
            keyCode: choice.rawValue,
            flags: choice.genericFlagMask | choice.deviceFlagMask)
        XCTAssertEqual(downs, 1)

        monitor.handleTapDisabled()
        XCTAssertEqual(ups, 1, "a disabled tap must fail safe by ending the hold")

        // A later release event for the already-cleared key is a no-op.
        monitor.handleFlagsChanged(keyCode: choice.rawValue, flags: 0)
        XCTAssertEqual(ups, 1)
    }

    // MARK: command key — a solo hold, never a shortcut

    private var inputCount: UInt32 = 0
    /// What the hardware reports right now; `feed` keeps it in step with events.
    private var hardwareFlags: UInt64 = 0
    private var clockNow = ContinuousClock.now
    private var timers: [(delay: TimeInterval, work: @MainActor () -> Void)] = []
    private var secondaryEvents: [String] = []

    private func makeCommandMonitor() -> HotkeyMonitor {
        AppSettings.shared.hotkey = .rightOption
        AppSettings.shared.commandHotkey = .rightCommand
        inputCount = 0
        hardwareFlags = 0
        timers = []
        secondaryEvents = []
        let monitor = HotkeyMonitor(
            inputCount: { [self] in inputCount },
            liveFlags: { [self] in hardwareFlags },
            now: { [self] in clockNow },
            schedule: { [self] delay, work in timers.append((delay, work)) })
        monitor.onSecondaryDown = { [self] in secondaryEvents.append("down") }
        monitor.onSecondaryUp = { [self] in secondaryEvents.append("up") }
        monitor.onSecondaryCancel = { [self] in secondaryEvents.append("cancel") }
        return monitor
    }

    /// A modifier event as the tap delivers it, with the hardware state to match.
    private func feed(_ monitor: HotkeyMonitor, keyCode: Int64, flags: UInt64) {
        hardwareFlags = flags
        monitor.handleFlagsChanged(keyCode: keyCode, flags: flags)
    }

    private func runNextTimer() {
        timers.removeFirst().work()
    }

    private func pressCommand(_ monitor: HotkeyMonitor, extraFlags: UInt64 = 0) {
        let cmd = HotkeyChoice.rightCommand
        feed(
            monitor, keyCode: cmd.rawValue, flags: cmd.genericFlagMask | cmd.deviceFlagMask | extraFlags)
    }

    private func releaseCommand(_ monitor: HotkeyMonitor) {
        feed(monitor, keyCode: HotkeyChoice.rightCommand.rawValue, flags: 0)
    }

    /// The command key (v2) is watched independently of the dictation key, and is
    /// announced only once it has been held alone for the hold delay.
    func testSecondaryKeyHeldAloneEmitsDownThenUp() {
        let monitor = makeCommandMonitor()
        var primary = 0
        monitor.onKeyDown = { primary += 1 }

        pressCommand(monitor)
        XCTAssertEqual(secondaryEvents, [], "nothing until the hold delay passes")
        XCTAssertEqual(timers.first?.delay, HotkeyMonitor.commandHoldDelay)
        runNextTimer()
        XCTAssertEqual(secondaryEvents, ["down"])
        releaseCommand(monitor)

        XCTAssertEqual(primary, 0, "the dictation key must not fire for the command key")
        XCTAssertEqual(secondaryEvents, ["down", "up"])
    }

    /// ⌘V: the V lands before the hold delay. No callbacks at all.
    func testQuickShortcutNeverReachesCommandMode() {
        let monitor = makeCommandMonitor()
        pressCommand(monitor)
        inputCount += 1 // the V key
        runNextTimer()
        releaseCommand(monitor)
        XCTAssertEqual(secondaryEvents, [])
    }

    /// A tap released before the hold delay is not a command either.
    func testTapShorterThanHoldDelayIsIgnored() {
        let monitor = makeCommandMonitor()
        pressCommand(monitor)
        releaseCommand(monitor)
        runNextTimer() // the stale timer from the released press
        XCTAssertEqual(secondaryEvents, [])

        // And the stale timer of one press can't announce the next.
        pressCommand(monitor)
        releaseCommand(monitor)
        pressCommand(monitor)
        runNextTimer() // first press's timer: inert
        XCTAssertEqual(secondaryEvents, [])
        runNextTimer() // second press's timer
        XCTAssertEqual(secondaryEvents, ["down"])
    }

    /// Shift already down (⇧⌘…), or another modifier joining during the delay
    /// and still down when it ends.
    func testOtherModifierHeldMakesItAShortcut() {
        let monitor = makeCommandMonitor()
        pressCommand(monitor, extraFlags: CGEventFlags.maskShift.rawValue | 0x02)
        runNextTimer()
        releaseCommand(monitor)
        XCTAssertEqual(secondaryEvents, [])
        timers.removeAll() // the first hold's watch for a lost release

        pressCommand(monitor)
        let cmd = HotkeyChoice.rightCommand
        feed(
            monitor, keyCode: Self.leftOptionKeyCode,
            flags: cmd.genericFlagMask | cmd.deviceFlagMask | CGEventFlags.maskAlternate.rawValue | Self.leftOptionBit)
        runNextTimer()
        releaseCommand(monitor)
        XCTAssertEqual(secondaryEvents, [])
    }

    /// Rolling off the dictation key onto the command key: both are down for an
    /// instant, then the command key is held alone. That is command mode.
    func testRollingOffTheDictationKeyStillStartsCommandMode() {
        let monitor = makeCommandMonitor()
        let opt = HotkeyChoice.rightOption
        let cmd = HotkeyChoice.rightCommand
        let optFlags = opt.genericFlagMask | opt.deviceFlagMask
        let cmdFlags = cmd.genericFlagMask | cmd.deviceFlagMask
        feed(monitor, keyCode: opt.rawValue, flags: optFlags)
        feed(monitor, keyCode: cmd.rawValue, flags: optFlags | cmdFlags) // command down first
        feed(monitor, keyCode: opt.rawValue, flags: cmdFlags)            // then option up
        runNextTimer()
        XCTAssertEqual(secondaryEvents, ["down"])
        releaseCommand(monitor)
        XCTAssertEqual(secondaryEvents, ["down", "up"])
    }

    /// A slow shortcut: the key arrives after the hold was announced. The poll
    /// cancels it, and the release that follows stays silent.
    func testKeyAfterAnnouncementCancelsTheHold() {
        let monitor = makeCommandMonitor()
        pressCommand(monitor)
        runNextTimer()
        XCTAssertEqual(secondaryEvents, ["down"])
        runNextTimer() // a poll with nothing pressed: keeps going
        XCTAssertEqual(secondaryEvents, ["down"])

        inputCount += 1
        runNextTimer()
        XCTAssertEqual(secondaryEvents, ["down", "cancel"])
        XCTAssertEqual(timers.count, 1, "only the watch for a lost release is left")
        releaseCommand(monitor)
        runNextTimer()
        XCTAssertEqual(secondaryEvents, ["down", "cancel"])
        XCTAssertTrue(timers.isEmpty, "and it stops once the key is up")
    }

    /// The key arrives between the last poll and the release.
    func testKeyJustBeforeReleaseCancelsInsteadOfUp() {
        let monitor = makeCommandMonitor()
        pressCommand(monitor)
        runNextTimer()
        inputCount += 1
        releaseCommand(monitor)
        XCTAssertEqual(secondaryEvents, ["down", "cancel"])
    }

    /// The main thread stalled past the hold delay with the key's release still
    /// queued behind the timer. The key is up; a tap must not start command mode.
    func testTimerAheadOfAQueuedReleaseDoesNotStartCommandMode() {
        let monitor = makeCommandMonitor()
        pressCommand(monitor)
        hardwareFlags = 0 // released, but the event has not been delivered yet
        runNextTimer()
        XCTAssertEqual(secondaryEvents, [])
        releaseCommand(monitor)
        XCTAssertEqual(secondaryEvents, [])
    }

    /// A paste Internos posts itself lands during the hold. Reported to the
    /// monitor, it is not the user's shortcut, whether the system has counted it
    /// yet or not; a real key after it still is.
    func testOwnPostedKeyPressesAreNotAShortcut() {
        let monitor = makeCommandMonitor()
        pressCommand(monitor)
        monitor.ownKeyPresses(1)
        inputCount += 1 // the synthetic ⌘V, counted
        runNextTimer()
        XCTAssertEqual(secondaryEvents, ["down"])

        monitor.ownKeyPresses(3) // backspaces posted, not counted yet
        runNextTimer() // poll
        XCTAssertEqual(secondaryEvents, ["down"])
        inputCount += 3 // now they are
        runNextTimer()
        XCTAssertEqual(secondaryEvents, ["down"])

        inputCount += 1 // the user's own key
        runNextTimer()
        XCTAssertEqual(secondaryEvents, ["down", "cancel"])
    }

    /// The command key goes down while a scratch's backspaces are reported but
    /// not all counted yet. The system catching up on them is not the user typing.
    func testHoldStartedBeforeOwnKeysAreCountedIsNotAShortcut() {
        let monitor = makeCommandMonitor()
        monitor.ownKeyPresses(5)
        inputCount += 2 // two of the five counted so far
        pressCommand(monitor)
        inputCount += 3 // the rest land during the hold delay
        runNextTimer()
        XCTAssertEqual(secondaryEvents, ["down"])

        inputCount += 1 // a real key still cancels
        runNextTimer()
        XCTAssertEqual(secondaryEvents, ["down", "cancel"])
    }

    /// A shortcut whose release was never delivered would leave the key looking
    /// held, and the next press looking like a repeat. The watch on an ignored
    /// hold notices the key is up.
    func testPressAfterAnUndeliveredReleaseStartsANewHold() {
        let monitor = makeCommandMonitor()
        pressCommand(monitor)
        inputCount += 1 // ⌘-Tab into a Secure Input app
        runNextTimer()
        XCTAssertEqual(secondaryEvents, [])
        hardwareFlags = 0 // released; the event is swallowed
        runNextTimer()
        XCTAssertTrue(timers.isEmpty)

        pressCommand(monitor)
        runNextTimer()
        XCTAssertEqual(secondaryEvents, ["down"])
        releaseCommand(monitor)
        XCTAssertEqual(secondaryEvents, ["down", "up"])
    }

    /// A repeated key-down for a key that is still held as part of a shortcut
    /// (a second keyboard, a remapper) does not turn it into a command hold.
    func testRepeatedDownDuringAShortcutStaysIgnored() {
        let monitor = makeCommandMonitor()
        pressCommand(monitor)
        inputCount += 1
        runNextTimer()
        pressCommand(monitor) // duplicate flagsChanged, key still down
        runNextTimer() // the watch: still held
        runNextTimer()
        XCTAssertEqual(secondaryEvents, [])
        XCTAssertEqual(timers.count, 1, "just the watch, no new hold timer")
    }

    /// The report comes before the keys are posted, so the reading it takes has
    /// none of them in it and a real key afterwards still counts.
    func testRealKeyAfterAnOwnPasteIsStillAShortcut() {
        let monitor = makeCommandMonitor()
        monitor.ownKeyPresses(1)
        inputCount += 1 // the paste, counted
        pressCommand(monitor)
        inputCount += 1 // ⌘C, the user's
        runNextTimer()
        XCTAssertEqual(secondaryEvents, [])
    }

    /// Posted keys the system never counts (another tool's tap dropped them)
    /// must not leave shortcut detection blind: the pre-post reading is only
    /// trusted for as long as counting can take.
    func testUncountedOwnKeysDoNotHideLaterUserInput() {
        let monitor = makeCommandMonitor()
        monitor.ownKeyPresses(5) // never counted
        clockNow += .seconds(10)
        pressCommand(monitor)
        inputCount += 1 // the user's key
        runNextTimer()
        XCTAssertEqual(secondaryEvents, [], "a shortcut, seen as one")
    }

    /// A report taken back (posting failed) leaves the count as it was.
    func testRetractedReportLeavesTheCountAlone() {
        let monitor = makeCommandMonitor()
        monitor.ownKeyPresses(3)
        monitor.ownKeyPresses(-3)
        pressCommand(monitor)
        runNextTimer()
        XCTAssertEqual(secondaryEvents, ["down"])
        inputCount += 1
        runNextTimer()
        XCTAssertEqual(secondaryEvents, ["down", "cancel"])
    }

    /// The release event never arrives (Secure Input can swallow it). The poll
    /// sees the key is up and ends the hold, so a recording can't stay on.
    func testPollEndsAHoldWhoseReleaseWasNeverDelivered() {
        let monitor = makeCommandMonitor()
        pressCommand(monitor)
        runNextTimer()
        hardwareFlags = 0
        runNextTimer() // poll
        XCTAssertEqual(secondaryEvents, ["down", "up"])
        XCTAssertTrue(timers.isEmpty, "polling stops once the hold is over")
        releaseCommand(monitor) // if it does turn up late, nothing more happens
        XCTAssertEqual(secondaryEvents, ["down", "up"])
    }

    /// Tap disabled mid-hold: an announced hold is canceled, an unannounced one just resets.
    func testTapDisabledEndsOnlyAnAnnouncedCommandHold() {
        let monitor = makeCommandMonitor()
        pressCommand(monitor)
        monitor.handleTapDisabled()
        runNextTimer()
        XCTAssertEqual(secondaryEvents, [])

        pressCommand(monitor)
        runNextTimer()
        monitor.handleTapDisabled()
        XCTAssertEqual(secondaryEvents, ["down", "cancel"],
                       "the key was never seen to come up: a cut-off instruction is dropped, not run")
    }

    /// A command key that collides with the dictation key is inactive.
    func testSecondaryKeyDisabledWhenCollidingWithPrimary() {
        AppSettings.shared.hotkey = .rightOption
        AppSettings.shared.commandHotkey = .rightOption
        let monitor = HotkeyMonitor()
        monitor.reloadSettings()
        var primaryDowns = 0
        var secondaryDowns = 0
        monitor.onKeyDown = { primaryDowns += 1 }
        monitor.onSecondaryDown = { secondaryDowns += 1 }

        let opt = HotkeyChoice.rightOption
        monitor.handleFlagsChanged(
            keyCode: opt.rawValue, flags: opt.genericFlagMask | opt.deviceFlagMask)

        XCTAssertEqual(primaryDowns, 1)
        XCTAssertEqual(secondaryDowns, 0, "a colliding command key never fires")

        monitor.handleFlagsChanged(keyCode: opt.rawValue, flags: 0)
        AppSettings.shared.commandHotkey = .rightCommand // restore default
    }

    /// Changing the hotkey while the old key is held ends the hold once and starts
    /// the new key from a clean state with no synthetic transition.
    func testReloadSettingsWhileHeldClearsStateOnce() {
        AppSettings.shared.hotkey = .rightOption
        let monitor = HotkeyMonitor()
        var downs = 0
        var ups = 0
        monitor.onKeyDown = { downs += 1 }
        monitor.onKeyUp = { ups += 1 }

        monitor.handleFlagsChanged(
            keyCode: HotkeyChoice.rightOption.rawValue,
            flags: HotkeyChoice.rightOption.genericFlagMask | HotkeyChoice.rightOption.deviceFlagMask)
        XCTAssertEqual(downs, 1)

        AppSettings.shared.hotkey = .rightCommand
        monitor.reloadSettings()
        XCTAssertEqual(ups, 1, "the in-flight hold on the old key must end")

        // The new key works normally afterwards.
        monitor.handleFlagsChanged(
            keyCode: HotkeyChoice.rightCommand.rawValue,
            flags: HotkeyChoice.rightCommand.genericFlagMask | HotkeyChoice.rightCommand.deviceFlagMask)
        XCTAssertEqual(downs, 2)
        XCTAssertEqual(ups, 1)

        AppSettings.shared.hotkey = .rightOption // restore default for other tests
    }
}
