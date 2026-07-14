// Feature 2: volatile last-transcript recovery — store semantics plus the
// controller-level copy/paste/clear behavior, all against fakes.

import AppKit
import XCTest
@testable import Internos

@MainActor
final class VolatileTranscriptStoreTests: XCTestCase {
    func testRecordAndClear() {
        let store = VolatileTranscriptStore()
        XCTAssertNil(store.current)

        store.record(raw: "raw one", final: "final one", cleanupApplied: true)
        XCTAssertEqual(store.current?.raw, "raw one")
        XCTAssertEqual(store.current?.final, "final one")
        XCTAssertEqual(store.current?.cleanupApplied, true)

        store.clear()
        XCTAssertNil(store.current)
    }

    func testEmptyFinalNeverReplacesValidValue() {
        let store = VolatileTranscriptStore()
        store.record(raw: "raw", final: "kept", cleanupApplied: false)
        store.record(raw: "whatever", final: "", cleanupApplied: false)
        XCTAssertEqual(store.current?.final, "kept")
    }

    func testNextNonEmptyTranscriptReplaces() {
        let store = VolatileTranscriptStore()
        store.record(raw: "a", final: "first", cleanupApplied: false)
        store.record(raw: "b", final: "second", cleanupApplied: false)
        XCTAssertEqual(store.current?.final, "second")
    }
}

@MainActor
final class RecoveryActionsTests: XCTestCase {
    private var hotkey = FakeHotkey()
    private var recorder = FakeRecorder()
    private var engine = FakeEngine()
    private var inserter = FakeInserter()
    private var status = FakeStatus()
    private var indicator = FakeIndicator()
    private var sounds: [String] = []

    private func makeReadyController() async -> DictationController {
        hotkey = FakeHotkey()
        recorder = FakeRecorder()
        engine = FakeEngine()
        inserter = FakeInserter()
        status = FakeStatus()
        indicator = FakeIndicator()
        sounds = []
        let controller = DictationController(
            hotkey: hotkey,
            recorder: recorder,
            engine: engine,
            inserter: inserter,
            statusItem: status,
            indicator: indicator,
            playSound: { [self] name in sounds.append(name) },
            frontmostPID: { 42 },
            onboardingPresenter: { _, _ in }
        )
        await controller.initializePipeline()
        return controller
    }

    private func dictate(_ controller: DictationController, text: String, index: Int = 1) async {
        controller.beginUtterance()
        await waitUntil { self.engine.pendingCount == 1 }
        controller.endUtterance()
        engine.complete(index, with: .success(text))
        await waitUntil { controller.state == .idle && self.engine.pendingCount == 0 }
    }

    func testSuccessfulDictationEnablesRecovery() async {
        let controller = await makeReadyController()
        await dictate(controller, text: "hello world")
        await controller.start() // wires the menu closures against the fakes
        let state = status.recoveryState?()
        XCTAssertEqual(state, RecoveryMenuState(hasTranscript: true, hasDistinctRaw: false))
        XCTAssertEqual(controller.volatileStore.current?.final, "hello world")
    }

    func testCopyLastUsesIntentionalClipboardWrite() async {
        let controller = await makeReadyController()
        await dictate(controller, text: "copy me")
        await controller.start()
        status.onCopyLast?()
        XCTAssertEqual(inserter.preserved, ["copy me"], "copy goes through the marker-tagged clipboard write")
    }

    func testPasteLastDoesNotReprocessAndKeepsValue() async {
        let controller = await makeReadyController()
        // "new line" would render differently if reprocessed; store final directly.
        controller.volatileStore.record(raw: "say new line now", final: "say\nnow", cleanupApplied: false)
        controller.lastExternalFrontmostPID = 42

        controller.pasteLastDictation()
        await waitUntil { self.inserter.insertions.count == 1 }

        XCTAssertEqual(inserter.insertions[0].text, "say\nnow", "the stored final value is inserted verbatim")
        XCTAssertEqual(inserter.insertions[0].target, 42, "the tracked external app is the target")
        XCTAssertNotNil(controller.volatileStore.current, "paste must not clear the stored transcript")
    }

    func testPasteLastFailureKeepsTranscriptAndShowsError() async {
        let controller = await makeReadyController()
        controller.volatileStore.record(raw: "r", final: "keep me", cleanupApplied: false)
        controller.lastExternalFrontmostPID = 42
        inserter.errorToThrow = InternosError.secureInputActive

        controller.pasteLastDictation()
        await waitUntil { self.inserter.preserved.count == 1 }

        XCTAssertTrue(inserter.insertions.isEmpty)
        XCTAssertEqual(inserter.preserved, ["keep me"])
        XCTAssertEqual(status.states.last, .error)
        XCTAssertEqual(controller.volatileStore.current?.final, "keep me")
    }

    func testInsertionFailureStillRecordsTranscriptForRecovery() async {
        let controller = await makeReadyController()
        inserter.errorToThrow = InternosError.insertionTargetChanged

        controller.beginUtterance()
        controller.endUtterance()
        await waitUntil { self.engine.pendingCount == 1 }
        engine.complete(1, with: .success("recover me"))
        await waitUntil { self.inserter.preserved.count == 1 }

        XCTAssertEqual(controller.volatileStore.current?.final, "recover me",
                       "a target mismatch keeps the value recoverable")
        XCTAssertEqual(controller.volatileStore.current?.raw, "recover me")
    }

    func testEmptyTranscriptionDoesNotEraseStoredValue() async {
        let controller = await makeReadyController()
        controller.volatileStore.record(raw: "r", final: "still here", cleanupApplied: false)

        controller.beginUtterance()
        controller.endUtterance()
        await waitUntil { self.engine.pendingCount == 1 }
        engine.complete(1, with: .success(""))
        await waitUntil { self.status.states.last == .error }

        XCTAssertEqual(controller.volatileStore.current?.final, "still here")
    }

    func testRawCopyOnlyOfferedWhenCleanupChangedText() async {
        let controller = await makeReadyController()
        await controller.start()
        controller.volatileStore.record(raw: "um hello", final: "hello", cleanupApplied: true)
        XCTAssertEqual(status.recoveryState?(),
                       RecoveryMenuState(hasTranscript: true, hasDistinctRaw: true))

        status.onCopyLastRaw?()
        XCTAssertEqual(inserter.preserved.last, "um hello")

        controller.volatileStore.record(raw: "same", final: "same", cleanupApplied: true)
        XCTAssertEqual(status.recoveryState?(),
                       RecoveryMenuState(hasTranscript: true, hasDistinctRaw: false),
                       "identical raw and final hides the raw copy action")
    }

    func testClearRemovesValueImmediately() async {
        let controller = await makeReadyController()
        await controller.start()
        controller.volatileStore.record(raw: "r", final: "f", cleanupApplied: false)
        status.onClearLast?()
        XCTAssertNil(controller.volatileStore.current)
        XCTAssertEqual(status.recoveryState?(), RecoveryMenuState())
    }
}
