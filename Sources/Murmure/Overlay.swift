import AppKit
import SwiftUI

final class OverlayModel: ObservableObject {
    enum Phase: Equatable { case recording, transcribing, message(String) }
    @Published var phase: Phase = .recording
    @Published var levels: [CGFloat] = Array(repeating: 0, count: OverlayModel.bars)
    @Published var language = "fr"
    static let bars = 9

    var onCancel: () -> Void = {}
    var onCommit: () -> Void = {}
    var onLanguage: () -> Void = {}

    func push(level rms: Float) {
        // Speech RMS sits around 0.01–0.2; map to 0…1 on a log scale.
        let db = 20 * log10(max(rms, 1e-5))
        let v = CGFloat(max(0, min(1, (db + 55) / 40)))
        levels.removeFirst()
        levels.append(v)
    }
}

struct PillView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        HStack(spacing: 10) {
            Button(action: model.onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color(white: 0.27)))
            }
            .buttonStyle(.plain)
            .help("Annuler (Esc)")

            center.frame(width: 92, height: 28)

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
            .help("Transcrire (Fn + ⇧ droit, ou Entrée)")
        }
        .padding(.horizontal, 7)
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
            .help("Langue")
        }
        .padding(.top, 10)
        .fixedSize()
    }

    @ViewBuilder private var center: some View {
        switch model.phase {
        case .recording:
            HStack(spacing: 4) {
                ForEach(0 ..< OverlayModel.bars, id: \.self) { i in
                    Capsule().fill(.white)
                        .frame(width: 3.5, height: 3.5 + model.levels[i] * 18)
                }
            }
            .animation(.easeOut(duration: 0.08), value: model.levels)
        case .transcribing:
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                HStack(spacing: 4) {
                    ForEach(0 ..< OverlayModel.bars, id: \.self) { i in
                        Circle().fill(.white)
                            .frame(width: 3.5, height: 3.5)
                            .opacity(0.3 + 0.7 * max(0, sin(t * 6 - Double(i) * 0.6)))
                    }
                }
            }
        case let .message(text):
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(Color(white: 0.85))
                .lineLimit(1).minimumScaleFactor(0.6)
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
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; animator().alphaValue = 0 }) { [weak self] in
            self?.orderOut(nil)
        }
    }
}
