// Deterministic spoken-command parser (feature handoff, features 3 & 5).
// Converts explicit commands, snippet invocations, and literal escapes into
// protected segments; everything else stays ordinary text with its original
// whitespace intact (the transcript is never split-and-rejoined globally).
//
// Precedence at each position: literal escape → snippet invocation → structural
// command → emoji/hashtag/symbol command → ordinary text. Unrecognized
// command-like phrases are left unchanged.

import Foundation

struct TranscriptToken {
    /// The whole token in the source string, punctuation included.
    let range: Range<String.Index>
    /// Case-folded word with surrounding punctuation stripped.
    let core: String
    let leading: String
    let trailing: String
    var bare: Bool { leading.isEmpty && trailing.isEmpty }
}

enum TranscriptTokenizer {
    private static let leadingPunct = Set("\"'“‘([{¿¡")
    private static let trailingPunct = Set(".,!?;:\"'”’)]}…")

    /// Whitespace-delimited tokens with punctuation split off, so commands are
    /// recognized next to trailing punctuation and closing quotes.
    static func tokenize(_ text: String) -> [TranscriptToken] {
        var tokens: [TranscriptToken] = []
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isWhitespace {
                i = text.index(after: i)
                continue
            }
            var j = i
            while j < text.endIndex, !text[j].isWhitespace {
                j = text.index(after: j)
            }
            tokens.append(makeToken(text, i..<j))
            i = j
        }
        return tokens
    }

    private static func makeToken(_ text: String, _ range: Range<String.Index>) -> TranscriptToken {
        let word = text[range]
        var start = word.startIndex
        var end = word.endIndex
        var leading = ""
        var trailing = ""
        while start < end, leadingPunct.contains(word[start]) {
            leading.append(word[start])
            start = word.index(after: start)
        }
        while end > start {
            let previous = word.index(before: end)
            guard trailingPunct.contains(word[previous]) else { break }
            trailing = String(word[previous]) + trailing
            end = previous
        }
        let core = String(word[start..<end]).folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
        return TranscriptToken(range: range, core: core, leading: leading, trailing: trailing)
    }

    /// Letter-run-insensitive phrase match: consumes whole tokens while their
    /// concatenated alphanumeric form builds toward `key` (itself squashed, folded).
    /// Matches only when the key ends exactly on a token boundary, so "tksunwave"
    /// can never match "tksunw". The recognizer merges and punctuates spelled
    /// letters unpredictably ("t k sun w" → "TK sun W" / "T. K. Sun W."), which
    /// token-wise matching alone cannot survive.
    static func compactMatch(
        _ key: String, at start: Int, tokens: [TranscriptToken]
    ) -> (trailing: String, consumed: Int)? {
        guard !key.isEmpty else { return nil }
        var running = ""
        var j = start
        while j < tokens.count {
            guard tokens[j].leading.isEmpty || j == start else { return nil }
            let piece = String(tokens[j].core.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
            guard !piece.isEmpty else { return nil }
            running += piece
            if running == key { return (tokens[j].trailing, j - start + 1) }
            guard running.count < key.count, key.hasPrefix(running) else { return nil }
            j += 1
        }
        return nil
    }
}

enum TranscriptCommandParser {
    private struct Match {
        let segments: [TranscriptSegment]
        let consumed: Int
    }

    // MARK: command tables

    private enum StructuralKind: Sendable {
        case lineBreak
        case paragraphBreak
        case bulletItem
        case numberedItem
        case openingMark(String)
        case closingMark(String)

        /// Trailing punctuation on the last word is re-attached where it still makes
        /// sense: before a break (sentence-ending), after a mark.
        func segments(trailing: String) -> [TranscriptSegment] {
            switch self {
            case .lineBreak: trailing.isEmpty ? [.lineBreak] : [.text(trailing), .lineBreak]
            case .paragraphBreak: trailing.isEmpty ? [.paragraphBreak] : [.text(trailing), .paragraphBreak]
            case .bulletItem: trailing.isEmpty ? [.bulletItem] : [.text(trailing), .bulletItem]
            case .numberedItem: trailing.isEmpty ? [.numberedItem] : [.text(trailing), .numberedItem]
            case .openingMark(let mark): [.openingMark(mark + trailing)]
            case .closingMark(let mark): [.closingMark(mark + trailing)]
            }
        }
    }

    private static let structural: [(words: [String], kind: StructuralKind)] = [
        (["new", "line"], .lineBreak),
        (["new", "paragraph"], .paragraphBreak),
        (["bullet", "point"], .bulletItem),
        (["numbered", "item"], .numberedItem),
        (["open", "quote"], .openingMark("\u{201C}")),
        (["close", "quote"], .closingMark("\u{201D}")),
        (["open", "parenthesis"], .openingMark("(")),
        (["close", "parenthesis"], .closingMark(")")),
    ]

    private static let symbols: [([String], String)] = [
        (["at", "sign"], "@"),
        (["dollar", "sign"], "$"),
        (["percent", "sign"], "%"),
    ]

    // Names recognized only after the spoken word "emoji". Longest match wins.
    private static let emoji: [([String], String)] = [
        (["smiley", "face"], "🙂"),
        (["smiley"], "🙂"),
        (["winking", "face"], "😉"),
        (["frowning", "face"], "🙁"),
        (["laughing", "face"], "😂"),
        (["crying", "face"], "😢"),
        (["angry", "face"], "😠"),
        (["thinking", "face"], "🤔"),
        (["heart", "eyes"], "😍"),
        (["heart"], "❤️"),
        (["broken", "heart"], "💔"),
        (["thumbs", "up"], "👍"),
        (["thumbs", "down"], "👎"),
        (["fire"], "🔥"),
        (["party", "popper"], "🎉"),
        (["rocket"], "🚀"),
        (["star"], "⭐"),
        (["check", "mark"], "✅"),
        (["cross", "mark"], "❌"),
        (["clapping", "hands"], "👏"),
        (["eyes"], "👀"),
        (["shrug"], "🤷"),
        (["skull"], "💀"),
        (["hundred"], "💯"),
        (["wave"], "👋"),
        (["sparkles"], "✨"),
        (["sunglasses"], "😎"),
        (["poop"], "💩"),
    ]

    // MARK: parsing

    static func parse(_ raw: String, snippets: SnippetTable = .empty) -> [TranscriptSegment] {
        let tokens = TranscriptTokenizer.tokenize(raw)
        var segments: [TranscriptSegment] = []
        var runStart: Int?

        func flushRun(upTo end: Int) {
            if let start = runStart, start < end {
                // Ordinary text keeps its original inter-word whitespace verbatim.
                segments.append(.text(String(raw[tokens[start].range.lowerBound..<tokens[end - 1].range.upperBound])))
            }
            runStart = nil
        }

        var i = 0
        while i < tokens.count {
            if let match = matchCommand(at: i, tokens: tokens, raw: raw, snippets: snippets) {
                flushRun(upTo: i)
                segments.append(contentsOf: match.segments)
                i += match.consumed
            } else {
                if runStart == nil { runStart = i }
                i += 1
            }
        }
        flushRun(upTo: tokens.count)
        return segments
    }

    private static func matchCommand(
        at i: Int, tokens: [TranscriptToken], raw: String, snippets: SnippetTable
    ) -> Match? {
        // 1. Literal escape suppresses exactly one recognized phrase.
        if tokens[i].core == "literal", tokens[i].bare,
           let escaped = recognizedPhrase(startingAt: i + 1, tokens: tokens, raw: raw, snippets: snippets) {
            return Match(segments: [.literal(escaped.text)], consumed: 1 + escaped.consumed)
        }
        // 2. Explicit snippet invocation.
        if let match = matchSnippet(at: i, tokens: tokens, snippets: snippets) { return match }
        // 3. Built-in structural commands.
        if let match = matchStructural(at: i, tokens: tokens) { return match }
        // 4. Existing hashtag / emoji / symbol commands.
        if let match = matchLegacy(at: i, tokens: tokens, raw: raw) { return match }
        return nil
    }

    /// The next complete recognized command or snippet invocation, as spoken text,
    /// for the `literal` escape. An unmatched trailing `literal` stays a plain word.
    private static func recognizedPhrase(
        startingAt j: Int, tokens: [TranscriptToken], raw: String, snippets: SnippetTable
    ) -> (text: String, consumed: Int)? {
        guard j < tokens.count else { return nil }
        // "literal literal" → the word "literal".
        if tokens[j].core == "literal" {
            return (span(raw, tokens, j, j), 1)
        }
        if let match = matchSnippet(at: j, tokens: tokens, snippets: snippets)
            ?? matchStructural(at: j, tokens: tokens)
            ?? matchLegacy(at: j, tokens: tokens, raw: raw) {
            return (span(raw, tokens, j, j + match.consumed - 1), match.consumed)
        }
        return nil
    }

    /// Auto-punctuation routinely glues a comma/colon to a leading command word
    /// ("Snippet, calendar link"). Prefix words therefore tolerate trailing
    /// punctuation — it's discarded with the command.
    private static func isPrefix(_ token: TranscriptToken, _ word: String) -> Bool {
        token.core == word && token.leading.isEmpty
    }

    private static func matchSnippet(at i: Int, tokens: [TranscriptToken], snippets: SnippetTable) -> Match? {
        guard isPrefix(tokens[i], "snippet") else { return nil }
        // Token-wise first (exact spoken form), longest name first.
        for entry in snippets.names {
            guard let hit = matchWords(entry.tokens, at: i + 1, tokens: tokens) else { continue }
            var segments: [TranscriptSegment] = [.snippet(entry.id)]
            if !hit.trailing.isEmpty { segments.append(.text(hit.trailing)) }
            return Match(segments: segments, consumed: 1 + entry.tokens.count)
        }
        // Letter-run-insensitive fallback: the recognizer merges/punctuates spelled
        // letters ("TK sun W", "T. K. Sun W."), so compare squashed alphanumerics.
        for entry in snippets.names.sorted(by: { $0.compactKey.count > $1.compactKey.count }) {
            guard let hit = matchCompact(entry.compactKey, at: i + 1, tokens: tokens) else { continue }
            var segments: [TranscriptSegment] = [.snippet(entry.id)]
            if !hit.trailing.isEmpty { segments.append(.text(hit.trailing)) }
            return Match(segments: segments, consumed: 1 + hit.consumed)
        }
        return nil
    }

    private static func matchCompact(
        _ key: String, at start: Int, tokens: [TranscriptToken]
    ) -> (trailing: String, consumed: Int)? {
        TranscriptTokenizer.compactMatch(key, at: start, tokens: tokens)
    }

    private static func matchStructural(at i: Int, tokens: [TranscriptToken]) -> Match? {
        for (words, kind) in structural {
            guard let hit = matchWords(words, at: i, tokens: tokens) else { continue }
            return Match(segments: kind.segments(trailing: hit.trailing), consumed: words.count)
        }
        return nil
    }

    private static func matchLegacy(at i: Int, tokens: [TranscriptToken], raw: String) -> Match? {
        if isPrefix(tokens[i], "hashtag"), i + 1 < tokens.count, !tokens[i + 1].core.isEmpty {
            // "#" plus the next token exactly as spoken (keeps its trailing punctuation).
            return Match(segments: [.literal("#" + String(raw[tokens[i + 1].range]))], consumed: 2)
        }
        if isPrefix(tokens[i], "emoji") {
            for (words, glyph) in emoji.sorted(by: { $0.0.count > $1.0.count }) {
                guard let hit = matchWords(words, at: i + 1, tokens: tokens) else { continue }
                return Match(segments: [.literal(glyph + hit.trailing)], consumed: 1 + words.count)
            }
        }
        for (words, glyph) in symbols.sorted(by: { $0.0.count > $1.0.count }) {
            guard let hit = matchWords(words, at: i, tokens: tokens) else { continue }
            return Match(segments: [.literal(glyph + hit.trailing)], consumed: words.count)
        }
        return nil
    }

    /// Case-insensitive whole-phrase match at `start`. Inner words must be bare;
    /// the last word's trailing punctuation is surfaced to the caller.
    private static func matchWords(
        _ words: [String], at start: Int, tokens: [TranscriptToken]
    ) -> (trailing: String, last: Int)? {
        guard !words.isEmpty, start + words.count <= tokens.count else { return nil }
        var trailing = ""
        for (offset, word) in words.enumerated() {
            let token = tokens[start + offset]
            let isLast = offset == words.count - 1
            guard token.core == word, token.leading.isEmpty, isLast || token.trailing.isEmpty else {
                return nil
            }
            if isLast { trailing = token.trailing }
        }
        return (trailing, start + words.count - 1)
    }

    private static func span(_ raw: String, _ tokens: [TranscriptToken], _ a: Int, _ b: Int) -> String {
        String(raw[tokens[a].range.lowerBound..<tokens[b].range.upperBound])
    }
}
