import BackboneEngine
import CLlamaBridge
import Foundation
import IPCProtocol

public enum RankerError: LocalizedError {
    case modelMissing(URL)
    case loadFailed(String)
    case scoreFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelMissing(let url):
            "The required bundled Qwen model is missing at \(url.path)."
        case .loadFailed(let detail):
            "Could not load Qwen: \(detail)"
        case .scoreFailed(let detail):
            "Qwen scoring failed: \(detail)"
        }
    }
}

private final class LlamaHandle: @unchecked Sendable {
    let rawValue: OpaquePointer

    init(_ rawValue: OpaquePointer) {
        self.rawValue = rawValue
    }

    deinit {
        biling_llama_close(rawValue)
    }
}

public final class QwenRanker: @unchecked Sendable {
    private struct RequestKey: Hashable {
        let clientID: UUID
        let generation: UInt64
    }

    private let handle: LlamaHandle
    private let queue = DispatchQueue(label: "com.biling.qwen-ranker", qos: .userInitiated)
    private let stateLock = NSLock()
    private var pending: Set<RequestKey> = []
    private var cancelled: Set<RequestKey> = []
    private var active: RequestKey?
    public let modelDescription: String

    public init(modelURL: URL) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw RankerError.modelMissing(modelURL)
        }
        var error = [CChar](repeating: 0, count: 512)
        guard let loaded = biling_llama_open(modelURL.path, &error, error.count) else {
            throw RankerError.loadFailed(String(cString: error))
        }
        handle = LlamaHandle(loaded)
        modelDescription = String(cString: biling_llama_description(loaded))
    }

    public func rank(_ request: RankRequest) async throws -> RankReply {
        let requestKey = RequestKey(
            clientID: request.clientID,
            generation: request.generation
        )
        _ = stateLock.withLock {
            pending.insert(requestKey)
        }
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<RankReply, Error>) in
            queue.async { [self, handle, modelDescription] in
                let cancelledBeforeStart = stateLock.withLock {
                    pending.remove(requestKey)
                    if cancelled.remove(requestKey) != nil {
                        return true
                    }
                    active = requestKey
                    return false
                }
                guard !cancelledBeforeStart else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                defer {
                    stateLock.withLock {
                        if active == requestKey {
                            active = nil
                        }
                        cancelled.remove(requestKey)
                    }
                }
                let clock = ContinuousClock()
                let start = clock.now
                biling_llama_reset_cancel(handle.rawValue)
                // The first candidate page is the only latency-critical surface. Sixteen
                // paths cover the first page plus blending headroom; the KV prefix cache
                // and vectorized softmax keep the warm request well under 50 ms.
                let capped = Array(request.candidates.prefix(16))
                var values = [Float](repeating: -.infinity, count: capped.count)
                var error = [CChar](repeating: 0, count: 512)
                let result = capped.withCStringArray { candidatePointers in
                    request.committedContext.withCString { contextPointer in
                        biling_llama_score(
                            handle.rawValue,
                            contextPointer,
                            candidatePointers,
                            Int32(capped.count),
                            &values,
                            &error,
                            error.count
                        )
                    }
                }
                guard result == 0 else {
                    continuation.resume(throwing: RankerError.scoreFailed(String(cString: error)))
                    return
                }
                var scores: [String: Double] = [:]
                for (index, candidate) in capped.enumerated() {
                    scores[candidate] = Double(values[index])
                }
                let order = capped.sorted {
                    scores[$0, default: -.infinity] > scores[$1, default: -.infinity]
                }
                let elapsed = start.duration(to: clock.now)
                let milliseconds = Double(elapsed.components.seconds) * 1_000
                    + Double(elapsed.components.attoseconds) / 1e15
                continuation.resume(
                    returning: RankReply(
                        clientID: request.clientID,
                        generation: request.generation,
                        orderedCandidates: order,
                        scores: scores,
                        latencyMilliseconds: milliseconds,
                        modelDescription: modelDescription
                    )
                )
            }
        }
    }

    public func cancel(clientID: UUID, generation: UInt64) {
        let requestKey = RequestKey(clientID: clientID, generation: generation)
        let shouldSignal = stateLock.withLock {
            if pending.contains(requestKey) {
                cancelled.insert(requestKey)
            }
            return active == requestKey
        }
        if shouldSignal {
            biling_llama_cancel(handle.rawValue)
        }
    }
}

private extension Array where Element == String {
    func withCStringArray<R>(_ body: (UnsafePointer<UnsafePointer<CChar>?>) -> R) -> R {
        let mutableStorage = map { strdup($0) }
        defer { mutableStorage.forEach { free($0) } }
        let storage: [UnsafePointer<CChar>?] = mutableStorage.map { pointer in
            pointer.map { UnsafePointer<CChar>($0) }
        }
        return storage.withUnsafeBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}

public enum ModelLocator {
    public static let fileName = "qwen3-0.6b-base-q4_k_m.gguf"

    public static func bundledModelURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["BILING_MODEL_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("Models/\(fileName)"),
           FileManager.default.fileExists(atPath: resource.path) {
            return resource
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let development = executable
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Models/\(fileName)")
        if FileManager.default.fileExists(atPath: development.path) {
            return development
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Models/\(fileName)")
    }
}
