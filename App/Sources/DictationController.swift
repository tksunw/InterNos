// State machine wiring the pipeline: hotkey ↓ → record+stream → hotkey ↑ → finalize → insert.
// Fail-loud policy (PRD F4a/§9): any failure surfaces in the status icon + error sound and
// inserts nothing; on Secure Input the transcript is left on the clipboard so it isn't lost.

import AppKit
import AVFoundation

@MainActor
final class DictationController {
    private let hotkey = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let engine = TranscriptionEngine()
    private let inserter = TextInserter()
    private let statusItem = StatusItemController()
    private let settingsWindow = SettingsWindowController()

    private var analyzerFormat: AVAudioFormat?
    private var utteranceTask: Task<String, Error>?
    private var isPaused = false

    func start() async {
        statusItem.onTogglePause = { [weak self] in self?.togglePause() }
        statusItem.onOpenSettings = { [weak self] in self?.openSettings() }

        // Permission + model preflight. MVP: log to console; real onboarding is milestone 4.
        let micOK = await AudioRecorder.requestMicPermission()
        if !micOK { NSLog("Internos: microphone permission denied") }

        _ = TextInserter.checkAccessibility(promptIfNeeded: true)

        do {
            try await engine.ensureModel()
            analyzerFormat = try await engine.analyzerFormat()
        } catch {
            NSLog("Internos: model setup failed: \(error)")
            statusItem.setState(.error)
        }

        hotkey.onKeyDown = { [weak self] in self?.hotkeyDown() }
        hotkey.onKeyUp = { [weak self] in self?.hotkeyUp() }
        if !hotkey.start() {
            NSLog("Internos: event tap creation failed — grant Input Monitoring and relaunch")
            statusItem.setState(.error)
            playSound("Basso")
        } else {
            NSLog("Internos: ready")
            statusItem.refreshHotkeyHint()
        }
    }

    // MARK: - hotkey handling (push-to-talk vs toggle)

    private func hotkeyDown() {
        guard !isPaused else { return }
        switch AppSettings.shared.mode {
        case .pushToTalk:
            beginUtterance()
        case .toggle:
            if utteranceTask == nil { beginUtterance() } else { endUtterance() }
        }
    }

    private func hotkeyUp() {
        guard !isPaused, AppSettings.shared.mode == .pushToTalk else { return }
        endUtterance()
    }

    private func togglePause() {
        isPaused.toggle()
        statusItem.isPaused = isPaused
        if isPaused, utteranceTask != nil {
            // Abandon any in-flight utterance without inserting.
            recorder.stop()
            utteranceTask?.cancel()
            utteranceTask = nil
        }
    }

    private func openSettings() {
        settingsWindow.show { [weak self] in
            self?.hotkey.reloadSettings()
            self?.statusItem.refreshHotkeyHint()
        }
    }

    // MARK: - utterance lifecycle

    private func beginUtterance() {
        guard utteranceTask == nil, let format = analyzerFormat else {
            NSLog("Internos: keyDown ignored (task active or no analyzer format)")
            return
        }
        NSLog("Internos: recording started")
        do {
            let stream = try recorder.start(analyzerFormat: format, deviceUID: AppSettings.shared.inputDeviceUID)
            // Transcription consumes buffers live during the hold; finalize unblocks on release.
            utteranceTask = Task { [engine] in
                try await engine.transcribe(input: stream, format: format)
            }
            statusItem.setState(.recording)
            playSound("Pop")
        } catch {
            NSLog("Internos: audio start failed: \(error)")
            statusItem.setState(.error)
            playSound("Basso")
        }
    }

    private func endUtterance() {
        guard let task = utteranceTask else { return }
        utteranceTask = nil
        recorder.stop() // finishes the stream → analyzer sees end of input
        NSLog("Internos: recording stopped, finalizing")
        statusItem.setState(.transcribing)
        Task {
            do {
                let transcript = try await task.value
                NSLog("Internos: transcript (\(transcript.count) chars): \"\(transcript)\"")
                guard !transcript.isEmpty else {
                    statusItem.setState(.error)
                    playSound("Basso")
                    return
                }
                try inserter.insert(transcript)
                NSLog("Internos: inserted")
                statusItem.setState(.idle)
                playSound("Purr")
            } catch InternosError.secureInputActive {
                // Preserve the transcript rather than lose it: leave it on the clipboard.
                if let transcript = try? await task.value, !transcript.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transcript, forType: .string)
                }
                NSLog("Internos: Secure Input active — transcript left on clipboard, not inserted")
                statusItem.setState(.error)
                playSound("Basso")
            } catch {
                NSLog("Internos: utterance failed: \(error)")
                statusItem.setState(.error)
                playSound("Basso")
            }
        }
    }

    private func playSound(_ name: String) {
        guard AppSettings.shared.playSounds else { return }
        NSSound(named: name)?.play()
    }
}
