// Text insertion, two paths (v2):
//   1. Accessibility-direct: set kAXSelectedTextAttribute on the focused element —
//      inserts at the cursor (or replaces the selection) WITHOUT touching the
//      pasteboard. Preferred: no clipboard exposure at all.
//   2. Clipboard swap fallback: save pasteboard → set transcript → synthetic ⌘V →
//      conditional restore (IR-002: the snapshot goes back only while the pasteboard
//      still holds our injected transcript; anything the user copies wins).
// Secure Input blocks both paths by policy (PRD F4a): preflight
// IsSecureEventInputEnabled() and fail loud, never silently. Both need Accessibility.

import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum InsertionMethod {
    case accessibility
    case clipboard
}

/// Controller-facing seam so lifecycle tests can observe insertions deterministically.
@MainActor
protocol TextInserting: AnyObject {
    /// Inserts `text` at the cursor of the frontmost app, but only if the app with
    /// process id `target` is still frontmost. Throws on Secure Input, missing
    /// Accessibility, a changed/missing target, or paste-event construction failure.
    /// Returns which path delivered the text.
    @discardableResult
    func insert(_ text: String, target: pid_t?) throws -> InsertionMethod

    /// Deletes the last `characterCount` characters at the cursor of `target` by
    /// synthesizing backspaces ("scratch that", v2). Same preflight rules as insert.
    func deleteBackward(_ characterCount: Int, target: pid_t?) throws

    /// Leaves `text` on the pasteboard without injecting it (failure paths: the
    /// transcript must never be silently lost). Cancels any pending restore that
    /// would otherwise clobber it.
    func preserveOnClipboard(_ text: String)

    /// Called with the number of key presses about to be posted (one for a
    /// clipboard paste, one per backspace), so whoever watches keyboard activity
    /// can tell them from the user's. Before, not after: the watcher needs its
    /// own reading from before the first of them lands. Called again with the
    /// negated count if posting then fails.
    var willPostKeyPresses: ((Int) -> Void)? { get set }

    /// Returns once the target app has had time to consume the synthetic key
    /// events of the previous insertion or deletion. Awaited between chained
    /// operations: a ⌘V or a run of backspaces is only queued when the call
    /// returns, and the next one rewrites the pasteboard or inserts directly.
    func settlePendingEvents() async
}

/// The few NSPasteboard operations the inserter needs, as a seam for tests.
@MainActor
protocol PasteboardProviding: AnyObject {
    var changeCount: Int { get }
    func snapshotItems() -> [[NSPasteboard.PasteboardType: Data]]
    func clear()
    func write(_ string: String, forType type: NSPasteboard.PasteboardType)
    func writeItems(_ items: [[NSPasteboard.PasteboardType: Data]])
}

extension NSPasteboard.PasteboardType {
    // nspasteboard.org conventions: well-behaved clipboard managers skip transient
    // entries and treat concealed ones as sensitive. Best effort only — not every
    // clipboard service honors them (see PRIVACY.md).
    static let transientMarker = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let concealedMarker = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
}

extension NSPasteboard: PasteboardProviding {
    func snapshotItems() -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if copy[type] == nil, let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        }
    }

    func clear() { clearContents() }

    func write(_ string: String, forType type: NSPasteboard.PasteboardType) {
        setString(string, forType: type)
    }

    func writeItems(_ items: [[NSPasteboard.PasteboardType: Data]]) {
        let restored: [NSPasteboardItem] = items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        writeObjects(restored)
    }
}

@MainActor
final class TextInserter: TextInserting {
    private struct PendingRestore {
        let id: Int
        let items: [[NSPasteboard.PasteboardType: Data]]
        /// Pasteboard change count right after we wrote the transcript. If the count
        /// moved since, someone else owns the pasteboard and we must not touch it.
        let injectedChangeCount: Int
        let work: DispatchWorkItem
    }

    /// How long a synthetic ⌘V is given to be consumed, for the clipboard restore
    /// and for the next chained insertion alike. 300 ms is a compromise: long enough
    /// for slow apps to read the pasteboard, short enough not to surprise.
    nonisolated static let pasteWindowMilliseconds = 300

    var willPostKeyPresses: ((Int) -> Void)?

    private var pendingRestore: PendingRestore?
    private var restoreID = 0
    /// When the app is assumed to have handled the last synthetic key events.
    private var eventsSettleAt: ContinuousClock.Instant?

    private let pasteboard: any PasteboardProviding
    private let pasteSettleTime: Duration
    private let sleep: (Duration) async -> Void
    private let scheduleRestore: (DispatchWorkItem) -> Void
    private let secureInputActive: () -> Bool
    private let accessibilityGranted: () -> Bool
    private let frontmostPID: () -> pid_t?
    private let axInsertionUnreliable: (pid_t) -> Bool
    private let axInsert: (String, pid_t) -> Bool
    private let postPaste: () throws -> Void
    private let postBackspaces: (Int) throws -> Void

    init(
        pasteboard: any PasteboardProviding = NSPasteboard.general,
        // How long the next chained insertion waits for this paste to land.
        pasteSettleTime: Duration = .milliseconds(TextInserter.pasteWindowMilliseconds),
        sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        // Restore the previous clipboard after the paste lands.
        scheduleRestore: @escaping (DispatchWorkItem) -> Void = {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(TextInserter.pasteWindowMilliseconds), execute: $0)
        },
        secureInputActive: @escaping () -> Bool = { IsSecureEventInputEnabled() },
        accessibilityGranted: @escaping () -> Bool = { TextInserter.checkAccessibility(promptIfNeeded: false) },
        frontmostPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        axInsertionUnreliable: @escaping (pid_t) -> Bool = { TextInserter.isChromiumApp($0) },
        axInsert: @escaping (String, pid_t) -> Bool = { TextInserter.accessibilityInsert($0, targetPID: $1) },
        postPaste: @escaping () throws -> Void = { try TextInserter.postCommandV() },
        postBackspaces: @escaping (Int) throws -> Void = { try TextInserter.postBackspaces($0) }
    ) {
        self.pasteboard = pasteboard
        self.pasteSettleTime = pasteSettleTime
        self.sleep = sleep
        self.scheduleRestore = scheduleRestore
        self.secureInputActive = secureInputActive
        self.accessibilityGranted = accessibilityGranted
        self.frontmostPID = frontmostPID
        self.axInsertionUnreliable = axInsertionUnreliable
        self.axInsert = axInsert
        self.postPaste = postPaste
        self.postBackspaces = postBackspaces
    }

    static func checkAccessibility(promptIfNeeded: Bool) -> Bool {
        if promptIfNeeded {
            // Literal key avoids the concurrency-unsafe global var kAXTrustedCheckOptionPrompt.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    @discardableResult
    func insert(_ text: String, target: pid_t?) throws -> InsertionMethod {
        guard !secureInputActive() else {
            // A password field has focus, or a background app has Secure Input stuck on.
            throw InternosError.secureInputActive
        }
        guard accessibilityGranted() else {
            throw InternosError.accessibilityNotGranted
        }
        // The app that owned the cursor when recording stopped must still be frontmost
        // (IR-003); otherwise the paste would land in whatever the user switched to.
        // A missing or exited target counts as a mismatch.
        guard let target, let current = frontmostPID(), current == target else {
            throw InternosError.insertionTargetChanged
        }

        // Preferred path: Accessibility-direct insertion. The transcript never touches
        // the pasteboard, so Universal Clipboard and clipboard managers never see it.
        // An AX success report is trusted (no fallback paste — that would risk a
        // double insertion); the volatile recovery buffer covers a lying app.
        // Known liars (Chromium reports a successful selected-text write into web
        // content without inserting anything) never get offered the AX path.
        if !axInsertionUnreliable(target), axInsert(text, target) {
            return .accessibility
        }

        flushPendingRestore()
        let saved = pasteboard.snapshotItems()
        writeTranscript(text)
        let injected = pasteboard.changeCount

        // Throws when a CGEvent can't be constructed (IR-009). The transcript stays on
        // the pasteboard and no restore is scheduled over it, so nothing is lost.
        try posting(1) { try postPaste() }
        eventsSettleAt = .now + pasteSettleTime

        restoreID += 1
        let id = restoreID
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.performPendingRestore(id: id) }
        }
        pendingRestore = PendingRestore(id: id, items: saved, injectedChangeCount: injected, work: work)
        scheduleRestore(work)
        return .clipboard
    }

    func deleteBackward(_ characterCount: Int, target: pid_t?) throws {
        guard characterCount > 0 else { return }
        guard !secureInputActive() else { throw InternosError.secureInputActive }
        guard accessibilityGranted() else { throw InternosError.accessibilityNotGranted }
        guard let target, let current = frontmostPID(), current == target else {
            throw InternosError.insertionTargetChanged
        }
        try posting(characterCount) { try postBackspaces(characterCount) }
        // ponytail: 1 ms per backspace on top of the paste window is a guess at how
        // fast an app drains key events; raise it if a scratch eats the next insertion.
        eventsSettleAt = .now + pasteSettleTime + .milliseconds(characterCount)
    }

    /// Synthetic key events are only queued when `insert` or `deleteBackward`
    /// returns; the app handles them when it gets around to it. An insertion
    /// chained straight behind (two utterances finalizing back to back) would
    /// otherwise swap the pasteboard under the first paste, which then pastes the
    /// second transcript, or land ahead of backspaces that then eat into it.
    func settlePendingEvents() async {
        guard let until = eventsSettleAt else { return }
        let remaining = until - .now
        if remaining > .zero { await sleep(remaining) }
    }

    private func posting(_ keyPresses: Int, _ post: () throws -> Void) throws {
        willPostKeyPresses?(keyPresses)
        do {
            try post()
        } catch {
            willPostKeyPresses?(-keyPresses)
            throw error
        }
    }

    func preserveOnClipboard(_ text: String) {
        // Cancel any in-flight restore first: it would wipe the preserved transcript.
        pendingRestore?.work.cancel()
        pendingRestore = nil
        writeTranscript(text)
    }

    private func writeTranscript(_ text: String) {
        pasteboard.clear()
        pasteboard.write(text, forType: .string)
        pasteboard.write("", forType: .transientMarker)
        pasteboard.write("", forType: .concealedMarker)
    }

    /// A dictation within the restore window must not snapshot the injected transcript
    /// as the "user's clipboard": settle the pending restore first. The snapshot goes
    /// back only if the pasteboard still holds our transcript; a user copy made during
    /// the window is left untouched and the stale snapshot is discarded.
    private func flushPendingRestore() {
        guard let pending = pendingRestore else { return }
        pending.work.cancel()
        pendingRestore = nil
        if pasteboard.changeCount == pending.injectedChangeCount {
            restore(pending.items)
        }
    }

    private func performPendingRestore(id: Int) {
        // The id check makes a superseded work item inert even if it somehow runs
        // after cancellation: it must not clear a newer insertion's pasteboard.
        guard let pending = pendingRestore, pending.id == id else { return }
        pendingRestore = nil
        guard pasteboard.changeCount == pending.injectedChangeCount else { return }
        restore(pending.items)
    }

    private func restore(_ items: [[NSPasteboard.PasteboardType: Data]]) {
        // Always clear: if the clipboard was empty before dictation, leaving the
        // transcript on it would persist it (and feed clipboard history/sync).
        pasteboard.clear()
        guard !items.isEmpty else { return }
        pasteboard.writeItems(items)
    }

    /// A key press with exactly `flags` as its modifiers. The flags are always set
    /// explicitly: an event built from the session state otherwise inherits whatever
    /// the user is physically holding (the dictation key, re-pressed for the next
    /// utterance), which turns Delete into Option-Delete or ⌘-Delete.
    static func keyPress(
        _ key: CGKeyCode, flags: CGEventFlags, source: CGEventSource?
    ) throws -> (down: CGEvent, up: CGEvent) {
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            throw InternosError.pasteEventFailed
        }
        keyDown.flags = flags
        keyUp.flags = flags
        return (keyDown, keyUp)
    }

    static func postCommandV() throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        let press = try keyPress(CGKeyCode(kVK_ANSI_V), flags: .maskCommand, source: source)
        press.down.post(tap: .cghidEventTap)
        press.up.post(tap: .cghidEventTap)
    }

    /// All or nothing: every event is built before the first is posted, so a
    /// construction failure never leaves half a deletion behind.
    static func postBackspaces(_ count: Int) throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        let presses = try (0..<count).map { _ in try keyPress(CGKeyCode(kVK_Delete), flags: [], source: source) }
        for press in presses {
            press.down.post(tap: .cghidEventTap)
            press.up.post(tap: .cghidEventTap)
        }
    }

    /// The focused element of a specific app, via its per-app accessibility element.
    /// The systemwide kAXFocusedUIElementAttribute query fails with cannotComplete
    /// (-25204) on macOS 26 even for trusted processes; the per-app route works
    /// (verified empirically, v2 beta-2). A short messaging timeout keeps a stuck
    /// target app from stalling the event-tap callback that triggers these reads.
    private static func focusedElement(ofApplication pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(focusedRef as AnyObject, to: AXUIElement.self)
    }

    /// Chromium's AX layer accepts a kAXSelectedTextAttribute write into web
    /// content and reports success without inserting anything. Since an AX success
    /// is trusted with no fallback, every Chromium host must be routed to the
    /// clipboard swap up front — Electron apps (Claude Desktop, Slack, VS Code…),
    /// CEF apps (Spotify…), and Chromium browsers (Chrome, Edge, Brave, Arc…).
    /// Framework sniff rather than a bundle-ID list so every such app is covered,
    /// present and future. Deliberately uncached: the sniff measures well under a
    /// millisecond, and a cached "native" answer from a transient readdir failure
    /// (mid-update swap, unreadable volume) would disable this gate until restart.
    static func isChromiumApp(_ pid: pid_t) -> Bool {
        guard let bundleURL = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
        return bundleContainsChromiumFramework(bundleURL)
    }

    private static func bundleContainsChromiumFramework(_ bundleURL: URL) -> Bool {
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks")
        let fm = FileManager.default
        // Fixed framework names first: Electron and CEF ship under stable names.
        for known in ["Electron Framework.framework", "Chromium Embedded Framework.framework"]
        where fm.fileExists(atPath: frameworks.appendingPathComponent(known).path) {
            return true
        }
        // Chromium browsers ship a per-product "<Name> Framework.framework"
        // (Google Chrome, Microsoft Edge, Brave Browser…). Identify those by the
        // graphics libraries Chromium bundles: SwiftShader's Vulkan ICD (all
        // current Chromium, verified Chrome 152/Edge/Brave) or ANGLE's libEGL
        // (older Chromium bases that predate the SwiftShader move).
        guard let entries = try? fm.contentsOfDirectory(atPath: frameworks.path) else { return false }
        // Top-level Libraries is a symlink to Versions/Current/Libraries in every
        // Chromium framework and fileExists follows it, so one spelling suffices.
        let markers = ["Libraries/libvk_swiftshader.dylib", "Libraries/libEGL.dylib"]
        for entry in entries where entry.hasSuffix(" Framework.framework") {
            let framework = frameworks.appendingPathComponent(entry)
            for marker in markers
            where fm.fileExists(atPath: framework.appendingPathComponent(marker).path) {
                return true
            }
        }
        return false
    }

    /// What the focused element reports about its text before/after an AX write.
    /// Either field is nil when the element doesn't expose that attribute.
    struct AXTextSnapshot: Equatable {
        var characterCount: Int?
        var selectedRange: (location: Int, length: Int)?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.characterCount == rhs.characterCount
                && lhs.selectedRange?.location == rhs.selectedRange?.location
                && lhs.selectedRange?.length == rhs.selectedRange?.length
        }

        var isEmpty: Bool { characterCount == nil && selectedRange == nil }
    }

    /// A non-empty write that took effect always moves something we can read:
    /// the caret lands after the inserted text (location changes, or a selection
    /// collapses) and the count changes unless it replaced same-length text.
    /// So "everything readable is identical" means the app dropped the write
    /// while reporting success. Nothing readable is inconclusive: trust the
    /// success rather than risk a clipboard paste on top of a real insertion.
    static func axWriteTookEffect(before: AXTextSnapshot, after: AXTextSnapshot) -> Bool {
        before.isEmpty || before != after
    }

    private static func textSnapshot(of element: AXUIElement) -> AXTextSnapshot {
        var snapshot = AXTextSnapshot()
        var countRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success,
           let count = countRef as? Int {
            snapshot.characterCount = count
        }
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(unsafeDowncast(rangeRef as AnyObject, to: AXValue.self), .cfRange, &range) {
                snapshot.selectedRange = (range.location, range.length)
            }
        }
        return snapshot
    }

    /// Accessibility-direct insertion: sets kAXSelectedTextAttribute on the target
    /// app's focused element, which inserts at the caret or replaces the current
    /// selection. Returns false when the element doesn't support settable selected
    /// text (web areas in some apps, terminals), or when the app reported success
    /// for a write it dropped — the caller falls back to the clipboard swap.
    ///
    /// The read-back exists because Chromium's AX layer returns success for a
    /// kAXSelectedTextAttribute write into web content without inserting anything
    /// (reproduced 2026-09-02, Chrome 152 textarea: value, count and range all
    /// unchanged after a "successful" set). Native text views (TextEdit, Chrome's
    /// own omnibox) update count and caret synchronously within the set call, so
    /// an unchanged snapshot is a dropped write, not a race. `isChromiumApp` stays
    /// as the fast path that skips the doomed attempt; this is the net for hosts
    /// the sniff can't see (Chromium under Contents/Helpers, PWA shims…).
    static func accessibilityInsert(_ text: String, targetPID: pid_t) -> Bool {
        guard !text.isEmpty, let element = focusedElement(ofApplication: targetPID) else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            return false
        }
        let before = textSnapshot(of: element)
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success else {
            return false
        }
        let tookEffect = axWriteTookEffect(before: before, after: textSnapshot(of: element))
        if !tookEffect {
            NSLog("Internos: AX insertion reported success but the element did not change — falling back to clipboard")
        }
        return tookEffect
    }

    /// Reads the selected text of the frontmost app's focused element (command mode).
    /// Called only on an explicit user invocation — never for ambient context.
    /// Returns nil when nothing is selected or the element doesn't expose a selection.
    static func accessibilitySelectedText() -> (text: String, pid: pid_t)? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontmost.processIdentifier
        guard let element = focusedElement(ofApplication: pid) else { return nil }
        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedRef) == .success,
              let selected = selectedRef as? String, !selected.isEmpty else {
            return nil
        }
        return (selected, pid)
    }
}
