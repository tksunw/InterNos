// Feature 5 acceptance criteria: voice-triggered snippets stay exact and protected.

import XCTest
@testable import Internos

final class SnippetProcessorTests: XCTestCase {
    private let calendarID = UUID()
    private let signatureID = UUID()
    private let supportID = UUID()

    private var table: SnippetTable {
        SnippetTable(snippets: [
            (calendarID, "calendar link", "https://example.com/schedule"),
            (signatureID, "email signature", "Cheers,\nTim Kennedy\nSenior Platform Engineer ✨"),
            (supportID, "support response", "Thanks for reaching out!\n\n\tWe're on it."),
        ])
    }

    private func processed(_ raw: String, replacements: ReplacementMatcher = .empty) async -> String {
        await TranscriptPipeline().process(
            raw, settings: ProcessingSettings(cleanupMode: .off, replacements: replacements, snippets: table)
        ).final
    }

    func testExplicitInvocationInsertsExactContent() async {
        let got = await processed("snippet calendar link")
        XCTAssertEqual(got, "https://example.com/schedule")
    }

    func testInvocationInsideSentence() async {
        let got = await processed("Thanks, snippet email signature")
        XCTAssertEqual(got, "Thanks, Cheers,\nTim Kennedy\nSenior Platform Engineer ✨")
    }

    func testMultilineUnicodeContentIsExact() async {
        let got = await processed("Use snippet support response")
        XCTAssertEqual(got, "Use Thanks for reaching out!\n\n\tWe're on it.")
    }

    func testNameWithoutPrefixStaysLiteralText() async {
        let got = await processed("the calendar link is broken")
        XCTAssertEqual(got, "the calendar link is broken")
    }

    func testUnknownNameStaysUnchanged() async {
        let got = await processed("snippet mystery thing here")
        XCTAssertEqual(got, "snippet mystery thing here")
    }

    func testLiteralEscapePreventsExpansion() async {
        let got = await processed("literal snippet calendar link")
        XCTAssertEqual(got, "snippet calendar link")
    }

    func testDisabledSnippetsDoNotExpand() async {
        let disabled = SnippetTable(snippets: []) // the store filters disabled entries out
        let got = await TranscriptPipeline().process(
            "snippet calendar link",
            settings: ProcessingSettings(cleanupMode: .off, replacements: .empty, snippets: disabled)
        ).final
        XCTAssertEqual(got, "snippet calendar link")
    }

    func testLongestNameWins() async {
        let extendedID = UUID()
        let overlapping = SnippetTable(snippets: [
            (calendarID, "calendar", "SHORT"),
            (extendedID, "calendar link", "LONG"),
        ])
        let got = await TranscriptPipeline().process(
            "snippet calendar link",
            settings: ProcessingSettings(cleanupMode: .off, replacements: .empty, snippets: overlapping)
        ).final
        XCTAssertEqual(got, "LONG")
    }

    func testCaseInsensitiveInvocationWithPunctuation() async {
        let got = await processed("Snippet Calendar Link.")
        XCTAssertEqual(got, "https://example.com/schedule.")
    }

    func testSnippetContentIsProtectedFromReplacementsAndCommands() async {
        // Content contains a replacement trigger AND a command phrase; both must stay literal.
        let boobyTrappedID = UUID()
        let trapped = SnippetTable(snippets: [
            (boobyTrappedID, "trap", "cube control new line hashtag yard"),
        ])
        let matcher = ReplacementMatcher(rules: [("cube control", "kubectl")])
        let got = await TranscriptPipeline().process(
            "run snippet trap now",
            settings: ProcessingSettings(cleanupMode: .off, replacements: matcher, snippets: trapped)
        ).final
        XCTAssertEqual(got, "run cube control new line hashtag yard now",
                       "snippet content must never be re-processed")
    }

    func testSnippetExpandsOncePerInvocation() async {
        let got = await processed("snippet calendar link and snippet calendar link")
        XCTAssertEqual(got, "https://example.com/schedule and https://example.com/schedule")
    }
}
