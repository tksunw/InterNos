// Spelling convention (docs/specs/spelling-convention.md): deterministic, no model.

import XCTest
@testable import Internos

final class SpellingNormalizerTests: XCTestCase {
    private func normalize(_ text: String, _ convention: SpellingConvention, startsSentence: Bool = true) -> String {
        SpellingNormalizer(convention: convention).normalize(text, startsSentence: startsSentence)
    }

    // MARK: table shape (the spec's expected pairs, through the committed table)

    func testAmericanTargetGetsTheBritishForms() {
        let pairs = [
            ("colour", "color"), ("organise", "organize"), ("centre", "center"), ("cheque", "check"),
            ("programme", "program"), ("metre", "meter"), ("tyre", "tire"), ("storey", "story"),
            ("kerb", "curb"), ("gaol", "jail"), ("labour", "labor"),
        ]
        for (source, target) in pairs {
            XCTAssertEqual(normalize(source, .american), target)
        }
    }

    func testBritishTargetGetsOnlyUnambiguousAmericanForms() {
        for (source, target) in [("color", "colour"), ("organize", "organise"), ("center", "centre"), ("labor", "labour")] {
            XCTAssertEqual(normalize(source, .british), target)
        }
        // Each of these is a different British word on at least one VarCon line.
        for word in ["check", "program", "meter", "story", "tire", "curb"] {
            XCTAssertEqual(normalize(word, .british), word)
        }
        XCTAssertEqual(normalize("I'll check the program's meter", .british), "I'll check the program's meter")
    }

    func testOtherConventions() {
        XCTAssertEqual(normalize("organise colour", .oxford), "organize colour")
        XCTAssertEqual(normalize("color center organise tyre", .canadian), "colour centre organize tire")
        XCTAssertEqual(normalize("programme color", .australian), "program colour")
        XCTAssertEqual(normalize("program", .australian), "program")
        for convention in SpellingConvention.allCases where convention != .asRecognized {
            XCTAssertEqual(normalize("gaol", convention), "jail", "\(convention)")
        }
    }

    // MARK: case and proper nouns

    func testCasePatterns() {
        XCTAssertEqual(normalize("colour", .american), "color")
        XCTAssertEqual(normalize("Colour is nice.", .american), "Color is nice.")
        XCTAssertEqual(normalize("COLOUR", .american), "COLOUR")
        XCTAssertEqual(normalize("ColOur", .american), "ColOur")
    }

    func testProperNounsMidSentenceSurvive() {
        XCTAssertEqual(normalize("I crossed the Harbour Bridge", .american), "I crossed the Harbour Bridge")
        XCTAssertEqual(normalize("Harbour views are nice.", .american), "Harbor views are nice.")
        // After a sentence ender the next word is sentence-initial again.
        XCTAssertEqual(normalize("Fine. Colour it in.", .american), "Fine. Color it in.")
        XCTAssertEqual(normalize("Centrelink paid.", .american, startsSentence: false), "Centrelink paid.")
        XCTAssertEqual(normalize("Colour it in", .american, startsSentence: false), "Colour it in")
    }

    // MARK: possessives, hyphens, punctuation, whitespace

    func testPossessiveAndHyphen() {
        XCTAssertEqual(normalize("the colour's depth", .american), "the color's depth")
        XCTAssertEqual(normalize("colour-blind", .american), "color-blind")
        XCTAssertEqual(normalize("e-mail", .american), "e-mail")
    }

    func testPunctuationAndWhitespacePreserved() {
        XCTAssertEqual(
            normalize("\"Colour,\"  she said;  (organise!)\n", .american),
            "\"Color,\"  she said;  (organize!)\n")
        XCTAssertEqual(normalize("  colour  ", .american), "  color  ")
    }

    func testAsRecognizedIsIdentity() {
        let text = "colour organise centre"
        XCTAssertEqual(normalize(text, .asRecognized), text)
        XCTAssertEqual(SpellingNormalizer.none.normalizedCore("colour"), "colour")
    }

    func testNonEnglishLocaleIsNoOp() {
        XCTAssertEqual(SpellingConvention.british.effective(forLocaleIdentifier: "es_ES"), .asRecognized)
        XCTAssertEqual(SpellingConvention.british.effective(forLocaleIdentifier: "en_AU"), .british)
        XCTAssertEqual(SpellingConvention.asRecognized.effective(forLocaleIdentifier: "en_US"), .asRecognized)
    }

    func testNormalizedCoreForTriggers() {
        let normalizer = SpellingNormalizer(convention: .american)
        XCTAssertEqual(normalizer.normalizedCore("colour"), "color")
        XCTAssertEqual(normalizer.normalizedCore("colour-blind"), "color-blind")
        XCTAssertEqual(normalizer.normalizedCore("kubectl"), "kubectl")
    }
}

final class SpellingPipelineTests: XCTestCase {
    private func settings(
        _ spelling: SpellingConvention, rules: [(String, String)] = [], snippets: SnippetTable = .empty,
        cleanup: CleanupMode = .off
    ) -> ProcessingSettings {
        ProcessingSettings(
            cleanupMode: cleanup, spelling: spelling,
            replacements: ReplacementMatcher(rules: rules, normalizer: SpellingNormalizer(convention: spelling)),
            snippets: snippets)
    }

    func testProtectedSegmentsAreNotRespelled() async {
        let id = UUID()
        let table = SnippetTable(snippets: [(id, "sig", "Cheers from the colour team")])
        let result = await TranscriptPipeline().process(
            "the colour of money snippet sig and more colour",
            settings: settings(.american, rules: [("money", "colour money")], snippets: table))
        XCTAssertEqual(result.final, "the color of colour money Cheers from the colour team and more color")
    }

    func testReplacementTriggerTypedInSourceSpellingStillFires() async {
        let result = await TranscriptPipeline().process(
            "pick a colour now", settings: settings(.american, rules: [("colour", "COLOUR!")]))
        XCTAssertEqual(result.final, "pick a COLOUR! now")
    }

    func testCleanupOutputIsNormalized() async {
        let cleaner = FakeCleaner()
        cleaner.transform = { _ in "We organised the colour palette." }
        let result = await TranscriptPipeline(cleaner: cleaner).process(
            "um we organised the colour palette", settings: settings(.american, cleanup: .light))
        XCTAssertEqual(result.final, "We organized the color palette.")
        XCTAssertTrue(result.cleanupApplied)
    }

    func testSentenceStartAfterBreak() async {
        let result = await TranscriptPipeline().process(
            "I like it new line Colour me surprised", settings: settings(.american))
        XCTAssertEqual(result.final, "I like it\nColor me surprised")
    }

    func testAsRecognizedLeavesTextAlone() async {
        let result = await TranscriptPipeline().process("the colour of money", settings: settings(.asRecognized))
        XCTAssertEqual(result.final, "the colour of money")
    }
}
