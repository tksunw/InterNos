// Internos — MVP core loop (PRD §12 milestone 2).
// Hold Right Option → record → release → transcribe on-device → insert at cursor.
// Hardcoded hotkey, no settings UI yet. Menu bar shell arrives in milestone 3.

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: DictationController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = DictationController()
        self.controller = controller
        Task { await controller.start() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // LSUIElement equivalent; no dock icon
app.run()
