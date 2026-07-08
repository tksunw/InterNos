// Mic capture: AVAudioEngine input tap → AVAudioConverter → AsyncStream<AnalyzerInput>.
// Conversion is mandatory: analyzer wants 16 kHz mono Int16, hardware gives 48 kHz Float32
// (spike finding b). A format mismatch produces silent empty results, not an error.

import AVFoundation
import Speech

final class AudioRecorder {
    // Fresh engine per utterance: a reused AVAudioEngine can report a stale/invalid input
    // format after stop()/removeTap() cycles, which silently yields empty transcripts.
    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    /// Live input level in 0...1 (perceptual), delivered on the main thread for the voice-print UI.
    var onLevel: (@Sendable (CGFloat) -> Void)?

    var isRunning: Bool { engine?.isRunning ?? false }

    static func requestMicPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Starts the tap and returns the stream of converted buffers for the analyzer.
    /// `deviceUID` selects a specific input device; nil uses the system default.
    func start(analyzerFormat: AVAudioFormat, deviceUID: String? = nil) throws -> AsyncStream<AnalyzerInput> {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode

        if let deviceUID, var deviceID = AudioDevices.deviceID(forUID: deviceUID) {
            // Route the engine's input to the chosen device (default is the system input).
            let status = AudioUnitSetProperty(
                input.audioUnit!,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                NSLog("Internos: input device selection failed (\(status)), using default")
            }
        }
        let hwFormat = input.inputFormat(forBus: 0)
        NSLog("Internos: mic format \(hwFormat.sampleRate) Hz \(hwFormat.channelCount) ch")
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw InternosError.audioConverterUnavailable
        }
        guard let converter = AVAudioConverter(from: hwFormat, to: analyzerFormat) else {
            throw InternosError.audioConverterUnavailable
        }

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.continuation = continuation

        // 1024-frame buffers (~21 ms at 48 kHz) give a smooth ~47 Hz level feed for the visualizer;
        // the analyzer is fed the converted buffers regardless of size.
        let levelCallback = onLevel
        // Capture the continuation directly: re-reading self.continuation here would race
        // with stop() nilling it from the main thread. Yield-after-finish is a safe no-op.
        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { buffer, _ in

            if let levelCallback, let ch = buffer.floatChannelData?[0] {
                let frames = Int(buffer.frameLength)
                var sumSquares: Float = 0
                for i in 0..<frames { sumSquares += ch[i] * ch[i] }
                let rms = frames > 0 ? sqrt(sumSquares / Float(frames)) : 0
                let db = 20 * log10(max(rms, 1e-7))
                // Map a useful speech window (-55 dB quiet … -12 dB loud) into 0...1.
                let level = CGFloat(min(1, max(0, (db + 55) / 43)))
                DispatchQueue.main.async { levelCallback(level) }
            }
            let ratio = analyzerFormat.sampleRate / hwFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
            var err: NSError?
            nonisolated(unsafe) var fed = false
            // convert() calls the input block synchronously on this thread; the buffer
            // never actually crosses an isolation boundary.
            nonisolated(unsafe) let source = buffer
            converter.convert(to: out, error: &err) { _, outStatus in
                if fed { outStatus.pointee = .noDataNow; return nil }
                fed = true
                outStatus.pointee = .haveData
                return source
            }
            if err == nil, out.frameLength > 0 {
                continuation.yield(AnalyzerInput(buffer: out))
            }
        }

        do {
            try engine.start()
        } catch {
            stop() // tear down the tap and finish the stream, or the next start() orphans them
            throw error
        }
        return stream
    }

    /// Stops the tap and finishes the stream (signals end of utterance to the analyzer).
    func stop() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        continuation?.finish()
        continuation = nil
    }
}

enum InternosError: Error {
    case audioConverterUnavailable
    case analyzerFormatUnavailable
    case modelNotInstalled
    case secureInputActive
    case accessibilityNotGranted
}
