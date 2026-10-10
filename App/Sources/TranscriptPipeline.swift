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
    /// Protected exact output (literal escapes, emoji/hashtag/symbol results).
    /// Rendered verbatim, skipped by every later stage.
    case literal(String)
    /// Protected output of a personal-dictionary rule. Like `literal`, except a
    /// leading space is the user's "keep this apart from the previous word".
    case replacement(String)
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

    /// Model cleanup is prompt-engineered and validated for English only; fed
    /// Spanish input under English instructions, the model translated the
    /// dictation outright (beta-5 field report). Other recognition languages
    /// take the deterministic path until per-language prompts are validated.
    func effective(forLocaleIdentifier identifier: String) -> CleanupMode {
        identifier.lowercased().hasPrefix("en") ? self : .off
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

        // Model cleanup runs only when the utterance is one plain text segment.
        // Commands and snippets punch holes in the text, and the model, handed a
        // dangling fragment like "my github handle is", invents completions for it —
        // a beta field report saw a fabricated markdown link. Structured utterances
        // (and model failures) get deterministic filler stripping instead, so
        // filler removal works everywhere without a hallucination surface.
        if settings.cleanupMode != .off {
            if let cleaner, segments.count == 1, case .text(let original) = segments[0] {
                if let cleaned = await cleaner.clean(original, mode: settings.cleanupMode),
                   cleaned != original {
                    segments[0] = .text(cleaned)
                    cleanupApplied = true
                } else {
                    let stripped = FillerStripper.strip(original)
                    if stripped != original {
                        segments[0] = .text(stripped)
                        cleanupApplied = true
                    }
                }
            } else {
                for index in segments.indices {
                    guard case .text(let original) = segments[index] else { continue }
                    let stripped = FillerStripper.strip(original)
                    if stripped != original {
                        segments[index] = .text(stripped)
                        cleanupApplied = true
                    }
                }
            }
        }

        // Replacements run after cleanup so configured spelling is authoritative.
        let parsed = segments
        segments = parsed.enumerated().flatMap { index, segment -> [TranscriptSegment] in
            guard case .text(let text) = segment else { return [segment] }
            // The text ends a sentence when nothing follows it or a break does,
            // looking past spoken closing quotes and brackets.
            let next = parsed[(index + 1)...].first { if case .closingMark = $0 { false } else { true } }
            let endsSentence: Bool = switch next {
            case nil, .lineBreak, .paragraphBreak, .bulletItem, .numberedItem: true
            default: false
            }
            return settings.replacements.apply(to: text, endsSentence: endsSentence)
        }

        let final = TranscriptRenderer.render(segments, snippets: settings.snippets)
        return TranscriptResult(raw: raw, final: final, cleanupApplied: cleanupApplied)
    }
}

// MARK: - Replacement matching

/// One word of a configured trigger or snippet name, split the way the tokenizer
/// splits transcript words, so "Dr. Smith" is compared as dr + smith rather than
/// as a "dr." no transcript token ever equals.
struct TriggerWord: Sendable, Equatable {
    /// Punctuation typed before the word ("'til" → "'").
    var leading = ""
    /// Case-folded, like `TranscriptToken.core`.
    let core: String
    /// Punctuation typed after the word ("Dr." → ".").
    var trailing = ""

    /// Punctuation typed in a phrase is part of it: the transcript has to carry
    /// it too, so "in." never fires on the word "in" nor "(c)" on a bare "c".
    var punctuationCount: Int { leading.count + trailing.count }

    /// The words of `phrase`, with each word's punctuation split off.
    static func words(of phrase: String) -> [TriggerWord] {
        TranscriptTokenizer.tokenize(phrase).map {
            TriggerWord(leading: $0.leading, core: $0.core, trailing: $0.trailing)
        }
    }

    /// Match order: the longest phrase first, and among equals the one typed with
    /// more punctuation, so "vs." gets its own rule's output while a plain "vs"
    /// rule still takes every other spelling. Two triggers match the same words
    /// only when they are the same string, which is what the store rejects.
    static func isMoreSpecific(_ a: [TriggerWord], than b: [TriggerWord]) -> Bool {
        if a.count != b.count { return a.count > b.count }
        return a.reduce(0) { $0 + $1.punctuationCount } > b.reduce(0) { $0 + $1.punctuationCount }
    }
}

/// Precomputed matcher for the personal dictionary (feature 1). Built once when the
/// configuration changes, not per token: rules are keyed by first word and sorted
/// longest-first so overlapping triggers resolve to the longest match.
struct ReplacementMatcher: Sendable {
    static let empty = ReplacementMatcher(rules: [])

    private struct Rule: Sendable {
        let words: [TriggerWord]
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
            let words = TriggerWord.words(of: rule.trigger)
            guard let first = words.first else { continue }
            map[first.core, default: []].append(Rule(words: words, output: rule.output))
            let key = SnippetTable.compactKey(of: words)
            if let firstChar = key.first {
                compact[firstChar, default: []].append(CompactRule(key: key, output: rule.output))
            }
        }
        byFirstWord = map.mapValues { $0.sorted { TriggerWord.isMoreSpecific($0.words, than: $1.words) } }
        compactByFirstChar = compact.mapValues { $0.sorted { $0.key.count > $1.key.count } }
    }

    /// Splits ordinary text into text/replacement segments. Whole-word matches
    /// only; each span is replaced at most once and outputs are emitted as
    /// protected `.replacement` segments, so replacement text can never trigger
    /// anything else.
    /// `endsSentence`: nothing follows this text on its line, so its last word
    /// ends a sentence.
    func apply(to text: String, endsSentence: Bool = true) -> [TranscriptSegment] {
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
            if let (output, leading, trailing, consumed) = match(at: i, tokens: tokens, endsSentence: endsSentence) {
                flushRun(upTo: i)
                // Punctuation immediately outside the phrase is preserved.
                // Behind an opening quote or bracket there is nothing to keep apart.
                let body = leading.isEmpty ? Substring(output) : output.drop { $0 == " " }
                segments.append(.replacement(leading + body + trailing))
                i += consumed
            } else {
                if runStart == nil { runStart = i }
                i += 1
            }
        }
        flushRun(upTo: tokens.count)
        return segments.isEmpty ? [.text("")] : segments
    }

    private func match(
        at i: Int, tokens: [TranscriptToken], endsSentence: Bool
    ) -> (output: String, leading: String, trailing: String, consumed: Int)? {
        if let candidates = byFirstWord[tokens[i].core] {
            for rule in candidates {
                guard let hit = TranscriptTokenizer.matchPhrase(rule.words, at: i, tokens: tokens) else { continue }
                // One period serves both an abbreviation and the sentence it ends:
                // "apples, etc." keeps its full stop when "etc." is rewritten. Only
                // where the text itself stops (end of the dictation, or a break).
                // Mid-text there is no telling "etc. Then" from "Dr. Smith", and
                // the period is taken as the trigger's.
                // Closing quotes and brackets after it don't change that (etc.”).
                let onlyClosers = hit.trailing.allSatisfy(TranscriptTokenizer.closingMarks.contains)
                let keepsFullStop = endsSentence && onlyClosers && hit.last == tokens.count - 1
                    && rule.words[rule.words.count - 1].trailing.hasSuffix(".")
                    && !(rule.output.last.map(TranscriptTokenizer.sentenceEnders.contains) ?? false)
                return (rule.output, hit.leading, (keepsFullStop ? "." : "") + hit.trailing, rule.words.count)
            }
        }
        // Letter-run-insensitive fallback: "t k sun w" must match "TK sun W" and
        // "T. K. Sun W." the recognizer produces for spelled-letter triggers.
        let piece = String(tokens[i].core.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        if let firstChar = piece.first, let candidates = compactByFirstChar[firstChar] {
            for rule in candidates {
                if let hit = TranscriptTokenizer.compactMatch(rule.key, at: i, tokens: tokens) {
                    return (rule.output, tokens[i].leading, hit.trailing, hit.consumed)
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
        let words: [TriggerWord]
        /// Squashed alphanumeric form ("t k sun w" → "tksunw") for letter-run-
        /// insensitive matching: the recognizer merges and punctuates spelled
        /// letters unpredictably ("TK sun W", "T. K. Sun W."), so token-wise
        /// matching alone misses names built from letter sequences.
        let compactKey: String
    }

    /// Sorted longest-first so the longest name wins.
    let names: [Entry]
    /// The same entries, longest compact key first, for the letter-run fallback.
    let namesByCompactKey: [Entry]
    let contentByID: [UUID: String]

    /// Folded alphanumerics only — the recognizer-proof comparison form. Empty
    /// (= disabled) unless the name contains a spelled letter: compact matching
    /// exists for spelled-letter names, and applying it to ordinary phrases would
    /// let "so on" match the word "soon". A spelled letter is a single character
    /// typed bare: "T" in "Mr. T", not the "I." of "I. T.", which would squash to
    /// the word "it". A lone "a" is the article, not a letter ("a part" must not
    /// match "apart"); next to another single character it is one ("a w s").
    /// "i" stays a letter even alone: "i phone", "i pad", "i cloud" are how
    /// people type the rules that fix "Iphone", and nobody keeps "I deal" in a
    /// dictionary.
    /// The key is letters and digits only, as it always was: this fallback is
    /// deliberately loose about punctuation ("Mr. T" still matches "Mr T" and
    /// "MRT"), unlike the word-by-word match that is tried first.
    static func compactKey(of words: [TriggerWord]) -> String {
        func isBareLetter(_ index: Int) -> Bool {
            words.indices.contains(index) && words[index].core.count == 1 && words[index].punctuationCount == 0
        }
        let hasSpelledLetter = words.indices.contains { index in
            guard isBareLetter(index) else { return false }
            return words[index].core != "a" || isBareLetter(index - 1) || isBareLetter(index + 1)
        }
        guard hasSpelledLetter else { return "" }
        return words.map(\.core).map { token in
            String(token.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }.joined()
    }

    init(names: [Entry], contentByID: [UUID: String]) {
        self.names = names.sorted { TriggerWord.isMoreSpecific($0.words, than: $1.words) }
        self.namesByCompactKey = names.sorted { $0.compactKey.count > $1.compactKey.count }
        self.contentByID = contentByID
    }

    init(snippets: [(id: UUID, name: String, content: String)]) {
        self.init(
            names: snippets.map {
                let words = TriggerWord.words(of: $0.name)
                return Entry(id: $0.id, words: words, compactKey: Self.compactKey(of: words))
            },
            // The store keeps IDs unique; a repeat must still never trap here,
            // on the launch path, where it would be a crash loop.
            contentByID: Dictionary(snippets.map { ($0.id, $0.content) }, uniquingKeysWith: { first, _ in first })
        )
    }
}
