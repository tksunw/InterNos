// Volatile last-transcript recovery (feature 2). Process memory only — this is
// deliberately NOT transcript history: one value, gone on quit, never written
// to disk, defaults, logs, or exports.

import Foundation

struct VolatileTranscript: Equatable, Sendable {
    let raw: String
    let final: String
    let completedAt: ContinuousClock.Instant
    let cleanupApplied: Bool
}

@MainActor
final class VolatileTranscriptStore {
    private(set) var current: VolatileTranscript?

    /// Records a completed transcript before the first insertion attempt. An empty
    /// final value never replaces a valid previous one.
    func record(raw: String, final: String, cleanupApplied: Bool) {
        guard !final.isEmpty else { return }
        current = VolatileTranscript(
            raw: raw, final: final, completedAt: ContinuousClock.now, cleanupApplied: cleanupApplied)
    }

    func clear() {
        current = nil
    }
}

/// What the status menu needs to enable/hide the recovery items.
struct RecoveryMenuState: Equatable {
    var hasTranscript = false
    /// True when smart cleanup changed the text, so "Copy Last Raw Dictation" is useful.
    var hasDistinctRaw = false
}
