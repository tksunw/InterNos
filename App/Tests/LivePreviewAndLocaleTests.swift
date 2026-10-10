// v2: live transcript preview routing (generation-guarded) and recognition-locale
// change handling (pipeline re-init without a second event tap).

import AppKit
import XCTest
@testable import Internos

@MainActor
final class LivePreviewAndLocaleTests: XCTestCase {
    private var hotkey = FakeHotkey()
    private var engine = FakeEngine()
    private var indicator = FakeIndicator()
    private var status = FakeStatus()

    private func makeReadyController() async -> DictationController {
        hotkey = FakeHotkey()
        engine = FakeEngine()
        indicator = FakeIndicator()
        status = FakeStatus()
        let controller = DictationController(
            hotkey: hotkey,
            recorder: FakeRecorder(),
            engine: engine,
            inserter: FakeInserter(),
            statusItem: status,
            indicator: indicator,
            processingSettings: { ProcessingSettings() },
            playSound: { _ in },
            frontmostPID: { 42 },
            onboardingPresenter: { _, _ in }
        )
        await controller.initializePipeline()
        return controller
    }

    func testPartialResultsReachTheIndicator() async {
        let controller = await makeReadyController()
        controller.beginUtterance()
        await waitUntil { self.engine.pendingCount == 1 }

        engine.emitPartial(1, text: "hel")
        engine.emitPartial(1, text: "hello wor")
        await waitUntil { self.indicator.partials.count == 2 }
        XCTAssertEqual(indicator.partials, ["hel", "hello wor"])

        controller.endUtterance()
        engine.complete(1, with: .success("hello world"))
        await waitUntil { controller.state == .idle }
    }

    func testSupersededUtterancePartialsAreSuppressed() async {
        let controller = await makeReadyController()
        controller.beginUtterance() // utterance 1
        await waitUntil { self.engine.pendingCount == 1 }
        controller.endUtterance()
        controller.beginUtterance() // utterance 2 owns the indicator now
        await waitUntil { self.engine.pendingCount == 2 }

        engine.emitPartial(1, text: "stale text from utterance one")
        engine.emitPartial(2, text: "live")
        await waitUntil { self.indicator.partials.contains("live") }

        XCTAssertFalse(indicator.partials.contains("stale text from utterance one"),
                       "an older utterance must not paint the newer recording's preview")

        engine.complete(1, with: .success("one"))
        engine.complete(2, with: .success("two"))
        await waitUntil { controller.state == .idle }
    }

    func testLocaleChangeReinitializesWithoutSecondTap() async {
        let saved = AppSettings.shared.recognitionLocale
        defer { AppSettings.shared.recognitionLocale = saved }
        AppSettings.shared.recognitionLocale = "en_US"

        let controller = await makeReadyController()
        XCTAssertEqual(hotkey.startCount, 1)

        AppSettings.shared.recognitionLocale = "de_DE"
        controller.handleLocaleChangeIfNeeded()
        await waitUntil { controller.state == .idle }

        XCTAssertEqual(controller.state, .idle, "model installed → pipeline ready again")
        XCTAssertEqual(hotkey.startCount, 1, "the event tap must not be created twice")
        XCTAssertEqual(status.states.last, .idle)
    }

    func testLocaleChangeWithMissingModelShowsSetup() async {
        let saved = AppSettings.shared.recognitionLocale
        defer { AppSettings.shared.recognitionLocale = saved }
        AppSettings.shared.recognitionLocale = "en_US"

        var onboardingShown = 0
        let controller = DictationController(
            hotkey: hotkey,
            recorder: FakeRecorder(),
            engine: engine,
            inserter: FakeInserter(),
            statusItem: status,
            indicator: indicator,
            processingSettings: { ProcessingSettings() },
            playSound: { _ in },
            frontmostPID: { 42 },
            onboardingPresenter: { _, _ in onboardingShown += 1 }
        )
        await controller.initializePipeline()

        engine.modelStatusValue = .supported // the new language's model isn't installed
        AppSettings.shared.recognitionLocale = "fr_FR"
        controller.handleLocaleChangeIfNeeded()
        await waitUntil { onboardingShown == 1 }

        XCTAssertEqual(onboardingShown, 1, "missing model routes through the setup window")
        XCTAssertEqual(controller.state, .settingUp)
    }

    func testNoReinitWhenLocaleUnchanged() async {
        let controller = await makeReadyController()
        controller.handleLocaleChangeIfNeeded()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(hotkey.startCount, 1)
    }

    /// A language picked while paused must not un-pause the controller behind the
    /// menu's back; it is applied on resume.
    func testLocaleChangeWhilePausedIsDeferredUntilResume() async {
        let saved = AppSettings.shared.recognitionLocale
        defer { AppSettings.shared.recognitionLocale = saved }
        AppSettings.shared.recognitionLocale = "en_US"

        let controller = await makeReadyController()
        controller.togglePause()
        engine.modelStatusValue = .supported // the new language needs a download
        AppSettings.shared.recognitionLocale = "de_DE"
        controller.handleLocaleChangeIfNeeded()

        XCTAssertEqual(controller.state, .paused)
        XCTAssertTrue(status.isPaused)
        controller.hotkeyDown()
        XCTAssertEqual(controller.state, .paused, "the hotkey stays dead while paused")

        controller.togglePause() // resume: now the change is picked up
        XCTAssertFalse(status.isPaused)
        XCTAssertEqual(controller.state, .settingUp)
    }

    func testLocaleChangeMidUtteranceAppliesWhenItCompletes() async {
        let saved = AppSettings.shared.recognitionLocale
        defer { AppSettings.shared.recognitionLocale = saved }
        AppSettings.shared.recognitionLocale = "en_US"

        let controller = await makeReadyController()
        controller.beginUtterance()
        await waitUntil { self.engine.pendingCount == 1 }
        engine.modelStatusValue = .supported
        AppSettings.shared.recognitionLocale = "fr_FR"
        controller.handleLocaleChangeIfNeeded()
        XCTAssertEqual(controller.state, .recording, "the recording keeps its state")

        controller.endUtterance()
        engine.complete(1, with: .success("bonjour"))
        await waitUntil { controller.state == .settingUp }
        XCTAssertEqual(controller.state, .settingUp)
    }

    /// The download window for a new language was closed; picking an installed
    /// language again must bring the pipeline back.
    func testPickingAnInstalledLanguageRecoversFromAbandonedSetup() async {
        let saved = AppSettings.shared.recognitionLocale
        defer { AppSettings.shared.recognitionLocale = saved }
        AppSettings.shared.recognitionLocale = "en_US"

        let controller = await makeReadyController()
        engine.modelStatusValue = .supported
        AppSettings.shared.recognitionLocale = "fr_FR"
        controller.handleLocaleChangeIfNeeded()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(controller.state, .settingUp)

        engine.modelStatusValue = .installed
        AppSettings.shared.recognitionLocale = "en_US"
        controller.handleLocaleChangeIfNeeded()
        await waitUntil { controller.state == .idle }
        XCTAssertEqual(controller.state, .idle)
    }

    /// A second pick while the first is still being set up is not dropped, and an
    /// unrelated settings change during setup does not restart it.
    func testSecondLanguagePickDuringSetupSupersedesTheFirst() async {
        let saved = AppSettings.shared.recognitionLocale
        defer { AppSettings.shared.recognitionLocale = saved }
        AppSettings.shared.recognitionLocale = "en_US"

        let controller = await makeReadyController()
        AppSettings.shared.recognitionLocale = "de_DE"
        controller.handleLocaleChangeIfNeeded()
        XCTAssertEqual(controller.state, .settingUp)
        let disabledCount = status.states.filter { $0 == .disabled }.count
        controller.handleLocaleChangeIfNeeded() // e.g. a hotkey change while setting up
        XCTAssertEqual(status.states.filter { $0 == .disabled }.count, disabledCount, "same pick: no restart")

        engine.modelStatusValue = .supported // the second pick needs a download
        AppSettings.shared.recognitionLocale = "fr_FR"
        controller.handleLocaleChangeIfNeeded()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(controller.state, .settingUp, "the first pick's setup must not finish over the second")
    }

    /// Pausing while a language re-init is still in flight must hold: setup
    /// finishing in the background can't flip the controller back to idle.
    func testPauseDuringLanguageSetupSurvivesItsCompletion() async {
        let saved = AppSettings.shared.recognitionLocale
        defer { AppSettings.shared.recognitionLocale = saved }
        AppSettings.shared.recognitionLocale = "en_US"

        let controller = await makeReadyController()
        AppSettings.shared.recognitionLocale = "de_DE"
        controller.handleLocaleChangeIfNeeded()
        XCTAssertEqual(controller.state, .settingUp)
        controller.togglePause() // before the setup task has run
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.state, .paused)
        XCTAssertTrue(status.isPaused)
        XCTAssertNotEqual(status.states.last, .idle)

        controller.togglePause()
        XCTAssertEqual(controller.state, .idle, "setup did finish; resume finds it ready")
    }

    /// First-run setup abandoned (the window was closed) with no pipeline ever
    /// ready: picking another language brings the setup window back. Never the
    /// pipeline directly: permissions may still be missing.
    func testLanguagePickRestartsAnAbandonedFirstRunSetup() async {
        let saved = AppSettings.shared.recognitionLocale
        defer { AppSettings.shared.recognitionLocale = saved }
        AppSettings.shared.recognitionLocale = "fr_FR"

        hotkey = FakeHotkey()
        engine = FakeEngine()
        status = FakeStatus()
        engine.modelStatusValue = .supported // fr_FR isn't installed: start() shows setup
        var onboardingShown = 0
        let controller = DictationController(
            hotkey: hotkey,
            recorder: FakeRecorder(),
            engine: engine,
            inserter: FakeInserter(),
            statusItem: status,
            indicator: FakeIndicator(),
            processingSettings: { ProcessingSettings() },
            playSound: { _ in },
            frontmostPID: { 42 },
            onboardingPresenter: { _, _ in onboardingShown += 1 }
        )
        await controller.start()
        XCTAssertEqual(controller.state, .settingUp)
        XCTAssertEqual(onboardingShown, 1)

        engine.modelStatusValue = .installed
        AppSettings.shared.recognitionLocale = "en_US"
        controller.handleLocaleChangeIfNeeded()
        await waitUntil { onboardingShown == 2 }
        XCTAssertEqual(onboardingShown, 2)
        XCTAssertEqual(hotkey.startCount, 0, "the event tap is not requested behind the setup window's back")
    }

    /// A language whose setup failed must not strand the app: going back to the
    /// one that worked is a change like any other.
    func testRevertingAfterAFailedLanguageSetupRecovers() async {
        let saved = AppSettings.shared.recognitionLocale
        defer { AppSettings.shared.recognitionLocale = saved }
        AppSettings.shared.recognitionLocale = "en_US"

        let controller = await makeReadyController()
        engine.ensureModelError = InternosError.modelNotInstalled
        AppSettings.shared.recognitionLocale = "fr_FR"
        controller.handleLocaleChangeIfNeeded()
        await waitUntil { controller.state == .setupFailed }
        XCTAssertEqual(controller.state, .setupFailed)

        engine.ensureModelError = nil
        AppSettings.shared.recognitionLocale = "en_US"
        controller.handleLocaleChangeIfNeeded()
        await waitUntil { controller.state == .idle }
        XCTAssertEqual(controller.state, .idle)
    }

    /// Paused over an abandoned download, then an installed language is picked:
    /// resume has no ready pipeline, and must still apply the pick.
    func testResumeWithoutAReadyPipelineAppliesThePausedPick() async {
        let saved = AppSettings.shared.recognitionLocale
        defer { AppSettings.shared.recognitionLocale = saved }
        AppSettings.shared.recognitionLocale = "en_US"

        let controller = await makeReadyController()
        engine.modelStatusValue = .supported
        AppSettings.shared.recognitionLocale = "fr_FR"
        controller.handleLocaleChangeIfNeeded()
        try? await Task.sleep(nanoseconds: 20_000_000)
        controller.togglePause()

        engine.modelStatusValue = .installed
        AppSettings.shared.recognitionLocale = "en_US"
        controller.handleLocaleChangeIfNeeded()
        XCTAssertEqual(controller.state, .paused)

        controller.togglePause()
        await waitUntil { controller.state == .idle }
        XCTAssertEqual(controller.state, .idle)
    }

    /// A language picked while a dictation is finalizing waits for it. A recording
    /// started in the meantime stays in the language its audio format is for.
    func testRecordingDuringAPendingLanguageChangeKeepsTheOldLanguage() async {
        let saved = AppSettings.shared.recognitionLocale
        defer { AppSettings.shared.recognitionLocale = saved }
        AppSettings.shared.recognitionLocale = "en_US"

        let controller = await makeReadyController()
        controller.beginUtterance()
        await waitUntil { self.engine.pendingCount == 1 }
        controller.endUtterance()
        AppSettings.shared.recognitionLocale = "de_DE"
        controller.handleLocaleChangeIfNeeded()
        XCTAssertEqual(controller.state, .finalizing)

        controller.beginUtterance()
        XCTAssertEqual(controller.state, .recording)
        await waitUntil { self.engine.pendingCount == 2 }
        XCTAssertEqual(engine.locales, ["en_US", "en_US"], "format and language stay a pair")

        controller.endUtterance()
        engine.complete(1, with: .success("hello"))
        engine.complete(2, with: .success("world"))
        await waitUntil { controller.state == .idle && self.engine.pendingCount == 0 }

        // Setup for the new language has run by now; the next recording uses it.
        controller.beginUtterance()
        await waitUntil { self.engine.pendingCount == 1 }
        XCTAssertEqual(engine.locales.last, "de_DE")
    }

    /// A failed event tap needs a relaunch. A language pick must not take the
    /// failure indicator down as if something were being fixed.
    func testLanguagePickLeavesATapFailureVisible() async {
        let saved = AppSettings.shared.recognitionLocale
        defer { AppSettings.shared.recognitionLocale = saved }
        AppSettings.shared.recognitionLocale = "en_US"

        hotkey = FakeHotkey()
        hotkey.startResult = false
        engine = FakeEngine()
        status = FakeStatus()
        let controller = DictationController(
            hotkey: hotkey,
            recorder: FakeRecorder(),
            engine: engine,
            inserter: FakeInserter(),
            statusItem: status,
            indicator: FakeIndicator(),
            processingSettings: { ProcessingSettings() },
            playSound: { _ in },
            frontmostPID: { 42 },
            onboardingPresenter: { _, _ in }
        )
        await controller.initializePipeline()
        XCTAssertEqual(controller.state, .setupFailed)

        AppSettings.shared.recognitionLocale = "de_DE"
        controller.handleLocaleChangeIfNeeded()
        XCTAssertEqual(controller.state, .setupFailed)
        XCTAssertEqual(status.states.last, .setupFailed)
    }

    /// Resume while a language's model is still being fetched: that is "setting
    /// up", not the persistent failure state.
    func testResumeDuringSetupIsNotAFailure() async {
        let saved = AppSettings.shared.recognitionLocale
        defer { AppSettings.shared.recognitionLocale = saved }
        AppSettings.shared.recognitionLocale = "en_US"

        let controller = await makeReadyController()
        engine.modelStatusValue = .supported // needs a download: setup window takes over
        AppSettings.shared.recognitionLocale = "fr_FR"
        controller.handleLocaleChangeIfNeeded()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(controller.state, .settingUp)

        controller.togglePause()
        controller.togglePause()
        XCTAssertEqual(controller.state, .settingUp)
        XCTAssertNotEqual(status.states.last, .setupFailed)
    }

    /// Two setups for the same language overlapping (a language pick and the
    /// setup window finishing): only the first to finish reports ready, so the
    /// second can't force idle over whatever started in between.
    func testOverlappingSetupsReportReadyOnce() async {
        hotkey = FakeHotkey()
        engine = FakeEngine()
        status = FakeStatus()
        let controller = DictationController(
            hotkey: hotkey,
            recorder: FakeRecorder(),
            engine: engine,
            inserter: FakeInserter(),
            statusItem: status,
            indicator: FakeIndicator(),
            processingSettings: { ProcessingSettings() },
            playSound: { _ in },
            frontmostPID: { 42 },
            onboardingPresenter: { _, _ in }
        )
        async let first: Void = controller.initializePipeline()
        async let second: Void = controller.initializePipeline()
        _ = await (first, second)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(status.states.filter { $0 == .idle }.count, 1)
        XCTAssertEqual(hotkey.startCount, 1)
    }

    /// Cleanup is English-only. An utterance recorded in Spanish stays out of the
    /// model even if the language setting flips to English before it ends.
    func testCleanupModeFollowsTheLanguageTheUtteranceWasRecordedIn() async {
        final class RecordingPipeline: TranscriptProcessing, @unchecked Sendable {
            private let lock = NSLock()
            private var _modes: [CleanupMode] = []
            var modes: [CleanupMode] { lock.withLock { _modes } }
            func process(_ raw: String, settings: ProcessingSettings) async -> TranscriptResult {
                lock.withLock { _modes.append(settings.cleanupMode) }
                return TranscriptResult(raw: raw, final: raw, cleanupApplied: false)
            }
        }
        let saved = AppSettings.shared.recognitionLocale
        defer { AppSettings.shared.recognitionLocale = saved }
        AppSettings.shared.recognitionLocale = "es_ES"

        hotkey = FakeHotkey()
        engine = FakeEngine()
        status = FakeStatus()
        let pipeline = RecordingPipeline()
        let controller = DictationController(
            hotkey: hotkey,
            recorder: FakeRecorder(),
            engine: engine,
            inserter: FakeInserter(),
            statusItem: status,
            indicator: FakeIndicator(),
            pipeline: pipeline,
            processingSettings: { ProcessingSettings(cleanupMode: .light) },
            playSound: { _ in },
            frontmostPID: { 42 },
            onboardingPresenter: { _, _ in }
        )
        await controller.initializePipeline()

        controller.beginUtterance()
        await waitUntil { self.engine.pendingCount == 1 }
        AppSettings.shared.recognitionLocale = "en_US"
        controller.handleLocaleChangeIfNeeded() // deferred: recording
        controller.endUtterance()
        engine.complete(1, with: .success("hola mundo"))
        await waitUntil { pipeline.modes.count == 1 }

        XCTAssertEqual(pipeline.modes, [.off])
        XCTAssertEqual(engine.locales, ["es_ES"])

        // And the other way round: once the pipeline is English, an utterance
        // keeps its cleanup even if Settings flips to Spanish before it ends.
        await waitUntil { controller.state == .idle }
        controller.beginUtterance()
        await waitUntil { self.engine.pendingCount == 1 }
        AppSettings.shared.recognitionLocale = "es_ES"
        controller.handleLocaleChangeIfNeeded()
        controller.endUtterance()
        engine.complete(2, with: .success("hello world"))
        await waitUntil { pipeline.modes.count == 2 }
        XCTAssertEqual(pipeline.modes, [.off, .light])
        XCTAssertEqual(engine.locales, ["es_ES", "en_US"])
    }

    /// A failed utterance with a language change waiting: the error icon is
    /// shown first, and only then does setup for the new language take over.
    func testErrorIsSeenBeforeAWaitingLanguageChange() async {
        let saved = AppSettings.shared.recognitionLocale
        defer { AppSettings.shared.recognitionLocale = saved }
        AppSettings.shared.recognitionLocale = "en_US"

        let controller = await makeReadyController()
        controller.beginUtterance()
        await waitUntil { self.engine.pendingCount == 1 }
        AppSettings.shared.recognitionLocale = "de_DE"
        engine.modelStatusValue = .supported // so the new setup parks in .settingUp
        controller.handleLocaleChangeIfNeeded()
        controller.endUtterance()
        engine.complete(1, with: .success("")) // empty transcript: a failure

        await waitUntil { controller.state == .idle }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(status.states.last, .error, "the failure is on the icon, not replaced at once")

        status.onErrorDismissed?() // the error icon has had its time
        XCTAssertEqual(controller.state, .settingUp)
    }

    /// Paused before the setup step could open the download window: no window
    /// behind a paused menu, and resume starts the setup over.
    func testNoSetupWindowWhilePausedAndResumeStartsOver() async {
        let saved = AppSettings.shared.recognitionLocale
        defer { AppSettings.shared.recognitionLocale = saved }
        AppSettings.shared.recognitionLocale = "en_US"

        var onboardingShown = 0
        hotkey = FakeHotkey()
        engine = FakeEngine()
        status = FakeStatus()
        let controller = DictationController(
            hotkey: hotkey,
            recorder: FakeRecorder(),
            engine: engine,
            inserter: FakeInserter(),
            statusItem: status,
            indicator: FakeIndicator(),
            processingSettings: { ProcessingSettings() },
            playSound: { _ in },
            frontmostPID: { 42 },
            onboardingPresenter: { _, _ in onboardingShown += 1 }
        )
        await controller.initializePipeline()

        engine.modelStatusValue = .supported // the new language needs a download
        AppSettings.shared.recognitionLocale = "fr_FR"
        controller.handleLocaleChangeIfNeeded()
        controller.togglePause() // before the setup step has run
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(onboardingShown, 0)
        XCTAssertEqual(controller.state, .paused)

        controller.togglePause()
        await waitUntil { onboardingShown == 1 }
        XCTAssertEqual(onboardingShown, 1)
        XCTAssertEqual(controller.state, .settingUp)
    }
}
