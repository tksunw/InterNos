// Spelling convention (docs/specs/spelling-convention.md): the recognition
// locale picks the model, and each model writes its own locale's spelling. This
// stage rewrites ordinary `.text` segments into the spelling the user asked for,
// after cleanup (so the setting is authoritative over the model) and before
// replacements (so personal-dictionary output is never re-spelled).
//
// The tables come from VarCon (SCOWL) through
// `App/scripts/generate-spelling-table.py` → `SpellingTable.generated.swift`.

import Foundation

enum SpellingConvention: String, CaseIterable, Identifiable, Sendable {
    case asRecognized, american, british, oxford, canadian, australian
    var id: String { rawValue }
    var label: String {
        switch self {
        case .asRecognized: "As recognized"
        case .american: "American"
        case .british: "British"
        case .oxford: "British (Oxford)"
        case .canadian: "Canadian"
        case .australian: "Australian"
        }
    }

    /// Spelling is an English feature; every other locale is a no-op. Mirrors
    /// `CleanupMode.effective(forLocaleIdentifier:)` so both gate the same way.
    func effective(forLocaleIdentifier identifier: String) -> SpellingConvention {
        identifier.lowercased().hasPrefix("en") ? self : .asRecognized
    }
}

struct SpellingNormalizer: Sendable {
    static let none = SpellingNormalizer(convention: .asRecognized)

    let convention: SpellingConvention
    /// Folded source word → target word. Empty for `.asRecognized`.
    private let table: [String: String]

    init(convention: SpellingConvention) {
        self.convention = convention
        table = Self.table(for: convention)
    }

    /// Rewrites ordinary text. Returns the input unchanged for `.asRecognized`.
    /// `startsSentence`: the text begins a sentence (start of dictation or after
    /// a break), so an initial capital on its first word is not a proper noun.
    func normalize(_ text: String, startsSentence: Bool) -> String {
        guard !table.isEmpty else { return text }
        var output = ""
        var cursor = text.startIndex
        var changed = false
        var sentenceStart = startsSentence
        for token in TranscriptTokenizer.tokenize(text) {
            defer { sentenceStart = token.trailing.contains(where: TranscriptTokenizer.sentenceEnders.contains) }
            guard let target = lookup(token.core) else { continue }
            // The word as spoken, with the tokenizer's punctuation peeled off.
            let wordStart = text.index(token.range.lowerBound, offsetBy: token.leading.count)
            let wordEnd = text.index(token.range.upperBound, offsetBy: -token.trailing.count)
            let word = text[wordStart..<wordEnd]
            let replacement: String
            if word.allSatisfy({ !$0.isUppercase }) {
                replacement = target
            } else if let first = word.first, first.isUppercase, word.dropFirst().allSatisfy({ !$0.isUppercase }) {
                // Capitalised mid-sentence is taken as a proper noun ("Harbour
                // Bridge", "Centrelink") and left alone. Sentence-initial, it is
                // an ordinary word that happens to start the sentence; "Labor won"
                // → "Labour won" under a British target is the accepted cost.
                guard sentenceStart else { continue }
                replacement = target.prefix(1).uppercased() + target.dropFirst()
            } else {
                continue // all caps or mixed case: acronym risk, skip
            }
            output += text[cursor..<wordStart]
            output += replacement
            cursor = wordEnd
            changed = true
        }
        guard changed else { return text }
        output += text[cursor...]
        return output
    }

    /// Single-word lookup for replacement triggers: folded in, folded out, so a
    /// trigger typed as "colour" still fires on dictation normalized to "color".
    func normalizedCore(_ core: String) -> String {
        lookup(core) ?? core
    }

    private func lookup(_ core: String) -> String? {
        if let hit = table[core] { return hit }
        // "colour-blind" converts part by part; "e-mail" has no hit and stays.
        guard core.contains("-") else { return nil }
        var changed = false
        let parts = core.split(separator: "-", omittingEmptySubsequences: false).map { part -> Substring in
            if let hit = table[String(part)] { changed = true; return Substring(hit) }
            return part
        }
        return changed ? parts.joined(separator: "-") : nil
    }

    // MARK: - tables

    // Parsed once per convention on first use (static lets are lazy and
    // thread-safe); every normalizer after that shares the dictionary storage.
    private static let american = parse(SpellingTable.american)
    private static let british = parse(SpellingTable.british)
    private static let oxford = parse(SpellingTable.oxford)
    private static let canadian = parse(SpellingTable.canadian)
    private static let australian = parse(SpellingTable.australian)

    private static func table(for convention: SpellingConvention) -> [String: String] {
        switch convention {
        case .asRecognized: [:]
        case .american: american
        case .british: british
        case .oxford: oxford
        case .canadian: canadian
        case .australian: australian
        }
    }

    private static func parse(_ source: String) -> [String: String] {
        var table: [String: String] = [:]
        table.reserveCapacity(12_000)
        for line in source.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            table[String(line[..<tab])] = String(line[line.index(after: tab)...])
        }
        return table
    }

    /// VarCon's license (the "Copyright" section of `App/Data/varcon/README`),
    /// reproduced in the About panel credits and README.md as its BSD clause requires.
    static let varconNotice = """
    Spelling tables derived from VarCon (Variant Conversion Info), part of SCOWL,
    by Kevin Atkinson and Benjamin Titze.

    Copyright 2000-2019 by Kevin Atkinson

    Permission to use, copy, modify, distribute and sell this array, the
    associated software, and its documentation for any purpose is hereby
    granted without fee, provided that the above copyright notice appears
    in all copies and that both that copyright notice and this permission
    notice appear in supporting documentation. Kevin Atkinson makes no
    representations about the suitability of this array for any
    purpose. It is provided "as is" without express or implied warranty.

    Copyright 2016 by Benjamin Titze

    Permission to use, copy, modify, distribute and sell this array, the
    associated software, and its documentation for any purpose is hereby
    granted without fee, provided that the above copyright notice appears
    in all copies and that both that copyright notice and this permission
    notice appear in supporting documentation. Benjamin Titze makes no
    representations about the suitability of this array for any
    purpose. It is provided "as is" without express or implied warranty.

    Since the original words lists come from the Ispell distribution:

    Copyright 1993, Geoff Kuenning, Granada Hills, CA
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions
    are met:

    1. Redistributions of source code must retain the above copyright
    notice, this list of conditions and the following disclaimer.
    2. Redistributions in binary form must reproduce the above copyright
    notice, this list of conditions and the following disclaimer in the
    documentation and/or other materials provided with the distribution.
    3. All modifications to the source code must be clearly marked as
    such.  Binary redistributions based on modified source code
    must be clearly marked as modified versions in the documentation
    and/or other materials provided with the distribution.
    (clause 4 removed with permission from Geoff Kuenning)
    5. The name of Geoff Kuenning may not be used to endorse or promote
    products derived from this software without specific prior
    written permission.

    THIS SOFTWARE IS PROVIDED BY GEOFF KUENNING AND CONTRIBUTORS ``AS IS'' AND
    ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
    IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
    ARE DISCLAIMED.  IN NO EVENT SHALL GEOFF KUENNING OR CONTRIBUTORS BE LIABLE
    FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
    DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
    OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
    HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
    LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
    OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
    SUCH DAMAGE.
    """
}
