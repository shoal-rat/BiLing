import AppKit

/// 山水 · The landscape: colours and type for every surface of 知音.
///
/// The palette is taken from 青绿山水 painting — mineral pigments on paper:
/// 宣 paper, 墨 ink, 石青 azurite, 石绿 malachite, 朱砂 cinnabar (the seal),
/// 赭石 ochre, 月白 moon-white for the night scheme (夜山).
enum Shanshui {
    enum Scheme: String, CaseIterable, Identifiable {
        case automatic = "自动"
        case paper = "宣纸"
        case night = "夜山"
        var id: String { rawValue }
    }

    enum Typeface: String, CaseIterable, Identifiable {
        case qingya = "清雅"   // PingFang SC
        case moyun = "墨韵"    // Songti SC
        case kaishu = "楷书"   // Kaiti SC
        var id: String { rawValue }

        var familyName: String {
            switch self {
            case .qingya: return "PingFang SC"
            case .moyun: return "Songti SC"
            case .kaishu: return "Kaiti SC"
            }
        }

        func font(size: CGFloat, bold: Bool = false) -> NSFont {
            let base = NSFont(name: familyName, size: size) ?? NSFont.systemFont(ofSize: size)
            guard bold else { return base }
            return NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        }
    }

    struct Colors {
        let paper: NSColor        // panel ground
        let ink: NSColor          // candidate text
        let faintInk: NSColor     // secondary text
        let string: NSColor       // the idle string (弦)
        let plucked: NSColor      // the plucked string under the highlighted candidate
        let seal: NSColor         // 朱砂 seal
        let sealText: NSColor
        let hui: NSColor          // index numerals (徽)
        let edge: NSColor
    }

    static let paperScheme = Colors(
        paper: NSColor(srgbRed: 0.965, green: 0.945, blue: 0.906, alpha: 0.985),   // 宣 #F6F1E7
        ink: NSColor(srgbRed: 0.137, green: 0.149, blue: 0.161, alpha: 1),          // 墨 #232629
        faintInk: NSColor(srgbRed: 0.137, green: 0.149, blue: 0.161, alpha: 0.55),
        string: NSColor(srgbRed: 0.184, green: 0.396, blue: 0.467, alpha: 0.35),    // 石青 #2F6577
        plucked: NSColor(srgbRed: 0.714, green: 0.263, blue: 0.184, alpha: 1),      // 朱砂 #B6432F
        seal: NSColor(srgbRed: 0.714, green: 0.263, blue: 0.184, alpha: 1),
        sealText: NSColor(srgbRed: 0.98, green: 0.96, blue: 0.93, alpha: 1),
        hui: NSColor(srgbRed: 0.604, green: 0.427, blue: 0.282, alpha: 1),          // 赭石 #9A6D48
        edge: NSColor(srgbRed: 0.137, green: 0.149, blue: 0.161, alpha: 0.10)
    )

    static let nightScheme = Colors(
        paper: NSColor(srgbRed: 0.086, green: 0.098, blue: 0.114, alpha: 0.975),   // 夜山 #16191D
        ink: NSColor(srgbRed: 0.894, green: 0.910, blue: 0.902, alpha: 1),         // 月白 #E4E8E6
        faintInk: NSColor(srgbRed: 0.894, green: 0.910, blue: 0.902, alpha: 0.5),
        string: NSColor(srgbRed: 0.341, green: 0.596, blue: 0.494, alpha: 0.45),   // 石绿 #57987E
        plucked: NSColor(srgbRed: 0.851, green: 0.384, blue: 0.290, alpha: 1),     // 朱砂, lifted for night
        seal: NSColor(srgbRed: 0.784, green: 0.318, blue: 0.231, alpha: 1),
        sealText: NSColor(srgbRed: 0.98, green: 0.96, blue: 0.93, alpha: 1),
        hui: NSColor(srgbRed: 0.784, green: 0.631, blue: 0.443, alpha: 1),
        edge: NSColor(white: 1, alpha: 0.08)
    )

    static func colors(for scheme: Scheme, appearance: NSAppearance?) -> Colors {
        switch scheme {
        case .paper: return paperScheme
        case .night: return nightScheme
        case .automatic:
            let dark = appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? nightScheme : paperScheme
        }
    }
}
