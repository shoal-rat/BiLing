import Combine
import Foundation

/// Everything 琴台 lets you change. Read on every keystroke, so a change in
/// 琴台 applies to the next key, not the next launch.
final class Preferences: ObservableObject, @unchecked Sendable {
    static let shared = Preferences()
    private let defaults = UserDefaults(suiteName: "com.zhiyin.inputmethod") ?? .standard

    // 指法 · touch
    @Published var shiftToggles: Bool { didSet { defaults.set(shiftToggles, forKey: "shiftToggles") } }
    @Published var fullWidthPunctuation: Bool { didSet { defaults.set(fullWidthPunctuation, forKey: "fullWidthPunctuation") } }
    @Published var pageSize: Int { didSet { defaults.set(pageSize, forKey: "pageSize") } }

    // 子期 · the listener
    @Published var listenerEnabled: Bool { didSet { defaults.set(listenerEnabled, forKey: "listenerEnabled") } }
    /// 细听 (wider search) or 轻听 (narrower, cheaper).
    @Published var attentive: Bool { didSet { defaults.set(attentive, forKey: "attentive") } }
    @Published var readContext: Bool { didSet { defaults.set(readContext, forKey: "readContext") } }
    @Published var soloOnLowPower: Bool { didSet { defaults.set(soloOnLowPower, forKey: "soloOnLowPower") } }
    @Published var restAfterMinutes: Int { didSet { defaults.set(restAfterMinutes, forKey: "restAfterMinutes") } }

    // 默契 · rapport
    @Published var learning: Bool { didSet { defaults.set(learning, forKey: "learning") } }

    // 山水 · landscape
    @Published var scheme: String { didSet { defaults.set(scheme, forKey: "scheme") } }
    @Published var typeface: String { didSet { defaults.set(typeface, forKey: "typeface") } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }

    private init() {
        let defaults = self.defaults
        let bool = { (key: String, fallback: Bool) -> Bool in
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        shiftToggles = bool("shiftToggles", true)
        fullWidthPunctuation = bool("fullWidthPunctuation", true)
        pageSize = defaults.object(forKey: "pageSize") == nil ? 7 : max(3, min(9, defaults.integer(forKey: "pageSize")))
        listenerEnabled = bool("listenerEnabled", true)
        attentive = bool("attentive", true)
        readContext = bool("readContext", true)
        soloOnLowPower = bool("soloOnLowPower", true)
        restAfterMinutes = defaults.object(forKey: "restAfterMinutes") == nil ? 15 : defaults.integer(forKey: "restAfterMinutes")
        learning = bool("learning", true)
        scheme = defaults.string(forKey: "scheme") ?? Shanshui.Scheme.automatic.rawValue
        typeface = defaults.string(forKey: "typeface") ?? Shanshui.Typeface.qingya.rawValue
        fontSize = defaults.object(forKey: "fontSize") == nil ? 17 : defaults.double(forKey: "fontSize")
    }

    var schemeValue: Shanshui.Scheme { Shanshui.Scheme(rawValue: scheme) ?? .automatic }
    var typefaceValue: Shanshui.Typeface { Shanshui.Typeface(rawValue: typeface) ?? .qingya }
}
