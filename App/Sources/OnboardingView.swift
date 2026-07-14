// First-run onboarding (PRD F6/F7, milestone 4): three permission steps + model download.
// TCC has no change notifications, so statuses poll on a timer while the window is open.
// Input Monitoring granted mid-session may still need an app relaunch for the event tap;
// the final step offers Restart when the tap failed earlier.
//
// Model install is trusted only when AssetInventory reports .installed after the fact
// (IR-006): a nil installation request or a returned downloadAndInstall() is not proof.

import Speech
import SwiftUI

/// Seam over AssetInventory so onboarding logic is unit-testable without Apple
/// framework state (IR-006).
protocol ModelAssetInstalling: Sendable {
    func status() async -> AssetInventory.Status
    func installationRequest() async throws -> (any ModelInstallationRequest)?
}

protocol ModelInstallationRequest: Sendable {
    var progress: Progress { get }
    func downloadAndInstall() async throws
}

struct SpeechModelAssetStore: ModelAssetInstalling {
    func status() async -> AssetInventory.Status {
        await AssetInventory.status(forModules: [TranscriptionEngine().makeTranscriber()])
    }

    func installationRequest() async throws -> (any ModelInstallationRequest)? {
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [TranscriptionEngine().makeTranscriber()]) else { return nil }
        return RequestBox(progress: request.progress) { try await request.downloadAndInstall() }
    }

    private struct RequestBox: ModelInstallationRequest, @unchecked Sendable {
        let progress: Progress
        let install: () async throws -> Void
        func downloadAndInstall() async throws { try await install() }
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    enum ModelSetupState: Equatable {
        case unknown
        case notInstalled
        case downloading
        case installed
        case failed(String)
        case unsupported
    }

    @Published var mic = PermissionsService.microphone
    @Published var inputMonitoring = PermissionsService.inputMonitoring
    @Published var accessibility = PermissionsService.accessibility
    @Published var modelState: ModelSetupState = .unknown
    @Published var downloadProgress: Double = 0

    var modelInstalled: Bool { modelState == .installed }
    var downloading: Bool { modelState == .downloading }

    var allDone: Bool {
        mic == .granted && inputMonitoring == .granted && accessibility == .granted && modelInstalled
    }

    private var timer: Timer?
    // Internal so tests can prove the progress observer stops on every exit (IR-008).
    var progressTicker: Timer?
    private let store: any ModelAssetInstalling

    init(store: any ModelAssetInstalling = SpeechModelAssetStore()) {
        self.store = store
    }

    func startPolling() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
        // The download itself may continue in the background, but nothing should keep
        // observing its progress once the window is gone (IR-008).
        progressTicker?.invalidate()
        progressTicker = nil
    }

    func refresh() {
        mic = PermissionsService.microphone
        inputMonitoring = PermissionsService.inputMonitoring
        accessibility = PermissionsService.accessibility
        Task { [store] in
            let status = await store.status()
            apply(status: status)
        }
    }

    private func apply(status: AssetInventory.Status) {
        // Never stomp an active download, and keep a failure visible until retried.
        guard modelState != .downloading else { return }
        switch status {
        case .installed:
            modelState = .installed
        case .unsupported:
            modelState = .unsupported
        default:
            if case .failed = modelState { return }
            modelState = .notInstalled
        }
    }

    func downloadModel() {
        // One attempt at a time (IR-006): repeated clicks must not stack requests.
        guard modelState != .downloading, modelState != .installed else { return }
        modelState = .downloading
        downloadProgress = 0
        Task {
            // Every exit path stops the progress observer (IR-008).
            defer {
                progressTicker?.invalidate()
                progressTicker = nil
            }
            do {
                if let request = try await store.installationRequest() {
                    let progress = request.progress
                    progressTicker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                        Task { @MainActor [weak self] in self?.downloadProgress = progress.fractionCompleted }
                    }
                    try await request.downloadAndInstall()
                }
                // Verify: only an .installed status counts as success (IR-006).
                switch await store.status() {
                case .installed:
                    downloadProgress = 1
                    modelState = .installed
                case .unsupported:
                    modelState = .unsupported
                default:
                    modelState = .failed("The model isn't installed yet. Try again in a moment.")
                }
            } catch {
                NSLog("Internos: model download failed: \(error)")
                modelState = .failed("Download failed: \(error.localizedDescription)")
            }
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    var needsRestart: Bool
    var onFinished: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to Internos")
                .font(.title2.bold())
            Text("Dictation that stays between us. Your voice is processed entirely on this Mac — no cloud, no accounts. Internos needs three permissions and one model download to work.")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)

            permissionRow(
                title: "Microphone",
                detail: "Captures your voice while the hotkey is held.",
                state: model.mic
            ) {
                if model.mic == .notAsked {
                    Task { _ = await PermissionsService.requestMicrophone(); model.refresh() }
                } else {
                    PermissionsService.openMicrophoneSettings()
                }
            }

            permissionRow(
                title: "Input Monitoring",
                detail: "Detects the dictation hotkey anywhere in macOS.",
                state: model.inputMonitoring
            ) {
                PermissionsService.requestInputMonitoring()
                PermissionsService.openInputMonitoringSettings()
            }

            permissionRow(
                title: "Accessibility",
                detail: "Inserts the transcribed text at your cursor.",
                state: model.accessibility
            ) {
                PermissionsService.requestAccessibility()
                PermissionsService.openAccessibilitySettings()
            }

            Divider()

            HStack {
                statusIcon(done: model.modelInstalled)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Speech model (English, US)").font(.body.weight(.medium))
                    switch model.modelState {
                    case .downloading:
                        ProgressView(value: model.downloadProgress)
                            .frame(width: 220)
                    case .failed(let message):
                        Text(message).font(.caption).foregroundStyle(.red)
                    case .unsupported:
                        Text("This Mac can't use the on-device speech model.")
                            .font(.caption).foregroundStyle(.red)
                    case .installed:
                        Text("Installed — shared across apps, stored by macOS.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .unknown, .notInstalled:
                        Text("One-time download, managed by macOS.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !model.modelInstalled && !model.downloading && model.modelState != .unsupported {
                    Button(buttonLabel) { model.downloadModel() }
                }
            }

            Divider()

            HStack {
                Spacer()
                if model.allDone {
                    Button(needsRestart ? "Restart Internos" : "Start Dictating") { onFinished() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Text("Grant the items above to continue")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { model.startPolling() }
        .onDisappear { model.stopPolling() }
    }

    private var buttonLabel: String {
        if case .failed = model.modelState { return "Try Again" }
        return "Download"
    }

    @ViewBuilder
    private func permissionRow(title: String, detail: String, state: PermissionState, action: @escaping () -> Void) -> some View {
        HStack {
            statusIcon(done: state == .granted)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if state != .granted {
                Button(state == .denied ? "Open Settings" : "Grant…", action: action)
            }
        }
    }

    private func statusIcon(done: Bool) -> some View {
        Image(systemName: done ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(done ? .green : .secondary)
            .font(.title3)
    }
}

@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private let model = OnboardingModel()

    func show(needsRestart: Bool, onFinished: @escaping () -> Void) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let view = OnboardingView(model: model, needsRestart: needsRestart) { [weak self] in
            self?.close()
            onFinished()
        }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Internos Setup"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() {
        window?.close()
        window = nil
    }
}
