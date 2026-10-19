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
    private var axInsertions: [(text: String, pid: pid_t)] = []
    private var backspacesPosted: [Int] = []
    /// What the fake focused element reports after an AX insertion, and now.
    private var axSnapshotAfterInsert = TextInserter.AXTextSnapshot()
    private var axSnapshotNow = TextInserter.AXTextSnapshot()

    private func makeInserter(
        secureInput: Bool = false,
        accessibility: Bool = true,
        frontmost: @escaping () -> pid_t? = { 42 },
        axUnreliable: Bool = false,
        axSucceeds: Bool = false,
        postPasteError: Error? = nil
    ) -> TextInserter {
        pasteboard = FakePasteboard()
        scheduled = []
        pastesPosted = 0
        axInsertions = []
        backspacesPosted = []
        axSnapshotAfterInsert = TextInserter.AXTextSnapshot()
        axSnapshotNow = TextInserter.AXTextSnapshot()
        return TextInserter(
            pasteboard: pasteboard,
            scheduleRestore: { [self] work in scheduled.append(work) },
            secureInputActive: { secureInput },
            accessibilityGranted: { accessibility },
            frontmostPID: frontmost,
            axInsertionUnreliable: { _ in axUnreliable },
            axInsert: { [self] text, pid in
                guard axSucceeds else { return nil }
                axInsertions.append((text, pid))
                return axSnapshotAfterInsert
            },
            axSnapshot: { [self] _ in axSnapshotNow },
            postPaste: { [self] in
                if let postPasteError { throw postPasteError }
                pastesPosted += 1
            },
            postBackspaces: { [self] count in backspacesPosted.append(count) }
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

    // MARK: v2 — Accessibility-direct path

    func testAXSuccessSkipsPasteboardEntirely() throws {
        let inserter = makeInserter(axSucceeds: true)
        pasteboard.userCopy("untouched")
        let method = try inserter.insert("transcript", target: 42)

        XCTAssertEqual(method, .accessibility)
        XCTAssertEqual(axInsertions.map(\.text), ["transcript"])
        XCTAssertEqual(axInsertions.first?.pid, 42)
        XCTAssertEqual(pasteboard.stringContents, "untouched", "AX insertion must not touch the pasteboard")
        XCTAssertEqual(pastesPosted, 0, "no synthetic paste on the AX path")
        XCTAssertTrue(scheduled.isEmpty, "no restore to schedule — nothing was swapped")
    }

    func testAXFailureFallsBackToClipboardSwap() throws {
        let inserter = makeInserter(axSucceeds: false)
        pasteboard.userCopy("original")
        let method = try inserter.insert("transcript", target: 42)

        XCTAssertEqual(method, .clipboard)
        XCTAssertEqual(pastesPosted, 1)
        runPendingRestore()
        XCTAssertEqual(pasteboard.stringContents, "original")
    }

    func testUnreliableAXTargetGoesStraightToClipboardSwap() throws {
        // Electron apps report AX success without inserting; the AX path must not
        // even be attempted for them (a trusted false success would drop the text).
        let inserter = makeInserter(axUnreliable: true, axSucceeds: true)
        pasteboard.userCopy("original")
        let method = try inserter.insert("transcript", target: 42)

        XCTAssertEqual(method, .clipboard)
        XCTAssertTrue(axInsertions.isEmpty, "no AX write may be attempted on an unreliable target")
        XCTAssertEqual(pastesPosted, 1)
        runPendingRestore()
        XCTAssertEqual(pasteboard.stringContents, "original")
    }

    func testAXPathStillRunsPreflightChecks() {
        let inserter = makeInserter(secureInput: true, axSucceeds: true)
        XCTAssertThrowsError(try inserter.insert("x", target: 42))
        XCTAssertTrue(axInsertions.isEmpty, "Secure Input blocks the AX path too")
    }

    // MARK: v2 — deleteBackward (scratch that)

    func testDeleteBackwardPostsBackspaces() throws {
        let inserter = makeInserter()
        try inserter.deleteBackward(11, target: 42)
        XCTAssertEqual(backspacesPosted, [11])
    }

    func testDeleteBackwardRefusesOnTargetMismatch() {
        let inserter = makeInserter(frontmost: { 99 })
        XCTAssertThrowsError(try inserter.deleteBackward(5, target: 42)) { error in
            XCTAssertEqual(error as? InternosError, .insertionTargetChanged)
        }
        XCTAssertTrue(backspacesPosted.isEmpty)
    }

    func testDeleteBackwardRespectsSecureInput() {
        let inserter = makeInserter(secureInput: true)
        XCTAssertThrowsError(try inserter.deleteBackward(5, target: 42)) { error in
            XCTAssertEqual(error as? InternosError, .secureInputActive)
        }
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

    // MARK: paste settle (chained insertions)

    private var slept: [Duration] = []

    private func makeSettlingInserter(axSucceeds: Bool) -> TextInserter {
        pasteboard = FakePasteboard()
        scheduled = []
        slept = []
        return TextInserter(
            pasteboard: pasteboard,
            pasteSettleTime: .seconds(60),
            sleep: { [self] in slept.append($0) },
            scheduleRestore: { [self] work in scheduled.append(work) },
            secureInputActive: { false },
            accessibilityGranted: { true },
            frontmostPID: { 42 },
            axInsertionUnreliable: { _ in false },
            axInsert: { _, _ in axSucceeds ? TextInserter.AXTextSnapshot() : nil },
            postPaste: {},
            postBackspaces: { _ in }
        )
    }

    func testSettleWaitsOutAClipboardPaste() async throws {
        let inserter = makeSettlingInserter(axSucceeds: false)
        await inserter.settlePendingEvents()
        XCTAssertTrue(slept.isEmpty, "nothing pasted yet: no wait")

        try inserter.insert("first", target: 42)
        await inserter.settlePendingEvents()
        XCTAssertEqual(slept.count, 1, "the app needs time to read the pasteboard before it changes again")
        XCTAssertGreaterThan(slept[0], .seconds(59))
        XCTAssertLessThanOrEqual(slept[0], .seconds(60))
    }

    func testSettleDoesNotWaitAfterAccessibilityInsertion() async throws {
        let inserter = makeSettlingInserter(axSucceeds: true)
        XCTAssertEqual(try inserter.insert("direct", target: 42), .accessibility)
        await inserter.settlePendingEvents()
        XCTAssertTrue(slept.isEmpty, "no paste event is in flight")
    }

    /// Backspaces are queued key events too: the next insertion waits for them,
    /// longer the more there are.
    func testSettleWaitsOutScratchBackspaces() async throws {
        let inserter = makeSettlingInserter(axSucceeds: true)
        try inserter.deleteBackward(2000, target: 42)
        await inserter.settlePendingEvents()
        XCTAssertEqual(slept.count, 1)
        XCTAssertGreaterThan(slept[0], .seconds(61))
    }

    /// The inserter says how many key presses it is about to post, so they can
    /// be told from the user's: one per paste, one per backspace, none for AX,
    /// and a report is taken back if the posting fails.
    func testReportsTheKeyPressesItPosts() throws {
        var posted: [Int] = []
        let pasting = makeInserter()
        pasting.willPostKeyPresses = { posted.append($0) }
        try pasting.insert("pasted", target: 42)
        try pasting.deleteBackward(20, target: 42)
        XCTAssertEqual(posted, [1, 20])

        posted = []
        let direct = makeInserter(axSucceeds: true)
        direct.willPostKeyPresses = { posted.append($0) }
        try direct.insert("direct", target: 42)
        XCTAssertEqual(posted, [])

        let failing = makeInserter(postPasteError: InternosError.pasteEventFailed)
        failing.willPostKeyPresses = { posted.append($0) }
        XCTAssertThrowsError(try failing.insert("never posted", target: 42))
        XCTAssertEqual(posted, [1, -1])
    }
    // MARK: concealed clipboard entries (password managers)

    func testConcealedClipboardIsClearedNotRestored() throws {
        let inserter = makeInserter()
        pasteboard.writeItems([[.string: Data("hunter2".utf8), .concealedMarker: Data()]])
        try inserter.insert("transcript", target: 42)
        runPendingRestore()
        XCTAssertTrue(pasteboard.items.isEmpty, "a concealed entry must not come back under a new change count")
    }

    func testRestorableItemsDropsWholeSnapshotWhenAnyItemIsConcealed() {
        let plain: [[NSPasteboard.PasteboardType: Data]] = [[.string: Data("a".utf8)]]
        XCTAssertEqual(TextInserter.restorableItems(plain).count, 1)
        let mixed = plain + [[.string: Data("secret".utf8), .concealedMarker: Data()]]
        XCTAssertTrue(TextInserter.restorableItems(mixed).isEmpty)
    }

    // MARK: scratch-that caret check

    func testScratchRefusedWhenCaretMovedSinceAXInsertion() throws {
        let inserter = makeInserter(axSucceeds: true)
        axSnapshotAfterInsert = .init(characterCount: 20, selectedRange: (20, 0))
        try inserter.insert("hello there", target: 42)
        axSnapshotNow = .init(characterCount: 20, selectedRange: (3, 0))
        XCTAssertThrowsError(try inserter.deleteBackward(11, target: 42)) { error in
            XCTAssertEqual(error as? InternosError, .scratchTargetChanged)
        }
        XCTAssertTrue(backspacesPosted.isEmpty, "nothing may be deleted behind a moved caret")
    }

    func testScratchRefusedWhenTextChangedSinceAXInsertion() throws {
        let inserter = makeInserter(axSucceeds: true)
        axSnapshotAfterInsert = .init(characterCount: 20, selectedRange: (20, 0))
        try inserter.insert("hello there", target: 42)
        axSnapshotNow = .init(characterCount: 25, selectedRange: (25, 0)) // the user typed on
        XCTAssertThrowsError(try inserter.deleteBackward(11, target: 42))
        XCTAssertTrue(backspacesPosted.isEmpty)
    }

    func testScratchProceedsWhenCaretUnchanged() throws {
        let inserter = makeInserter(axSucceeds: true)
        axSnapshotAfterInsert = .init(characterCount: 20, selectedRange: (20, 0))
        try inserter.insert("hello there", target: 42)
        axSnapshotNow = axSnapshotAfterInsert
        try inserter.deleteBackward(11, target: 42)
        XCTAssertEqual(backspacesPosted, [11])
    }

    func testScratchProceedsWhenNothingIsReadable() throws {
        // Unreadable now (focus moved to an element without text attributes, or the
        // snapshot after the insertion was empty): inconclusive, same-app check only.
        let inserter = makeInserter(axSucceeds: true)
        axSnapshotAfterInsert = .init(characterCount: 20, selectedRange: (20, 0))
        try inserter.insert("hello there", target: 42)
        axSnapshotNow = TextInserter.AXTextSnapshot()
        try inserter.deleteBackward(11, target: 42)
        XCTAssertEqual(backspacesPosted, [11])
    }

    func testScratchAfterClipboardPasteHasNoCaretCheck() throws {
        let inserter = makeInserter(axSucceeds: false)
        try inserter.insert("hello there", target: 42)
        axSnapshotNow = .init(characterCount: 1, selectedRange: (0, 0))
        try inserter.deleteBackward(11, target: 42)
        XCTAssertEqual(backspacesPosted, [11])
    }

    func testScratchCheckIsOneShot() throws {
        let inserter = makeInserter(axSucceeds: true)
        axSnapshotAfterInsert = .init(characterCount: 20, selectedRange: (20, 0))
        try inserter.insert("hello there", target: 42)
        axSnapshotNow = axSnapshotAfterInsert
        try inserter.deleteBackward(11, target: 42)
        axSnapshotNow = .init(characterCount: 9, selectedRange: (2, 0))
        try inserter.deleteBackward(1, target: 42) // the controller never does this; the inserter must not refuse on a stale record
        XCTAssertEqual(backspacesPosted, [11, 1])
    }
}
