import AppKit
import SwiftUI

final class OverlayModel: ObservableObject {
    enum Phase: Equatable { case recording, transcribing, message(String) }
    @Published var phase: Phase = .recording
    @Published var levels: [CGFloat] = Array(repeating: 0, count: OverlayModel.bars)
    @Published var language = "fr"
    @Published var livePreview = ""
    static let bars = 30
    private var last: CGFloat = 0

    var onCancel: () -> Void = {}
    var onCommit: () -> Void = {}
    var onLanguage: () -> Void = {}

    /// One display tick (40 ms): scroll in the loudest envelope value
    /// measured since the previous tick.
    func tick(_ envelope: [Float]) {
        if let peak = envelope.max() { last = CGFloat(peak) } else { last *= 0.8 }
        levels.removeFirst()
        levels.append(pow(last, 0.8))  // lifts ordinary speech a little
    }
}

struct PillView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        VStack(spacing: 4) {
            if !model.livePreview.isEmpty {
                Text(model.livePreview)
                    .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                    .underline(true, color: Color(white: 0.55))
                    .foregroundStyle(Color(white: 0.88))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 260)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(Color(white: 0.11).opacity(0.94))
                            .overlay(Capsule().strokeBorder(Color(white: 0.24), lineWidth: 1))
                    )
            }

            HStack(spacing: 6) {
                Button(action: model.onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color(white: 0.27)))
                }
                .buttonStyle(.plain)
                .help("Cancel (Esc)")

                center.frame(width: 128, height: 28)

                Button(action: model.onCommit) {
                    Group {
                        if model.phase == .transcribing {
                            ProgressView().controlSize(.small).tint(.black)
                        } else {
                            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                        }
                    }
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(.white))
                }
                .buttonStyle(.plain)
                .disabled(model.phase != .recording)
                .help("Transcribe (Return)")
            }
            .padding(.horizontal, 6)
            .frame(height: 42)
            .background(
                Capsule().fill(Color(white: 0.085))
                    .overlay(Capsule().strokeBorder(Color(white: 0.24), lineWidth: 1))
            )
            .overlay(alignment: .top) {
                Button(action: model.onLanguage) {
                    Text(model.language.uppercased())
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(white: 0.7))
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Capsule().fill(Color(white: 0.085)).overlay(Capsule().strokeBorder(Color(white: 0.24), lineWidth: 1)))
                }
                .buttonStyle(.plain)
                .offset(y: -8)
                .help("Language")
            }
            .padding(.top, 10)
        }
        .fixedSize()
    }

    @ViewBuilder private var center: some View {
        switch model.phase {
        case .recording:
            // ProMotion 60-120 FPS Canvas waveform (zero SwiftUI view-tree rebuilds per tick)
            TimelineView(.animation) { _ in
                FluidWaveformCanvas(targets: model.levels)
            }
        case .transcribing:
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                Canvas { gc, size in
                    let count = OverlayModel.bars
                    let dot: CGFloat = 2
                    let gap = (size.width - dot * CGFloat(count)) / CGFloat(max(count - 1, 1))
                    let midY = size.height / 2
                    for i in 0 ..< count {
                        let x = CGFloat(i) * (dot + gap)
                        let opacity = 0.25 + 0.75 * max(0, sin(t * 7 - Double(i) * 0.35))
                        let rect = CGRect(x: x, y: midY - dot / 2, width: dot, height: dot)
                        gc.fill(Path(ellipseIn: rect), with: .color(.white.opacity(opacity)))
                    }
                }
            }
        case let .message(text):
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(Color(white: 0.85))
                .lineLimit(1).minimumScaleFactor(0.6)
        }
    }
}

/// Smoothly interpolated 60-120 FPS Canvas waveform matching Scribe & Murmure's obsidian pill language.
private struct FluidWaveformCanvas: View {
    let targets: [CGFloat]
    @State private var smoothed: [CGFloat] = Array(repeating: 0, count: OverlayModel.bars)

    var body: some View {
        Canvas { gc, size in
            let count = min(targets.count, smoothed.count)
            guard count > 0 else { return }
            let barW: CGFloat = 2
            let gap = (size.width - barW * CGFloat(count)) / CGFloat(max(count - 1, 1))
            let midY = size.height / 2
            let maxH = max(size.height - 2, barW)
            for i in 0 ..< count {
                let lvl = max(0, min(1, smoothed[i]))
                let h = barW + lvl * (maxH - barW)
                let x = CGFloat(i) * (barW + gap)
                let rect = CGRect(x: x, y: midY - h / 2, width: barW, height: h)
                let alpha = 0.38 + 0.62 * Double(lvl)
                gc.fill(
                    Path(roundedRect: rect, cornerRadius: barW / 2),
                    with: .color(.white.opacity(alpha))
                )
            }
        }
        .onChange(of: targets) { _, newVals in
            for i in 0 ..< min(newVals.count, smoothed.count) {
                smoothed[i] += (newVals[i] - smoothed[i]) * 0.45
            }
        }
    }
}

/// Borderless, non-activating panel: the app you dictate into keeps focus.
final class OverlayPanel: NSPanel {
    init(model: OverlayModel) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: PillView(model: model))
        host.setFrameSize(host.fittingSize)
        contentView = host
        setContentSize(host.fittingSize)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            let size = frame.size
            setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.minY + 36))
        }
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; animator().alphaValue = 1 }
    }

    func hide() {
        // Keeps the panel alive until it is ordered out.
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; animator().alphaValue = 0 }) {
            self.orderOut(nil)
        }
    }
}
