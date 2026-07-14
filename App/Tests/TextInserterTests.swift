// IR-002 (conditional clipboard restore), IR-003 (target verification),
// IR-009 (paste-event failure). No real pasteboard, timers, or CGEvents.

import AppKit
import XCTest
@testable import Internos

@MainActor
final class TextInserterTests: XCTestCase {
    private var pasteboard = FakePasteboard()
    private var scheduled: [DispatchWorkItem] = []
    private var pastesPosted = 0

    private func makeInserter(
        secureInput: Bool = false,
        accessibility: Bool = true,
        frontmost: @escaping () -> pid_t? = { 42 },
        postPasteError: Error? = nil
    ) -> TextInserter {
        pasteboard = FakePasteboard()
        scheduled = []
        pastesPosted = 0
        return TextInserter(
            pasteboard: pasteboard,
            scheduleRestore: { [self] work in scheduled.append(work) },
            secureInputActive: { secureInput },
            accessibilityGranted: { accessibility },
            frontmostPID: frontmost,
            postPaste: { [self] in
                if let postPasteError { throw postPasteError }
                pastesPosted += 1
            }
        )
    }

    private func runPendingRestore() {
        scheduled.removeLast().perform()
    }

    // MARK: IR-002 — conditional restore

    func testRestoresMultiTypePasteboardWhenUnchanged() throws {
        let inserter = makeInserter()
        pasteboard.writeItems([
            [.string: Data("original".utf8), .html: Data("<b>original</b>".utf8)],
            [.string: Data("second item".utf8)],
        ])
        let original = pasteboard.items

        try inserter.insert("transcript", target: 42)
        XCTAssertEqual(pasteboard.stringContents, "transcript")
        XCTAssertEqual(pastesPosted, 1)

        runPendingRestore()
        XCTAssertEqual(pasteboard.items, original, "every item and type must be restored")
    }

    func testRestoresOriginallyEmptyPasteboardToEmpty() throws {
        let inserter = makeInserter()
        try inserter.insert("transcript", target: 42)
        runPendingRestore()
        XCTAssertTrue(pasteboard.items.isEmpty, "an empty clipboard must not keep the transcript")
    }

    func testDoesNotOverwriteUserCopyMadeDuringRestoreWindow() throws {
        let inserter = makeInserter()
        pasteboard.userCopy("before dictation")

        try inserter.insert("transcript", target: 42)
        pasteboard.userCopy("copied during window")

        runPendingRestore()
        XCTAssertEqual(pasteboard.stringContents, "copied during window",
                       "content copied after dictation must survive the restore")
    }

    func testTwoInsertionsInsideWindowPreserveOriginalClipboard() throws {
        let inserter = makeInserter()
        pasteboard.userCopy("user clipboard")

        try inserter.insert("first", target: 42)
        try inserter.insert("second", target: 42) // inside first's restore window

        XCTAssertEqual(pasteboard.stringContents, "second")
        runPendingRestore()
        XCTAssertEqual(pasteboard.stringContents, "user clipboard",
                       "back-to-back dictations must not lose the pre-dictation clipboard")
    }

    func testTwoInsertionsRespectUserCopyBetweenThem() throws {
        let inserter = makeInserter()
        pasteboard.userCopy("user clipboard")

        try inserter.insert("first", target: 42)
        pasteboard.userCopy("newer copy")
        try inserter.insert("second", target: 42)

        runPendingRestore()
        XCTAssertEqual(pasteboard.stringContents, "newer copy",
                       "a user copy between insertions wins over the stale snapshot")
    }

    func testCanceledRestoreCannotClearNewerInsertion() throws {
        let inserter = makeInserter()
        try inserter.insert("first", target: 42)
        let firstWork = scheduled[0]
        try inserter.insert("second", target: 42)

        XCTAssertTrue(firstWork.isCancelled)
        firstWork.perform() // even if it somehow ran, it must be inert
        XCTAssertEqual(pasteboard.stringContents, "second")
    }

    func testTranscriptCarriesTransientAndConcealedMarkers() throws {
        let inserter = makeInserter()
        try inserter.insert("transcript", target: 42)
        XCTAssertNotNil(pasteboard.items.first?[.transientMarker])
        XCTAssertNotNil(pasteboard.items.first?[.concealedMarker])
    }

    // MARK: IR-003 — target verification

    func testInsertsWhenTargetStillFrontmost() throws {
        let inserter = makeInserter(frontmost: { 42 })
        try inserter.insert("transcript", target: 42)
        XCTAssertEqual(pastesPosted, 1)
    }

    func testRefusesWhenFrontmostChanged() {
        let inserter = makeInserter(frontmost: { 99 })
        XCTAssertThrowsError(try inserter.insert("transcript", target: 42)) { error in
            XCTAssertEqual(error as? InternosError, .insertionTargetChanged)
        }
        XCTAssertEqual(pastesPosted, 0, "no keyboard events on a target mismatch")
        XCTAssertEqual(pasteboard.changeCount, 0, "the pasteboard must be untouched")
    }

    func testRefusesWhenTargetExited() {
        let inserter = makeInserter(frontmost: { nil }) // no frontmost app resolvable
        XCTAssertThrowsError(try inserter.insert("transcript", target: 42)) { error in
            XCTAssertEqual(error as? InternosError, .insertionTargetChanged)
        }
        XCTAssertEqual(pastesPosted, 0)
    }

    func testRefusesWhenTargetUnknown() {
        let inserter = makeInserter()
        XCTAssertThrowsError(try inserter.insert("transcript", target: nil)) { error in
            XCTAssertEqual(error as? InternosError, .insertionTargetChanged)
        }
    }

    // MARK: preflight failures

    func testSecureInputBlocksInsertion() {
        let inserter = makeInserter(secureInput: true)
        XCTAssertThrowsError(try inserter.insert("transcript", target: 42)) { error in
            XCTAssertEqual(error as? InternosError, .secureInputActive)
        }
        XCTAssertEqual(pastesPosted, 0)
        XCTAssertEqual(pasteboard.changeCount, 0)
    }

    func testMissingAccessibilityBlocksInsertion() {
        let inserter = makeInserter(accessibility: false)
        XCTAssertThrowsError(try inserter.insert("transcript", target: 42)) { error in
            XCTAssertEqual(error as? InternosError, .accessibilityNotGranted)
        }
        XCTAssertEqual(pastesPosted, 0)
    }

    // MARK: IR-009 — paste-event failure

    func testPasteEventFailureThrowsAndPreservesTranscript() {
        let inserter = makeInserter(postPasteError: InternosError.pasteEventFailed)
        XCTAssertThrowsError(try inserter.insert("transcript", target: 42)) { error in
            XCTAssertEqual(error as? InternosError, .pasteEventFailed)
        }
        XCTAssertEqual(pasteboard.stringContents, "transcript",
                       "the transcript must stay recoverable on the pasteboard")
        XCTAssertTrue(scheduled.isEmpty, "no restore may be scheduled over the preserved transcript")
    }

    // MARK: preserveOnClipboard

    func testPreserveCancelsPendingRestore() throws {
        let inserter = makeInserter()
        pasteboard.userCopy("user clipboard")
        try inserter.insert("first", target: 42)
        let work = scheduled[0]

        inserter.preserveOnClipboard("preserved transcript")
        XCTAssertTrue(work.isCancelled)
        work.perform()
        XCTAssertEqual(pasteboard.stringContents, "preserved transcript",
                       "a pending restore must not wipe a preserved transcript")
    }
}
