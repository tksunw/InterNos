// Per-utterance SpeechAnalyzer session around SpeechTranscriber(.transcription).
// Spike findings: finalized-results-only fits hold-and-release; DictationTranscriber
// finalizes poorly — don't use it. processLifetime retention keeps the model warm
// so back-to-back utterances stay fast.

import AVFoundation
import Speech

/// Controller-facing seam so lifecycle tests can substitute a deterministic transcriber.
protocol TranscriptionProviding: Sendable {
    func modelStatus() async -> AssetInventory.Status
    func ensureModel() async throws
    func analyzerFormat() async throws -> AVAudioFormat
    func transcribe(input: AsyncStream<AnalyzerInput>, format: AVAudioFormat) async throws -> String
}

final class TranscriptionEngine: TranscriptionProviding, Sendable {
    private let locale = Locale(identifier: "en_US")

    func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .transcription)
    }

    func modelStatus() async -> AssetInventory.Status {
        await AssetInventory.status(forModules: [makeTranscriber()])
    }

    /// Ensure the en-US model asset is installed (downloads on first run).
    func ensureModel() async throws {
        let transcriber = makeTranscriber()
        let status = await AssetInventory.status(forModules: [transcriber])
        switch status {
        case .installed:
            return
        case .supported, .downloading:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            // A nil request or a returned downloadAndInstall() is not proof of
            // installation (IR-006): only a verified .installed status counts.
            guard await AssetInventory.status(forModules: [makeTranscriber()]) == .installed else {
                throw InternosError.modelNotInstalled
            }
        case .unsupported:
            throw InternosError.modelNotInstalled
        @unknown default:
            throw InternosError.modelNotInstalled
        }
    }

    func analyzerFormat() async throws -> AVAudioFormat {
        let transcriber = makeTranscriber()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw InternosError.analyzerFormatUnavailable
        }
        return format
    }

    /// Runs one utterance session: consumes `input` until it finishes, returns the final transcript.
    func transcribe(input: AsyncStream<AnalyzerInput>, format: AVAudioFormat) async throws -> String {
        let transcriber = makeTranscriber()
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .processLifetime)
        )
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: input)

        let consumer = Task {
            var transcript = ""
            for try await result in transcriber.results where result.isFinal {
                transcript += String(result.text.characters)
            }
            return transcript
        }

        // Input stream finishing (hotkey release) ends analysis; finalize flushes the tail.
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return TranscriptPostProcessor.process(
            try await consumer.value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
