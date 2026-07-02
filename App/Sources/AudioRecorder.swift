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

        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self, let continuation = self.continuation else { return }
            let ratio = analyzerFormat.sampleRate / hwFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
            var err: NSError?
            nonisolated(unsafe) var fed = false
            converter.convert(to: out, error: &err) { _, outStatus in
                if fed { outStatus.pointee = .noDataNow; return nil }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }
            if err == nil, out.frameLength > 0 {
                continuation.yield(AnalyzerInput(buffer: out))
            }
        }

        try engine.start()
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
