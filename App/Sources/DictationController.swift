// State machine wiring the pipeline: hotkey ↓ → record+stream → hotkey ↑ → finalize → insert.
// Fail-loud policy (PRD F4a/§9): any failure surfaces in the status icon + error sound and
// inserts nothing; on insertion failures the transcript is left on the clipboard so it isn't lost.
//
// Lifecycle invariants (build-and-repair IR-001…IR-004):
// - Insertions are serialized in recording order via `insertionChain`, even when
//   transcriptions finish out of order.
// - A superseded utterance (a newer recording started) may still insert, but must not
//   touch the icon, indicator, or sounds owned by the newer one (`utteranceGeneration`).
// - Pause bumps `pauseEpoch`: work from an earlier epoch can never reach the inserter.
//   A transcript that completed before cancellation is preserved on the clipboard
//   without being injected.
// - The paste target is the app frontmost when recording stopped; TextInserter refuses
//   to paste if a different app is frontmost at insertion time.

import AppKit
import AVFoundation

@MainActor
final class DictationController {
    enum State: Equatable {
        case settingUp
        case idle
        case recording
        case finalizing
        case paused
        case setupFailed
    }

    private let hotkey: any HotkeyMonitoring
    private let recorder: any RecordingSource
    private let engine: any TranscriptionProviding
    private let inserter: any TextInserting
    private let statusItem: any StatusPresenting
    private let indicator: any IndicatorPresenting
    private let playSound: @MainActor (String) -> Void
    private let frontmostPID: @MainActor () -> pid_t?
    private let onboardingPresenter: (@MainActor (_ needsRestart: Bool, _ onFinished: @escaping () -> Void) -> Void)?
    private lazy var settingsWindow = SettingsWindowController()
    private lazy var onboarding = OnboardingWindowController()

    private(set) var state: State = .settingUp
    private var analyzerFormat: AVAudioFormat?
    private var utteranceTask: Task<String, Error>?
    // Bumped on every recording start; a previous utterance's completion must not
    // clobber the icon/indicator/sounds of a newer one (rapid re-press).
    private var utteranceGeneration = 0
    // Bumped on pause; completions from an earlier epoch are suppressed entirely.
    private var pauseEpoch = 0
    // FIFO insertion order: each finalization awaits the previous one before inserting.
    private var insertionChain: Task<Void, Never>?
    private var pipelineReady = false
    private var tapFailed = false

    init(
        hotkey: any HotkeyMonitoring = HotkeyMonitor(),
        recorder: any RecordingSource = AudioRecorder(),
        engine: any TranscriptionProviding = TranscriptionEngine(),
        inserter: any TextInserting = TextInserter(),
        statusItem: any StatusPresenting = StatusItemController(),
        indicator: any IndicatorPresenting = RecordingIndicator(),
        playSound: (@MainActor (String) -> Void)? = nil,
        frontmostPID: (@MainActor () -> pid_t?)? = nil,
        onboardingPresenter: (@MainActor (Bool, @escaping () -> Void) -> Void)? = nil
    ) {
        self.hotkey = hotkey
        self.recorder = recorder
        self.engine = engine
        self.inserter = inserter
        self.statusItem = statusItem
        self.indicator = indicator
        self.playSound = playSound ?? { name in
            guard AppSettings.shared.playSounds else { return }
            NSSound(named: name)?.play()
        }
        self.frontmostPID = frontmostPID ?? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        self.onboardingPresenter = onboardingPresenter
    }

    func start() async {
        statusItem.onTogglePause = { [weak self] in self?.togglePause() }
        statusItem.onOpenSettings = { [weak self] in self?.openSettings() }
        statusItem.onOpenSetup = { [weak self] in self?.showOnboarding() }
        // Delivered on the main thread by AudioRecorder; assumeIsolated satisfies Swift 6.
        recorder.onLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.indicator.pushLevel(level) }
        }

        if AppSettings.shared.checkUpdatesAtLaunch {
            UpdateChecker.check(quiet: true)
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

    func initializePipeline() async {
        guard !pipelineReady else { return }
        do {
            try await engine.ensureModel()
            analyzerFormat = try await engine.analyzerFormat()
        } catch {
            NSLog("Internos: model setup failed: \(error)")
            enterSetupFailed()
            return
        }

        hotkey.onKeyDown = { [weak self] in self?.hotkeyDown() }
        hotkey.onKeyUp = { [weak self] in self?.hotkeyUp() }
        if !hotkey.start() {
            // Input Monitoring granted after launch doesn't reach an existing process;
            // the onboarding window offers a restart in this state.
            NSLog("Internos: event tap creation failed — restart needed after Input Monitoring grant")
            tapFailed = true
            enterSetupFailed()
            showOnboarding()
        } else {
            NSLog("Internos: ready")
            pipelineReady = true
            state = .idle
            statusItem.setState(.idle)
            statusItem.refreshHotkeyHint()
        }
    }

    /// Persistent failure (IR-007): stays visible until a retry succeeds; never
    /// auto-reverts to an idle icon that would imply a working pipeline.
    private func enterSetupFailed() {
        pipelineReady = false
        state = .setupFailed
        statusItem.setState(.setupFailed)
    }

    private func showOnboarding() {
        let onFinished: () -> Void = { [weak self] in
            guard let self else { return }
            if self.tapFailed {
                Self.relaunch()
            } else {
                Task { await self.initializePipeline() }
            }
        }
        if let onboardingPresenter {
            onboardingPresenter(tapFailed, onFinished)
        } else {
            onboarding.show(needsRestart: tapFailed, onFinished: onFinished)
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

    func hotkeyDown() {
        guard state != .paused else { return }
        switch AppSettings.shared.mode {
        case .pushToTalk:
            beginUtterance()
        case .toggle:
            if state == .recording { endUtterance() } else { beginUtterance() }
        }
    }

    func hotkeyUp() {
        guard state != .paused, AppSettings.shared.mode == .pushToTalk else { return }
        endUtterance()
    }

    func togglePause() {
        if state == .paused {
            statusItem.isPaused = false
            if pipelineReady {
                // Resume implies readiness only when the pipeline actually is (IR-004).
                state = .idle
                statusItem.setState(.idle)
            } else {
                enterSetupFailed()
            }
        } else {
            statusItem.isPaused = true
            state = .paused
            statusItem.setState(.disabled)
            // Suppress every pending finalization and insertion (IR-004): completions
            // from before this point can no longer reach the inserter or the UI.
            pauseEpoch += 1
            if let task = utteranceTask {
                // Abandon an in-flight recording without inserting.
                recorder.stop()
                task.cancel()
                utteranceTask = nil
            }
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

    func beginUtterance() {
        guard state == .idle || state == .finalizing, let format = analyzerFormat else {
            NSLog("Internos: keyDown ignored (state not ready for recording)")
            return
        }
        NSLog("Internos: recording started")
        do {
            let stream = try recorder.start(analyzerFormat: format, deviceUID: AppSettings.shared.inputDeviceUID)
            utteranceGeneration += 1
            // Transcription consumes buffers live during the hold; finalize unblocks on release.
            utteranceTask = Task { [engine] in
                try await engine.transcribe(input: stream, format: format)
            }
            state = .recording
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

    func endUtterance() {
        guard state == .recording, let task = utteranceTask else { return }
        utteranceTask = nil
        recorder.stop() // finishes the stream → analyzer sees end of input
        NSLog("Internos: recording stopped, finalizing")
        state = .finalizing
        statusItem.setState(.transcribing)
        indicator.show(.transcribing)

        let gen = utteranceGeneration
        let epoch = pauseEpoch
        // The app under the cursor right now is the authoritative paste target (IR-003).
        let target = frontmostPID()
        let previous = insertionChain
        insertionChain = Task { [weak self] in
            // FIFO: utterance N inserts only after N-1 fully completed, even if N's
            // transcription finished first (IR-001).
            await previous?.value
            let result: Result<String, Error>
            do { result = .success(try await task.value) } catch { result = .failure(error) }
            self?.completeUtterance(gen: gen, epoch: epoch, target: target, result: result)
        }
    }

    private func completeUtterance(gen: Int, epoch: Int, target: pid_t?, result: Result<String, Error>) {
        guard epoch == pauseEpoch else {
            // Paused (or paused-and-resumed) after this utterance was captured: never
            // insert (IR-004). A transcript that completed anyway is preserved on the
            // clipboard — without injection and without touching the paused UI.
            if case .success(let transcript) = result, !transcript.isEmpty {
                inserter.preserveOnClipboard(transcript)
                NSLog("Internos: canceled by pause — transcript preserved on clipboard, not inserted")
            }
            return
        }
        // A newer recording owns the icon, indicator, and sounds; a superseded
        // completion still inserts (in order) but stays silent and invisible (IR-001).
        let isCurrent = gen == utteranceGeneration
        let updateUI: (AppState, String?) -> Void = { [self] uiState, sound in
            guard isCurrent else { return }
            indicator.hide()
            statusItem.setState(uiState)
            state = .idle
            if let sound { playSound(sound) }
        }

        switch result {
        case .success(let transcript) where transcript.isEmpty:
            NSLog("Internos: empty transcript")
            updateUI(.error, "Basso")
        case .success(let transcript):
            // Log length only — never the content. Writing transcripts to the unified
            // log (persistent, readable) would contradict the app's whole premise.
            NSLog("Internos: transcript finalized (\(transcript.count) chars)")
            do {
                try inserter.insert(transcript, target: target)
                NSLog("Internos: inserted")
                updateUI(.idle, "Purr")
            } catch {
                handleInsertionFailure(error, transcript: transcript)
                updateUI(.error, "Basso")
            }
        case .failure(let error):
            NSLog("Internos: utterance failed: \(error)")
            updateUI(.error, "Basso")
        }
    }

    /// Insertion failures preserve the transcript rather than lose it: it stays on the
    /// clipboard for the user to paste manually. Logs name the cause, never the content.
    private func handleInsertionFailure(_ error: Error, transcript: String) {
        switch error {
        case InternosError.secureInputActive:
            inserter.preserveOnClipboard(transcript)
            NSLog("Internos: Secure Input active — transcript left on clipboard, not inserted")
        case InternosError.insertionTargetChanged:
            inserter.preserveOnClipboard(transcript)
            NSLog("Internos: frontmost app changed during finalization — transcript left on clipboard, not inserted")
        case InternosError.accessibilityNotGranted:
            inserter.preserveOnClipboard(transcript)
            NSLog("Internos: Accessibility not granted — transcript left on clipboard, not inserted")
        case InternosError.pasteEventFailed:
            // The inserter already left the transcript on the pasteboard with no restore scheduled.
            NSLog("Internos: paste event creation failed — transcript left on clipboard")
        default:
            NSLog("Internos: insertion failed: \(error)")
        }
    }
}
