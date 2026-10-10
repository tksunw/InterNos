// Global dictation hotkey via a listenOnly CGEventTap.
// listenOnly needs Input Monitoring (not Accessibility) per Apple DTS — PRD §7.
// Watches a configurable modifier key (AppSettings.hotkey); down/up derived from
// the keycode + the device-specific modifier flag on flagsChanged events, so
// holding the matching left-side key cannot mask the watched right key's release.
//
// The command key is also an ordinary modifier (Right Command by default), so it
// only counts as a command-mode hold when it is held alone: no other modifier,
// and no key press, click or drag, for `commandHoldDelay`. The tap still
// sees modifier changes only; the rest is noticed through the system's event
// counters, which say that something happened and nothing about what.
//
// The counters are the session's, so they see every keyboard the tap sees
// (injected ones included) and also the keys Internos posts itself (⌘V,
// backspaces). Those are reported by the inserter (`ownKeyPresses`) and taken
// out of the count, so a paste landing during a hold is not mistaken for the
// user typing a shortcut.

import AppKit
import CoreGraphics

/// Controller-facing seam so lifecycle tests can drive hotkey events without a real event tap.
@MainActor
protocol HotkeyMonitoring: AnyObject {
    var onKeyDown: (() -> Void)? { get set }
    var onKeyUp: (() -> Void)? { get set }
    /// Command-mode key (v2). Inactive when it collides with the dictation key.
    var onSecondaryDown: (() -> Void)? { get set }
    var onSecondaryUp: (() -> Void)? { get set }
    /// The hold that `onSecondaryDown` announced turned out to be a shortcut
    /// (a key or click arrived during it). Replaces `onSecondaryUp` for that hold.
    var onSecondaryCancel: (() -> Void)? { get set }
    /// Internos is about to post `count` key presses of its own (a paste is one,
    /// a scratch one per backspace); negative takes back a report whose posting
    /// failed. They are not the user turning a hold into a shortcut.
    func ownKeyPresses(_ count: Int)
    func start() -> Bool
    func reloadSettings()
}

@MainActor
final class HotkeyMonitor: HotkeyMonitoring {
    enum Transition {
        case down
        case up
    }

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onSecondaryDown: (() -> Void)?
    var onSecondaryUp: (() -> Void)?
    var onSecondaryCancel: (() -> Void)?

    /// How long the command key must be held alone before it counts as command
    /// mode. ponytail: a trade, not a measurement. Recording starts this long after
    /// the key goes down, so longer clips the first word of an instruction spoken
    /// straight away; shorter lets more ordinary shortcuts start a recording that
    /// the poll below then has to cancel.
    static let commandHoldDelay: TimeInterval = 0.2
    /// How often an announced hold is re-checked for a key press or click.
    static let commandPollInterval: TimeInterval = 0.1

    private enum SecondaryPhase {
        case up
        /// Down, waiting out `commandHoldDelay`.
        case pending(inputCount: UInt32)
        /// Announced through `onSecondaryDown`.
        case active(inputCount: UInt32)
        /// Down as part of a shortcut: no callbacks until it is released.
        case ignored
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isHeld = false
    private var watched: HotkeyChoice = AppSettings.shared.hotkey
    private var secondaryPhase = SecondaryPhase.up
    /// Bumped on every phase reset so a timer from an earlier press is inert.
    private var secondaryPressID = 0
    private var secondaryWatched: HotkeyChoice? = HotkeyMonitor.effectiveCommandKey()
    /// Flags of the latest modifier event: which other modifiers are down right now.
    private var lastFlags: UInt64 = 0
    /// Key presses Internos posted itself so far, to take out of `inputCount`.
    private var ownKeyPressTally: UInt32 = 0
    /// The user's input count as it stood just before Internos last posted keys.
    /// Until the system has counted those, `userInputCount()` reads low; a
    /// baseline taken then would make the catch-up look like the user typing.
    /// Trusted only for as long as that catch-up can take: if some of the keys
    /// are never counted, a floor without an end would hide the user's own.
    private var countBeforeOwnPost: (count: UInt32, until: ContinuousClock.Instant)?
    private let now: () -> ContinuousClock.Instant

    private let inputCount: () -> UInt32
    /// Modifier flags as they are right now, not as of the last event this
    /// monitor got round to handling. Session state and hardware state together:
    /// the first sees whatever keyboard the tap sees, injected ones included
    /// (screen sharing, keyboard-sharing tools); the second can't be disturbed
    /// by the explicit flags on keys Internos posts itself. A key is up only
    /// when both say so.
    private let liveFlags: () -> UInt64
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void

    init(
        inputCount: @escaping () -> UInt32 = HotkeyMonitor.hardwareInputCount,
        liveFlags: @escaping () -> UInt64 = {
            CGEventSource.flagsState(.combinedSessionState).rawValue | CGEventSource.flagsState(.hidSystemState).rawValue
        },
        now: @escaping () -> ContinuousClock.Instant = { .now },
        schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(work) }
        }
    ) {
        self.inputCount = inputCount
        self.liveFlags = liveFlags
        self.now = now
        self.schedule = schedule
    }

    /// Key presses, clicks and drags since login, from the session's event
    /// counters: the deliberate things a held modifier can be a shortcut with. Scrolling is left
    /// out on purpose. Trackpad momentum and a finger resting on a Magic Mouse
    /// produce scroll events nobody meant, and either would silently swallow a
    /// real command. Readable without any permission and without observing the
    /// events themselves.
    nonisolated static func hardwareInputCount() -> UInt32 {
        let types: [CGEventType] = [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        ]
        return types.reduce(0) {
            $0 &+ CGEventSource.counterForEventType(.combinedSessionState, eventType: $1)
        }
    }

    /// Device bits of every modifier key: the selectable ones, plus the left-side
    /// keys and both Shifts (IOLLEvent.h NX_DEVICE… masks).
    private static let modifierDeviceMask: UInt64 = HotkeyChoice.allCases.reduce(
        0x01 /* L Control */ | 0x02 /* L Shift */ | 0x04 /* R Shift */ | 0x08 /* L Command */ | 0x20 /* L Option */
    ) { $0 | $1.deviceFlagMask }

    /// The command key is active only when it differs from the dictation key.
    private static func effectiveCommandKey() -> HotkeyChoice? {
        let command = AppSettings.shared.commandHotkey
        return command == AppSettings.shared.hotkey ? nil : command
    }

    /// Pure transition logic, kept separate from the event tap so it is unit-testable.
    /// Down/up comes from the selected key's device-specific flag bit, not the generic
    /// modifier mask: with Left+Right Option both held, releasing Right Option clears
    /// only the device bit while maskAlternate stays set.
    static func transition(isHeld: Bool, watched: HotkeyChoice, keyCode: Int64, flags: UInt64)
        -> (isHeld: Bool, event: Transition?)
    {
        guard keyCode == watched.rawValue else { return (isHeld, nil) }
        let down = flags & watched.deviceFlagMask != 0
        if down && !isHeld { return (true, .down) }
        if !down && isHeld { return (false, .up) }
        return (isHeld, nil) // duplicate flagsChanged for an unchanged state: no callback
    }

    /// Re-read the configured hotkeys after a settings change. If an old key is mid-hold,
    /// end it (emitting keyUp so a recording can't run forever) before switching keys;
    /// the new keys start from a clean not-held state with no synthetic transition.
    func reloadSettings() {
        if isHeld {
            isHeld = false
            onKeyUp?()
        }
        abandonSecondary()
        watched = AppSettings.shared.hotkey
        secondaryWatched = Self.effectiveCommandKey()
    }

    func ownKeyPresses(_ count: Int) {
        // Called before the first key is posted, so this reading has none of them.
        // ponytail: a second plus a millisecond per key is a guess at the longest
        // the system takes to count them.
        if count > 0 {
            countBeforeOwnPost = (inputBaseline(), now() + .seconds(1) + .milliseconds(count))
        }
        ownKeyPressTally &+= UInt32(bitPattern: Int32(clamping: count))
    }

    /// The count to measure a hold against: the current one, or the one from
    /// before Internos's last post if the system is still catching up on it.
    private func inputBaseline() -> UInt32 {
        let current = userInputCount()
        guard let floor = countBeforeOwnPost, floor.until > now(),
              Int32(bitPattern: floor.count &- current) > 0 else { return current }
        return floor.count
    }

    /// Input events so far that were the user's.
    private func userInputCount() -> UInt32 {
        inputCount() &- ownKeyPressTally
    }

    /// Whether the user pressed or clicked something since `baseline` was read.
    /// Only a count that moved up says so: a posted key is reported here before
    /// the system has counted it, and for that moment the difference dips.
    private func userInput(since baseline: UInt32) -> Bool {
        Int32(bitPattern: userInputCount() &- baseline) > 0
    }

    /// Returns false if the event tap could not be created (Input Monitoring not granted).
    func start() -> Bool {
        if !CGPreflightListenEventAccess() {
            CGRequestListenEventAccess() // async system prompt; user may need to relaunch after granting
        }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MainActor.assumeIsolated { monitor.handleTapDisabled() }
                } else if type == .flagsChanged {
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                    let flags = event.flags.rawValue
                    MainActor.assumeIsolated { monitor.handleFlagsChanged(keyCode: keyCode, flags: flags) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func handleFlagsChanged(keyCode: Int64, flags: UInt64) {
        lastFlags = flags
        let (held, event) = Self.transition(isHeld: isHeld, watched: watched, keyCode: keyCode, flags: flags)
        isHeld = held
        switch event {
        case .down: onKeyDown?()
        case .up: onKeyUp?()
        case nil: break
        }

        if let secondaryWatched {
            handleSecondary(watched: secondaryWatched, keyCode: keyCode, flags: flags)
        }
    }

    private func handleSecondary(watched: HotkeyChoice, keyCode: Int64, flags: UInt64) {
        let held = if case .up = secondaryPhase { false } else { true }
        let (_, event) = Self.transition(isHeld: held, watched: watched, keyCode: keyCode, flags: flags)
        switch event {
        case .down:
            secondaryPressID += 1
            secondaryPhase = .pending(inputCount: inputBaseline())
            let id = secondaryPressID
            schedule(Self.commandHoldDelay) { [weak self] in self?.secondaryHoldElapsed(id, watched: watched) }
        case .up:
            releaseSecondary()
        case nil:
            break
        }
    }

    /// The hold is a shortcut: nothing more is reported for it. It is still
    /// watched for a release that never arrives as an event (Secure Input can
    /// swallow it), or the key would look held forever and the next press
    /// would be taken for a repeat.
    private func ignoreSecondaryHold(_ id: Int, watched: HotkeyChoice) {
        secondaryPhase = .ignored
        schedule(Self.commandPollInterval) { [weak self] in self?.pollIgnoredHold(id, watched: watched) }
    }

    private func pollIgnoredHold(_ id: Int, watched: HotkeyChoice) {
        guard id == secondaryPressID, case .ignored = secondaryPhase else { return }
        guard liveFlags() & watched.genericFlagMask != 0 else {
            releaseSecondary()
            return
        }
        schedule(Self.commandPollInterval) { [weak self] in self?.pollIgnoredHold(id, watched: watched) }
    }

    /// Ends a hold whose key the user has not released, as far as anyone knows
    /// (settings reload, tap disabled). An instruction cut off there is not one
    /// to act on: cancel, so the selection stays as it was.
    private func abandonSecondary() {
        let wasActive = if case .active = secondaryPhase { true } else { false }
        secondaryPhase = .up
        secondaryPressID += 1
        if wasActive { onSecondaryCancel?() }
    }

    /// The end of a hold whose key came up, whether the release arrived as an
    /// event or was noticed by a poll.
    private func releaseSecondary() {
        let phase = secondaryPhase
        secondaryPhase = .up
        secondaryPressID += 1
        // A quick tap or a shortcut was never announced, so there is nothing to end.
        guard case .active(let count) = phase else { return }
        if userInput(since: count) { onSecondaryCancel?() } else { onSecondaryUp?() }
    }

    /// The hold delay is over: command mode, unless this is a shortcut. Other
    /// modifiers are judged now, not at key-down, so rolling off the dictation key
    /// onto the command key (both down for an instant) still counts as held alone,
    /// while Shift or Option held alongside does not.
    private func secondaryHoldElapsed(_ id: Int, watched: HotkeyChoice) {
        guard id == secondaryPressID, case .pending(let count) = secondaryPhase else { return }
        // After a main-thread stall this timer can run ahead of the key's own
        // release event, still queued. The live state knows: its flag clear means
        // the key is up, and that event will reset the phase when it arrives.
        guard !userInput(since: count), liveFlags() & watched.genericFlagMask != 0,
              lastFlags & Self.modifierDeviceMask & ~watched.deviceFlagMask == 0 else {
            ignoreSecondaryHold(id, watched: watched)
            return
        }
        secondaryPhase = .active(inputCount: count)
        onSecondaryDown?()
        schedule(Self.commandPollInterval) { [weak self] in self?.pollSecondaryHold(id, watched: watched) }
    }

    /// A key or click after the hold was announced (a slow shortcut): end it now
    /// rather than at release, so the mic and indicator don't linger. And a key
    /// that is up without its release event having arrived (Secure Input can
    /// swallow it) is released here, so a recording can't stay on.
    private func pollSecondaryHold(_ id: Int, watched: HotkeyChoice) {
        guard id == secondaryPressID, case .active(let count) = secondaryPhase else { return }
        guard liveFlags() & watched.genericFlagMask != 0 else {
            releaseSecondary()
            return
        }
        guard !userInput(since: count) else {
            ignoreSecondaryHold(id, watched: watched)
            onSecondaryCancel?()
            return
        }
        schedule(Self.commandPollInterval) { [weak self] in self?.pollSecondaryHold(id, watched: watched) }
    }

    /// The tap was disabled (timeout or user input) — we may have missed the release.
    /// Fail safe: end any in-flight hold so a recording can't remain stuck on.
    func handleTapDisabled() {
        if isHeld {
            isHeld = false
            onKeyUp?()
        }
        abandonSecondary()
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
}
