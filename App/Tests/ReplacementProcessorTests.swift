// Feature 1 acceptance criteria: deterministic personal-dictionary replacements.

import XCTest
@testable import Internos

final class ReplacementProcessorTests: XCTestCase {
    private func settings(_ rules: [(String, String)], snippets: SnippetTable = .empty) -> ProcessingSettings {
        ProcessingSettings(cleanupMode: .off, replacements: ReplacementMatcher(rules: rules), snippets: snippets)
    }

    private func processed(_ raw: String, _ rules: [(String, String)]) async -> String {
        await TranscriptPipeline().process(raw, settings: settings(rules)).final
    }

    func testCaseInsensitiveMatchingEmitsConfiguredCase() async {
        let rules = [("power shell", "PowerShell")]
        for input in ["Power Shell", "power shell", "POWER SHELL"] {
            let got = await processed("we use \(input) here", rules)
            XCTAssertEqual(got, "we use PowerShell here", "input: \(input)")
        }
    }

    func testWholeWordsOnly() async {
        let a = await processed("please concatenate the strings", [("cat", "🐱")])
        XCTAssertEqual(a, "please concatenate the strings", "cat must not match inside concatenate")
        let b = await processed("the internal review", [("internal", "IN-TERNAL")])
        XCTAssertEqual(b, "the IN-TERNAL review")
        let c = await processed("Internos is great", [("internal", "IN-TERNAL")])
        XCTAssertEqual(c, "Internos is great", "internal must not modify Internos")
    }

    func testLongestTriggerWins() async {
        let rules = [("power", "POWER"), ("power shell", "PowerShell")]
        let got = await processed("the power shell prompt", rules)
        XCTAssertEqual(got, "the PowerShell prompt")
        let single = await processed("raw power output", rules)
        XCTAssertEqual(single, "raw POWER output")
    }

    func testMultiWordTechnicalTriggers() async {
        let got = await processed("run cube control get pods and t k sun w",
                                  [("cube control", "kubectl"), ("t k sun w", "tksunw")])
        XCTAssertEqual(got, "run kubectl get pods and tksunw")
    }

    func testPunctuationOutsideMatchIsPreserved() async {
        let got = await processed("Have you tried cube control?", [("cube control", "kubectl")])
        XCTAssertEqual(got, "Have you tried kubectl?")
        let comma = await processed("internist, our app, is fast", [("internist", "Internos")])
        XCTAssertEqual(comma, "Internos, our app, is fast")
    }

    func testReplacementOutputStaysLiteral() async {
        // Output containing a command phrase must not become a command.
        let a = await processed("insert marker here", [("marker", "the new line marker")])
        XCTAssertEqual(a, "insert the new line marker here")
        // Output containing another trigger must not be replaced again.
        let b = await processed("say alpha", [("alpha", "beta"), ("beta", "gamma")])
        XCTAssertEqual(b, "say beta")
        // Output containing the word snippet stays literal.
        let c = await processed("say shortcut", [("shortcut", "snippet calendar link")])
        XCTAssertEqual(c, "say snippet calendar link")
    }

    func testEachSpanReplacedOnce() async {
        let got = await processed("echo echo echo", [("echo", "echo echo")])
        XCTAssertEqual(got, "echo echo echo echo echo echo", "no recursion, each source span once")
    }

    func testReplacementInsideCommandContext() async {
        let got = await processed("bullet point cube control basics", [("cube control", "kubectl")])
        XCTAssertEqual(got, "• kubectl basics")
    }

    func testDisabledRulesViaEmptyMatcher() async {
        // The pipeline only sees enabled rules (the store filters); an empty matcher changes nothing.
        let got = await processed("power shell stays", [])
        XCTAssertEqual(got, "power shell stays")
    }

    func testUnicodeTriggers() async {
        let got = await processed("visit the café now", [("café", "Café Internos")])
        XCTAssertEqual(got, "visit the Café Internos now")
    }
}
