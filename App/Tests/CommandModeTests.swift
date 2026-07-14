// v2: command mode — capture selection, record instruction, transform on-device,
// replace through the shared inserter. Every failure changes nothing.

import AppKit
import XCTest
@testable import Internos

final class FakeTransformer: TextTransforming, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(text: String, instruction: String)] = []
    var calls: [(text: String, instruction: String)] { lock.withLock { _calls } }
    var result: String?

    func transform(_ text: String, instruction: String) async -> String? {
        lock.withLock { _calls.append((text, instruction)) }
        return result
    }
}

@MainActor
final class CommandModeTests: XCTestCase {
    private var recorder = FakeRecorder()
    private var engine = FakeEngine()
    private var inserter = FakeInserter()
    private var status = FakeStatus()
    private var transformer = FakeTransformer()
    private var selection: (text: String, pid: pid_t)? = ("helo wrld", 42)
    private var available = true

    private func makeReadyController() async -> DictationController {
        recorder = FakeRecorder()
        engine = FakeEngine()
        inserter = FakeInserter()
        status = FakeStatus()
        transformer = FakeTransformer()
        selection = ("helo wrld", 42)
        available = true
        let controller = DictationController(
            hotkey: FakeHotkey(),
            recorder: recorder,
            engine: engine,
            inserter: inserter,
            statusItem: status,
            indicator: FakeIndicator(),
            processingSettings: { ProcessingSettings() },
            playSound: { _ in },
            frontmostPID: { 42 },
            onboardingPresenter: { _, _ in },
            transformer: transformer,
            selectionProvider: { [self] in selection },
            commandModeAvailable: { [self] in available }
        )
        await controller.initializePipeline()
        return controller
    }

    func testHappyPathReplacesSelection() async {
        let controller = await makeReadyController()
        transformer.result = "hello world"

        controller.commandKeyDown()
        XCTAssertEqual(controller.state, .commandRecording)
        await waitUntil { self.engine.pendingCount == 1 }
        controller.commandKeyUp()
        engine.complete(1, with: .success("fix the spelling"))

        await waitUntil { self.inserter.insertions.count == 1 }
        XCTAssertEqual(transformer.calls.count, 1)
        XCTAssertEqual(transformer.calls.first?.text, "helo wrld")
        XCTAssertEqual(transformer.calls.first?.instruction, "fix the spelling")
        XCTAssertEqual(inserter.insertions.first?.text, "hello world")
        XCTAssertEqual(inserter.insertions.first?.target, 42)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.volatileStore.current?.raw, "helo wrld",
                       "the original selection is recoverable via Copy Last Raw")
        XCTAssertEqual(controller.volatileStore.current?.final, "hello world")
    }

    func testNoSelectionFailsLoudWithoutRecording() async {
        let controller = await makeReadyController()
        selection = nil

        controller.commandKeyDown()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(recorder.startCount, 0, "no selection → no capture")
        XCTAssertEqual(status.states.last, .error)
    }

    func testUnavailableModelFailsLoudWithoutRecording() async {
        let controller = await makeReadyController()
        available = false

        controller.commandKeyDown()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(recorder.startCount, 0)
        XCTAssertEqual(status.states.last, .error)
    }

    func testTransformFailureChangesNothing() async {
        let controller = await makeReadyController()
        transformer.result = nil // timeout / refusal / invalid output

        controller.commandKeyDown()
        await waitUntil { self.engine.pendingCount == 1 }
        controller.commandKeyUp()
        engine.complete(1, with: .success("make it fancy"))

        await waitUntil { self.status.states.last == .error }
        XCTAssertTrue(inserter.insertions.isEmpty, "a failed transform must not touch the selection")
        XCTAssertNil(controller.volatileStore.current)
        XCTAssertEqual(controller.state, .idle)
    }

    func testEmptyInstructionChangesNothing() async {
        let controller = await makeReadyController()
        transformer.result = "SHOULD NOT BE USED"

        controller.commandKeyDown()
        await waitUntil { self.engine.pendingCount == 1 }
        controller.commandKeyUp()
        engine.complete(1, with: .success("   "))

        await waitUntil { self.status.states.last == .error }
        XCTAssertTrue(transformer.calls.isEmpty, "an empty instruction never reaches the model")
        XCTAssertTrue(inserter.insertions.isEmpty)
    }

    func testPauseDuringCommandPreventsReplacement() async {
        let controller = await makeReadyController()
        transformer.result = "hello world"

        controller.commandKeyDown()
        await waitUntil { self.engine.pendingCount == 1 }
        controller.commandKeyUp()
        controller.togglePause()
        engine.complete(1, with: .success("fix the spelling"))

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(inserter.insertions.isEmpty, "pause suppresses the pending replacement")
        XCTAssertEqual(controller.state, .paused)
    }

    func testScratchAfterCommandDeletesTransformedText() async {
        let controller = await makeReadyController()
        transformer.result = "hello world" // 11 chars

        controller.commandKeyDown()
        await waitUntil { self.engine.pendingCount == 1 }
        controller.commandKeyUp()
        engine.complete(1, with: .success("fix the spelling"))
        await waitUntil { self.inserter.insertions.count == 1 }

        controller.beginUtterance()
        await waitUntil { self.engine.pendingCount == 1 }
        controller.endUtterance()
        engine.complete(2, with: .success("scratch that"))
        await waitUntil { !self.inserter.deletions.isEmpty }

        XCTAssertEqual(inserter.deletions.map(\.count), [11])
    }

    func testDictationKeyIgnoredDuringCommandRecording() async {
        let controller = await makeReadyController()
        transformer.result = "x"

        controller.commandKeyDown()
        await waitUntil { self.engine.pendingCount == 1 }
        controller.beginUtterance() // dictation attempt mid-command
        XCTAssertEqual(recorder.startCount, 1, "command recording owns the mic")

        controller.commandKeyUp()
        engine.complete(1, with: .success("noop"))
        await waitUntil { controller.state == .idle }
    }

    func testCommandTransformValidation() {
        let validate = { CommandTransformCoordinator.validate($0, input: "0123456789") }
        XCTAssertNil(validate(""))
        XCTAssertNil(validate("  \n "))
        XCTAssertNil(validate("bad \u{0007} output"))
        XCTAssertNil(validate(String(repeating: "x", count: 10 * 4 + 1024 + 1)))
        XCTAssertEqual(validate(" ok\r\nvalue "), "ok\nvalue")
    }

    func testCoordinatorDeadlineFallsBack() async {
        struct HangingTransformer: TextTransforming {
            let gate: Gate
            func transform(_ text: String, instruction: String) async -> String? {
                await gate.wait()
                return "late"
            }
        }
        let gate = Gate()
        let coordinator = CommandTransformCoordinator(
            transformer: HangingTransformer(gate: gate), deadline: .milliseconds(50))
        let result = await coordinator.transform("text", instruction: "do it")
        XCTAssertNil(result)
        gate.open()
    }
}
