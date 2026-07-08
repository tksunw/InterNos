// Permission status detection + prompting for the three TCC grants (PRD F7, §7).
// Silently-denied permissions are the #1 failure mode for this app class — each
// permission gets: a status check, a prompt trigger, and a System Settings deep link.

import AppKit
import AVFoundation
import CoreGraphics

enum PermissionState {
    case granted
    case denied      // explicitly denied or restricted — prompt won't reappear; deep link required
    case notAsked    // no TCC record yet — prompting will show the system dialog
}

@MainActor
enum PermissionsService {
    // MARK: - Microphone

    static var microphone: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notAsked
        @unknown default: .denied
        }
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - Input Monitoring (for the listenOnly CGEventTap hotkey)

    static var inputMonitoring: PermissionState {
        // CGPreflight only reports yes/no; TCC doesn't expose "never asked" here.
        CGPreflightListenEventAccess() ? .granted : .notAsked
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool {
        let granted = CGRequestListenEventAccess()
        if !granted {
            // CGRequestListenEventAccess alone doesn't reliably create the TCC record,
            // so the app never appears in the Input Monitoring pane and there's nothing
            // to toggle. An actual listenOnly tap attempt registers it every time.
            if let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
                callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
                userInfo: nil
            ) {
                CFMachPortInvalidate(tap)
            }
        }
        return granted
    }

    // MARK: - Accessibility (for synthetic ⌘V insertion)

    static var accessibility: PermissionState {
        AXIsProcessTrusted() ? .granted : .notAsked
    }

    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - System Settings deep links

    static func openSettings(pane: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        NSWorkspace.shared.open(url)
    }

    static func openMicrophoneSettings() { openSettings(pane: "Privacy_Microphone") }
    static func openInputMonitoringSettings() { openSettings(pane: "Privacy_ListenEvent") }
    static func openAccessibilitySettings() { openSettings(pane: "Privacy_Accessibility") }

    static var allGranted: Bool {
        microphone == .granted && inputMonitoring == .granted && accessibility == .granted
    }
}
