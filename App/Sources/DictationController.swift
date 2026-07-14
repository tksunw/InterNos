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
        /// Command mode (v2): recording a spoken instruction for the captured selection.
        case commandRecording
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
    private let pipeline: any TranscriptProcessing
    /// Shared with the Settings window; nil in tests that inject processingSettings.
    private let customizations: CustomizationStore?
    private let processingSettings: @MainActor () -> ProcessingSettings
    private let playSound: @MainActor (String) -> Void
    private let frontmostPID: @MainActor () -> pid_t?
    private let onboardingPresenter: (@MainActor (_ needsRestart: Bool, _ onFinished: @escaping () -> Void) -> Void)?
    // Command mode (v2): selection capture, on-device transform, availability check.
    private let transformer: any TextTransforming
    private let selectionProvider: @MainActor () -> (text: String, pid: pid_t)?
    private let commandModeAvailable: @MainActor () -> Bool
    /// Selection captured when the command key went down; consumed on completion.
    private var commandContext: (selection: String, target: pid_t)?
    private lazy var settingsWindow = SettingsWindowController()
    private lazy var onboarding = OnboardingWindowController()

    /// Last completed transcript, memory only (feature 2). Never persisted.
    let volatileStore = VolatileTranscriptStore()
    /// Last successful insertion, for the "scratch that" voice undo (v2).
    /// One-shot: consumed by a scratch, replaced by the next insertion.
    private(set) var lastInsertion: (characterCount: Int, target: pid_t?)?
    /// ponytail: backspace-count cap for scratch-that; per-character key events get
    /// slow past this. Raise if long-dictation scratching turns out to matter.
    static let maxScratchCharacters = 2000
    /// Most recent frontmost app that isn't Internos: the target for Paste Last
    /// Dictation, so opening the status menu can't redirect the paste to us.
    var lastExternalFrontmostPID: pid_t?
    private var workspaceObserver: NSObjectProtocol?

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
    // The tap survives locale re-initialization; it must be created only once.
    private var hotkeyStarted = false
    /// Locale the ready pipeline was initialized with (v2 multi-language).
    private var activeLocaleIdentifier: String?

    init(
        hotkey: any HotkeyMonitoring = HotkeyMonitor(),
        recorder: any RecordingSource = AudioRecorder(),
        engine: any TranscriptionProviding = TranscriptionEngine(),
        inserter: any TextInserting = TextInserter(),
        statusItem: any StatusPresenting = StatusItemController(),
        indicator: any IndicatorPresenting = RecordingIndicator(),
        pipeline: any TranscriptProcessing = TranscriptPipeline(
            cleaner: SmartCleanupCoordinator(cleaner: FoundationModelCleaner())),
        customizations: CustomizationStore? = nil,
        processingSettings: (@MainActor () -> ProcessingSettings)? = nil,
        playSound: (@MainActor (String) -> Void)? = nil,
        frontmostPID: (@MainActor () -> pid_t?)? = nil,
        onboardingPresenter: (@MainActor (Bool, @escaping () -> Void) -> Void)? = nil,
        transformer: any TextTransforming = CommandTransformCoordinator(transformer: FoundationModelTransformer()),
        selectionProvider: (@MainActor () -> (text: String, pid: pid_t)?)? = nil,
        commandModeAvailable: (@MainActor () -> Bool)? = nil
    ) {
        self.hotkey = hotkey
        self.recorder = recorder
        self.engine = engine
        self.inserter = inserter
        self.statusItem = statusItem
        self.indicator = indicator
        self.pipeline = pipeline
        // Tests inject processingSettings; the app snapshots the live store + mode.
        let store = customizations
        self.customizations = store
        self.processingSettings = processingSettings ?? {
            guard let store else { return ProcessingSettings() }
            return store.processingSnapshot(cleanupMode: AppSettings.shared.cleanupMode)
        }
        self.playSound = playSound ?? { name in
            guard AppSettings.shared.playSounds else { return }
            NSSound(named: name)?.play()
        }
        self.frontmostPID = frontmostPID ?? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        self.onboardingPresenter = onboardingPresenter
        self.transformer = transformer
        self.selectionProvider = selectionProvider ?? { TextInserter.accessibilitySelectedText() }
        self.commandModeAvailable = commandModeAvailable ?? { CleanupAvailability.isAvailable }
    }

    func start() async {
        statusItem.onTogglePause = { [weak self] in self?.togglePause() }
        statusItem.onOpenSettings = { [weak self] in self?.openSettings() }
        statusItem.onOpenSetup = { [weak self] in self?.showOnboarding() }
        statusItem.onCopyLast = { [weak self] in self?.copyLastDictation(raw: false) }
        statusItem.onCopyLastRaw = { [weak self] in self?.copyLastDictation(raw: true) }
        statusItem.onPasteLast = { [weak self] in self?.pasteLastDictation() }
        statusItem.onClearLast = { [weak self] in self?.volatileStore.clear() }
        statusItem.recoveryState = { [weak self] in
            guard let value = self?.volatileStore.current else { return RecoveryMenuState() }
            return RecoveryMenuState(
                hasTranscript: true,
                hasDistinctRaw: value.cleanupApplied && value.raw != value.final)
        }
        trackExternalFrontmostApplication()
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
        hotkey.onSecondaryDown = { [weak self] in self?.commandKeyDown() }
        hotkey.onSecondaryUp = { [weak self] in self?.commandKeyUp() }
        if !hotkeyStarted && !hotkey.start() {
            // Input Monitoring granted after launch doesn't reach an existing process;
            // the onboarding window offers a restart in this state.
            NSLog("Internos: event tap creation failed — restart needed after Input Monitoring grant")
            tapFailed = true
            enterSetupFailed()
            showOnboarding()
        } else {
            hotkeyStarted = true
            NSLog("Internos: ready")
            pipelineReady = true
            activeLocaleIdentifier = AppSettings.shared.recognitionLocale
            state = .idle
            statusItem.setState(.idle)
            statusItem.refreshHotkeyHint()
        }
    }

    /// A recognition-language change needs a new analyzer format and possibly a new
    /// model asset. Re-initialize; if the model for the new language isn't installed,
    /// the setup window's download step takes over.
    func handleLocaleChangeIfNeeded() {
        let selected = AppSettings.shared.recognitionLocale
        guard let active = activeLocaleIdentifier, selected != active, state != .recording, state != .finalizing else { return }
        NSLog("Internos: recognition language changed — reinitializing pipeline")
        pipelineReady = false
        state = .settingUp
        statusItem.setState(.disabled)
        Task {
            if await engine.modelStatus() == .installed {
                await initializePipeline()
            } else {
                showOnboarding()
            }
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
            commandContext = nil
            indicator.hide()
        }
    }

    private func openSettings() {
        guard let customizations else { return }
        settingsWindow.show(customizations: customizations) { [weak self] in
            self?.hotkey.reloadSettings()
            self?.statusItem.refreshHotkeyHint()
            self?.handleLocaleChangeIfNeeded()
        }
    }

    // MARK: - last-transcript recovery (feature 2)

    /// Tracks the most recent frontmost application that isn't Internos, via
    /// workspace activation notifications. Status-menu clicks must not make
    /// Internos the paste target.
    private func trackExternalFrontmostApplication() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalFrontmostPID = frontmost.processIdentifier
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in self?.lastExternalFrontmostPID = pid }
        }
    }

    /// Intentional clipboard operation: replaces the pasteboard, restores nothing.
    private func copyLastDictation(raw: Bool) {
        guard let value = volatileStore.current else { return }
        inserter.preserveOnClipboard(raw ? value.raw : value.final)
        NSLog("Internos: last dictation copied (\(raw ? "raw" : "final"))")
    }

    /// User-initiated re-insertion of the stored final value: same serialized
    /// inserter, same Secure Input/Accessibility/target checks, no reprocessing,
    /// and the stored value is kept regardless of outcome.
    func pasteLastDictation() {
        guard let value = volatileStore.current else { return }
        let target = lastExternalFrontmostPID
        let epoch = pauseEpoch
        let previous = insertionChain
        insertionChain = Task { [weak self] in
            await previous?.value
            guard let self, self.pauseEpoch == epoch else { return }
            do {
                try self.inserter.insert(value.final, target: target)
                NSLog("Internos: last dictation pasted")
                self.lastInsertion = (value.final.count, target)
                self.playSound("Purr")
            } catch {
                self.handleInsertionFailure(error, transcript: value.final)
                self.statusItem.setState(.error)
                self.playSound("Basso")
            }
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
            let gen = utteranceGeneration
            // Transcription consumes buffers live during the hold; finalize unblocks on
            // release. Partial results drive the live preview (display only).
            let onPartial: @Sendable (String) -> Void = { [weak self] text in
                Task { @MainActor in self?.handlePartial(text, generation: gen) }
            }
            utteranceTask = Task { [engine] in
                try await engine.transcribe(input: stream, format: format, onPartial: onPartial)
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

    /// Live preview: only the current utterance may paint the indicator, and only
    /// while it's actually on screen (recording/finalizing).
    private func handlePartial(_ text: String, generation: Int) {
        guard generation == utteranceGeneration, state == .recording || state == .finalizing else { return }
        indicator.showPartial(text)
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
        // Snapshot processing configuration now so a settings edit can't change
        // this transcript halfway through the pipeline.
        let settings = processingSettings()
        let previous = insertionChain
        insertionChain = Task { [weak self, pipeline] in
            // FIFO: utterance N inserts only after N-1 fully completed, even if N's
            // transcription finished first (IR-001).
            await previous?.value
            let result: Result<TranscriptResult, Error>
            do {
                let raw = try await task.value
                result = .success(await pipeline.process(raw, settings: settings))
            } catch {
                result = .failure(error)
            }
            self?.completeUtterance(gen: gen, epoch: epoch, target: target, result: result)
        }
    }

    private func completeUtterance(gen: Int, epoch: Int, target: pid_t?, result: Result<TranscriptResult, Error>) {
        guard epoch == pauseEpoch else {
            // Paused (or paused-and-resumed) after this utterance was captured: never
            // insert (IR-004). A transcript that completed anyway is preserved on the
            // clipboard — without injection and without touching the paused UI.
            if case .success(let transcript) = result, !transcript.final.isEmpty {
                volatileStore.record(raw: transcript.raw, final: transcript.final, cleanupApplied: transcript.cleanupApplied)
                inserter.preserveOnClipboard(transcript.final)
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
        case .success(let transcript) where transcript.final.isEmpty:
            NSLog("Internos: empty transcript")
            updateUI(.error, "Basso")
        case .success(let transcript) where Self.isScratchCommand(transcript.raw):
            // "scratch that" (v2): delete the previous insertion instead of inserting.
            performScratch(updateUI: updateUI)
        case .success(let transcript):
            // Log length only — never the content. Writing transcripts to the unified
            // log (persistent, readable) would contradict the app's whole premise.
            NSLog("Internos: transcript finalized (\(transcript.final.count) chars, cleanup: \(transcript.cleanupApplied))")
            // Recorded before the first insertion attempt (feature 2): every failure
            // path below still leaves the transcript recoverable from the menu.
            volatileStore.record(raw: transcript.raw, final: transcript.final, cleanupApplied: transcript.cleanupApplied)
            do {
                let method = try inserter.insert(transcript.final, target: target)
                NSLog("Internos: inserted (\(method == .accessibility ? "accessibility" : "clipboard"))")
                lastInsertion = (transcript.final.count, target)
                updateUI(.idle, "Purr")
            } catch {
                handleInsertionFailure(error, transcript: transcript.final)
                updateUI(.error, "Basso")
            }
        case .failure(let error):
            NSLog("Internos: utterance failed: \(error)")
            updateUI(.error, "Basso")
        }
    }

    // MARK: - command mode (v2)

    /// Command key pressed: capture the current selection (explicit invocation only),
    /// then record the spoken instruction while the key is held.
    func commandKeyDown() {
        guard state == .idle || state == .finalizing, let format = analyzerFormat else { return }
        guard commandModeAvailable() else {
            NSLog("Internos: command mode unavailable (Apple Intelligence)")
            statusItem.setState(.error)
            playSound("Basso")
            return
        }
        guard let selection = selectionProvider() else {
            NSLog("Internos: command mode — no selected text in the focused element")
            statusItem.setState(.error)
            playSound("Basso")
            return
        }
        do {
            let stream = try recorder.start(analyzerFormat: format, deviceUID: AppSettings.shared.inputDeviceUID)
            utteranceGeneration += 1
            commandContext = (selection.text, selection.pid)
            utteranceTask = Task { [engine] in
                try await engine.transcribe(input: stream, format: format, onPartial: nil)
            }
            state = .commandRecording
            statusItem.setState(.recording)
            indicator.show(.recording)
            playSound("Pop")
            NSLog("Internos: command mode recording (selection \(selection.text.count) chars)")
        } catch {
            NSLog("Internos: command mode audio start failed: \(error)")
            commandContext = nil
            statusItem.setState(.error)
            indicator.hide()
            playSound("Basso")
        }
    }

    func commandKeyUp() {
        guard state == .commandRecording, let task = utteranceTask, let context = commandContext else { return }
        utteranceTask = nil
        commandContext = nil
        recorder.stop()
        state = .finalizing
        statusItem.setState(.transcribing)
        indicator.show(.transcribing)

        let gen = utteranceGeneration
        let epoch = pauseEpoch
        let previous = insertionChain
        insertionChain = Task { [weak self, transformer] in
            await previous?.value
            var transformed: String?
            var instructionHeard = false
            if let instruction = try? await task.value,
               !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                instructionHeard = true
                transformed = await transformer.transform(context.selection, instruction: instruction)
            }
            self?.completeCommand(
                gen: gen, epoch: epoch, context: context,
                transformed: transformed, instructionHeard: instructionHeard)
        }
    }

    private func completeCommand(
        gen: Int, epoch: Int, context: (selection: String, target: pid_t),
        transformed: String?, instructionHeard: Bool
    ) {
        guard epoch == pauseEpoch else { return } // paused: change nothing (IR-004 semantics)
        let isCurrent = gen == utteranceGeneration
        let updateUI: (AppState, String?) -> Void = { [self] uiState, sound in
            guard isCurrent else { return }
            indicator.hide()
            statusItem.setState(uiState)
            state = .idle
            if let sound { playSound(sound) }
        }

        guard instructionHeard, let transformed else {
            // Unavailable model, timeout, refusal, empty instruction: the selection is
            // untouched — fail loud, change nothing.
            NSLog("Internos: command mode produced no transformation")
            updateUI(.error, "Basso")
            return
        }
        // Raw = the original selection, so Copy Last Raw Dictation can recover it.
        volatileStore.record(raw: context.selection, final: transformed, cleanupApplied: true)
        do {
            // Replacing the selection is the same primitive as insertion: the AX path
            // sets selected text; the paste fallback replaces the selection natively.
            let method = try inserter.insert(transformed, target: context.target)
            NSLog("Internos: command replacement inserted (\(method == .accessibility ? "accessibility" : "clipboard"))")
            lastInsertion = (transformed.count, context.target)
            updateUI(.idle, "Purr")
        } catch {
            handleInsertionFailure(error, transcript: transformed)
            updateUI(.error, "Basso")
        }
    }

    /// Whole-utterance "scratch that" (with optional trailing punctuation) triggers the
    /// voice undo. Checked against the RAW transcript so replacements can't hijack it.
    static func isScratchCommand(_ raw: String) -> Bool {
        let folded = raw.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
        return folded == "scratch that"
    }

    private func performScratch(updateUI: (AppState, String?) -> Void) {
        guard let last = lastInsertion, last.characterCount <= Self.maxScratchCharacters else {
            NSLog("Internos: scratch that ignored (nothing to scratch or too long)")
            updateUI(.error, "Basso")
            return
        }
        do {
            try inserter.deleteBackward(last.characterCount, target: last.target)
            NSLog("Internos: scratched last insertion (\(last.characterCount) chars)")
            lastInsertion = nil // one-shot: a second scratch must not eat older text
            updateUI(.idle, "Purr")
        } catch {
            // Wrong app frontmost, Secure Input, etc. — delete nothing, fail loud.
            NSLog("Internos: scratch failed: \(error)")
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
