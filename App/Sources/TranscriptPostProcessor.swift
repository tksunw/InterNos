// Spoken-token substitution pass between transcription and insertion.
// SpeechTranscriber has no spoken-command support (its only TranscriptionOption
// is etiquetteReplacements), so "hashtag yard" arrives as literal words.
// Rewrites, case-insensitively:
//   "hashtag <word>"      -> #<word>
//   "emoji <name>"        -> the emoji glyph; unknown names are left untouched.
//                            The "emoji" prefix is required so literal speech
//                            ("she sent me a smiley face") never converts.
//   explicit symbol names -> "at sign" -> @, "dollar sign" -> $, "percent sign" -> %
// ponytail: flat word-match tables, no NLP. Extend the tables when users ask.
enum TranscriptPostProcessor {
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

    static func process(_ text: String) -> String {
        let tokens = text.split(separator: " ").map(String.init)
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            let (core, trailing) = strip(tokens[i])
            if core == "hashtag", trailing.isEmpty, i + 1 < tokens.count {
                out.append("#" + tokens[i + 1])
                i += 2
            } else if core == "emoji", trailing.isEmpty,
                      let hit = match(emoji, in: tokens, from: i + 1) {
                out.append(hit.replacement)
                i = hit.next
            } else if let hit = match(symbols, in: tokens, from: i) {
                out.append(hit.replacement)
                i = hit.next
            } else {
                out.append(tokens[i])
                i += 1
            }
        }
        return out.joined(separator: " ")
    }

    /// Longest table entry whose words match tokens starting at `from`.
    /// Inner words must be bare; the last word keeps its trailing punctuation.
    private static func match(
        _ table: [([String], String)], in tokens: [String], from: Int
    ) -> (replacement: String, next: Int)? {
        for (words, glyph) in table.sorted(by: { $0.0.count > $1.0.count }) {
            guard from + words.count <= tokens.count else { continue }
            var trailing = ""
            var ok = true
            for (offset, word) in words.enumerated() {
                let (core, tail) = strip(tokens[from + offset])
                let isLast = offset == words.count - 1
                guard core == word, isLast || tail.isEmpty else { ok = false; break }
                if isLast { trailing = tail }
            }
            if ok { return (glyph + trailing, from + words.count) }
        }
        return nil
    }

    /// Lowercased word with any trailing punctuation split off.
    private static func strip(_ token: String) -> (core: String, trailing: String) {
        var core = Substring(token)
        var trailing = ""
        while let last = core.last, ".,!?;:".contains(last) {
            trailing = String(last) + trailing
            core = core.dropLast()
        }
        return (core.lowercased(), trailing)
    }
}
