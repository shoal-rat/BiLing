#!/usr/bin/env swift
// Draws 知音's icons with CoreGraphics — no bitmaps in the repository.
//
//   swift Tools/brand/draw_icons.swift Resources/Brand
//
// App icon: seven strings of a qin on 宣 paper; the middle string rises into
// a mountain (高山) and runs out as water (流水); a cinnabar seal 知音.
// Menu glyph: 知 in a rounded frame, drawn as a template image.

import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Brand")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let paperTop = NSColor(srgbRed: 0.975, green: 0.957, blue: 0.918, alpha: 1)
let paperBottom = NSColor(srgbRed: 0.925, green: 0.902, blue: 0.851, alpha: 1)
let ink = NSColor(srgbRed: 0.137, green: 0.149, blue: 0.161, alpha: 1)
let azurite = NSColor(srgbRed: 0.184, green: 0.396, blue: 0.467, alpha: 1)
let malachite = NSColor(srgbRed: 0.243, green: 0.541, blue: 0.431, alpha: 1)
let cinnabar = NSColor(srgbRed: 0.714, green: 0.263, blue: 0.184, alpha: 1)

func png(_ size: Int, _ draw: (CGContext, CGFloat) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    draw(ctx.cgContext, CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func appIcon(_ c: CGContext, _ s: CGFloat) {
    let u = s / 1024
    // macOS icon grid: 824 pt body inside 1024, continuous-corner rect.
    let body = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * u, yRadius: 185 * u)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 28 * u, color: NSColor(white: 0, alpha: 0.28).cgColor)
    paperTop.setFill()
    shape.fill()
    c.restoreGState()
    c.saveGState()
    shape.addClip()
    let gradient = NSGradient(starting: paperTop, ending: paperBottom)!
    gradient.draw(in: body, angle: -90)

    // Faint distant ridge in azurite wash.
    let wash = NSBezierPath()
    wash.move(to: CGPoint(x: body.minX, y: 470 * u))
    wash.curve(to: CGPoint(x: 420 * u, y: 600 * u), controlPoint1: CGPoint(x: 230 * u, y: 520 * u), controlPoint2: CGPoint(x: 330 * u, y: 610 * u))
    wash.curve(to: CGPoint(x: body.maxX, y: 520 * u), controlPoint1: CGPoint(x: 560 * u, y: 580 * u), controlPoint2: CGPoint(x: 760 * u, y: 600 * u))
    wash.line(to: CGPoint(x: body.maxX, y: body.minY))
    wash.line(to: CGPoint(x: body.minX, y: body.minY))
    wash.close()
    azurite.withAlphaComponent(0.10).setFill()
    wash.fill()

    // Seven strings.
    let left = 170 * u, right = 854 * u
    let spacing: CGFloat = 52 * u
    let mid = 470 * u
    for i in 0..<7 {
        let y = mid + CGFloat(i - 3) * spacing
        let p = NSBezierPath()
        if i == 3 {
            // The middle string: mountain, then water.
            p.move(to: CGPoint(x: left, y: y))
            p.line(to: CGPoint(x: 300 * u, y: y))
            p.curve(to: CGPoint(x: 430 * u, y: y + 250 * u), controlPoint1: CGPoint(x: 350 * u, y: y + 40 * u), controlPoint2: CGPoint(x: 395 * u, y: y + 250 * u))
            p.curve(to: CGPoint(x: 520 * u, y: y + 120 * u), controlPoint1: CGPoint(x: 465 * u, y: y + 250 * u), controlPoint2: CGPoint(x: 490 * u, y: y + 140 * u))
            p.curve(to: CGPoint(x: 600 * u, y: y + 175 * u), controlPoint1: CGPoint(x: 550 * u, y: y + 100 * u), controlPoint2: CGPoint(x: 575 * u, y: y + 175 * u))
            p.curve(to: CGPoint(x: 680 * u, y: y), controlPoint1: CGPoint(x: 630 * u, y: y + 175 * u), controlPoint2: CGPoint(x: 650 * u, y: y + 20 * u))
            var x = 680 * u
            while x < right {
                let next = min(right, x + 58 * u)
                p.curve(to: CGPoint(x: next, y: y), controlPoint1: CGPoint(x: x + 15 * u, y: y - 13 * u), controlPoint2: CGPoint(x: next - 15 * u, y: y + 13 * u))
                x = next
            }
            p.lineWidth = 15 * u
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            ink.setStroke()
        } else {
            p.move(to: CGPoint(x: left, y: y))
            p.line(to: CGPoint(x: right, y: y))
            p.lineWidth = (i % 2 == 0 ? 5 : 4) * u
            p.lineCapStyle = .round
            (i < 3 ? azurite : malachite).withAlphaComponent(0.55).setStroke()
        }
        p.stroke()
    }
    // 徽: inlaid position dots along the top edge, as on a guqin.
    for k in 0..<7 {
        let x = left + CGFloat(k) * (right - left) / 6
        let r = (k == 3 ? 11 : 7) * u
        NSColor(srgbRed: 0.604, green: 0.427, blue: 0.282, alpha: 0.85).setFill()
        NSBezierPath(ovalIn: CGRect(x: x - r, y: 760 * u - r, width: 2 * r, height: 2 * r)).fill()
    }
    // Seal.
    let sealRect = CGRect(x: 650 * u, y: 160 * u, width: 150 * u, height: 150 * u)
    cinnabar.setFill()
    NSBezierPath(roundedRect: sealRect, xRadius: 18 * u, yRadius: 18 * u).fill()
    let font = NSFont(name: "Songti SC Bold", size: 54 * u) ?? NSFont.boldSystemFont(ofSize: 54 * u)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: paperTop]
    // Two characters stacked. In a non-flipped context draw(at:) takes the
    // bottom of the line box; a CJK glyph's visual centre sits ~0.38 em above
    // the baseline, and the baseline sits -descender above that point.
    let em = font.pointSize
    let gap = 6 * u
    let step = em * 0.95 + gap
    for (j, ch) in ["知", "音"].enumerated() {
        let str = ch as NSString
        let size = str.size(withAttributes: attrs)
        let centre = sealRect.midY + step / 2 - CGFloat(j) * step
        str.draw(at: CGPoint(x: sealRect.midX - size.width / 2, y: centre - 0.38 * em + font.descender), withAttributes: attrs)
    }
    c.restoreGState()
}

func menuGlyph(_ c: CGContext, _ s: CGFloat) {
    let u = s / 16
    let frame = CGRect(x: 1.5 * u, y: 1.5 * u, width: 13 * u, height: 13 * u)
    let box = NSBezierPath(roundedRect: frame, xRadius: 3 * u, yRadius: 3 * u)
    box.lineWidth = 1.1 * u
    NSColor.black.setStroke()
    box.stroke()
    let font = NSFont(name: "PingFang SC Semibold", size: 10.5 * u) ?? NSFont.boldSystemFont(ofSize: 10.5 * u)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    let str = "知" as NSString
    let size = str.size(withAttributes: attrs)
    str.draw(at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2 + 0.3 * u), withAttributes: attrs)
}

let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(base, appIcon).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(base * 2, appIcon).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(1024, appIcon).write(to: out.appendingPathComponent("AppIcon-1024.png"))
try png(16, menuGlyph).write(to: out.appendingPathComponent("MenuIcon.png"))
try png(32, menuGlyph).write(to: out.appendingPathComponent("MenuIcon@2x.png"))
print("icons written to \(out.path)")
