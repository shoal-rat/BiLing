import Foundation
import os

/// Versioned expert configuration, one validated file.
///
/// Two kinds of knobs exist and they deliberately live apart: user
/// preferences (fuzzy pinyin, auto-spacing…) belong to the Settings UI and
/// UserDefaults; the engine's tuning parameters — swept values with measured
/// consequences — live here, in `~/Library/Application Support/BiLing/
/// config.json`, where changing one is an explicit, diffable act.
///
/// Validation is per-field: a value outside its documented range falls back
/// to that field's default (logged once), so one typo cannot silently reset
/// every other override. No file at all is the common case and costs one
/// stat.
///
/// `diagnostics` turns on verbose per-keystroke logging in the input
/// controller. It is never on by default and no code path may flip it
/// programmatically — observability of one's own typing is opt-in only.
public struct EngineConfig: Sendable {
    public let gateThreshold: Double
    public let gateThresholdContext: Double
    public let characterFanIn: Int
    public let tolerantFanIn: Int
    public let modelTimeoutMilliseconds: Int
    public let diagnostics: Bool

    public static let fallback = EngineConfig(
        gateThreshold: 0.35,
        gateThresholdContext: 0.15,
        characterFanIn: 20,
        tolerantFanIn: 8,
        modelTimeoutMilliseconds: 2_500,
        diagnostics: false
    )

    public static let shared: EngineConfig = load()

    static func load() -> EngineConfig {
        let url = ProcessInfo.processInfo.environment["BILING_CONFIG_PATH"]
            .map(URL.init(fileURLWithPath:))
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("BiLing/config.json")
        guard let url, let data = try? Data(contentsOf: url) else { return .fallback }
        return parse(data, source: url.path)
    }

    static func parse(_ data: Data, source: String = "inline") -> EngineConfig {
        let log = Logger(subsystem: "com.biling.inputmethod", category: "config")
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schema"] as? String == "biling-config",
              object["version"] as? Int == 1
        else {
            log.error("config \(source, privacy: .public) unreadable or wrong schema; using defaults")
            return .fallback
        }

        func field<T>(_ name: String, default value: T, valid: (T) -> Bool) -> T {
            guard let raw = object[name] else { return value }
            guard let typed = raw as? T, valid(typed) else {
                log.error("config field \(name, privacy: .public) invalid; using its default")
                return value
            }
            return typed
        }

        return EngineConfig(
            gateThreshold: field(
                "gate_threshold", default: fallback.gateThreshold, valid: { $0 > 0 && $0 < 1 }
            ),
            gateThresholdContext: field(
                "gate_threshold_context",
                default: fallback.gateThresholdContext,
                valid: { $0 > 0 && $0 < 1 }
            ),
            characterFanIn: field(
                "character_fan_in", default: fallback.characterFanIn, valid: { (1...64).contains($0) }
            ),
            tolerantFanIn: field(
                "tolerant_fan_in", default: fallback.tolerantFanIn, valid: { (1...32).contains($0) }
            ),
            modelTimeoutMilliseconds: field(
                "model_timeout_ms",
                default: fallback.modelTimeoutMilliseconds,
                valid: { (100...30_000).contains($0) }
            ),
            diagnostics: field("diagnostics", default: false, valid: { _ in true })
        )
    }
}
