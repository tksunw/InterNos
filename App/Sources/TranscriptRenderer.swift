// Renders parsed segments into the final insertion string (feature 3 rendering rules).
// Owns list-run state (bullet vs numbered, numbering resets), break coalescing
// (never more than two consecutive separator newlines), and typographic spacing
// around quotes and parentheses. Snippet contents are expanded verbatim.

import Foundation

enum TranscriptRenderer {
    /// Punctuation that must never get a space inserted before it.
    private static let noSpaceBefore = Set(".,!?;:\u{201D}\u{2019}\"')]}…")

    private enum ListRun {
        case none
        case bullet
        case numbered
    }

    static func render(_ segments: [TranscriptSegment], snippets: SnippetTable = .empty) -> String {
        var out = ""
        // True when the next word-like piece attaches without a leading space
        // (start of line, after an opening mark, after a list marker).
        var suppressSpace = true
        var listRun = ListRun.none
        var numberCounter = 0

        func appendPiece(_ piece: String) {
            guard !piece.isEmpty else { return }
            if !suppressSpace, let last = out.last, !last.isWhitespace,
               let first = piece.first, !first.isWhitespace, !noSpaceBefore.contains(first) {
                out += " "
            }
            out += piece
            suppressSpace = false
        }

        /// Appends up to `count` newlines, trimming spaces beside the break and
        /// capping any run of separator newlines at two.
        func appendNewlines(_ count: Int) {
            while out.last == " " || out.last == "\t" { out.removeLast() }
            guard !out.isEmpty else {
                suppressSpace = true
                return
            }
            var existing = 0
            for character in out.reversed() {
                guard character == "\n" else { break }
                existing += 1
            }
            out += String(repeating: "\n", count: max(0, min(2, existing + count) - existing))
            suppressSpace = true
        }

        func startListItem(marker: String) {
            while out.last == " " || out.last == "\t" { out.removeLast() }
            if let last = out.last, last != "\n" { out += "\n" }
            out += marker
            suppressSpace = true
        }

        for segment in segments {
            switch segment {
            case .text(let text), .literal(let text):
                appendPiece(text)
            case .lineBreak:
                appendNewlines(1)
            case .paragraphBreak:
                appendNewlines(2)
                // A paragraph break ends the current list run.
                listRun = .none
            case .bulletItem:
                listRun = .bullet
                startListItem(marker: "\u{2022} ")
            case .numberedItem:
                numberCounter = listRun == .numbered ? numberCounter + 1 : 1
                listRun = .numbered
                startListItem(marker: "\(numberCounter). ")
            case .openingMark(let mark):
                appendPiece(mark)
                suppressSpace = true
            case .closingMark(let mark):
                // The no-space-before set already glues it to the previous word.
                appendPiece(mark)
            case .snippet(let id):
                if let content = snippets.contentByID[id] {
                    appendPiece(content)
                }
            }
        }

        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
