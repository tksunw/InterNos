# Spike findings (2026-07-02)

Hardware: Apple Silicon (arm64), macOS 26.5.2, Xcode 26.4 / SDK 26.4.

## (a) en-US model asset flow — works

- `SpeechTranscriber.supportedLocales`: 30 locales incl. `en_US`.
- `AssetInventory.status(forModules:)` went `supported` → (download) → `installed`.
- `AssetInventory.assetInstallationRequest(supporting:).downloadAndInstall()` completed in seconds on this machine (asset small or pre-staged).
- Note: `AssetInventory.maximumReservedLocales = 5` — a system-wide cap the PRD didn't know about; irrelevant for en-US-only v1.

## (b) audio format — conversion required, as predicted

- `SpeechAnalyzer.bestAvailableAudioFormat` = **16 kHz mono Int16**.
- Mic hardware format = **48 kHz mono Float32**.
- AVAudioConverter per-chunk conversion (the MVP tap pattern) works; validated in the `stream` command.

## (c) end-to-end transcription — works, fast, accurate

- File path (`SpeechAnalyzer(inputAudioFile:finishAfterFile:true)`): ~6.6 s utterance transcribed in **0.37–0.44 s**.
- Streaming path (AsyncStream<AnalyzerInput> → `start(inputSequence:)` → `finalizeAndFinishThroughEndOfInput()`): release→final latency **0.22 s** — well under the PRD's 1 s target.
- Accuracy on jargon was strong out of the box: "Azure Gateway", "firewall rules", "Scout Troop" all correct from a synthesized `say` voice.
- Confirmed the silent-empty-result failure mode is real (DictationTranscriber case below).

## (d) custom vocabulary — API exists but is inert for SpeechTranscriber

The PRD v0.1 claim ("no custom vocabulary") was **wrong about the API surface but right about the effect**:

- `AnalysisContext.contextualStrings: [ContextualStringsTag: [String]]` **exists** in the macOS 26 SDK and is accepted by `SpeechAnalyzer(analysisContext:)`.
- Empirically it had **no effect** on `SpeechTranscriber` output (misrecognized "Internos" → "Internist" with and without the term supplied), nor on `DictationTranscriber`.
- `DictationTranscriber.ContentHint.customizedLanguage(modelConfiguration: SFSpeechLanguageModel.Configuration)` exists — a full custom-LM path (train `SFCustomLanguageModelData` with PhraseCounts/CustomPronunciations). Heavier, and tied to DictationTranscriber.
- Conclusion for v1: treat recognition-layer vocabulary as unavailable; post-processing (Foundation Models find/replace) remains the practical dictionary route.

## Module choice: SpeechTranscriber, not DictationTranscriber

- `DictationTranscriber(.shortDictation)` on the same audio emitted only a **volatile** result (never finalized through the file flow) and lower accuracy ("the internal" for "Internos dictation").
- `SpeechTranscriber(.transcription)` finalizes properly and is more accurate. Use it.

## Not yet exercised

- `live` (real mic capture) — requires interactive Microphone TCC grant; the code path is identical to `stream` except for the AVAudioEngine tap. Run `swift run internos-spike live 6` in a terminal to verify interactively.

## Usage

```
swift run internos-spike info                # locales, asset status, formats
swift run internos-spike download            # install en-US model
swift run internos-spike file <path> [terms…]     # file transcription (+contextual strings)
swift run internos-spike file --dictation <path>  # DictationTranscriber comparison
swift run internos-spike stream <path>       # simulated live pipeline + latency
swift run internos-spike live <seconds>      # real mic (needs TCC grant)
```
