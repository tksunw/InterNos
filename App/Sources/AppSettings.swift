// UserDefaults-backed settings (PRD F8: hotkey remap, input device, launch-at-login).
// Persistence stays minimal per PRD §7 — settings only, no transcript storage.

import CoreGraphics
import Foundation
import ServiceManagement

enum ActivationMode: String, CaseIterable, Identifiable {
    case pushToTalk
    case toggle
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pushToTalk: "Push to talk (hold)"
        case .toggle: "Toggle (tap to start/stop)"
        }
    }
}

/// The hotkey choices are modifier keys that can be held alone without typing side effects.
enum HotkeyChoice: Int64, CaseIterable, Identifiable {
    case rightOption = 61
    case rightCommand = 54
    case rightControl = 62
    case fn = 63
    var id: Int64 { rawValue }
    var label: String {
        switch self {
        case .rightOption: "Right Option (⌥)"
        case .rightCommand: "Right Command (⌘)"
        case .rightControl: "Right Control (⌃)"
        case .fn: "Fn / Globe"
        }
    }
    /// The generic CGEventFlags bit that indicates this modifier is down. Paired with the
    /// keycode check in HotkeyMonitor, this distinguishes down from up on flagsChanged.
    var flagMask: UInt64 {
        switch self {
        case .rightOption: CGEventFlags.maskAlternate.rawValue
        case .rightCommand: CGEventFlags.maskCommand.rawValue
        case .rightControl: CGEventFlags.maskControl.rawValue
        case .fn: CGEventFlags.maskSecondaryFn.rawValue
        }
    }
}

@MainActor
final class AppSettings {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let hotkey = "hotkeyKeyCode"
        static let mode = "activationMode"
        static let inputDeviceUID = "inputDeviceUID"
        static let playSounds = "playSounds"
    }

    var hotkey: HotkeyChoice {
        get { HotkeyChoice(rawValue: Int64(defaults.integer(forKey: Key.hotkey))) ?? .rightOption }
        set { defaults.set(Int(newValue.rawValue), forKey: Key.hotkey) }
    }

    var mode: ActivationMode {
        get { ActivationMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .pushToTalk }
        set { defaults.set(newValue.rawValue, forKey: Key.mode) }
    }

    /// nil = system default input device
    var inputDeviceUID: String? {
        get { defaults.string(forKey: Key.inputDeviceUID) }
        set { defaults.set(newValue, forKey: Key.inputDeviceUID) }
    }

    var playSounds: Bool {
        get { defaults.object(forKey: Key.playSounds) == nil ? true : defaults.bool(forKey: Key.playSounds) }
        set { defaults.set(newValue, forKey: Key.playSounds) }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Internos: launch-at-login change failed: \(error)")
            }
        }
    }
}
