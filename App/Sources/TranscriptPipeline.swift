// Staged transcript processing (feature handoff, processing architecture):
//   raw speech → command parser → [smart cleanup] → user replacements → renderer → final text.
//
// Protected segments are the privacy/correctness backbone: snippet contents, literal
// escapes, and replacement outputs are never re-parsed, never re-replaced, and never
// sent to a language model. Only ordinary `.text` segments are eligible for cleanup
// and replacement.

import Foundation

struct TranscriptResult: Equatable, Sendable {
    let raw: String
    let final: String
    let cleanupApplied: Bool
}

enum TranscriptSegment: Equatable, Sendable {
    /// Ordinary speech text. Cleanup and user replacements apply only here.
    case text(String)
    /// Protected exact output (literal escapes, emoji/hashtag/symbol results,
    /// replacement outputs). Rendered verbatim, skipped by every later stage.
    case literal(String)
    case lineBreak
    case paragraphBreak
    case bulletItem
    case numberedItem
    /// Attaches to the following word with no space after it (“, ().
    case openingMark(String)
    /// Attaches to the preceding word with no space before it (”, )).
    case closingMark(String)
    /// Expanded by the renderer from the snippet table; content is never processed.
    case snippet(UUID)
}

enum CleanupMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case light
    case polished
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Off"
        case .light: "Light"
        case .polished: "Polished"
        }
    }
}

/// On-device text cleanup. `nil` means "fall back to the original text" — every
/// failure (unavailable, timeout, refusal, invalid output) is a soft failure.
protocol SmartCleaning: Sendable {
    func clean(_ text: String, mode: CleanupMode) async -> String?
}

/// Everything the pipeline needs, snapshotted at the start of processing so a
/// settings edit can't change a transcript halfway through (feature handoff,
/// settings layout).
struct ProcessingSettings: Sendable {
    var cleanupMode: CleanupMode = .off
    var replacements: ReplacementMatcher = .empty
    var snippets: SnippetTable = .empty
}

protocol TranscriptProcessing: Sendable {
    func process(_ raw: String, settings: ProcessingSettings) async -> TranscriptResult
}

struct TranscriptPipeline: TranscriptProcessing {
    /// Absent (or mode .off) means deterministic-only processing.
    var cleaner: (any SmartCleaning)?

    init(cleaner: (any SmartCleaning)? = nil) {
        self.cleaner = cleaner
    }

    func process(_ raw: String, settings: ProcessingSettings) async -> TranscriptResult {
        var segments = TranscriptCommandParser.parse(raw, snippets: settings.snippets)
        var cleanupApplied = false

        // Cleanup runs only when the utterance is one plain text segment. Commands
        // and snippets punch holes in the text, and the model, handed a dangling
        // fragment like "my github handle is", invents completions for it — a beta
        // field report saw a fabricated markdown link. Structured utterances take
        // the deterministic path.
        if settings.cleanupMode != .off, let cleaner,
           segments.count == 1, case .text(let original) = segments[0] {
            if let cleaned = await cleaner.clean(original, mode: settings.cleanupMode),
               cleaned != original {
                segments[0] = .text(cleaned)
                cleanupApplied = true
            }
        }

        // Replacements run after cleanup so configured spelling is authoritative.
        segments = segments.flatMap { segment -> [TranscriptSegment] in
            guard case .text(let text) = segment else { return [segment] }
            return settings.replacements.apply(to: text)
        }

        let final = TranscriptRenderer.render(segments, snippets: settings.snippets)
        return TranscriptResult(raw: raw, final: final, cleanupApplied: cleanupApplied)
    }
}

// MARK: - Replacement matching

/// Precomputed matcher for the personal dictionary (feature 1). Built once when the
/// configuration changes, not per token: rules are keyed by first word and sorted
/// longest-first so overlapping triggers resolve to the longest match.
struct ReplacementMatcher: Sendable {
    static let empty = ReplacementMatcher(rules: [])

    private struct Rule: Sendable {
        let tokens: [String]
        let output: String
    }

    private struct CompactRule: Sendable {
        let key: String
        let output: String
    }

    private let byFirstWord: [String: [Rule]]
    /// Letter-run-insensitive fallback, bucketed by first character of the
    /// squashed key so the per-token cost stays flat with large rule sets.
    private let compactByFirstChar: [Character: [CompactRule]]

    var isEmpty: Bool { byFirstWord.isEmpty }

    init(rules: [(trigger: String, output: String)]) {
        var map: [String: [Rule]] = [:]
        var compact: [Character: [CompactRule]] = [:]
        for rule in rules {
            let tokens = Self.normalizedTriggerTokens(rule.trigger)
            guard let first = tokens.first else { continue }
            map[first, default: []].append(Rule(tokens: tokens, output: rule.output))
            let key = SnippetTable.compactKey(of: tokens)
            if let firstChar = key.first {
                compact[firstChar, default: []].append(CompactRule(key: key, output: rule.output))
            }
        }
        byFirstWord = map.mapValues { $0.sorted { $0.tokens.count > $1.tokens.count } }
        compactByFirstChar = compact.mapValues { $0.sorted { $0.key.count > $1.key.count } }
    }

    /// Locale-independent case folding + whitespace normalization, shared with
    /// validation so duplicate detection and matching agree.
    static func normalizedTriggerTokens(_ trigger: String) -> [String] {
        trigger.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    /// Splits ordinary text into text/literal segments. Whole-word matches only;
    /// each span is replaced at most once and outputs are emitted as protected
    /// literals, so replacement text can never trigger anything else.
    func apply(to text: String) -> [TranscriptSegment] {
        guard !isEmpty else { return [.text(text)] }
        let tokens = TranscriptTokenizer.tokenize(text)
        var segments: [TranscriptSegment] = []
        var runStart: Int?

        func flushRun(upTo end: Int) {
            if let start = runStart, start < end {
                segments.append(.text(String(text[tokens[start].range.lowerBound..<tokens[end - 1].range.upperBound])))
            }
            runStart = nil
        }

        var i = 0
        while i < tokens.count {
            if let (output, consumed) = match(at: i, tokens: tokens) {
                flushRun(upTo: i)
                // Punctuation immediately outside the phrase is preserved.
                segments.append(.literal(tokens[i].leading + output + tokens[i + consumed - 1].trailing))
                i += consumed
            } else {
                if runStart == nil { runStart = i }
                i += 1
            }
        }
        flushRun(upTo: tokens.count)
        return segments.isEmpty ? [.text("")] : segments
    }

    private func match(at i: Int, tokens: [TranscriptToken]) -> (output: String, consumed: Int)? {
        if let candidates = byFirstWord[tokens[i].core] {
            for rule in candidates {
                let count = rule.tokens.count
                guard i + count <= tokens.count else { continue }
                var ok = true
                for (offset, word) in rule.tokens.enumerated() {
                    let token = tokens[i + offset]
                    let isFirst = offset == 0
                    let isLast = offset == count - 1
                    guard token.core == word,
                          isFirst || token.leading.isEmpty,
                          isLast || token.trailing.isEmpty else { ok = false; break }
                }
                if ok { return (rule.output, count) }
            }
        }
        // Letter-run-insensitive fallback: "t k sun w" must match "TK sun W" and
        // "T. K. Sun W." the recognizer produces for spelled-letter triggers.
        let piece = String(tokens[i].core.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        if let firstChar = piece.first, let candidates = compactByFirstChar[firstChar] {
            for rule in candidates {
                if let hit = TranscriptTokenizer.compactMatch(rule.key, at: i, tokens: tokens) {
                    return (rule.output, hit.consumed)
                }
            }
        }
        return nil
    }
}

// MARK: - Snippet lookup

/// Immutable snapshot of enabled snippets for one processing pass (feature 5).
struct SnippetTable: Sendable {
    static let empty = SnippetTable(names: [], contentByID: [:])

    struct Entry: Sendable {
        let id: UUID
        let tokens: [String]
        /// Squashed alphanumeric form ("t k sun w" → "tksunw") for letter-run-
        /// insensitive matching: the recognizer merges and punctuates spelled
        /// letters unpredictably ("TK sun W", "T. K. Sun W."), so token-wise
        /// matching alone misses names built from letter sequences.
        let compactKey: String
    }

    /// Sorted longest-first so the longest name wins.
    let names: [Entry]
    let contentByID: [UUID: String]

    /// Folded alphanumerics only — the recognizer-proof comparison form. Empty
    /// (= disabled) unless the name contains a single-character token: compact
    /// matching exists for spelled-letter names, and applying it to ordinary
    /// phrases would let "so on" match the word "soon".
    static func compactKey(of tokens: [String]) -> String {
        guard tokens.contains(where: { $0.count == 1 }) else { return "" }
        return tokens.map { token in
            String(token.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }.joined()
    }

    init(names: [Entry], contentByID: [UUID: String]) {
        self.names = names.sorted { $0.tokens.count > $1.tokens.count }
        self.contentByID = contentByID
    }

    init(snippets: [(id: UUID, name: String, content: String)]) {
        self.init(
            names: snippets.map {
                let tokens = ReplacementMatcher.normalizedTriggerTokens($0.name)
                return Entry(id: $0.id, tokens: tokens, compactKey: Self.compactKey(of: tokens))
            },
            contentByID: Dictionary(uniqueKeysWithValues: snippets.map { ($0.id, $0.content) })
        )
    }
}
