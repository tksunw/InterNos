// Deterministic pipeline coverage: command parser, renderer, and the migrated
// hashtag/emoji/symbol behavior (feature handoff phases 1 and 3).

import XCTest
@testable import Internos

/// Deterministic processing only: cleanup off, no replacements, optional snippets.
private func plain(_ raw: String, snippets: SnippetTable = .empty) async -> String {
    await TranscriptPipeline().process(
        raw, settings: ProcessingSettings(cleanupMode: .off, replacements: .empty, snippets: snippets)
    ).final
}

final class TranscriptCommandParserTests: XCTestCase {
    // MARK: migrated hashtag / emoji / symbol behavior

    func testLegacySubstitutionsStillPass() async {
        let cases: [(String, String)] = [
            ("Hashtag yard sale this weekend.", "#yard sale this weekend."),
            ("Check out hashtag yard.", "Check out #yard."),
            ("Emoji thumbs up.", "👍."),
            ("Sounds good emoji smiley face", "Sounds good 🙂"),
            ("emoji flibbertigibbet", "emoji flibbertigibbet"),
            ("She sent me a smiley face.", "She sent me a smiley face."),
            ("tim at sign example.com", "tim @ example.com"),
            ("that's the hashtag", "that's the hashtag"),
        ]
        for (input, expected) in cases {
            let got = await plain(input)
            XCTAssertEqual(got, expected, "input: \(input)")
        }
    }

    // MARK: structural commands

    func testStructuralCommands() async {
        let cases: [(String, String)] = [
            ("say new line now", "say\nnow"),
            ("first line New Line second line", "first line\nsecond line"),
            ("one new paragraph two", "one\n\ntwo"),
            ("end of sentence new line.", "end of sentence."),
            ("stop here. new line next", "stop here.\nnext"),
            ("open quote hello close quote", "\u{201C}hello\u{201D}"),
            ("she said open quote yes close quote loudly", "she said \u{201C}yes\u{201D} loudly"),
            ("open parenthesis aside close parenthesis done", "(aside) done"),
            ("value open parenthesis in dollars close parenthesis.", "value (in dollars)."),
        ]
        for (input, expected) in cases {
            let got = await plain(input)
            XCTAssertEqual(got, expected, "input: \(input)")
        }
    }

    func testCommandsWorkWithCapitalizationAndPunctuation() async {
        let a = await plain("first New Line, second")
        XCTAssertEqual(a, "first,\nsecond")
        let b = await plain("first NEW PARAGRAPH second")
        XCTAssertEqual(b, "first\n\nsecond")
    }

    func testOrdinaryWordsDoNotTriggerCommands() async {
        for input in ["the newline character", "a bulletproof vest", "a parenthetical remark",
                      "renumbered items", "his new lines of code were great"] {
            let got = await plain(input)
            XCTAssertEqual(got, input, "must remain unchanged: \(input)")
        }
    }

    func testRepeatedBreaksAreCappedAtTwoNewlines() async {
        let a = await plain("one new line new line two")
        XCTAssertEqual(a, "one\n\ntwo", "two explicit new lines make one blank line")
        let b = await plain("one new paragraph new paragraph two")
        XCTAssertEqual(b, "one\n\ntwo", "separator newlines never exceed two")
        let c = await plain("one new paragraph new line two")
        XCTAssertEqual(c, "one\n\ntwo")
    }

    func testTrailingCommandAddsNoTrailingWhitespace() async {
        let got = await plain("done new line")
        XCTAssertEqual(got, "done")
    }

    // MARK: lists

    func testBulletList() async {
        let got = await plain("bullet point apples bullet point oranges bullet point pears")
        XCTAssertEqual(got, "• apples\n• oranges\n• pears")
    }

    func testNumberedListIncrementsAndParagraphResets() async {
        let a = await plain("numbered item first numbered item second numbered item third")
        XCTAssertEqual(a, "1. first\n2. second\n3. third")
        let b = await plain("numbered item first numbered item second new paragraph numbered item fresh")
        XCTAssertEqual(b, "1. first\n2. second\n\n1. fresh")
    }

    func testListAfterTextStartsOnNewLine() async {
        let got = await plain("shopping list numbered item milk numbered item eggs")
        XCTAssertEqual(got, "shopping list\n1. milk\n2. eggs")
    }

    func testSwitchingListTypeStartsNewRun() async {
        let got = await plain("numbered item one bullet point extra numbered item restart")
        XCTAssertEqual(got, "1. one\n• extra\n1. restart")
    }

    // MARK: literal escape

    func testLiteralEscape() async {
        let cases: [(String, String)] = [
            ("say literal new line now", "say new line now"),
            ("literal emoji thumbs up", "emoji thumbs up"),
            ("literal literal", "literal"),
            ("literal hashtag yard", "hashtag yard"),
            ("literal at sign", "at sign"),
            ("a literal genius", "a literal genius"), // unmatched escape stays a word
            ("ends with literal", "ends with literal"),
        ]
        for (input, expected) in cases {
            let got = await plain(input)
            XCTAssertEqual(got, expected, "input: \(input)")
        }
    }

    func testLiteralEscapesExactlyOnePhrase() async {
        let got = await plain("say literal new line now new line done")
        XCTAssertEqual(got, "say new line now\ndone")
    }

    // MARK: whitespace preservation

    func testOrdinaryWhitespaceIsNotCollapsed() async {
        let got = await plain("keep  double  spaces intact")
        XCTAssertEqual(got, "keep  double  spaces intact")
    }
}

final class TranscriptRendererTests: XCTestCase {
    func testMarksAttachWithoutInnerSpaces() {
        let out = TranscriptRenderer.render([
            .text("she said"), .openingMark("\u{201C}"), .text("yes"), .closingMark("\u{201D}"), .text("today"),
        ])
        XCTAssertEqual(out, "she said \u{201C}yes\u{201D} today")
    }

    func testNoSpaceInsertedBeforePunctuation() {
        let out = TranscriptRenderer.render([.text("wait"), .text(", right")])
        XCTAssertEqual(out, "wait, right")
    }

    func testSnippetExpandsExactly() {
        let id = UUID()
        let table = SnippetTable(snippets: [(id, "sig", "Line one\n\tLine two ✨")])
        let out = TranscriptRenderer.render([.text("Thanks,"), .snippet(id)], snippets: table)
        XCTAssertEqual(out, "Thanks, Line one\n\tLine two ✨")
    }

    func testUnknownSnippetRendersNothing() {
        let out = TranscriptRenderer.render([.text("before"), .snippet(UUID()), .text("after")])
        XCTAssertEqual(out, "before after")
    }

    func testLiteralSegmentsRenderVerbatim() {
        let out = TranscriptRenderer.render([.literal("new line stays text"), .text("ok")])
        XCTAssertEqual(out, "new line stays text ok")
    }
}

final class UpdateCheckerTests: XCTestCase {
    @MainActor
    func testVersionCompare() {
        XCTAssertTrue(UpdateChecker.isNewer("1.0.5", than: "1.0.4"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.10", than: "1.0.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.4", than: "1.0.5"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0", than: "1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0.0"))
    }
}
