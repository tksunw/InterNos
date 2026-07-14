// Command mode (v2): transform the user's selected text according to a spoken
// instruction, entirely on-device via Foundation Models. The selection is read
// only on an explicit command-key invocation — never as ambient context — and
// neither the selection, the instruction, nor the model output is ever logged.
//
// Every failure (unavailable, timeout, refusal, invalid output) changes nothing:
// the selection stays exactly as it was and the app shows the error state.

import Foundation
import FoundationModels

protocol TextTransforming: Sendable {
    /// Returns the transformed text, or nil to signal a soft failure.
    func transform(_ text: String, instruction: String) async -> String?
}

/// Source-controlled prompt so changes are reviewable and testable.
enum CommandPrompt {
    static let version = 1

    static let instructions = """
    You edit text according to a spoken instruction. Return ONLY the edited text \
    with no preamble, labels, quotes, or commentary.

    Rules:
    - Apply the instruction faithfully; keep everything the instruction doesn't ask to change.
    - Preserve names, acronyms, code-like text, URLs, paths, numbers, and units unless \
    the instruction explicitly targets them.
    - Never add facts or content beyond what the instruction requires.
    - Preserve the input's paragraph boundaries unless the instruction changes structure.
    - If the instruction cannot be applied to this text, return the input unchanged.
    """

    static func prompt(instruction: String, text: String) -> String {
        "Instruction: \(instruction)\n\nText:\n\(text)"
    }
}

struct FoundationModelTransformer: TextTransforming {
    func transform(_ text: String, instruction: String) async -> String? {
        guard CleanupAvailability.isAvailable else { return nil }
        let session = LanguageModelSession(instructions: CommandPrompt.instructions)
        do {
            return try await session.respond(to: CommandPrompt.prompt(instruction: instruction, text: text)).content
        } catch {
            NSLog("Internos: command transform model error (\(type(of: error)))")
            return nil
        }
    }
}

/// Deadline + validation around the raw transformer. Transforms may legitimately
/// grow the text (expansions, translations), so the output cap is looser than
/// smart cleanup's.
struct CommandTransformCoordinator: TextTransforming {
    static let maxInputLength = 8000

    var transformer: any TextTransforming
    var deadline: Duration = .seconds(10)

    func transform(_ text: String, instruction: String) async -> String? {
        guard !text.isEmpty, !instruction.isEmpty else { return nil }
        guard text.count <= Self.maxInputLength else {
            NSLog("Internos: command transform skipped, selection too long (\(text.count) chars)")
            return nil
        }
        let start = ContinuousClock.now
        let raw = await Self.withDeadline(deadline) { [transformer] in
            await transformer.transform(text, instruction: instruction)
        }
        let elapsed = ContinuousClock.now - start
        guard let raw, let validated = Self.validate(raw, input: text) else {
            NSLog("Internos: command transform fallback (\(elapsed), \(text.count) chars in)")
            return nil
        }
        NSLog("Internos: command transform ok (\(elapsed), \(text.count) → \(validated.count) chars)")
        return validated
    }

    static func validate(_ output: String, input: String) -> String? {
        let value = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        // ponytail: 4x + 1024 growth ceiling; loosen if real rewrite use hits it.
        guard value.count <= input.count * 4 + 1024 else { return nil }
        let hasForbiddenControls = value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar) && scalar.value != 9 && scalar.value != 10
        }
        guard !hasForbiddenControls else { return nil }
        return value
    }

    /// Same non-blocking race as SmartCleanupCoordinator: the deadline never waits
    /// on a model call that ignores cancellation.
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
}
