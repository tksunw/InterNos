// internos-spike — throwaway CLI validating the Internos transcription pipeline (PRD §12 milestone 1).
//
// Answers four spike questions:
//   (a) en-US model asset status/download via AssetInventory
//   (b) bestAvailableAudioFormat vs. hardware format (mismatch = silent empty results)
//   (c) end-to-end transcription (audio file or live mic)
//   (d) whether contextualStrings (custom vocabulary) affects results
//
// Usage:
//   internos-spike info                     # locales, asset status, audio formats
//   internos-spike download                 # install the en-US model asset if needed
//   internos-spike file <path> [terms...]   # transcribe an audio file; optional contextual strings
//   internos-spike live <seconds>           # record from default mic and transcribe

import AVFoundation
import Foundation
import Speech

let locale = Locale(identifier: "en_US")

func fmt(_ format: AVAudioFormat?) -> String {
    guard let f = format else { return "nil" }
    return "\(f.sampleRate) Hz, \(f.channelCount) ch, \(f.commonFormat.rawValue) (commonFormat)"
}

func makeTranscriber() -> SpeechTranscriber {
    // Hold-and-release flow: finalized results only — no volatile reporting needed.
    SpeechTranscriber(locale: locale, preset: .transcription)
}

func printInfo() async {
    print("== SpeechTranscriber locales ==")
    let supported = await SpeechTranscriber.supportedLocales
    print("supported: \(supported.map(\.identifier).sorted().joined(separator: ", "))")
    let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    print("equivalent to en_US: \(equivalent?.identifier ?? "NONE — unsupported")")

    let transcriber = makeTranscriber()
    let status = await AssetInventory.status(forModules: [transcriber])
    print("\n== AssetInventory ==")
    print("status(en_US): \(status)")
    print("maximumReservedLocales: \(AssetInventory.maximumReservedLocales)")
    let reserved = await AssetInventory.reservedLocales
    print("reservedLocales: \(reserved.map(\.identifier).joined(separator: ", "))")

    print("\n== Audio formats ==")
    let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    print("bestAvailableAudioFormat: \(fmt(best))")
    let engine = AVAudioEngine()
    let hw = engine.inputNode.inputFormat(forBus: 0)
    print("mic hardware format:      \(fmt(hw))")
    if let best, hw.sampleRate != best.sampleRate || hw.channelCount != best.channelCount {
        print("→ conversion REQUIRED (as the PRD warns; mismatch yields silent empty results)")
    }
}

func ensureAssets() async throws {
    let transcriber = makeTranscriber()
    let status = await AssetInventory.status(forModules: [transcriber])
    print("asset status: \(status)")
    switch status {
    case .installed:
        print("model already installed — nothing to do")
    case .supported, .downloading:
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            print("downloading model asset…")
            let progress = request.progress
            let ticker = Task {
                while !Task.isCancelled {
                    print("  \(Int(progress.fractionCompleted * 100))%")
                    try await Task.sleep(for: .seconds(2))
                }
            }
            try await request.downloadAndInstall()
            ticker.cancel()
            print("download complete; status now: \(await AssetInventory.status(forModules: [transcriber]))")
        } else {
            print("no installation request returned (asset may already be resolving)")
        }
    case .unsupported:
        print("ERROR: en_US unsupported on this system")
    @unknown default:
        print("unknown status")
    }
}

@discardableResult
func transcribe(file path: String, contextualTerms: [String], useDictation: Bool) async throws -> String {
    let url = URL(fileURLWithPath: path)
    let audioFile = try AVAudioFile(forReading: url)

    let context = AnalysisContext()
    if !contextualTerms.isEmpty {
        context.contextualStrings = [.general: contextualTerms]
        print("contextualStrings(.general): \(contextualTerms)")
    }

    let start = ContinuousClock.now
    var transcript = ""

    if useDictation {
        let module = DictationTranscriber(locale: locale, preset: .shortDictation)
        let status = await AssetInventory.status(forModules: [module])
        print("module: DictationTranscriber(.shortDictation), assets: \(status)")
        if status != .installed, let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            print("downloading DictationTranscriber assets…")
            try await req.downloadAndInstall()
        }
        let analyzer = try await SpeechAnalyzer(
            inputAudioFile: audioFile, modules: [module],
            analysisContext: context, finishAfterFile: true
        )
        _ = analyzer
        for try await result in module.results {
            print("  result(isFinal: \(result.isFinal)): \"\(String(result.text.characters))\"")
            if result.isFinal { transcript += String(result.text.characters) }
        }
    } else {
        let module = makeTranscriber()
        print("module: SpeechTranscriber(.transcription)")
        let analyzer = try await SpeechAnalyzer(
            inputAudioFile: audioFile, modules: [module],
            analysisContext: context, finishAfterFile: true
        )
        _ = analyzer
        for try await result in module.results where result.isFinal {
            transcript += String(result.text.characters)
        }
    }

    let elapsed = ContinuousClock.now - start
    print("transcript: \"\(transcript.trimmingCharacters(in: .whitespacesAndNewlines))\"")
    print("elapsed: \(elapsed)")
    return transcript
}

// Simulates the MVP's live path without a mic: file → chunked buffers → AVAudioConverter →
// AsyncStream<AnalyzerInput> → analyzer.start(inputSequence:) → finalize. Measures release→final latency.
func transcribeStreaming(file path: String) async throws {
    let audioFile = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let transcriber = makeTranscriber()
    guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
        print("ERROR: no compatible audio format (run `download` first)")
        return
    }
    let sourceFormat = audioFile.processingFormat
    print("source: \(fmt(sourceFormat)) → analyzer: \(fmt(analyzerFormat))")
    guard let converter = AVAudioConverter(from: sourceFormat, to: analyzerFormat) else {
        print("ERROR: cannot build AVAudioConverter")
        return
    }

    let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    try await analyzer.prepareToAnalyze(in: analyzerFormat)
    try await analyzer.start(inputSequence: stream)

    let consumer = Task {
        var transcript = ""
        for try await result in transcriber.results where result.isFinal {
            transcript += String(result.text.characters)
        }
        return transcript
    }

    // Feed in mic-tap-sized chunks through the same conversion the MVP tap will do.
    let chunkFrames: AVAudioFrameCount = 4096
    while audioFile.framePosition < audioFile.length {
        let remaining = AVAudioFrameCount(audioFile.length - audioFile.framePosition)
        let toRead = min(chunkFrames, remaining)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: toRead) else { break }
        try audioFile.read(into: inBuf, frameCount: toRead)
        if inBuf.frameLength == 0 { break }
        let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 16
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: cap) else { break }
        var err: NSError?
        nonisolated(unsafe) var fed = false
        converter.convert(to: outBuf, error: &err) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        if err == nil, outBuf.frameLength > 0 {
            continuation.yield(AnalyzerInput(buffer: outBuf))
        }
    }
    continuation.finish()
    let stop = ContinuousClock.now // "hotkey release"
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    let transcript = try await consumer.value
    let latency = ContinuousClock.now - stop
    print("transcript: \"\(transcript.trimmingCharacters(in: .whitespacesAndNewlines))\"")
    print("release→final latency: \(latency)")
}

func transcribeLive(seconds: Int) async throws {
    // Mic permission: TCC prompt attributes to the invoking terminal for CLI tools.
    let granted = await AVCaptureDevice.requestAccess(for: .audio)
    guard granted else {
        print("ERROR: microphone permission denied")
        return
    }

    let transcriber = makeTranscriber()
    guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
        print("ERROR: no compatible audio format (is the model installed? run `download`)")
        return
    }

    let engine = AVAudioEngine()
    let input = engine.inputNode
    let hwFormat = input.inputFormat(forBus: 0)
    print("mic: \(fmt(hwFormat)) → analyzer: \(fmt(analyzerFormat))")

    guard let converter = AVAudioConverter(from: hwFormat, to: analyzerFormat) else {
        print("ERROR: cannot build AVAudioConverter")
        return
    }

    let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
    input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { buffer, _ in
        let ratio = analyzerFormat.sampleRate / hwFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
        var err: NSError?
        nonisolated(unsafe) var fed = false
        converter.convert(to: out, error: &err) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if err == nil, out.frameLength > 0 {
            continuation.yield(AnalyzerInput(buffer: out))
        }
    }

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    try await analyzer.prepareToAnalyze(in: analyzerFormat)

    try engine.start()
    print("recording for \(seconds)s — speak now…")
    try await analyzer.start(inputSequence: stream)

    let consumer = Task {
        var transcript = ""
        for try await result in transcriber.results where result.isFinal {
            transcript += String(result.text.characters)
            print("  final: \(String(result.text.characters))")
        }
        return transcript
    }

    try await Task.sleep(for: .seconds(seconds))
    engine.stop()
    input.removeTap(onBus: 0)
    continuation.finish()
    let stop = ContinuousClock.now
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    let transcript = try await consumer.value
    let latency = ContinuousClock.now - stop
    print("transcript: \"\(transcript.trimmingCharacters(in: .whitespacesAndNewlines))\"")
    print("release→final latency: \(latency)")
}

// MARK: - entry

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "info":
    await printInfo()
case "download":
    try await ensureAssets()
case "file":
    guard args.count >= 2 else { print("usage: internos-spike file [--dictation] <path> [terms...]"); exit(2) }
    var rest = Array(args.dropFirst())
    let useDictation = rest.first == "--dictation"
    if useDictation { rest.removeFirst() }
    guard let path = rest.first else { print("usage: internos-spike file [--dictation] <path> [terms...]"); exit(2) }
    try await transcribe(file: path, contextualTerms: Array(rest.dropFirst()), useDictation: useDictation)
case "stream":
    guard args.count >= 2 else { print("usage: internos-spike stream <path>"); exit(2) }
    try await transcribeStreaming(file: args[1])
case "live":
    let secs = args.count >= 2 ? Int(args[1]) ?? 5 : 5
    try await transcribeLive(seconds: secs)
default:
    print("usage: internos-spike [info|download|file <path> [terms...]|live <seconds>]")
    exit(2)
}
