import BackboneEngine
import Foundation

@MainActor
final class Runtime {
    static let shared: Runtime = {
        do {
            let engine = try PinyinEngine.production()
            engine.tolerance = AppSettings.shared.fuzzyPinyin ? .all : .off
            return Runtime(engine: engine)
        } catch {
            fatalError("BiLing candidate engine could not start: \(error.localizedDescription)")
        }
    }()

    let engine: PinyinEngine
    let llm = EngineClient.shared

    private init(engine: PinyinEngine) {
        self.engine = engine
    }
}
