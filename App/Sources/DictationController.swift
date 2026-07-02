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
    private let onboarding = OnboardingWindowController()
    private let indicator = RecordingIndicator()

    private var analyzerFormat: AVAudioFormat?
    private var utteranceTask: Task<String, Error>?
    private var isPaused = false
    private var pipelineReady = false
    private var tapFailed = false

    func start() async {
        statusItem.onTogglePause = { [weak self] in self?.togglePause() }
        statusItem.onOpenSettings = { [weak self] in self?.openSettings() }
        statusItem.onOpenSetup = { [weak self] in self?.showOnboarding() }
        // Delivered on the main thread by AudioRecorder; assumeIsolated satisfies Swift 6.
        recorder.onLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.indicator.pushLevel(level) }
        }

        let modelInstalled = await engine.modelStatus() == .installed
        if PermissionsService.allGranted && modelInstalled {
            await initializePipeline()
        } else {
            // First run (or a permission was revoked): walk the user through setup.
            statusItem.setState(.disabled)
            showOnboarding()
        }
    }

    private func initializePipeline() async {
        guard !pipelineReady else { return }
        do {
            try await engine.ensureModel()
            analyzerFormat = try await engine.analyzerFormat()
        } catch {
            NSLog("Internos: model setup failed: \(error)")
            statusItem.setState(.error)
            return
        }

        hotkey.onKeyDown = { [weak self] in self?.hotkeyDown() }
        hotkey.onKeyUp = { [weak self] in self?.hotkeyUp() }
        if !hotkey.start() {
            // Input Monitoring granted after launch doesn't reach an existing process;
            // the onboarding window offers a restart in this state.
            NSLog("Internos: event tap creation failed — restart needed after Input Monitoring grant")
            tapFailed = true
            statusItem.setState(.error)
            showOnboarding()
        } else {
            NSLog("Internos: ready")
            pipelineReady = true
            statusItem.setState(.idle)
            statusItem.refreshHotkeyHint()
        }
    }

    private func showOnboarding() {
        onboarding.show(needsRestart: tapFailed) { [weak self] in
            guard let self else { return }
            if self.tapFailed {
                Self.relaunch()
            } else {
                Task { await self.initializePipeline() }
            }
        }
    }

    /// Relaunches the app (needed when Input Monitoring was granted after the tap failed).
    private static func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
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
            indicator.hide()
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
            indicator.show(.recording)
            playSound("Pop")
        } catch {
            NSLog("Internos: audio start failed: \(error)")
            statusItem.setState(.error)
            indicator.hide()
            playSound("Basso")
        }
    }

    private func endUtterance() {
        guard let task = utteranceTask else { return }
        utteranceTask = nil
        recorder.stop() // finishes the stream → analyzer sees end of input
        NSLog("Internos: recording stopped, finalizing")
        statusItem.setState(.transcribing)
        indicator.show(.transcribing)
        Task {
            do {
                let transcript = try await task.value
                // Log length only — never the content. Writing transcripts to the unified
                // log (persistent, readable) would contradict the app's whole premise.
                NSLog("Internos: transcript finalized (\(transcript.count) chars)")
                indicator.hide()
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
                indicator.hide()
                playSound("Basso")
            } catch {
                NSLog("Internos: utterance failed: \(error)")
                statusItem.setState(.error)
                indicator.hide()
                playSound("Basso")
            }
        }
    }

    private func playSound(_ name: String) {
        guard AppSettings.shared.playSounds else { return }
        NSSound(named: name)?.play()
    }
}
