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
}
