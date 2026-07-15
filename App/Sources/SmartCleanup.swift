// Optional on-device smart cleanup (feature 4). Foundation Models only — the
// default SystemLanguageModel, one fresh session per utterance, no cloud, no
// fallback service. Every failure (unavailable, refusal, timeout, invalid
// output) is soft: the pipeline continues with deterministic processing.
//
// Only ordinary text segments ever reach a prompt (TranscriptPipeline routes
// them); snippet contents, literals, and replacement outputs never do.
// Logging is category-only: mode, elapsed time, character counts. Never content.

import Foundation
import FoundationModels

/// Source-controlled prompt instructions so changes are reviewable and testable.
enum CleanupPrompt {
    static let version = 1

    private static let common = """
    You revise dictated speech into clean written text. Return ONLY the revised text \
    with no preamble, labels, quotes, or commentary.

    Rules you must always follow:
    - Preserve the speaker's meaning and level of detail. Never add facts, advice, \
    names, examples, or conclusions. Never summarize away substantive content.
    - Preserve names, acronyms, code-like text, URLs, file paths, commands, numbers, \
    units, and quoted content exactly, unless the speaker explicitly corrected them.
    - When the speaker corrects themselves (for example "Tuesday, actually Wednesday"), \
    keep only the corrected value.
    - Preserve paragraph boundaries present in the input.
    - Do not translate. Do not change the tone beyond what the selected level permits.
    """

    private static let light = """
    Level: LIGHT. Apply only these transformations:
    - Remove filler words such as "um", "uh", "you know", "like" (when used as filler).
    - Remove immediate accidental word repetition.
    - Collapse clear false starts.
    - Apply explicit self-corrections.
    - Fix obvious punctuation and sentence-boundary errors.
    Change nothing else. Keep the speaker's wording.
    """

    private static let polished = """
    Level: POLISHED. Apply the LIGHT transformations, and additionally:
    - Smooth spoken fragments into complete sentences.
    - Format short prose for readability.
    - Remove conversational scaffolding.
    Preserve the speaker's meaning, detail, and voice.
    """

    static func instructions(for mode: CleanupMode) -> String {
        switch mode {
        case .off: ""
        case .light: common + "\n\n" + light
        case .polished: common + "\n\n" + polished
        }
    }
}

/// Deterministic filler-word removal — the zero-risk subset of Light cleanup.
/// Used for utterances containing snippets/commands (where the model would see
/// dangling fragments and invent completions) and as the fallback when the model
/// path fails. Only non-word vocalizations: stripping "like" or "you know"
/// needs semantics only the model has.
enum FillerStripper {
    private static let fillers: Set<String> = ["um", "uh", "uhm", "umm", "er", "erm", "hmm", "mhm"]

    static func strip(_ text: String) -> String {
        let tokens = TranscriptTokenizer.tokenize(text)
        guard tokens.contains(where: { fillers.contains($0.core) }) else { return text }
        let kept = tokens.filter { !fillers.contains($0.core) }
        return kept.map { String(text[$0.range]) }.joined(separator: " ")
    }
}

/// Availability of the on-device model, for Settings and preflight checks.
enum CleanupAvailability {
    static var isAvailable: Bool { explanation == nil }

    /// nil when available; otherwise a short local explanation for Settings.
    static var explanation: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            nil
        case .unavailable(.deviceNotEligible):
            "This Mac doesn't support Apple Intelligence, which smart cleanup requires."
        case .unavailable(.appleIntelligenceNotEnabled):
            "Turn on Apple Intelligence in System Settings to use smart cleanup."
        case .unavailable(.modelNotReady):
            "The Apple Intelligence model is still downloading. Smart cleanup will become available when it finishes."
        case .unavailable:
            "Apple Intelligence isn't available on this Mac right now."
        }
    }
}

/// The raw Foundation Models cleaner. Availability is checked before every
/// session; a fresh session is created per utterance and discarded.
struct FoundationModelCleaner: SmartCleaning {
    func clean(_ text: String, mode: CleanupMode) async -> String? {
        guard mode != .off else { return nil }
        guard CleanupAvailability.isAvailable else { return nil }
        let session = LanguageModelSession(instructions: CleanupPrompt.instructions(for: mode))
        do {
            return try await session.respond(to: text).content
        } catch {
            // Refusals, guardrails, context exhaustion, cancellation: soft failure.
            // Log the error type only — messages could echo prompt content.
            NSLog("Internos: cleanup model error (\(type(of: error)))")
            return nil
        }
    }
}

/// Wraps a cleaner with the product's safety bounds: input size cap, hard
/// deadline, and output validation. This is what the pipeline talks to.
struct SmartCleanupCoordinator: SmartCleaning {
    static let maxInputLength = 4000

    var cleaner: any SmartCleaning
    var deadline: Duration = .seconds(2)

    func clean(_ text: String, mode: CleanupMode) async -> String? {
        guard mode != .off, !text.isEmpty else { return nil }
        guard text.count <= Self.maxInputLength else {
            NSLog("Internos: cleanup skipped, input too long (\(text.count) chars)")
            return nil
        }
        let start = ContinuousClock.now
        let raw = await Self.withDeadline(deadline) { [cleaner] in
            await cleaner.clean(text, mode: mode)
        }
        let elapsed = ContinuousClock.now - start
        guard let raw, let validated = Self.validate(raw, input: text) else {
            NSLog("Internos: cleanup fallback (mode \(mode.rawValue), \(elapsed), \(text.count) chars in)")
            return nil
        }
        NSLog("Internos: cleanup applied (mode \(mode.rawValue), \(elapsed), \(text.count) → \(validated.count) chars)")
        return validated
    }

    /// Races `work` against the deadline without blocking on a model call that
    /// ignores cancellation: whoever finishes first wins, the loser is cancelled
    /// and its eventual result discarded.
    private static func withDeadline(
        _ limit: Duration, _ work: @escaping @Sendable () async -> String?
    ) async -> String? {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<String?, Never>?
            init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }
            func resume(_ value: String?) {
                let taken: CheckedContinuation<String?, Never>? = lock.withLock {
                    defer { continuation = nil }
                    return continuation
                }
                taken?.resume(returning: value)
            }
        }
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
            let workTask = Task { once.resume(await work()) }
            Task {
                try? await Task.sleep(for: limit)
                workTask.cancel()
                once.resume(nil)
            }
        }
    }

    /// Obvious-failure checks, not semantic fidelity (the raw value stays in
    /// volatile recovery for that). Returns the normalized output or nil to reject.
    static func validate(_ output: String, input: String) -> String? {
        let value = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        guard value.count <= Int(Double(input.count) * 1.5) + 128 else { return nil }
        let hasForbiddenControls = value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) && scalar.value != 9 && scalar.value != 10
        }
        guard !hasForbiddenControls else { return nil }
        // A URL or markdown link the speaker never said is a hallucination signature
        // (beta field report: a fabricated "[handle here](https://…)" completion).
        let inputFolded = input.lowercased()
        for marker in ["http://", "https://", "]("] where value.lowercased().contains(marker) && !inputFolded.contains(marker) {
            return nil
        }
        return value
    }
}
