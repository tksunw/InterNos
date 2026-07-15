// v2 beta-1 field bugs: the recognizer merges/punctuates spelled-letter names
// ("t k sun w" → "TK sun W" / "T. K. Sun W.") and auto-punctuation glues commas
// to command prefixes ("Snippet, …"). Token-wise matching alone missed all of it.

import XCTest
@testable import Internos

final class RecognizerRobustnessTests: XCTestCase {
    private let snippetID = UUID()

    private var table: SnippetTable {
        SnippetTable(snippets: [(snippetID, "t k sun w", "tksunw")])
    }

    private func processed(_ raw: String, replacements: ReplacementMatcher = .empty) async -> String {
        await TranscriptPipeline().process(
            raw, settings: ProcessingSettings(cleanupMode: .off, replacements: replacements, snippets: table)
        ).final
    }

    // MARK: snippet names vs recognizer output (the beta-1 report)

    func testSpelledLetterNameSurvivesRecognizerVariants() async {
        for raw in [
            "snippet t k sun w",
            "Snippet T K Sun W.",
            "Snippet TK sun W",
            "Snippet TK Sun W.",
            "Snippet T. K. Sun W.",
            "Snippet TKSunW",
            "Snippet, t k sun w", // auto-punctuation comma on the prefix
        ] {
            let got = await processed(raw)
            XCTAssertTrue(got.hasPrefix("tksunw"), "\(raw) → \(got)")
        }
    }

    func testCompactMatchRequiresTokenBoundary() async {
        let got = await processed("snippet tksunwave")
        XCTAssertEqual(got, "snippet tksunwave", "a longer word must not match a shorter key")
    }

    func testCompactMatchingDisabledForOrdinaryPhrases() async {
        // "so on" has no single-letter token → compact matching stays off, so the
        // word "soon" is untouched.
        let matcher = ReplacementMatcher(rules: [("so on", "REPLACED")])
        let got = await TranscriptPipeline().process(
            "see you soon", settings: ProcessingSettings(cleanupMode: .off, replacements: matcher, snippets: .empty)
        ).final
        XCTAssertEqual(got, "see you soon")
    }

    // MARK: replacement triggers get the same treatment

    func testSpelledLetterReplacementTrigger() async {
        let matcher = ReplacementMatcher(rules: [("t k sun w", "tksunw")])
        for raw in ["my handle is TK sun W", "my handle is T. K. Sun W.", "my handle is t k sun w"] {
            let got = await TranscriptPipeline().process(
                raw, settings: ProcessingSettings(cleanupMode: .off, replacements: matcher, snippets: .empty)
            ).final
            XCTAssertEqual(got, "my handle is tksunw" + (raw.hasSuffix(".") ? "." : ""), "raw: \(raw)")
        }
    }

    // MARK: command prefixes tolerate auto-punctuation

    func testPrefixesTolerateTrailingPunctuation() async {
        let hash = await processed("Hashtag, yard sale")
        XCTAssertEqual(hash, "#yard sale")
        let emoji = await processed("Emoji, thumbs up")
        XCTAssertEqual(emoji, "👍")
    }
}

@MainActor
final class CommandModeFeedbackTests: XCTestCase {
    func testNoSelectionShowsInstructionalMessage() async {
        let indicator = FakeIndicator()
        let controller = DictationController(
            hotkey: FakeHotkey(),
            recorder: FakeRecorder(),
            engine: FakeEngine(),
            inserter: FakeInserter(),
            statusItem: FakeStatus(),
            indicator: indicator,
            processingSettings: { ProcessingSettings() },
            playSound: { _ in },
            frontmostPID: { 42 },
            onboardingPresenter: { _, _ in },
            transformer: FakeTransformer(),
            selectionProvider: { nil },
            commandModeAvailable: { true }
        )
        await controller.initializePipeline()
        controller.commandKeyDown()
        XCTAssertEqual(indicator.messages.count, 1, "an invisible failure is a bug — say why")
        XCTAssertTrue(indicator.messages[0].contains("Select some text"))
    }

    func testUnavailableModelShowsMessage() async {
        let indicator = FakeIndicator()
        let controller = DictationController(
            hotkey: FakeHotkey(),
            recorder: FakeRecorder(),
            engine: FakeEngine(),
            inserter: FakeInserter(),
            statusItem: FakeStatus(),
            indicator: indicator,
            processingSettings: { ProcessingSettings() },
            playSound: { _ in },
            frontmostPID: { 42 },
            onboardingPresenter: { _, _ in },
            transformer: FakeTransformer(),
            selectionProvider: { ("text", 42) },
            commandModeAvailable: { false }
        )
        await controller.initializePipeline()
        controller.commandKeyDown()
        XCTAssertEqual(indicator.messages.count, 1)
        XCTAssertTrue(indicator.messages[0].contains("Apple Intelligence"))
    }
}
