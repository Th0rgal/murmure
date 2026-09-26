import AppKit
import SwiftUI

// `Murmure --render-pill <dir>` writes the overlay states as PNGs (docs, visual checks).
@MainActor func renderPills(to dir: URL) {
    let states: [(String, OverlayModel.Phase, [CGFloat])] = [
        ("idle", .recording, Array(repeating: 0, count: OverlayModel.bars)),
        ("speaking", .recording, [0.2, 0.5, 0.9, 0.6, 1, 0.7, 0.4, 0.6, 0.3]),
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

if let i = CommandLine.arguments.firstIndex(of: "--render-pill"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { renderPills(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
