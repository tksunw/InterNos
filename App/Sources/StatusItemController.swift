// Menu bar presence (PRD F5/F9): state-driven status icon + menu.
// The app should "almost disappear when working correctly" — icon states are subtle,
// error state reverts to idle automatically.

import AppKit

enum AppState {
    case idle
    case recording
    case transcribing
    /// Transient utterance error — auto-reverts to idle.
    case error
    /// Persistent setup failure (model or event tap) — stays until a successful retry,
    /// so a broken pipeline can never look ready (IR-007).
    case setupFailed
    case disabled

    // Idle/disabled use waveform.and.mic — the same glyph as the app icon (make-icon.swift),
    // so the menu bar presence reads as Internos, not a generic mic. Transient states keep
    // symbols that say "live right now"; error stays the universal warning.
    var symbolName: String {
        switch self {
        case .idle: "waveform.and.mic"
        case .recording: "mic.fill"
        case .transcribing: "waveform"
        case .error, .setupFailed: "exclamationmark.triangle"
        case .disabled: "waveform.slash"
        }
    }

    /// Only transient utterance errors revert on a timer; a setup failure must remain
    /// visible until a retry actually succeeds.
    var autoRevertsToIdle: Bool { self == .error }
}

/// Controller-facing seam so lifecycle tests can observe menu-bar state without NSStatusBar.
@MainActor
protocol StatusPresenting: AnyObject {
    var onTogglePause: (() -> Void)? { get set }
    var onOpenSettings: (() -> Void)? { get set }
    var onOpenSetup: (() -> Void)? { get set }
    var onCopyLast: (() -> Void)? { get set }
    var onCopyLastRaw: (() -> Void)? { get set }
    var onPasteLast: (() -> Void)? { get set }
    var onClearLast: (() -> Void)? { get set }
    /// Queried when the menu opens to enable/hide the recovery items.
    var recoveryState: (() -> RecoveryMenuState)? { get set }
    var isPaused: Bool { get set }
    func setState(_ state: AppState)
    func refreshHotkeyHint()
}

@MainActor
final class StatusItemController: NSObject, StatusPresenting {
    private let statusItem: NSStatusItem
    private var revertTimer: Timer?

    var onTogglePause: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenSetup: (() -> Void)?
    var onCopyLast: (() -> Void)?
    var onCopyLastRaw: (() -> Void)?
    var onPasteLast: (() -> Void)?
    var onClearLast: (() -> Void)?
    var recoveryState: (() -> RecoveryMenuState)?
    // Title only: the icon state is owned by DictationController, which knows whether
    // resume should land on idle or on a persistent setup failure (IR-004/IR-007).
    var isPaused = false {
        didSet { pauseItem.title = isPaused ? "Resume Dictation" : "Pause Dictation" }
    }

    private let pauseItem = NSMenuItem(title: "Pause Dictation", action: #selector(togglePause), keyEquivalent: "")
    private let copyLastItem = NSMenuItem(title: "Copy Last Dictation", action: #selector(copyLast), keyEquivalent: "")
    private let copyLastRawItem = NSMenuItem(title: "Copy Last Raw Dictation", action: #selector(copyLastRaw), keyEquivalent: "")
    private let pasteLastItem = NSMenuItem(title: "Paste Last Dictation", action: #selector(pasteLast), keyEquivalent: "")
    private let clearLastItem = NSMenuItem(title: "Clear Last Dictation", action: #selector(clearLast), keyEquivalent: "")

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
        menu.addItem(.separator())
        for item in [copyLastItem, copyLastRawItem, pasteLastItem, clearLastItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
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
        let aboutItem = NSMenuItem(title: "About Internos", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(NSMenuItem(title: "Quit Internos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
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
        if state.autoRevertsToIdle {
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
    @objc private func copyLast() { onCopyLast?() }
    @objc private func copyLastRaw() { onCopyLastRaw?() }
    @objc private func pasteLast() { onPasteLast?() }
    @objc private func clearLast() { onClearLast?() }
    @objc private func checkForUpdates() { UpdateChecker.check() }
    @objc private func showAbout() {
        // Menu-bar-only app: without activate the panel opens behind the frontmost app.
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func openSetup() { onOpenSetup?() }
}

extension StatusItemController: NSMenuDelegate, NSMenuItemValidation {
    func menuWillOpen(_ menu: NSMenu) {
        // Raw copy exists only when smart cleanup actually changed the text.
        copyLastRawItem.isHidden = !(recoveryState?().hasDistinctRaw ?? false)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let state = recoveryState?() ?? RecoveryMenuState()
        switch menuItem.action {
        case #selector(copyLast), #selector(pasteLast), #selector(clearLast):
            return state.hasTranscript
        case #selector(copyLastRaw):
            return state.hasDistinctRaw
        default:
            return true
        }
    }
}
