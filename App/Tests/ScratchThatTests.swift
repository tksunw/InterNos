// v2: "scratch that" voice undo — deletes the previous insertion via backspaces,
// one-shot, only into the same still-frontmost app.

import AppKit
import XCTest
@testable import Internos

@MainActor
final class ScratchThatTests: XCTestCase {
    private var engine = FakeEngine()
    private var inserter = FakeInserter()
    private var status = FakeStatus()
    private var frontmost: pid_t? = 42

    private func makeReadyController() async -> DictationController {
        engine = FakeEngine()
        inserter = FakeInserter()
        status = FakeStatus()
        frontmost = 42
        let controller = DictationController(
            hotkey: FakeHotkey(),
            recorder: FakeRecorder(),
            engine: engine,
            inserter: inserter,
            statusItem: status,
            indicator: FakeIndicator(),
            processingSettings: { ProcessingSettings() },
            playSound: { _ in },
            frontmostPID: { [self] in frontmost },
            onboardingPresenter: { _, _ in }
        )
        await controller.initializePipeline()
        return controller
    }

    private func dictate(_ controller: DictationController, _ text: String, index: Int) async {
        controller.beginUtterance()
        await waitUntil { self.engine.pendingCount == 1 }
        controller.endUtterance()
        engine.complete(index, with: .success(text))
        await waitUntil { controller.state == .idle && self.engine.pendingCount == 0 }
    }

    func testScratchCommandDetection() {
        XCTAssertTrue(DictationController.isScratchCommand("scratch that"))
        XCTAssertTrue(DictationController.isScratchCommand("Scratch that."))
        XCTAssertTrue(DictationController.isScratchCommand("  SCRATCH THAT!  "))
        // Natural lead-ins (beta-4 field report: "Actually, scratch that.").
        XCTAssertTrue(DictationController.isScratchCommand("Actually, scratch that."))
        XCTAssertTrue(DictationController.isScratchCommand("No, scratch that."))
        XCTAssertTrue(DictationController.isScratchCommand("oh wait scratch that"))
        XCTAssertTrue(DictationController.isScratchCommand("please scratch that"))
        // Longer sentences and other endings stay literal text.
        XCTAssertFalse(DictationController.isScratchCommand("scratch that itch"))
        XCTAssertFalse(DictationController.isScratchCommand("I told him he should scratch that"))
        XCTAssertFalse(DictationController.isScratchCommand("we should go scratch that lottery ticket"))
        XCTAssertFalse(DictationController.isScratchCommand("scratch"))
    }

    func testScratchDeletesPreviousInsertion() async {
        let controller = await makeReadyController()
        await dictate(controller, "hello world", index: 1) // 11 chars inserted
        XCTAssertEqual(inserter.insertions.count, 1)

        await dictate(controller, "scratch that", index: 2)

        XCTAssertEqual(inserter.deletions.map(\.count), [11])
        XCTAssertEqual(inserter.deletions.first?.target, 42)
        XCTAssertEqual(inserter.insertions.count, 1, "the scratch utterance itself is never inserted")
    }

    func testScratchIsOneShot() async {
        let controller = await makeReadyController()
        await dictate(controller, "hello", index: 1)
        await dictate(controller, "scratch that", index: 2)
        await dictate(controller, "scratch that", index: 3)

        XCTAssertEqual(inserter.deletions.count, 1, "a second scratch must not eat older text")
        XCTAssertEqual(status.states.last, .error, "second scratch fails loud")
    }

    func testScratchWithNothingToUndoFailsLoud() async {
        let controller = await makeReadyController()
        await dictate(controller, "scratch that", index: 1)
        XCTAssertTrue(inserter.deletions.isEmpty)
        XCTAssertEqual(status.states.last, .error)
    }

    func testScratchRefusedWhenTargetChanged() async {
        let controller = await makeReadyController()
        await dictate(controller, "hello", index: 1)
        inserter.errorToThrow = InternosError.insertionTargetChanged

        await dictate(controller, "scratch that", index: 2)
        XCTAssertTrue(inserter.deletions.isEmpty)
        XCTAssertEqual(status.states.last, .error)
    }

    func testNextInsertionReplacesScratchTarget() async {
        let controller = await makeReadyController()
        await dictate(controller, "first", index: 1)   // 5 chars
        await dictate(controller, "second!", index: 2) // 7 chars
        await dictate(controller, "scratch that", index: 3)

        XCTAssertEqual(inserter.deletions.map(\.count), [7], "scratch deletes the most recent insertion only")
    }
}
