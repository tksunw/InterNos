// Floating recording indicator (PRD §5 step 3): a small pill near the bottom of the
// active screen showing record/transcribe state. Uses a non-activating panel that never
// becomes key — critical, because stealing focus would send the paste to the wrong app.

import AppKit
import SwiftUI

enum IndicatorState: Equatable {
    case hidden
    case recording
    case transcribing
}

struct RecordingIndicatorView: View {
    let state: IndicatorState
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 9) {
            switch state {
            case .recording:
                Circle()
                    .fill(.red)
                    .frame(width: 9, height: 9)
                    .opacity(pulse ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
                    .onDisappear { pulse = false }
                Text("Listening…").font(.system(size: 13, weight: .medium))
            case .transcribing:
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 9, height: 9)
                Text("Transcribing…").font(.system(size: 13, weight: .medium))
            case .hidden:
                EmptyView()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .fixedSize()
    }
}

@MainActor
final class RecordingIndicator {
    private var panel: NSPanel?
    private let hosting = NSHostingController(rootView: RecordingIndicatorView(state: .hidden))

    func show(_ state: IndicatorState) {
        guard state != .hidden else { hide(); return }
        hosting.rootView = RecordingIndicatorView(state: state)

        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless() // never makeKey — must not take focus from the target app
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentViewController = hosting
        return panel
    }

    private func position(_ panel: NSPanel) {
        panel.layoutIfNeeded()
        let size = hosting.view.fittingSize
        panel.setContentSize(size)
        // Bottom-center of the screen under the cursor (or main screen), above the Dock.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let x = visible.midX - size.width / 2
        let y = visible.minY + 96
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
