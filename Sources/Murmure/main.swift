import AppKit
import SwiftUI

// `Murmure --render-pill <dir>` writes the overlay states as PNGs (docs, visual checks).
@MainActor func renderPills(to dir: URL) {
    let states: [(String, OverlayModel.Phase, [CGFloat])] = [
        ("idle", .recording, Array(repeating: 0, count: OverlayModel.bars)),
        ("speaking", .recording, (0 ..< OverlayModel.bars).map { i in
            let x = Double(i) / Double(OverlayModel.bars - 1)
            return CGFloat(max(0, sin(x * 9) * 0.5 + sin(x * 23) * 0.3 + 0.25) * (i < 5 ? 0 : 1))
        }),
        ("transcribing", .transcribing, Array(repeating: 0, count: OverlayModel.bars)),
    ]
    for (name, phase, levels) in states {
        let m = OverlayModel()
        m.phase = phase
        m.levels = levels
        let r = ImageRenderer(content: PillView(model: m).padding(12).background(Color(white: 0.11)))
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("pill-\(name).png"))
        }
    }
}

@MainActor func renderSettings(to dir: URL) {
    let host = NSHostingView(rootView: SettingsView(prefs: Preferences()) {})
    host.setFrameSize(host.fittingSize)
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("settings.png"))
}

if let i = CommandLine.arguments.firstIndex(of: "--render-settings"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { renderSettings(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--render-pill"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { renderPills(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
