// First-run onboarding (PRD F6/F7, milestone 4): three permission steps + model download.
// TCC has no change notifications, so statuses poll on a timer while the window is open.
// Input Monitoring granted mid-session may still need an app relaunch for the event tap;
// the final step offers Restart when the tap failed earlier.

import Speech
import SwiftUI

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var mic = PermissionsService.microphone
    @Published var inputMonitoring = PermissionsService.inputMonitoring
    @Published var accessibility = PermissionsService.accessibility
    @Published var modelInstalled = false
    @Published var downloading = false
    @Published var downloadProgress: Double = 0

    var allDone: Bool {
        mic == .granted && inputMonitoring == .granted && accessibility == .granted && modelInstalled
    }

    private var timer: Timer?
    private let engine = TranscriptionEngine()

    func startPolling() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        mic = PermissionsService.microphone
        inputMonitoring = PermissionsService.inputMonitoring
        accessibility = PermissionsService.accessibility
        Task {
            let status = await AssetInventory.status(forModules: [engine.makeTranscriber()])
            modelInstalled = status == .installed
        }
    }

    func downloadModel() {
        guard !downloading else { return }
        downloading = true
        Task {
            do {
                let transcriber = engine.makeTranscriber()
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    let progress = request.progress
                    let ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                        Task { @MainActor [weak self] in self?.downloadProgress = progress.fractionCompleted }
                    }
                    try await request.downloadAndInstall()
                    ticker.invalidate()
                }
                downloadProgress = 1
                modelInstalled = true
            } catch {
                NSLog("Internos: model download failed: \(error)")
            }
            downloading = false
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
            Text("Dictation that stays between us. Everything runs on this Mac — no audio or text ever leaves it. Internos needs three permissions and one model download to work.")
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
                    if model.downloading {
                        ProgressView(value: model.downloadProgress)
                            .frame(width: 220)
                    } else {
                        Text(model.modelInstalled
                             ? "Installed — shared across apps, stored by macOS."
                             : "One-time download, managed by macOS.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !model.modelInstalled && !model.downloading {
                    Button("Download") { model.downloadModel() }
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
