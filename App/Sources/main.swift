// Entry point. Menu-bar-only app (accessory activation policy, LSUIElement):
// AppDelegate builds the one DictationController, which wires the hotkey,
// recorder, engine, pipeline, inserter and UI together and runs setup.
// DictationController.current exists for App Intents, which the system runs
// in-process with no route to this delegate.

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: DictationController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = DictationController(customizations: CustomizationStore())
        self.controller = controller
        DictationController.current = controller
        Task { await controller.start() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // LSUIElement equivalent; no dock icon
app.run()
