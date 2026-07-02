// State machine wiring the pipeline: hotkey ↓ → record+stream → hotkey ↑ → finalize → insert.
// Fail-loud policy (PRD F4a/§9): any failure plays an error sound and inserts nothing;
// on Secure Input the transcript is left on the clipboard so it isn't lost.

import AppKit
import AVFoundation

@MainActor
final class DictationController {
    private let hotkey = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let engine = TranscriptionEngine()
    private let inserter = TextInserter()

    private var analyzerFormat: AVAudioFormat?
    private var utteranceTask: Task<String, Error>?

    func start() async {
        // Permission + model preflight. MVP: log to console; real onboarding is milestone 4.
        let micOK = await AudioRecorder.requestMicPermission()
        if !micOK { NSLog("Internos: microphone permission denied") }

        _ = TextInserter.checkAccessibility(promptIfNeeded: true)

        do {
            try await engine.ensureModel()
            analyzerFormat = try await engine.analyzerFormat()
        } catch {
            NSLog("Internos: model setup failed: \(error)")
        }

        hotkey.onKeyDown = { [weak self] in self?.beginUtterance() }
        hotkey.onKeyUp = { [weak self] in self?.endUtterance() }
        if !hotkey.start() {
            NSLog("Internos: event tap creation failed — grant Input Monitoring and relaunch")
            playSound("Basso")
        } else {
            NSLog("Internos: ready — hold Right Option to dictate")
            playSound("Glass")
        }
    }

    private func beginUtterance() {
        guard utteranceTask == nil, let format = analyzerFormat else {
            NSLog("Internos: keyDown ignored (task active or no analyzer format)")
            return
        }
        NSLog("Internos: recording started")
        do {
            let stream = try recorder.start(analyzerFormat: format)
            // Transcription consumes buffers live during the hold; finalize unblocks on release.
            utteranceTask = Task { [engine] in
                try await engine.transcribe(input: stream, format: format)
            }
            playSound("Pop")
        } catch {
            NSLog("Internos: audio start failed: \(error)")
            playSound("Basso")
        }
    }

    private func endUtterance() {
        guard let task = utteranceTask else { return }
        utteranceTask = nil
        recorder.stop() // finishes the stream → analyzer sees end of input
        NSLog("Internos: recording stopped, finalizing")
        Task {
            do {
                let transcript = try await task.value
                NSLog("Internos: transcript (\(transcript.count) chars): \"\(transcript)\"")
                guard !transcript.isEmpty else {
                    playSound("Basso")
                    return
                }
                try inserter.insert(transcript)
                NSLog("Internos: inserted")
                playSound("Purr")
            } catch InternosError.secureInputActive {
                // Preserve the transcript rather than lose it: leave it on the clipboard.
                if let transcript = try? await task.value, !transcript.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transcript, forType: .string)
                }
                NSLog("Internos: Secure Input active — transcript left on clipboard, not inserted")
                playSound("Basso")
            } catch {
                NSLog("Internos: utterance failed: \(error)")
                playSound("Basso")
            }
        }
    }

    private func playSound(_ name: String) {
        NSSound(named: name)?.play()
    }
}
