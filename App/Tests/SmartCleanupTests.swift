// Feature 4: cleanup coordinator bounds (deadline, size cap, validation),
// pipeline integration (protected segments, replacements-after-cleanup), and
// controller-level cancellation. All against a fake cleaner — no Apple Intelligence.

import XCTest
@testable import Internos

final class FakeCleaner: SmartCleaning, @unchecked Sendable {
    private let lock = NSLock()
    private var _inputs: [String] = []
    var inputs: [String] { lock.withLock { _inputs } }

    var transform: @Sendable (String) -> String? = { _ in nil }
    var gate: Gate?

    func clean(_ text: String, mode: CleanupMode) async -> String? {
        lock.withLock { _inputs.append(text) }
        if let gate { await gate.wait() }
        return transform(text)
    }
}

final class SmartCleanupCoordinatorTests: XCTestCase {
    func testOffModeNeverCallsCleaner() async {
        let cleaner = FakeCleaner()
        let coordinator = SmartCleanupCoordinator(cleaner: cleaner)
        let result = await coordinator.clean("some text", mode: .off)
        XCTAssertNil(result)
        XCTAssertTrue(cleaner.inputs.isEmpty, "Off must not touch the model layer")
    }

    func testOversizedInputSkipsCleanup() async {
        let cleaner = FakeCleaner()
        cleaner.transform = { _ in "should not be used" }
        let coordinator = SmartCleanupCoordinator(cleaner: cleaner)
        let big = String(repeating: "a", count: SmartCleanupCoordinator.maxInputLength + 1)
        let result = await coordinator.clean(big, mode: .light)
        XCTAssertNil(result, "inputs above 4,000 characters continue deterministically")
        XCTAssertTrue(cleaner.inputs.isEmpty)
    }

    func testDeadlineFallsBackWithoutBlocking() async {
        let cleaner = FakeCleaner()
        cleaner.gate = Gate() // never opened during the call
        let coordinator = SmartCleanupCoordinator(cleaner: cleaner, deadline: .milliseconds(50))

        let start = ContinuousClock.now
        let result = await coordinator.clean("slow input", mode: .light)
        let elapsed = ContinuousClock.now - start

        XCTAssertNil(result, "timeout is a soft failure")
        XCTAssertLessThan(elapsed, .seconds(1), "the deadline must not block on the stuck model call")
        cleaner.gate?.open() // release the orphaned task
    }

    func testValidationRejectsGarbageOutput() {
        let validate = { SmartCleanupCoordinator.validate($0, input: "0123456789") }
        XCTAssertNil(validate(""), "empty output rejected")
        XCTAssertNil(validate("   \n  "), "whitespace-only output rejected")
        XCTAssertNil(validate(String(repeating: "x", count: 15 + 128 + 1)), "oversize output rejected")
        XCTAssertNil(validate("has a \u{0007} bell"), "control characters rejected")
        XCTAssertEqual(validate("ok\ttab and\nnewline"), "ok\ttab and\nnewline", "tab and newline allowed")
        XCTAssertEqual(validate("  trimmed \r\n"), "trimmed", "outer whitespace trimmed, line endings normalized")
        XCTAssertEqual(validate("line one\r\nline two"), "line one\nline two")
    }

    func testRejectedOutputFallsBackToOriginal() async {
        let cleaner = FakeCleaner()
        cleaner.transform = { _ in "\u{0007}" } // invalid model output
        let coordinator = SmartCleanupCoordinator(cleaner: cleaner)
        let result = await coordinator.clean("keep me", mode: .polished)
        XCTAssertNil(result, "rejection means the original segment is used")
    }
}

final class SmartCleanupPipelineTests: XCTestCase {
    private func pipeline(_ cleaner: FakeCleaner) -> TranscriptPipeline {
        TranscriptPipeline(cleaner: SmartCleanupCoordinator(cleaner: cleaner, deadline: .milliseconds(200)))
    }

    func testCleanupThenReplacementMakesConfiguredSpellingAuthoritative() async {
        // Cross-feature case 1: cleanup produces prose, replacement fixes the term.
        let cleaner = FakeCleaner()
        cleaner.transform = { _ in "We use cube control for deployments." }
        let settings = ProcessingSettings(
            cleanupMode: .light,
            replacements: ReplacementMatcher(rules: [("cube control", "kubectl")]),
            snippets: .empty)

        let result = await pipeline(cleaner).process("um we use uh cube control for deployments", settings: settings)
        XCTAssertEqual(result.final, "We use kubectl for deployments.")
        XCTAssertTrue(result.cleanupApplied)
        XCTAssertEqual(result.raw, "um we use uh cube control for deployments", "raw preserved for recovery")
    }

    func testUtteranceWithSnippetSkipsCleanupEntirely() async {
        // Cleanup on fragments around a snippet made the model invent completions
        // (beta field report: a fabricated markdown link). A structured utterance
        // takes the deterministic path — the model sees nothing at all.
        let id = UUID()
        let table = SnippetTable(snippets: [(id, "support response", "Secret exact\ncontent ✨")])
        let cleaner = FakeCleaner()
        cleaner.transform = { $0.uppercased() }
        let settings = ProcessingSettings(cleanupMode: .polished, replacements: .empty, snippets: table)

        let result = await pipeline(cleaner).process("please use snippet support response thanks", settings: settings)

        XCTAssertEqual(result.final, "please use Secret exact\ncontent ✨ thanks")
        XCTAssertTrue(cleaner.inputs.isEmpty, "no fragment may reach the model when protected segments exist")
        XCTAssertFalse(result.cleanupApplied)
    }

    func testUtteranceWithCommandSkipsCleanupEntirely() async {
        let cleaner = FakeCleaner()
        cleaner.transform = { $0.uppercased() }
        let settings = ProcessingSettings(cleanupMode: .light, replacements: .empty, snippets: .empty)
        let result = await pipeline(cleaner).process("say literal new line loudly", settings: settings)
        XCTAssertEqual(result.final, "say new line loudly", "deterministic path, escaped phrase exact")
        XCTAssertTrue(cleaner.inputs.isEmpty)
    }

    func testPlainUtteranceStillGetsCleanup() async {
        let cleaner = FakeCleaner()
        cleaner.transform = { _ in "Cleaned up nicely." }
        let settings = ProcessingSettings(cleanupMode: .light, replacements: .empty, snippets: .empty)
        let result = await pipeline(cleaner).process("um so cleaned up nicely", settings: settings)
        XCTAssertEqual(result.final, "Cleaned up nicely.")
        XCTAssertTrue(result.cleanupApplied)
    }

    func testStructuredUtteranceGetsDeterministicFillerRemoval() async {
        // Filler removal must survive in command/snippet utterances (beta-3 feedback) —
        // deterministically, with the model never invoked.
        let id = UUID()
        let table = SnippetTable(snippets: [(id, "t k sun w", "tksunw")])
        let cleaner = FakeCleaner()
        cleaner.transform = { _ in "SHOULD NOT RUN" }
        let settings = ProcessingSettings(cleanupMode: .light, replacements: .empty, snippets: table)

        let result = await pipeline(cleaner).process(
            "um my GitHub handle is uh snippet t k sun w", settings: settings)

        XCTAssertEqual(result.final, "my GitHub handle is tksunw")
        XCTAssertTrue(cleaner.inputs.isEmpty, "structured utterances never reach the model")
        XCTAssertTrue(result.cleanupApplied)
    }

    func testModelFailureFallsBackToFillerStripping() async {
        let cleaner = FakeCleaner()
        cleaner.transform = { _ in nil } // timeout / refusal
        let settings = ProcessingSettings(cleanupMode: .light, replacements: .empty, snippets: .empty)
        let result = await pipeline(cleaner).process("um so this uh still gets tidied", settings: settings)
        XCTAssertEqual(result.final, "so this still gets tidied")
        XCTAssertTrue(result.cleanupApplied)
    }

    func testFillerStripperConservatism() {
        XCTAssertEqual(FillerStripper.strip("Um, hello there"), "hello there")
        XCTAssertEqual(FillerStripper.strip("I was, um, thinking"), "I was, thinking")
        XCTAssertEqual(FillerStripper.strip("no fillers here"), "no fillers here")
        XCTAssertEqual(FillerStripper.strip("the drummer plays the drum"), "the drummer plays the drum")
        // Words the stripper must NOT touch without semantics: "like", "you know".
        XCTAssertEqual(FillerStripper.strip("I like this, you know"), "I like this, you know")
    }

    func testFillersUntouchedWhenCleanupOff() async {
        let cleaner = FakeCleaner()
        let settings = ProcessingSettings(cleanupMode: .off, replacements: .empty, snippets: .empty)
        let result = await pipeline(cleaner).process("um exactly what I said", settings: settings)
        XCTAssertEqual(result.final, "um exactly what I said")
    }

    func testModelCleanupGatedToEnglishRecognition() {
        // Beta-5 field report: Spanish dictation came back translated to English —
        // the cleanup model drifts under English instructions on non-English input.
        XCTAssertEqual(CleanupMode.light.effective(forLocaleIdentifier: "es_US"), .off)
        XCTAssertEqual(CleanupMode.polished.effective(forLocaleIdentifier: "de_DE"), .off)
        XCTAssertEqual(CleanupMode.light.effective(forLocaleIdentifier: "en_US"), .light)
        XCTAssertEqual(CleanupMode.polished.effective(forLocaleIdentifier: "en_GB"), .polished)
        XCTAssertEqual(CleanupMode.off.effective(forLocaleIdentifier: "en_US"), .off)
    }

    func testValidationRejectsIntroducedLinks() {
        // The exact beta failure: model invents a markdown link the speaker never said.
        XCTAssertNil(SmartCleanupCoordinator.validate(
            "My GitHub handle is [handle here](https://github.com/username)",
            input: "my github handle is"))
        XCTAssertNil(SmartCleanupCoordinator.validate(
            "see https://example.com for details", input: "see the site for details"))
        // URLs the speaker actually dictated survive.
        XCTAssertEqual(SmartCleanupCoordinator.validate(
            "Go to https://example.com now.", input: "go to https://example.com now"),
            "Go to https://example.com now.")
    }

    func testCleanupTimeoutStillRendersCommandsReplacementsSnippets() async {
        // Cross-feature case 5.
        let id = UUID()
        let cleaner = FakeCleaner()
        cleaner.gate = Gate() // cleanup hangs → deadline → deterministic output
        let settings = ProcessingSettings(
            cleanupMode: .light,
            replacements: ReplacementMatcher(rules: [("cube control", "kubectl")]),
            snippets: SnippetTable(snippets: [(id, "sig", "Cheers, Tim")]))

        let result = await pipeline(cleaner)
            .process("cube control new line snippet sig", settings: settings)

        XCTAssertEqual(result.final, "kubectl\nCheers, Tim")
        XCTAssertFalse(result.cleanupApplied)
        cleaner.gate?.open()
    }

    func testOffModeNeverTouchesCleaner() async {
        let cleaner = FakeCleaner()
        let settings = ProcessingSettings(cleanupMode: .off, replacements: .empty, snippets: .empty)
        _ = await pipeline(cleaner).process("hello there", settings: settings)
        XCTAssertTrue(cleaner.inputs.isEmpty)
    }
}

@MainActor
final class SmartCleanupControllerTests: XCTestCase {
    // Cross-feature case 6: pause during cleanup produces no insertion.
    func testPauseDuringCleanupPreventsInsertion() async {
        let hotkey = FakeHotkey()
        let engine = FakeEngine()
        let inserter = FakeInserter()
        let cleaner = FakeCleaner()
        let gate = Gate()
        cleaner.gate = gate
        cleaner.transform = { $0 + " cleaned" }

        let controller = DictationController(
            hotkey: hotkey,
            recorder: FakeRecorder(),
            engine: engine,
            inserter: inserter,
            statusItem: FakeStatus(),
            indicator: FakeIndicator(),
            pipeline: TranscriptPipeline(cleaner: SmartCleanupCoordinator(cleaner: cleaner, deadline: .seconds(5))),
            processingSettings: { ProcessingSettings(cleanupMode: .light, replacements: .empty, snippets: .empty) },
            playSound: { _ in },
            frontmostPID: { 42 },
            onboardingPresenter: { _, _ in }
        )
        await controller.initializePipeline()

        controller.beginUtterance()
        await waitUntil { engine.pendingCount == 1 }
        controller.endUtterance()
        engine.complete(1, with: .success("hello"))
        await waitUntil { !cleaner.inputs.isEmpty } // cleanup is now in flight

        controller.togglePause()
        gate.open() // cleanup finishes after pause

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(inserter.insertions.isEmpty, "a completion during pause must not insert")
        XCTAssertEqual(inserter.preserved, ["hello cleaned"],
                       "the completed transcript is preserved without injection")
        XCTAssertEqual(controller.volatileStore.current?.raw, "hello",
                       "raw and final both land in volatile recovery")
    }
}
