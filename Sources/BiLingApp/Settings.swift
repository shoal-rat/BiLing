import Foundation

final class AppSettings: @unchecked Sendable {
    static let shared = AppSettings()
    private let defaults = UserDefaults(suiteName: "com.biling.inputmethod") ?? .standard

    var autoSpacing: Bool {
        get { defaults.object(forKey: "autoSpacing") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoSpacing") }
    }

    var fullWidthPunctuation: Bool {
        get { defaults.object(forKey: "fullWidthPunctuation") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "fullWidthPunctuation") }
    }

    var learningEnabled: Bool {
        get { defaults.object(forKey: "learningEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "learningEnabled") }
    }

    var fuzzyPinyin: Bool {
        get { defaults.object(forKey: "fuzzyPinyin") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "fuzzyPinyin") }
    }
}
