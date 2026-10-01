import AppKit
import ZhiyinCore

/// 弦 · The candidate panel.
///
/// Candidates sit along a single string, as notes sit along a qin string. The
/// highlighted one is the plucked note: its stretch of string turns cinnabar,
/// and its numeral sits in a filled 徽 (the inlaid position markers on a
/// guqin). While 子期 is still listening the string trembles; when the list
/// comes from 子期 a small 听 seal is stamped at the end, and 谱 when the
/// score alone answered.
final class StringsPanel {
    struct Content {
        var candidates: [Candidate]
        var highlighted: Int
        var page: Int
        var pageCount: Int
        var heard: Bool
        var listening: Bool
    }

    private let window: NSPanel
    private let view: StringsView

    init() {
        view = StringsView(frame: .zero)
        window = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        window.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = view
    }

    var isVisible: Bool { window.isVisible }

    /// Shows the panel just below `caret` (screen coordinates, as reported by
    /// the client's line-height rectangle), flipping above near the bottom.
    func show(_ content: Content, below caret: NSRect) {
        let prefs = Preferences.shared
        view.content = content
        view.colors = Shanshui.colors(for: prefs.schemeValue, appearance: NSApp.effectiveAppearance)
        view.typeface = prefs.typefaceValue
        view.fontSize = CGFloat(prefs.fontSize)
        let size = view.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(caret.origin) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: caret.minX - 10, y: caret.minY - size.height - 6)
        if origin.y < visible.minY { origin.y = caret.maxY + 6 }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        view.needsDisplay = true
        if !window.isVisible { window.orderFrontRegardless() }
        view.setTrembling(content.listening)
    }

    func hide() {
        view.setTrembling(false)
        window.orderOut(nil)
    }

    /// Renders a panel to PNG without a screen (documentation, smoke tests).
    static func snapshot(_ content: Content, scheme: Shanshui.Scheme, to url: URL) -> Bool {
        let view = StringsView(frame: .zero)
        view.content = content
        view.colors = Shanshui.colors(for: scheme, appearance: nil)
        view.typeface = Preferences.shared.typefaceValue
        view.fontSize = CGFloat(Preferences.shared.fontSize)
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return false }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}

final class StringsView: NSView {
    var content = StringsPanel.Content(candidates: [], highlighted: 0, page: 0, pageCount: 1, heard: false, listening: false)
    var colors = Shanshui.paperScheme
    var typeface = Shanshui.Typeface.qingya
    var fontSize: CGFloat = 17

    private var phase: CGFloat = 0
    private var amplitude: CGFloat = 0
    private var timer: Timer?

    private let padding = NSEdgeInsets(top: 8, left: 12, bottom: 11, right: 10)
    private let gap: CGFloat = 16
    private let numeralWidth: CGFloat = 15

    override var isFlipped: Bool { true }

    private var textFont: NSFont { typeface.font(size: fontSize) }
    private var highlightFont: NSFont { typeface.font(size: fontSize, bold: true) }
    private var numeralFont: NSFont { NSFont.monospacedDigitSystemFont(ofSize: max(10, fontSize * 0.62), weight: .medium) }

    private struct Slot { let x: CGFloat; let width: CGFloat }

    private func measure() -> (slots: [Slot], width: CGFloat, height: CGFloat) {
        var x = padding.left
        var slots: [Slot] = []
        for (i, c) in content.candidates.enumerated() {
            let font = i == content.highlighted ? highlightFont : textFont
            let w = (c.text as NSString).size(withAttributes: [.font: font]).width
            slots.append(Slot(x: x, width: numeralWidth + w))
            x += numeralWidth + w + gap
        }
        let tail: CGFloat = (content.pageCount > 1 ? 26 : 0) + 18
        let width = max(120, x - gap + 10 + tail + padding.right)
        let height = ceil(textFont.ascender - textFont.descender + textFont.leading) + padding.top + padding.bottom
        return (slots, width, height)
    }

    override var fittingSize: NSSize {
        let l = measure()
        return NSSize(width: ceil(l.width), height: ceil(l.height))
    }

    func setTrembling(_ on: Bool) {
        if on {
            guard timer == nil else { return }
            amplitude = 1.6
            // Only while 子期 is still listening, and never longer than ~1 s:
            // the panel never animates when idle.
            let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.phase += 0.55
                self.amplitude *= 0.965
                if self.amplitude < 0.15 { self.setTrembling(false) }
                self.needsDisplay = true
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else {
            timer?.invalidate()
            timer = nil
            amplitude = 0
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let l = measure()
        let body = NSRect(x: 0.5, y: 0.5, width: bounds.width - 1, height: bounds.height - 1)
        let shape = NSBezierPath(roundedRect: body, xRadius: 9, yRadius: 9)
        colors.paper.setFill()
        shape.fill()
        colors.edge.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        let stringY = bounds.height - padding.bottom + 4.5
        let left = padding.left - 2
        let right = bounds.width - padding.right - 20

        // The string.
        let line = NSBezierPath()
        line.lineWidth = 0.9
        if amplitude > 0 {
            var x = left
            line.move(to: NSPoint(x: x, y: stringY))
            while x <= right {
                let envelope = sin(.pi * (x - left) / max(1, right - left))
                line.line(to: NSPoint(x: x, y: stringY + amplitude * envelope * sin(x / 6 + phase)))
                x += 2
            }
        } else {
            line.move(to: NSPoint(x: left, y: stringY))
            line.line(to: NSPoint(x: right, y: stringY))
        }
        colors.string.setStroke()
        line.stroke()

        let baseline = padding.top + textFont.ascender
        for (i, c) in content.candidates.enumerated() {
            let slot = l.slots[i]
            let on = i == content.highlighted
            // 徽 numeral.
            let numeral = "\(i + 1)" as NSString
            let nAttr: [NSAttributedString.Key: Any] = [
                .font: numeralFont,
                .foregroundColor: on ? colors.sealText : colors.hui,
            ]
            let nSize = numeral.size(withAttributes: nAttr)
            let nOrigin = NSPoint(x: slot.x + (numeralWidth - 3 - nSize.width) / 2, y: baseline - numeralFont.ascender - 1)
            if on {
                let d = max(nSize.width, nSize.height) + 2
                let dot = NSRect(x: nOrigin.x + nSize.width / 2 - d / 2, y: nOrigin.y + nSize.height / 2 - d / 2, width: d, height: d)
                colors.plucked.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            numeral.draw(at: nOrigin, withAttributes: nAttr)
            // Candidate text.
            let font = on ? highlightFont : textFont
            let wholeLength = content.candidates.first?.consumed ?? 0
            let partial = c.consumed < wholeLength
            let tint: NSColor = on ? colors.ink : colors.ink.withAlphaComponent(partial ? 0.78 : 0.92)
            let tAttr: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint]
            (c.text as NSString).draw(at: NSPoint(x: slot.x + numeralWidth, y: baseline - font.ascender), withAttributes: tAttr)
            if on {
                let plucked = NSBezierPath()
                plucked.lineWidth = 2.2
                plucked.lineCapStyle = .round
                plucked.move(to: NSPoint(x: slot.x + numeralWidth, y: stringY))
                plucked.line(to: NSPoint(x: slot.x + slot.width, y: stringY))
                colors.plucked.setStroke()
                plucked.stroke()
            }
        }

        // Page marks and the seal.
        var x = bounds.width - padding.right - 14
        let sealRect = NSRect(x: x, y: (bounds.height - 14) / 2 - 1, width: 14, height: 14)
        let seal = NSBezierPath(roundedRect: sealRect, xRadius: 2.5, yRadius: 2.5)
        (content.heard ? colors.seal : colors.faintInk.withAlphaComponent(0.35)).setFill()
        seal.fill()
        let mark = (content.heard ? "听" : "谱") as NSString
        let mAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Songti SC", size: 10) ?? NSFont.systemFont(ofSize: 10),
            .foregroundColor: colors.sealText,
        ]
        let mSize = mark.size(withAttributes: mAttr)
        mark.draw(at: NSPoint(x: sealRect.midX - mSize.width / 2, y: sealRect.midY - mSize.height / 2), withAttributes: mAttr)
        if content.pageCount > 1 {
            x -= 26
            let arrows = "\(content.page > 0 ? "‹" : " ")\(content.page + 1 < content.pageCount ? "›" : " ")" as NSString
            arrows.draw(at: NSPoint(x: x, y: baseline - textFont.ascender + 1), withAttributes: [
                .font: NSFont.systemFont(ofSize: fontSize * 0.8, weight: .light),
                .foregroundColor: colors.faintInk,
            ])
        }
    }
}
