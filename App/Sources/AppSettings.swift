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
    /// Device-specific CGEventFlags bit for this exact physical key (IOKit NX_DEVICE… masks,
    /// IOLLEvent.h). The generic masks (maskAlternate etc.) stay set while the matching
    /// left-side key is held, which would swallow the watched right key's release.
    var deviceFlagMask: UInt64 {
        switch self {
        case .rightOption: 0x0000_0040   // NX_DEVICERALTKEYMASK
        case .rightCommand: 0x0000_0010  // NX_DEVICERCMDKEYMASK
        case .rightControl: 0x0000_2000  // NX_DEVICERCTLKEYMASK
        case .fn: CGEventFlags.maskSecondaryFn.rawValue // Fn has no left/right variant
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
        static let checkUpdatesAtLaunch = "checkUpdatesAtLaunch"
        static let cleanupMode = "cleanupMode"
    }

    /// Default Off: smart cleanup is opt-in until it clears beta validation.
    var cleanupMode: CleanupMode {
        get { CleanupMode(rawValue: defaults.string(forKey: Key.cleanupMode) ?? "") ?? .off }
        set { defaults.set(newValue.rawValue, forKey: Key.cleanupMode) }
    }

    /// Default OFF: the launch check is the app's only automatic network call,
    /// so it must be an explicit opt-in (README privacy posture).
    var checkUpdatesAtLaunch: Bool {
        get { defaults.bool(forKey: Key.checkUpdatesAtLaunch) }
        set { defaults.set(newValue, forKey: Key.checkUpdatesAtLaunch) }
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
