import AppKit

/// The small seal that appears near the caret when Shift switches between
/// 中 and 英. It fades by itself; nothing else ever animates while idle.
@MainActor
final class ModeBadge {
    static let shared = ModeBadge()
    private let window: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    private init() {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 30, height: 30),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        let seal = NSView(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        seal.wantsLayer = true
        seal.layer?.cornerRadius = 6
        seal.layer?.backgroundColor = Shanshui.paperScheme.seal.cgColor
        label.font = NSFont(name: "Songti SC", size: 17) ?? .systemFont(ofSize: 17)
        label.textColor = Shanshui.paperScheme.sealText
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 3, width: 30, height: 24)
        seal.addSubview(label)
        window.contentView = seal
    }

    nonisolated func show(_ text: String, near caret: NSRect) {
        MainActor.assumeIsolated {
            label.stringValue = text
            window.setFrameOrigin(NSPoint(x: caret.minX, y: caret.minY - 36))
            window.alphaValue = 1
            window.orderFrontRegardless()
            hideWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.25
                    self?.window.animator().alphaValue = 0
                }, completionHandler: { self?.window.orderOut(nil) })
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
        }
    }
}
