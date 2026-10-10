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

    // MARK: punctuation in triggers and outputs

    func testTriggerWithAbbreviationPeriodMatches() async {
        let rules = [("Dr. Smith", "Dr. Smyth")]
        let dotted = await processed("ask Dr. Smith about it", rules)
        XCTAssertEqual(dotted, "ask Dr. Smyth about it")
        let bare = await processed("ask Dr Smith, please", rules)
        XCTAssertEqual(bare, "ask Dr Smith, please", "punctuation typed in a trigger is required")
    }

    func testTriggerPunctuationIsConsumedNotDuplicated() async {
        let rules = [("vs.", "versus"), ("e.g.", "for example")]
        let a = await processed("cats vs. dogs", rules)
        XCTAssertEqual(a, "cats versus dogs")
        let b = await processed("fruit, e.g., apples", rules)
        XCTAssertEqual(b, "fruit, for example, apples")
    }

    /// An abbreviation rule must not fire on the ordinary word it abbreviates to.
    func testAbbreviationTriggerDoesNotMatchTheBareWord() async {
        let rules = [("in.", "inches"), ("no.", "number")]
        let a = await processed("I'm in the office, no question", rules)
        XCTAssertEqual(a, "I'm in the office, no question")
        let b = await processed("cut 4 in. off board no. 7", rules)
        XCTAssertEqual(b, "cut 4 inches off board number 7")
    }

    /// One period ends both the abbreviation and the sentence.
    func testAbbreviationAtEndOfSentenceKeepsTheFullStop() async {
        let a = await processed("apples, oranges, etc.", [("etc.", "et cetera")])
        XCTAssertEqual(a, "apples, oranges, et cetera.")
        let b = await processed("see the appendix, ect.", [("ect.", "etc.")])
        XCTAssertEqual(b, "see the appendix, etc.", "no doubled period when the output has its own")
        // Only where the text stops. A break ends the sentence; an emoji does not.
        let c = await processed("thanks Dr. emoji thumbs up", [("Dr.", "Doctor")])
        XCTAssertEqual(c, "thanks Doctor 👍")
        let d = await processed("apples, etc. new line pears", [("etc.", "et cetera")])
        XCTAssertEqual(d, "apples, et cetera.\npears")
        let f = await processed("she said \u{201C}apples, etc.\u{201D}", [("etc.", "et cetera")])
        XCTAssertEqual(f, "she said \u{201C}apples, et cetera.\u{201D}")
        let g = await processed("open quote apples, etc. close quote", [("etc.", "et cetera")])
        XCTAssertEqual(g, "\u{201C}apples, et cetera.\u{201D}", "a spoken closing quote is still the end")
        let h = await processed("apples, etc... and more", [("etc.", "et cetera")])
        XCTAssertEqual(h, "apples, et cetera... and more", "an ellipsis stays whole")
        let e = await processed("apples, pears, etc.", [("etc.", "and so on!")])
        XCTAssertEqual(e, "apples, pears, and so on!", "the output brought its own ending")
    }

    /// Punctuation is required even where spelled letters would otherwise be
    /// matched run-together: "I. T." is not the word "it".
    func testPunctuatedSpelledLettersDoNotSquash() async {
        let rules = [("I. T.", "IT department"), ("Plan B.", "the fallback")]
        let a = await processed("it is plan b for it", rules)
        XCTAssertEqual(a, "it is plan b for it")
        let b = await processed("ask I. T. about Plan B. tomorrow", rules)
        XCTAssertEqual(b, "ask IT department about the fallback tomorrow")
    }

    /// A dotted and a bare trigger are different rules, and neither is dead.
    func testDottedAndBareTriggersCoexist() async {
        for rules in [[("vs", "versus"), ("vs.", "v.")], [("vs.", "v."), ("vs", "versus")]] {
            let got = await processed("cats vs dogs, Smith vs. Jones, us vs them", rules)
            XCTAssertEqual(got, "cats versus dogs, Smith v. Jones, us versus them")
        }
    }

    func testSentenceBoundaryStillBlocksAPlainTrigger() async {
        let got = await processed("I went home. Smith stayed", [("home smith", "WRONG")])
        XCTAssertEqual(got, "I went home. Smith stayed")
    }

    /// Punctuation typed in a trigger is required on both sides of the word.
    func testLeadingAndWrappingPunctuationInTriggers() async {
        let rules = [("(c)", "©"), ("'til", "until"), ("rock 'n' roll", "rock and roll"), ("...", "\u{2026}")]
        let a = await processed("vitamin c is fine til then", rules)
        XCTAssertEqual(a, "vitamin c is fine til then", "the bare words are not the triggers")
        let b = await processed("wait 'til the (c) notice, ('til then)", rules)
        XCTAssertEqual(b, "wait until the © notice, (until then)")
        let c = await processed("we like rock 'n' roll.", rules)
        XCTAssertEqual(c, "we like rock and roll.")
        let d = await processed("wait ... what?", rules)
        XCTAssertEqual(d, "wait\u{2026} what?")
    }

    /// Output starting with punctuation attaches, the way a suffix should.
    func testOutputStartingWithPunctuationAttaches() async {
        let rules = [("incorporated", ", Inc."), ("dot com", ".com"), ("apostrophe s", "'s"), ("comma", ",")]
        let a = await processed("Acme incorporated owns example dot com", rules)
        XCTAssertEqual(a, "Acme, Inc. owns example.com")
        let b = await processed("that is Tim apostrophe s desk comma I think", rules)
        XCTAssertEqual(b, "that is Tim's desk, I think")
    }

    /// A leading space in the output is the user saying "this is a word".
    func testLeadingSpaceInOutputKeepsItApart() async {
        let rules = [("dot net", " .NET"), ("colon w q", " :wq")]
        let a = await processed("I use dot net daily", rules)
        XCTAssertEqual(a, "I use .NET daily")
        let b = await processed("dot net is fine, new line colon w q saves", rules)
        XCTAssertEqual(b, ".NET is fine,\n:wq saves", "no stray space where there is nothing to separate")
        let c = await processed("the (dot net) runtime", rules)
        XCTAssertEqual(c, "the (.NET) runtime")
    }

    func testLoneArticleDoesNotEnableLetterRunMatching() async {
        let a = await processed("they drifted apart", [("a part", "WRONG")])
        XCTAssertEqual(a, "they drifted apart")
        let b = await processed("it is a part of it", [("a part", "one piece")])
        XCTAssertEqual(b, "it is one piece of it")
        // Spelled letters still squash, including a leading "a".
        let c = await processed("deploy to AWS today", [("a w s", "Amazon Web Services")])
        XCTAssertEqual(c, "deploy to Amazon Web Services today")
        let d = await processed("get an xray", [("x ray", "X-ray")])
        XCTAssertEqual(d, "get an X-ray")
        // "i" and a bare letter beside a punctuated word still count, as they always did.
        let e = await processed("my Iphone met MRT and Mr T", [("i phone", "iPhone"), ("Mr. T", "Mr. T")])
        XCTAssertEqual(e, "my iPhone met Mr. T and Mr. T")
    }
}
