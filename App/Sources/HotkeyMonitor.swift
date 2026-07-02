// Global push-to-talk hotkey via a listenOnly CGEventTap.
// listenOnly needs Input Monitoring (not Accessibility) per Apple DTS — PRD §7.
// Hardcoded for MVP: hold Right Option (kVK_RightOption = 61).

import AppKit
import CoreGraphics

@MainActor
final class HotkeyMonitor {
    static let rightOptionKeyCode: Int64 = 61

    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isHeld = false

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
                    let optionDown = event.flags.contains(.maskAlternate)
                    MainActor.assumeIsolated { monitor.handleFlagsChanged(keyCode: keyCode, optionDown: optionDown) }
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

    private func handleFlagsChanged(keyCode: Int64, optionDown: Bool) {
        guard keyCode == Self.rightOptionKeyCode else { return }
        if optionDown && !isHeld {
            isHeld = true
            onKeyDown?()
        } else if !optionDown && isHeld {
            isHeld = false
            onKeyUp?()
        }
    }

    private func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
}
