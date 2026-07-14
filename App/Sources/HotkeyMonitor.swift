// Global dictation hotkey via a listenOnly CGEventTap.
// listenOnly needs Input Monitoring (not Accessibility) per Apple DTS — PRD §7.
// Watches a configurable modifier key (AppSettings.hotkey); down/up derived from
// the keycode + the device-specific modifier flag on flagsChanged events, so
// holding the matching left-side key cannot mask the watched right key's release.

import AppKit
import CoreGraphics

/// Controller-facing seam so lifecycle tests can drive hotkey events without a real event tap.
@MainActor
protocol HotkeyMonitoring: AnyObject {
    var onKeyDown: (() -> Void)? { get set }
    var onKeyUp: (() -> Void)? { get set }
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

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isHeld = false
    private var watched: HotkeyChoice = AppSettings.shared.hotkey

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

    /// Re-read the configured hotkey after a settings change. If the old key is mid-hold,
    /// end it (emitting keyUp so a recording can't run forever) before switching keys;
    /// the new key starts from a clean not-held state with no synthetic transition.
    func reloadSettings() {
        if isHeld {
            isHeld = false
            onKeyUp?()
        }
        watched = AppSettings.shared.hotkey
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
        let (held, event) = Self.transition(isHeld: isHeld, watched: watched, keyCode: keyCode, flags: flags)
        isHeld = held
        switch event {
        case .down: onKeyDown?()
        case .up: onKeyUp?()
        case nil: break
        }
    }

    /// The tap was disabled (timeout or user input) — we may have missed the release.
    /// Fail safe: end any in-flight hold so a recording can't remain stuck on.
    func handleTapDisabled() {
        if isHeld {
            isHeld = false
            onKeyUp?()
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
}
