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

    private func genericMask(for choice: HotkeyChoice) -> UInt64 {
        switch choice {
        case .rightOption: CGEventFlags.maskAlternate.rawValue
        case .rightCommand: CGEventFlags.maskCommand.rawValue
        case .rightControl: CGEventFlags.maskControl.rawValue
        case .fn: CGEventFlags.maskSecondaryFn.rawValue
        }
    }

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
            let generic = genericMask(for: choice)
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
            flags: genericMask(for: choice) | choice.deviceFlagMask)
        XCTAssertEqual(event, .down)
        XCTAssertTrue(held)
        (held, event) = HotkeyMonitor.transition(
            isHeld: held, watched: choice, keyCode: choice.rawValue, flags: 0)
        XCTAssertEqual(event, .up)
        XCTAssertFalse(held)
    }

    func testDuplicateFlagsChangedProducesNoDuplicateCallbacks() {
        let choice = HotkeyChoice.rightCommand
        let downFlags = genericMask(for: choice) | choice.deviceFlagMask
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
            flags: genericMask(for: choice) | Self.leftOptionBit)
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
            flags: genericMask(for: choice) | choice.deviceFlagMask)
        XCTAssertEqual(downs, 1)

        monitor.handleTapDisabled()
        XCTAssertEqual(ups, 1, "a disabled tap must fail safe by ending the hold")

        // A later release event for the already-cleared key is a no-op.
        monitor.handleFlagsChanged(keyCode: choice.rawValue, flags: 0)
        XCTAssertEqual(ups, 1)
    }

    /// The command key (v2) is watched independently of the dictation key.
    func testSecondaryKeyEmitsIndependentTransitions() {
        AppSettings.shared.hotkey = .rightOption
        AppSettings.shared.commandHotkey = .rightCommand
        let monitor = HotkeyMonitor()
        monitor.reloadSettings()
        var primary = 0
        var secondaryDowns = 0
        var secondaryUps = 0
        monitor.onKeyDown = { primary += 1 }
        monitor.onSecondaryDown = { secondaryDowns += 1 }
        monitor.onSecondaryUp = { secondaryUps += 1 }

        let cmd = HotkeyChoice.rightCommand
        monitor.handleFlagsChanged(
            keyCode: cmd.rawValue, flags: genericMask(for: cmd) | cmd.deviceFlagMask)
        monitor.handleFlagsChanged(keyCode: cmd.rawValue, flags: 0)

        XCTAssertEqual(primary, 0, "the dictation key must not fire for the command key")
        XCTAssertEqual(secondaryDowns, 1)
        XCTAssertEqual(secondaryUps, 1)
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
            keyCode: opt.rawValue, flags: genericMask(for: opt) | opt.deviceFlagMask)

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
            flags: genericMask(for: .rightOption) | HotkeyChoice.rightOption.deviceFlagMask)
        XCTAssertEqual(downs, 1)

        AppSettings.shared.hotkey = .rightCommand
        monitor.reloadSettings()
        XCTAssertEqual(ups, 1, "the in-flight hold on the old key must end")

        // The new key works normally afterwards.
        monitor.handleFlagsChanged(
            keyCode: HotkeyChoice.rightCommand.rawValue,
            flags: genericMask(for: .rightCommand) | HotkeyChoice.rightCommand.deviceFlagMask)
        XCTAssertEqual(downs, 2)
        XCTAssertEqual(ups, 1)

        AppSettings.shared.hotkey = .rightOption // restore default for other tests
    }
}
