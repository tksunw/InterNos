// Read-back check behind TextInserter.accessibilityInsert: a Chromium web
// area returns success for a dropped kAXSelectedTextAttribute write. The
// AX calls themselves need a live target app; this covers the decision.

import XCTest
@testable import Internos

@MainActor
final class AXReadBackTests: XCTestCase {
    typealias Snap = TextInserter.AXTextSnapshot

    func testUnchangedSnapshotIsDroppedWrite() {
        let s = Snap(characterCount: 6, selectedRange: (6, 0))
        XCTAssertFalse(TextInserter.axWriteTookEffect(before: s, after: s))
    }

    func testCaretMoveAloneCountsAsInsertion() {
        // Same-length replacement: count is unchanged, the selection collapsed.
        let before = Snap(characterCount: 10, selectedRange: (2, 3))
        let after = Snap(characterCount: 10, selectedRange: (5, 0))
        XCTAssertTrue(TextInserter.axWriteTookEffect(before: before, after: after))
    }

    func testCountChangeAloneCountsAsInsertion() {
        let before = Snap(characterCount: 6, selectedRange: nil)
        let after = Snap(characterCount: 12, selectedRange: nil)
        XCTAssertTrue(TextInserter.axWriteTookEffect(before: before, after: after))
    }

    func testNothingReadableTrustsSuccess() {
        XCTAssertTrue(TextInserter.axWriteTookEffect(before: Snap(), after: Snap()))
    }
}
