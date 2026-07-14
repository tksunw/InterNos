// Test doubles for the dictation lifecycle (build-and-repair handoff).
// All fakes are deterministic: no real audio, speech, pasteboard, event tap, or timers.

import AppKit
import AVFoundation
import Speech
@testable import Internos

/// Polls a condition on the main actor until it holds or the timeout expires.
@MainActor
func waitUntil(
    timeout: TimeInterval = 2,
    _ condition: @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

// MARK: - DictationController dependencies

@MainActor
final class FakeHotkey: HotkeyMonitoring {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var startResult = true
    private(set) var reloadCount = 0
    func start() -> Bool { startResult }
    func reloadSettings() { reloadCount += 1 }
}

final class FakeRecorder: RecordingSource, @unchecked Sendable {
    var onLevel: (@Sendable (CGFloat) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var startError: Error?
    func start(analyzerFormat: AVAudioFormat, deviceUID: String?) throws -> AsyncStream<AnalyzerInput> {
        if let startError { throw startError }
        startCount += 1
        return AsyncStream { $0.finish() }
    }
    func stop() { stopCount += 1 }
}

/// Transcriptions complete only when the test says so, in whatever order the test picks.
final class FakeEngine: TranscriptionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]
    private var callIndex = 0

    var ensureModelError: Error?
    var modelStatusValue: AssetInventory.Status = .installed

    var pendingCount: Int { lock.withLock { pending.count } }

    func modelStatus() async -> AssetInventory.Status { modelStatusValue }

    func ensureModel() async throws {
        if let ensureModelError { throw ensureModelError }
    }

    func analyzerFormat() async throws -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    }

    func transcribe(input: AsyncStream<AnalyzerInput>, format: AVAudioFormat) async throws -> String {
        let index: Int = lock.withLock {
            callIndex += 1
            return callIndex
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { pending[index] = continuation }
        }
    }

    /// Completes the `index`-th transcription (1-based, in start order).
    func complete(_ index: Int, with result: Result<String, Error>) {
        let continuation = lock.withLock { pending.removeValue(forKey: index) }
        continuation?.resume(with: result)
    }
}

@MainActor
final class FakeInserter: TextInserting {
    private(set) var insertions: [(text: String, target: pid_t?)] = []
    private(set) var preserved: [String] = []
    var errorToThrow: Error?
    func insert(_ text: String, target: pid_t?) throws {
        if let errorToThrow { throw errorToThrow }
        insertions.append((text, target))
    }
    func preserveOnClipboard(_ text: String) { preserved.append(text) }
}

@MainActor
final class FakeStatus: StatusPresenting {
    var onTogglePause: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenSetup: (() -> Void)?
    var isPaused = false
    private(set) var states: [AppState] = []
    func setState(_ state: AppState) { states.append(state) }
    func refreshHotkeyHint() {}
}

@MainActor
final class FakeIndicator: IndicatorPresenting {
    private(set) var shown: [IndicatorState] = []
    private(set) var hideCount = 0
    func show(_ state: IndicatorState) { shown.append(state) }
    func hide() { hideCount += 1 }
    func pushLevel(_ level: CGFloat) {}
}

// MARK: - TextInserter dependencies

@MainActor
final class FakePasteboard: PasteboardProviding {
    private(set) var changeCount = 0
    private(set) var items: [[NSPasteboard.PasteboardType: Data]] = []

    var stringContents: String? {
        items.first?[.string].flatMap { String(data: $0, encoding: .utf8) }
    }

    func snapshotItems() -> [[NSPasteboard.PasteboardType: Data]] { items }

    // NSPasteboard semantics: taking ownership (clearContents) bumps changeCount;
    // adding data to the current ownership does not.
    func clear() {
        items = []
        changeCount += 1
    }

    func write(_ string: String, forType type: NSPasteboard.PasteboardType) {
        if items.isEmpty { items = [[:]] }
        items[0][type] = Data(string.utf8)
    }

    func writeItems(_ newItems: [[NSPasteboard.PasteboardType: Data]]) {
        items = newItems
    }

    /// Simulates the user (or another app) copying something during the restore window.
    func userCopy(_ string: String) {
        clear()
        write(string, forType: .string)
    }
}

// MARK: - OnboardingModel dependencies

/// Lets a test block downloadAndInstall until released.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let alreadyOpen: Bool = lock.withLock {
                if opened { return true }
                waiters.append(continuation)
                return false
            }
            if alreadyOpen { continuation.resume() }
        }
    }

    func open() {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            opened = true
            let w = waiters
            waiters = []
            return w
        }
        toResume.forEach { $0.resume() }
    }
}

struct FakeInstallRequest: ModelInstallationRequest, @unchecked Sendable {
    let progress = Progress(totalUnitCount: 10)
    var installError: Error?
    var gate: Gate?
    func downloadAndInstall() async throws {
        if let gate { await gate.wait() }
        if let installError { throw installError }
    }
}

final class FakeAssetStore: ModelAssetInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: AssetInventory.Status = .supported
    private var _requestCount = 0

    var request: (any ModelInstallationRequest)?
    var requestError: Error?

    var statusValue: AssetInventory.Status {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
    var requestCount: Int { lock.withLock { _requestCount } }

    func status() async -> AssetInventory.Status { statusValue }

    func installationRequest() async throws -> (any ModelInstallationRequest)? {
        lock.withLock { _requestCount += 1 }
        if let requestError { throw requestError }
        return request
    }
}
