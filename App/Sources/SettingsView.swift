// SwiftUI settings window (PRD F8): hotkey, activation mode, input device, sounds, login item.

import SwiftUI

struct SettingsView: View {
    @State private var hotkey = AppSettings.shared.hotkey
    @State private var mode = AppSettings.shared.mode
    @State private var inputDeviceUID: String = AppSettings.shared.inputDeviceUID ?? ""
    @State private var playSounds = AppSettings.shared.playSounds
    @State private var launchAtLogin = AppSettings.shared.launchAtLogin
    @State private var devices = AudioDevices.inputDevices()

    var onChange: (() -> Void)?

    var body: some View {
        Form {
            Section {
                Picker("Dictation key", selection: $hotkey) {
                    ForEach(HotkeyChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                Picker("Activation", selection: $mode) {
                    ForEach(ActivationMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
            }
            Section {
                Picker("Microphone", selection: $inputDeviceUID) {
                    Text("System default").tag("")
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
            }
            Section {
                Toggle("Play sounds", isOn: $playSounds)
                Toggle("Launch at login", isOn: $launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize()
        .onChange(of: hotkey) { AppSettings.shared.hotkey = hotkey; onChange?() }
        .onChange(of: mode) { AppSettings.shared.mode = mode; onChange?() }
        .onChange(of: inputDeviceUID) {
            AppSettings.shared.inputDeviceUID = inputDeviceUID.isEmpty ? nil : inputDeviceUID
            onChange?()
        }
        .onChange(of: playSounds) { AppSettings.shared.playSounds = playSounds }
        .onChange(of: launchAtLogin) { AppSettings.shared.launchAtLogin = launchAtLogin }
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(onChange: @escaping () -> Void) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let view = SettingsView(onChange: onChange)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Internos Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
