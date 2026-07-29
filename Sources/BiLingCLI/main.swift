import BackboneEngine
import Foundation
import IPCProtocol
import LLMRanker

func usage() -> Never {
    print("""
    Usage: biling-cli [--xpc | --engine-only] [--fuzzy] [--model path] [--adapter path] \
    [--context text] PINYIN
           biling-cli --export-training-data DIR
    """)
    exit(64)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var modelURL = ModelLocator.personalModelURL() ?? ModelLocator.bundledModelURL()
var adapterURL = ModelLocator.adapterURL()
var context = ""
var pinyin: String?
var useXPC = false
var noContext = false
var engineOnly = false
var fuzzy = false
var evaluateCorpus: URL?
var dumpFeaturesCorpus: URL?
var replayCorpus: URL?
var replayLimit = 50
var exportDirectory: String?
var learningExportPath: String?
var forgetLearnedID: Int64?
while !arguments.isEmpty {
    let item = arguments.removeFirst()
    switch item {
    case "--xpc":
        useXPC = true
    case "--no-context":
        noContext = true
    case "--engine-only":
        engineOnly = true
    case "--replay":
        guard !arguments.isEmpty else { usage() }
        replayCorpus = URL(fileURLWithPath: arguments.removeFirst())
    case "--replay-limit":
        guard !arguments.isEmpty else { usage() }
        replayLimit = Int(arguments.removeFirst()) ?? 50
    case "--dump-features":
        guard !arguments.isEmpty else { usage() }
        dumpFeaturesCorpus = URL(fileURLWithPath: arguments.removeFirst())
    case "--fuzzy":
        fuzzy = true
    case "--evaluate":
        guard !arguments.isEmpty else { usage() }
        evaluateCorpus = URL(fileURLWithPath: arguments.removeFirst())
    case "--model":
        guard !arguments.isEmpty else { usage() }
        modelURL = URL(fileURLWithPath: arguments.removeFirst())
    case "--adapter":
        guard !arguments.isEmpty else { usage() }
        adapterURL = URL(fileURLWithPath: arguments.removeFirst())
    case "--context":
        guard !arguments.isEmpty else { usage() }
        context = arguments.removeFirst()
    case "--export-training-data":
        guard !arguments.isEmpty else { usage() }
        exportDirectory = arguments.removeFirst()
    case "--export-learning":
        guard !arguments.isEmpty else { usage() }
        learningExportPath = arguments.removeFirst()
    case "--forget-learned":
        guard !arguments.isEmpty else { usage() }
        forgetLearnedID = Int64(arguments.removeFirst())
    default:
        pinyin = item
    }
}

// Data-ownership commands operate on the real store (Keychain consent is the
// user's to give — macOS will ask on first access from this binary).
if learningExportPath != nil || forgetLearnedID != nil {
    do {
        let engine = try PinyinEngine.production()
        if let forgetLearnedID {
            engine.learningStore.deleteItem(id: forgetLearnedID)
            print("Removed learned entry \(forgetLearnedID)")
        }
        if let learningExportPath {
            let data = try engine.learningStore.exportData()
            try data.write(to: URL(fileURLWithPath: learningExportPath))
            print("Learning data exported to \(learningExportPath)")
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Learning-store access failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

if let exportDirectory {
    do {
        let count = try TrainingDataExporter.export(to: URL(fileURLWithPath: exportDirectory, isDirectory: true))
        print("Exported \(count) learned selections to \(exportDirectory)/train.jsonl and valid.jsonl")
        exit(count > 0 ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("Export failed: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

EnglishLexicon.shared.warm()

if let dumpFeaturesCorpus {
    do {
        let teacher = engineOnly ? nil : try QwenRanker(modelURL: modelURL)
        try Evaluate.dumpFeatures(corpus: dumpFeaturesCorpus, useContext: !noContext, teacher: teacher)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

if let replayCorpus {
    do {
        let ranker = engineOnly ? nil : try QwenRanker(modelURL: modelURL)
        try ReplayBenchmark.run(
            corpus: replayCorpus,
            limit: replayLimit,
            ranker: ranker,
            useContext: !noContext
        )
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

if let evaluateCorpus {
    do {
        let ranker = engineOnly ? nil : try QwenRanker(modelURL: modelURL)
        try Evaluate.run(
            corpus: evaluateCorpus,
            ranker: ranker,
            useContext: !noContext,
            tolerance: fuzzy ? .all : .off
        )
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

guard let pinyin else { usage() }

do {
    let engine = try PinyinEngine(
        dictionary: .bundled(),
        learningStore: MemoryLearningStore(),
        tolerance: fuzzy ? .all : .off
    )
    let clock = ContinuousClock()
    let engineStart = clock.now
    let result = engine.candidates(for: pinyin, context: context, generation: 1)
    let engineElapsed = engineStart.duration(to: clock.now)
    let engineMilliseconds = Double(engineElapsed.components.seconds) * 1_000
        + Double(engineElapsed.components.attoseconds) / 1e15

    if engineOnly {
        print("笔灵 · 词典引擎 · \(String(format: "%.1f", engineMilliseconds)) ms")
        for (index, candidate) in result.candidates.prefix(12).enumerated() {
            print("\(index + 1). \(candidate.text)\t\(candidate.source.rawValue)\t\(candidate.pinyin)")
        }
        exit(0)
    }

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
        let ranker = try QwenRanker(
            modelURL: modelURL,
            adapterURL: adapterURL,
            adapterScale: ModelLocator.adapterScale()
        )
        guard let reply = try await ranker.rank(request) else {
            throw RankerError.scoreFailed("Qwen 超时（BILING_MODEL_TIMEOUT_MS 可调整预算）")
        }
        ranked = reply
    }
    if let error = ranked.error {
        throw RankerError.scoreFailed(error)
    }
    // Blend with the same function the input method uses, so this output is
    // the ranking a user would actually see.
    let blended = CandidateBlender.blend(
        result.candidates,
        orderedCandidates: ranked.orderedCandidates,
        scores: ranked.scores,
        hasContext: !context.isEmpty
    )
    print("笔灵 · \(ranked.modelDescription) · \(String(format: "%.1f", ranked.latencyMilliseconds)) ms")
    for (index, candidate) in blended.prefix(12).enumerated() {
        let lm = ranked.scores[candidate.text].map { String(format: "%.3f", $0) } ?? "—"
        print("\(index + 1). \(candidate.text)\tLM \(lm)\t\(candidate.pinyin)")
    }
} catch {
    FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
