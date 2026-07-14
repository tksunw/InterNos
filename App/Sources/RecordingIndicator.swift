// Floating recording indicator (PRD §5 step 3): a premium real-time "voice print" — a
// scrolling waveform of rounded bars driven by actual mic amplitude — in a frosted rounded
// box near the bottom of the active screen. Uses a non-activating panel that never becomes
// key, so it never steals focus (stealing focus would send the paste to the wrong app).

import AppKit
import SwiftUI

enum IndicatorState: Equatable {
    case hidden
    case recording
    case transcribing
}

/// Rolling ring buffer of recent input levels, newest at the end. Drives the waveform.
@MainActor
final class LevelMeter: ObservableObject {
    @Published private(set) var levels: [CGFloat]
    private let capacity: Int
    private var smoothed: CGFloat = 0

    init(capacity: Int = 48) {
        self.capacity = capacity
        levels = Array(repeating: 0, count: capacity)
    }

    func push(_ level: CGFloat) {
        // Light attack/decay smoothing so the bars breathe instead of jitter.
        smoothed = level > smoothed ? (smoothed * 0.4 + level * 0.6)
                                    : (smoothed * 0.7 + level * 0.3)
        var next = levels
        next.removeFirst()
        next.append(smoothed)
        levels = next
    }

    func reset() {
        smoothed = 0
        levels = Array(repeating: 0, count: capacity)
    }
}

private let brandGradient = Gradient(colors: [
    Color(red: 0.55, green: 0.45, blue: 0.98),
    Color(red: 0.72, green: 0.42, blue: 0.95),
    Color(red: 0.55, green: 0.45, blue: 0.98),
])

struct VoicePrintView: View {
    @ObservedObject var meter: LevelMeter

    var body: some View {
        Canvas { ctx, size in
            let count = meter.levels.count
            let gap: CGFloat = 2.5
            let barW = max(2, (size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            let midY = size.height / 2
            var bars = Path()
            for (i, level) in meter.levels.enumerated() {
                // Ease the amplitude and keep a small floor so silence reads as a dotted line.
                let h = max(barW, pow(level, 0.85) * size.height)
                let x = CGFloat(i) * (barW + gap)
                bars.addPath(Path(roundedRect: CGRect(x: x, y: midY - h / 2, width: barW, height: h),
                                  cornerRadius: barW / 2))
            }
            ctx.fill(bars, with: .linearGradient(brandGradient,
                                                 startPoint: .zero,
                                                 endPoint: CGPoint(x: size.width, y: 0)))
        }
        .drawingGroup() // render on the GPU for smooth ~47 Hz updates
    }
}

/// Rolling live-preview text, newest words visible (head-truncated).
@MainActor
final class PreviewModel: ObservableObject {
    @Published var text = ""
}

struct RecordingIndicatorView: View {
    let state: IndicatorState
    @ObservedObject var meter: LevelMeter
    @ObservedObject var preview: PreviewModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(.black.opacity(0.78))
                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 4)

            switch state {
            case .recording:
                VStack(spacing: 5) {
                    VoicePrintView(meter: meter)
                        .frame(height: 28)
                    // Live preview: single line, head-truncated so the newest words
                    // stay visible while speaking. Empty until recognition starts.
                    Text(preview.text.isEmpty ? " " : preview.text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            case .transcribing:
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small).scaleEffect(0.75).frame(width: 10, height: 10)
                    Text("Transcribing…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                }
            case .hidden:
                EmptyView()
            }
        }
        .frame(width: 260, height: state == .recording ? 70 : 54)
    }
}

/// Controller-facing seam so lifecycle tests can observe the indicator without NSPanel.
@MainActor
protocol IndicatorPresenting: AnyObject {
    func show(_ state: IndicatorState)
    func hide()
    func pushLevel(_ level: CGFloat)
    /// Live transcript preview while recording (v2): the accumulated recognized
    /// text so far. Display only — never logged, never persisted.
    func showPartial(_ text: String)
}

@MainActor
final class RecordingIndicator: IndicatorPresenting {
    private var panel: NSPanel?
    private let meter = LevelMeter()
    private let preview = PreviewModel()
    private lazy var hosting = NSHostingController(
        rootView: RecordingIndicatorView(state: .hidden, meter: meter, preview: preview))

    /// Feed a live input level (0...1) from the capture tap.
    func pushLevel(_ level: CGFloat) { meter.push(level) }

    func showPartial(_ text: String) { preview.text = text }

    func show(_ state: IndicatorState) {
        guard state != .hidden else { hide(); return }
        if state == .recording {
            meter.reset()
            preview.text = ""
        }
        hosting.rootView = RecordingIndicatorView(state: state, meter: meter, preview: preview)

        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel, height: state == .recording ? 70 : 54)
        panel.orderFrontRegardless() // never makeKey — must not take focus from the target app
    }

    func hide() {
        panel?.orderOut(nil)
        meter.reset()
        preview.text = ""
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 216, height: 54),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // the SwiftUI card draws its own shadow
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentViewController = hosting
        return panel
    }

    private func position(_ panel: NSPanel, height: CGFloat) {
        let size = NSSize(width: 260, height: height)
        panel.setContentSize(size)
        // Bottom-center of the screen under the cursor (or main screen), above the Dock.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let x = visible.midX - size.width / 2
        let y = visible.minY + 96
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
