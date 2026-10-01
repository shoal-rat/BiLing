import AppKit
import ZhiyinCore
import ZhiyinListener

/// The instruments every input session shares: one score, one memory, one
/// listener. Sessions (one per client app) come and go; these stay.
@MainActor
final class Runtime {
    static let shared = Runtime()

    let qinpu: Qinpu?
    let moqi: Moqi
    let listener: ListenerService?
    let syllables: SyllableTable
    private(set) var generation: UInt64 = 0
    private(set) var listenerState: ListenerService.State = .resting
    var onListenerState: [(ListenerService.State) -> Void] = []

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Zhiyin", isDirectory: true)
    }

    private init() {
        let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")
        let data = resources.appendingPathComponent("Data")
        qinpu = try? Qinpu(path: data.appendingPathComponent("qinpu.trie").path)
        try? FileManager.default.createDirectory(at: Runtime.supportDirectory, withIntermediateDirectories: true)
        moqi = Moqi(directory: Runtime.supportDirectory)
        let model = resources.appendingPathComponent("Models/ziqi.gguf").path
        let vocab = data.appendingPathComponent("ziqi-vocab.trie").path
        if FileManager.default.fileExists(atPath: model), FileManager.default.fileExists(atPath: vocab) {
            listener = ListenerService(modelPath: model, vocabularyPath: vocab)
        } else {
            listener = nil
            listenerState = .absent("模型文件缺失")
        }
        syllables = qinpu?.syllables ?? SyllableTable(names: [])
        applyPreferences()
        listener?.onStateChange = { state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Runtime.shared.listenerState = state
                    for f in Runtime.shared.onListenerState { f(state) }
                }
            }
        }
    }

    func nextGeneration() -> UInt64 {
        generation &+= 1
        return generation
    }

    func applyPreferences() {
        let prefs = Preferences.shared
        guard let listener else { return }
        var config = listener.config
        config.beam = prefs.attentive ? 6 : 3
        config.results = prefs.attentive ? 8 : 5
        listener.config = config
        listener.idleRelease = TimeInterval(max(1, prefs.restAfterMinutes)) * 60
    }

    /// Should 子期 be asked at all right now?
    var listenerActive: Bool {
        let prefs = Preferences.shared
        guard listener != nil, prefs.listenerEnabled else { return false }
        if prefs.soloOnLowPower, ProcessInfo.processInfo.isLowPowerModeEnabled { return false }
        if case .absent = listenerState { return false }
        return true
    }

    /// 子期's state in words, for the menu and 琴台.
    var listenerStatus: String {
        let prefs = Preferences.shared
        if listener == nil { return "独奏 · 子期的模型文件缺失" }
        if !prefs.listenerEnabled { return "独奏 · 子期已暂歇" }
        if prefs.soloOnLowPower, ProcessInfo.processInfo.isLowPowerModeEnabled { return "独奏 · 低电量，子期不扰" }
        switch listenerState {
        case .resting: return "子期小憩 · 下一个字唤醒"
        case .arriving: return "子期将至 · 正在载入"
        case .listening: return "子期在听"
        case .absent(let why): return "独奏 · 子期未能到来（\(why)）"
        }
    }
}
