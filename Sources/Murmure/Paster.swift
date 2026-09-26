import AppKit
import ApplicationServices

/// Inserts text in the frontmost app: pasteboard + synthetic ⌘V, then puts
/// the previous clipboard back.
enum Paster {
    static var canPost: Bool { AXIsProcessTrusted() }

    static func insert(_ text: String, restore: Bool) {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = restore ? (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } : []
        pb.clearContents()
        pb.setString(text, forType: .string)
        // Tell clipboard managers this entry is transient.
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        guard canPost else { return }  // text stays on the clipboard
        let src = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
        guard restore else { return }
        let change = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard pb.changeCount == change else { return }  // someone copied meanwhile
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
    }
}
