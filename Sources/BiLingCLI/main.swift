import BackboneEngine
import Foundation
import IPCProtocol
import LLMRanker

func usage() -> Never {
    print("Usage: biling-cli [--xpc] [--model path] [--context text] PINYIN")
    exit(64)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var modelURL = ModelLocator.bundledModelURL()
var context = ""
var pinyin: String?
var useXPC = false
while !arguments.isEmpty {
    let item = arguments.removeFirst()
    switch item {
    case "--xpc":
        useXPC = true
    case "--model":
        guard !arguments.isEmpty else { usage() }
        modelURL = URL(fileURLWithPath: arguments.removeFirst())
    case "--context":
        guard !arguments.isEmpty else { usage() }
        context = arguments.removeFirst()
    default:
        pinyin = item
    }
}
guard let pinyin else { usage() }

do {
    let engine = try PinyinEngine(
        dictionary: .bundled(),
        learningStore: MemoryLearningStore()
    )
    let result = engine.candidates(for: pinyin, context: context, generation: 1)
    let request = RankRequest(
        clientID: UUID(),
        generation: 1,
        input: pinyin,
        committedContext: context,
        candidates: result.candidates.prefix(30).map(\.text)
    )
    let ranked: RankReply
    if useXPC {
        let connection = NSXPCConnection(machServiceName: biLingMachServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: BiLingEngineXPC.self)
        connection.resume()
        defer { connection.invalidate() }
        ranked = try await withCheckedThrowingContinuation { continuation in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                continuation.resume(throwing: error)
            }) as? BiLingEngineXPC else {
                continuation.resume(throwing: RankerError.scoreFailed("XPC proxy unavailable"))
                return
            }
            proxy.rank(IPCCoder.encode(request)) { data in
                guard let reply = IPCCoder.decode(RankReply.self, from: data) else {
                    continuation.resume(throwing: RankerError.scoreFailed("Invalid XPC response"))
                    return
                }
                continuation.resume(returning: reply)
            }
        }
    } else {
        let ranker = try QwenRanker(modelURL: modelURL)
        ranked = try await ranker.rank(request)
    }
    if let error = ranked.error {
        throw RankerError.scoreFailed(error)
    }
    print("笔灵 · \(ranked.modelDescription) · \(String(format: "%.1f", ranked.latencyMilliseconds)) ms")
    for (index, text) in ranked.orderedCandidates.prefix(12).enumerated() {
        let backbone = result.candidates.first(where: { $0.text == text })
        print("\(index + 1). \(text)\tLM \(String(format: "%.3f", ranked.scores[text, default: 0]))\t\(backbone?.pinyin ?? "")")
    }
} catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
