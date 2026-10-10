// A deadline race for on-device model calls (smart cleanup, command mode).
// The model can ignore cancellation, so the deadline never waits on it.

import Foundation

/// Resumes a continuation at most once, whichever racer gets there first.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?
    init(_ continuation: CheckedContinuation<Value?, Never>) { self.continuation = continuation }
    func resume(_ value: Value?) {
        let taken: CheckedContinuation<Value?, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        taken?.resume(returning: value)
    }
}

/// Races `work` against a deadline without blocking on a call that ignores
/// cancellation (a stuck model or analyzer): whoever finishes first wins, the
/// loser is cancelled and its eventual result discarded. nil means the deadline won.
func withDeadline<Value: Sendable>(
    _ limit: Duration, _ work: @escaping @Sendable () async -> Value?
) async -> Value? {
    await withCheckedContinuation { continuation in
        let once = ResumeOnce(continuation)
        let workTask = Task { await work() }
        let timer = Task {
            try await Task.sleep(for: limit) // throws once the work has won
            workTask.cancel()
            once.resume(nil)
        }
        Task {
            once.resume(await workTask.value)
            timer.cancel()
        }
    }
}
