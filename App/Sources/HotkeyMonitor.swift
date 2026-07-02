// Global dictation hotkey via a listenOnly CGEventTap.
// listenOnly needs Input Monitoring (not Accessibility) per Apple DTS — PRD §7.
// Watches a configurable modifier key (AppSettings.hotkey); down/up derived from
// the keycode + generic modifier flag on flagsChanged events.

import AppKit
import CoreGraphics

@MainActor
final class HotkeyMonitor {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isHeld = false
    private var watched: HotkeyChoice = AppSettings.shared.hotkey

    /// Re-read the configured hotkey after a settings change.
    func reloadSettings() {
        watched = AppSettings.shared.hotkey
        isHeld = false
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
                    MainActor.assumeIsolated { monitor.reenable() }
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

    private func handleFlagsChanged(keyCode: Int64, flags: UInt64) {
        guard keyCode == watched.rawValue else { return }
        let down = flags & watched.flagMask != 0
        if down && !isHeld {
            isHeld = true
            onKeyDown?()
        } else if !down && isHeld {
            isHeld = false
            onKeyUp?()
        }
    }

    private func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
}
