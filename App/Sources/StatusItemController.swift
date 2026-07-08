// Menu bar presence (PRD F5/F9): state-driven status icon + menu.
// The app should "almost disappear when working correctly" — icon states are subtle,
// error state reverts to idle automatically.

import AppKit

enum AppState {
    case idle
    case recording
    case transcribing
    case error
    case disabled

    var symbolName: String {
        switch self {
        case .idle: "mic"
        case .recording: "mic.fill"
        case .transcribing: "waveform"
        case .error: "exclamationmark.triangle"
        case .disabled: "mic.slash"
        }
    }
}

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private var revertTimer: Timer?

    var onTogglePause: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenSetup: (() -> Void)?
    var isPaused = false {
        didSet {
            pauseItem.title = isPaused ? "Resume Dictation" : "Pause Dictation"
            setState(isPaused ? .disabled : .idle)
        }
    }

    private let pauseItem = NSMenuItem(title: "Pause Dictation", action: #selector(togglePause), keyEquivalent: "")

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        let menu = NSMenu()
        let hotkeyInfo = NSMenuItem(title: "Hold \(AppSettings.shared.hotkey.label) to dictate", action: nil, keyEquivalent: "")
        hotkeyInfo.isEnabled = false
        menu.addItem(hotkeyInfo)
        menu.addItem(.separator())
        pauseItem.target = self
        menu.addItem(pauseItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let setupItem = NSMenuItem(title: "Setup & Permissions…", action: #selector(openSetup), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Internos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        setState(.idle)
    }

    /// Refreshes the hotkey hint line after a settings change.
    func refreshHotkeyHint() {
        statusItem.menu?.item(at: 0)?.title = mode(AppSettings.shared.mode, hotkey: AppSettings.shared.hotkey)
    }

    private func mode(_ mode: ActivationMode, hotkey: HotkeyChoice) -> String {
        switch mode {
        case .pushToTalk: "Hold \(hotkey.label) to dictate"
        case .toggle: "Tap \(hotkey.label) to start/stop"
        }
    }

    func setState(_ state: AppState) {
        revertTimer?.invalidate()
        let image = NSImage(systemSymbolName: state.symbolName, accessibilityDescription: "Internos")
        image?.isTemplate = true
        statusItem.button?.image = image
        if state == .error {
            // Fail loud but briefly (PRD §9), then return to idle.
            revertTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.isPaused else { return }
                    self.setState(.idle)
                }
            }
        }
    }

    @objc private func togglePause() { onTogglePause?() }
    @objc private func checkForUpdates() { UpdateChecker.check() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openSetup() { onOpenSetup?() }
}
