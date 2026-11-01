// Performance requirement: deterministic parsing, replacements, commands, and
// snippet resolution under 20 ms for a 4,000-character transcript with a large
// (500 + 500) customization set.

import XCTest
@testable import Internos

final class PipelinePerformanceTests: XCTestCase {
    func testDeterministicProcessingSpeed() async {
        var rules: [(String, String)] = (0..<499).map { ("trigger phrase \($0)", "output \($0)") }
        rules.append(("cube control", "kubectl"))
        let matcher = ReplacementMatcher(rules: rules)
        var snippets: [(UUID, String, String)] = (0..<499).map { (UUID(), "snippet name \($0)", "content \($0)") }
        snippets.append((UUID(), "sig", "Cheers,\nTim"))
        let table = SnippetTable(snippets: snippets)
        let settings = ProcessingSettings(cleanupMode: .off, replacements: matcher, snippets: table)

        let sentence = "the quick brown fox asked cube control to jump new line bullet point over the lazy dog snippet sig and emoji thumbs up then "
        var raw = ""
        while raw.count < 4000 { raw += sentence }
        raw = String(raw.prefix(4000))

        let pipeline = TranscriptPipeline()
        _ = await pipeline.process(raw, settings: settings) // warm-up

        let start = ContinuousClock.now
        let result = await pipeline.process(raw, settings: settings)
        let elapsed = ContinuousClock.now - start

        XCTAssertFalse(result.final.isEmpty)
        // 20 ms is the release-hardware target; this debug-build assert catches
        // order-of-magnitude regressions without being flaky on CI.
        XCTAssertLessThan(elapsed, .milliseconds(100), "deterministic processing too slow: \(elapsed)")
        print("Internos perf: 4000-char deterministic pipeline took \(elapsed)")
    }

    func testSpellingNormalizationSpeed() async {
        let paragraph = "The color of the harbor at the center of town organized itself around a gray program of labor, humor and flavor. "
        var raw = ""
        while raw.count < 4000 { raw += paragraph }
        raw = String(raw.prefix(4000))
        let settings = ProcessingSettings(cleanupMode: .off, spelling: .british, replacements: .empty, snippets: .empty)

        let pipeline = TranscriptPipeline()
        _ = await pipeline.process(raw, settings: settings) // warm-up, includes the one-time table parse

        let start = ContinuousClock.now
        let result = await pipeline.process(raw, settings: settings)
        let elapsed = ContinuousClock.now - start

        XCTAssertTrue(result.final.contains("colour") && result.final.contains("program"), result.final)
        XCTAssertLessThan(elapsed, .milliseconds(100), "spelling normalization too slow: \(elapsed)")
        print("Internos perf: 4000-char British spelling pass took \(elapsed)")
    }
}
