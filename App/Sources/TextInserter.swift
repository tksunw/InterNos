// Clipboard-swap insertion: save pasteboard → set transcript → synthetic ⌘V → restore.
// Both insertion paths end in a synthesized keystroke, so BOTH are blocked by Secure
// Input (PRD F4a): preflight IsSecureEventInputEnabled() and fail loud, never silently.
// Posting the keystroke requires Accessibility.

import AppKit
import Carbon.HIToolbox

@MainActor
final class TextInserter {
    static func checkAccessibility(promptIfNeeded: Bool) -> Bool {
        if promptIfNeeded {
            // Literal key avoids the concurrency-unsafe global var kAXTrustedCheckOptionPrompt.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    /// Inserts `text` at the cursor of the frontmost app. Throws on Secure Input or missing permission.
    func insert(_ text: String) throws {
        guard !IsSecureEventInputEnabled() else {
            // A password field has focus, or a background app has Secure Input stuck on.
            throw InternosError.secureInputActive
        }
        guard Self.checkAccessibility(promptIfNeeded: false) else {
            throw InternosError.accessibilityNotGranted
        }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postCommandV()

        // Restore the previous clipboard after the paste lands. 300 ms is a compromise:
        // long enough for slow apps to read the pasteboard, short enough not to surprise.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Self.restore(pasteboard, items: saved)
        }
    }

    private func postCommandV() {
        let vKey = CGKeyCode(kVK_ANSI_V)
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        }
    }

    private static func restore(_ pasteboard: NSPasteboard, items: [[NSPasteboard.PasteboardType: Data]]) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        let restored: [NSPasteboardItem] = items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(restored)
    }
}
