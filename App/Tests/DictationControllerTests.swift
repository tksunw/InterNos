// IR-001 (serialized, ordered insertion), IR-003 (stop-time target capture),
// IR-004 (pause owns all pending work), IR-007 (persistent setup failures).
// Everything runs against fakes; no audio, speech, pasteboard, or UI.

import AppKit
import XCTest
@testable import Internos

@MainActor
final class DictationControllerTests: XCTestCase {
    private var hotkey = FakeHotkey()
    private var recorder = FakeRecorder()
    private var engine = FakeEngine()
    private var inserter = FakeInserter()
    private var status = FakeStatus()
    private var indicator = FakeIndicator()
    private var sounds: [String] = []
    private var frontmost: pid_t? = 42
    private var onboardingShown = 0

    private func makeController() -> DictationController {
        hotkey = FakeHotkey()
        recorder = FakeRecorder()
        engine = FakeEngine()
        inserter = FakeInserter()
        status = FakeStatus()
        indicator = FakeIndicator()
        sounds = []
        frontmost = 42
        onboardingShown = 0
        return DictationController(
            hotkey: hotkey,
            recorder: recorder,
            engine: engine,
            inserter: inserter,
            statusItem: status,
            indicator: indicator,
            playSound: { [self] name in sounds.append(name) },
            frontmostPID: { [self] in frontmost },
            onboardingPresenter: { [self] _, _ in onboardingShown += 1 }
        )
    }

    private func makeReadyController() async -> DictationController {
        let controller = makeController()
        await controller.initializePipeline()
        XCTAssertEqual(controller.state, .idle)
        return controller
    }

    // MARK: IR-001 — ordered, serialized insertion

    func testInsertionOrderFollowsRecordingOrder() async {
        let controller = await makeReadyController()

        controller.beginUtterance() // utterance 1
        await waitUntil { self.engine.pendingCount == 1 } // pin index 1 to utterance 1
        controller.endUtterance()
        controller.beginUtterance() // utterance 2, while 1 is finalizing
        controller.endUtterance()
        await waitUntil { self.engine.pendingCount == 2 }

        // Utterance 2's transcription finishes FIRST.
        engine.complete(2, with: .success("B"))
        engine.complete(1, with: .success("A"))

        await waitUntil { self.inserter.insertions.count == 2 }
        XCTAssertEqual(inserter.insertions.map(\.text), ["A", "B"],
                       "insertions must land in recording order, not completion order")
        XCTAssertEqual(controller.state, .idle)
    }

    func testSupersededCompletionDoesNotTouchNewerRecordingUI() async {
        let controller = await makeReadyController()

        controller.beginUtterance() // utterance 1
        await waitUntil { self.engine.pendingCount == 1 } // pin index 1 to utterance 1
        controller.endUtterance()
        controller.beginUtterance() // utterance 2 still recording
        await waitUntil { self.engine.pendingCount == 2 }

        let hidesBefore = indicator.hideCount
        let statesBefore = status.states
        let soundsBefore = sounds

        engine.complete(1, with: .success("A"))
        await waitUntil { self.inserter.insertions.count == 1 }

        XCTAssertEqual(inserter.insertions.map(\.text), ["A"], "the older transcript still inserts")
        XCTAssertEqual(indicator.hideCount, hidesBefore,
                       "an older completion must not hide the newer recording's indicator")
        XCTAssertEqual(status.states, statesBefore,
                       "an older completion must not change the newer recording's menu-bar state")
        XCTAssertEqual(sounds, soundsBefore,
                       "an older completion must not play sounds over the newer recording")
        XCTAssertEqual(controller.state, .recording)

        engine.complete(2, with: .success("")) // clean up the still-pending transcription
    }

    func testCanceledUtteranceNeverReachesInserter() async {
        let controller = await makeReadyController()

        controller.beginUtterance()
        await waitUntil { self.engine.pendingCount == 1 }
        controller.togglePause() // cancel mid-recording

        XCTAssertEqual(recorder.stopCount, 1, "pause must stop capture")
        engine.complete(1, with: .success("too late"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(inserter.insertions.isEmpty, "a canceled utterance must never insert")
    }

    // MARK: IR-003 — target captured when recording stops

    func testTargetCapturedAtStopTimeIsPassedToInserter() async {
        let controller = await makeReadyController()

        frontmost = 7
        controller.beginUtterance()
        controller.endUtterance() // stop-time frontmost: 7
        frontmost = 9             // user switches apps during finalization
        await waitUntil { self.engine.pendingCount == 1 }
        engine.complete(1, with: .success("hello"))

        await waitUntil { self.inserter.insertions.count == 1 }
        XCTAssertEqual(inserter.insertions[0].target, 7,
                       "the paste target is the app frontmost when recording stopped")
    }

    func testTargetMismatchPreservesTranscriptAndShowsError() async {
        let controller = await makeReadyController()
        inserter.errorToThrow = InternosError.insertionTargetChanged

        controller.beginUtterance()
        controller.endUtterance()
        await waitUntil { self.engine.pendingCount == 1 }
        engine.complete(1, with: .success("hello"))

        await waitUntil { self.inserter.preserved.count == 1 }
        XCTAssertEqual(inserter.preserved, ["hello"], "the transcript must not be lost")
        XCTAssertTrue(inserter.insertions.isEmpty)
        XCTAssertEqual(status.states.last, .error)
    }

    // MARK: IR-004 — pause owns recording, finalization, and insertion

    func testPauseDuringFinalizationPreventsInsertion() async {
        let controller = await makeReadyController()

        controller.beginUtterance()
        controller.endUtterance()
        await waitUntil { self.engine.pendingCount == 1 }
        controller.togglePause() // pause while "Transcribing"

        engine.complete(1, with: .success("finished after pause"))
        await waitUntil { self.inserter.preserved.count == 1 }

        XCTAssertTrue(inserter.insertions.isEmpty, "no transcript may insert after Pause")
        XCTAssertEqual(inserter.preserved, ["finished after pause"],
                       "a transcript completed before cancellation is preserved, not injected")
        XCTAssertEqual(status.states.last, .disabled,
                       "a completion arriving after Pause must not change the paused state")
        XCTAssertEqual(controller.state, .paused)
    }

    func testResumeReturnsToIdleOnlyWhenPipelineReady() async {
        let controller = await makeReadyController()
        controller.togglePause()
        XCTAssertEqual(controller.state, .paused)
        controller.togglePause()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(status.states.last, .idle)
    }

    func testResumeAfterSetupFailureDoesNotImplyReadiness() async {
        let controller = makeController()
        engine.ensureModelError = InternosError.modelNotInstalled
        await controller.initializePipeline()
        XCTAssertEqual(controller.state, .setupFailed)

        controller.togglePause()
        controller.togglePause() // resume
        XCTAssertEqual(controller.state, .setupFailed)
        XCTAssertEqual(status.states.last, .setupFailed,
                       "resume must not show idle while the pipeline is broken")
    }

    // MARK: IR-007 — persistent setup failures

    func testModelSetupFailureIsPersistent() async {
        let controller = makeController()
        engine.ensureModelError = InternosError.modelNotInstalled
        await controller.initializePipeline()

        XCTAssertEqual(controller.state, .setupFailed)
        XCTAssertEqual(status.states.last, .setupFailed)
        XCTAssertFalse(AppState.setupFailed.autoRevertsToIdle,
                       "a setup failure must not auto-revert to an idle icon")
        XCTAssertTrue(AppState.error.autoRevertsToIdle,
                       "ordinary utterance errors still auto-revert")
    }

    func testEventTapFailureIsPersistentAndOffersSetup() async {
        let controller = makeController()
        hotkey.startResult = false
        await controller.initializePipeline()

        XCTAssertEqual(controller.state, .setupFailed)
        XCTAssertEqual(status.states.last, .setupFailed)
        XCTAssertEqual(onboardingShown, 1)
    }

    func testSuccessfulRetryClearsPersistentFailure() async {
        let controller = makeController()
        engine.ensureModelError = InternosError.modelNotInstalled
        await controller.initializePipeline()
        XCTAssertEqual(controller.state, .setupFailed)

        engine.ensureModelError = nil
        await controller.initializePipeline()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(status.states.last, .idle)
    }

    // MARK: transcript-level errors

    func testEmptyTranscriptShowsTransientError() async {
        let controller = await makeReadyController()

        controller.beginUtterance()
        controller.endUtterance()
        await waitUntil { self.engine.pendingCount == 1 }
        engine.complete(1, with: .success(""))

        await waitUntil { self.status.states.last == .error }
        XCTAssertTrue(inserter.insertions.isEmpty)
        XCTAssertEqual(sounds.last, "Basso")
        XCTAssertEqual(controller.state, .idle, "a transient error returns the controller to ready")
    }

    func testRecordingRejectedWhileNotReady() {
        let controller = makeController() // pipeline never initialized
        controller.beginUtterance()
        XCTAssertEqual(recorder.startCount, 0)
        XCTAssertEqual(controller.state, .settingUp)
    }
}
