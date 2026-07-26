import BackboneEngine
import Foundation

@MainActor
final class Runtime {
    static let shared: Runtime = {
        do {
            return Runtime(engine: try PinyinEngine.production())
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
