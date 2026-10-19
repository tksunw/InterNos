// Per-utterance SpeechAnalyzer session around SpeechTranscriber(.transcription).
// Spike findings: finalized-results-only fits hold-and-release; DictationTranscriber
// finalizes poorly — don't use it. processLifetime retention keeps the model warm
// so back-to-back utterances stay fast.

import AVFoundation
import Speech

/// Controller-facing seam so lifecycle tests can substitute a deterministic transcriber.
protocol TranscriptionProviding: Sendable {
    // Every step takes the language it is for. The caller pins one language per
    // setup and per utterance: a pick in Settings while either is under way must
    // not reach a step whose model or audio format belong to the earlier one.
    func modelStatus(locale: Locale) async -> AssetInventory.Status
    func ensureModel(locale: Locale) async throws
    func analyzerFormat(locale: Locale) async throws -> AVAudioFormat
    /// `onPartial` receives the accumulated transcript (finalized prefix + current
    /// volatile tail) as recognition progresses — drives the live preview (v2).
    func transcribe(
        input: AsyncStream<AnalyzerInput>,
        format: AVAudioFormat,
        locale: Locale,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String
}

final class TranscriptionEngine: TranscriptionProviding, Sendable {
    /// The language selected in Settings, for callers outside a pinned setup or
    /// utterance (the setup window's model download).
    static var selectedLocale: Locale {
        Locale(identifier: UserDefaults.standard.string(forKey: recognitionLocaleKey) ?? recognitionLocaleDefault)
    }

    /// Volatile results feed the live preview; finalized results build the transcript.
    /// The locale is always the caller's: a default that read Settings here would
    /// undo the pinning the controller does per setup and per utterance.
    func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
    }

    func modelStatus(locale: Locale) async -> AssetInventory.Status {
        await AssetInventory.status(forModules: [makeTranscriber(locale: locale)])
    }

    /// Ensure the model asset for `locale` is installed (downloads on first run).
    func ensureModel(locale: Locale) async throws {
        let transcriber = makeTranscriber(locale: locale)
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
            guard await AssetInventory.status(forModules: [makeTranscriber(locale: locale)]) == .installed else {
                throw InternosError.modelNotInstalled
            }
        case .unsupported:
            throw InternosError.modelNotInstalled
        @unknown default:
            throw InternosError.modelNotInstalled
        }
    }

    func analyzerFormat(locale: Locale) async throws -> AVAudioFormat {
        let transcriber = makeTranscriber(locale: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw InternosError.analyzerFormatUnavailable
        }
        return format
    }

    /// Runs one utterance session: consumes `input` until it finishes, returns the
    /// trimmed raw transcript. User-facing postprocessing (commands, replacements,
    /// snippets, cleanup) is owned by TranscriptPipeline, not the engine.
    func transcribe(
        input: AsyncStream<AnalyzerInput>,
        format: AVAudioFormat,
        locale: Locale,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let transcriber = makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .processLifetime)
        )
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: input)

        let consumer = Task {
            var transcript = ""
            for try await result in transcriber.results {
                if result.isFinal {
                    transcript += String(result.text.characters)
                    onPartial?(transcript)
                } else {
                    // Volatile tail: replaces the previous volatile guess, shown
                    // after the finalized prefix for display only (live preview).
                    onPartial?(transcript + String(result.text.characters))
                }
            }
            return transcript
        }

        // Input stream finishing (hotkey release) ends analysis; finalize flushes the tail.
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await consumer.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
