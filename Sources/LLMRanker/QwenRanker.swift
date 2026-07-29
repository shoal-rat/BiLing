import BackboneEngine
import CLlamaBridge
import Foundation
import IPCProtocol

public enum RankerError: LocalizedError {
    case modelMissing(URL)
    case loadFailed(String)
    case scoreFailed(String)
    case permanentlyDisabled(String)

    public var errorDescription: String? {
        switch self {
        case .modelMissing(let url):
            "The required bundled Qwen model is missing at \(url.path)."
        case .loadFailed(let detail):
            "Could not load Qwen: \(detail)"
        case .scoreFailed(let detail):
            "Qwen scoring failed: \(detail)"
        case .permanentlyDisabled(let detail):
            "Qwen 已停用（本次会话）: \(detail)"
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

    /// C bridge result codes (mirrors BILING_LLAMA_* in BiLingLlama.h).
    private static let resultCancelled: Int32 = -2
    private static let resultTimedOut: Int32 = -8

    private let handle: LlamaHandle
    private let queue = DispatchQueue(label: "com.biling.qwen-ranker", qos: .userInitiated)
    private let stateLock = NSLock()
    private var pending: Set<RequestKey> = []
    private var cancelled: Set<RequestKey> = []
    private var active: RequestKey?
    private let timeoutMilliseconds: Int
    public let modelDescription: String

    /// Wall-clock budget for one scoring call, from BILING_MODEL_TIMEOUT_MS
    /// (milliseconds, > 0) with a 2500 ms default.
    public static func defaultTimeoutMilliseconds(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard let raw = environment["BILING_MODEL_TIMEOUT_MS"],
              let value = Int(raw), value > 0 else {
            return EngineConfig.shared.modelTimeoutMilliseconds
        }
        return value
    }

    public init(
        modelURL: URL,
        adapterURL: URL? = nil,
        adapterScale: Float = 1.0,
        timeoutMilliseconds: Int? = nil
    ) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw RankerError.modelMissing(modelURL)
        }
        self.timeoutMilliseconds = timeoutMilliseconds ?? Self.defaultTimeoutMilliseconds()
        var error = [CChar](repeating: 0, count: 512)
        guard let loaded = biling_llama_open(
            modelURL.path,
            adapterURL?.path,
            adapterScale,
            &error,
            error.count
        ) else {
            throw RankerError.loadFailed(String(cString: error))
        }
        handle = LlamaHandle(loaded)
        modelDescription = String(cString: biling_llama_description(loaded))
    }

    /// Scores the request's candidates against its committed context.
    ///
    /// Returns nil when the wall-clock budget expired: the caller ships the
    /// deterministic ranking as-is. Throws CancellationError when the request
    /// was superseded by a newer generation (via `cancel` or by a newer
    /// `rank` call for the same client), and RankerError for real failures.
    public func rank(_ request: RankRequest) async throws -> RankReply? {
        let requestKey = RequestKey(
            clientID: request.clientID,
            generation: request.generation
        )
        stateLock.withLock {
            pending.insert(requestKey)
            // A newer generation supersedes every older request of the same
            // client: stale work must stop burning energy, not run to
            // completion. The C cancel is signalled under the lock so it can
            // never race the next request's reset (which also happens under
            // the lock).
            for key in pending
            where key.clientID == requestKey.clientID && key.generation < requestKey.generation {
                cancelled.insert(key)
            }
            if let current = active,
               current.clientID == requestKey.clientID,
               current.generation < requestKey.generation {
                biling_llama_cancel(handle.rawValue)
            }
        }
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<RankReply?, Error>) in
            queue.async { [self, handle, modelDescription, timeoutMilliseconds] in
                let cancelledBeforeStart = stateLock.withLock {
                    pending.remove(requestKey)
                    if cancelled.remove(requestKey) != nil {
                        return true
                    }
                    active = requestKey
                    // Reset under the same lock that `cancel` signals under,
                    // so a cancel aimed at the previous request can never
                    // leak into this one.
                    biling_llama_reset_cancel(handle.rawValue)
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
                            timeoutMilliseconds,
                            &values,
                            &error,
                            error.count
                        )
                    }
                }
                switch result {
                case 0:
                    break
                case Self.resultCancelled:
                    continuation.resume(throwing: CancellationError())
                    return
                case Self.resultTimedOut:
                    // The deterministic ranking ships as-is; the model simply
                    // has no opinion this keystroke.
                    continuation.resume(returning: nil)
                    return
                default:
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

    /// Cancels the given request and anything older from the same client.
    /// Signalling the C flag happens under the state lock, paired with the
    /// worker's reset-under-lock, so a late cancel can never abort a newer
    /// request that has already started.
    public func cancel(clientID: UUID, generation: UInt64) {
        stateLock.withLock {
            for key in pending
            where key.clientID == clientID && key.generation <= generation {
                cancelled.insert(key)
            }
            if let current = active,
               current.clientID == clientID,
               current.generation <= generation {
                biling_llama_cancel(handle.rawValue)
            }
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

    /// A personal LoRA adapter, if the user trained one. Checked on every
    /// (lazy) model load, so a freshly trained adapter is picked up on the
    /// next load — at the latest after the daemon's idle unload — without
    /// reinstalling anything. `BILING_LORA_PATH=""` disables it.
    public static func adapterURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["BILING_LORA_PATH"] {
            return override.isEmpty ? nil : URL(fileURLWithPath: override)
        }
        let candidate = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BiLing/adapters/qwen-lora.gguf")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    public static func adapterScale() -> Float {
        guard let raw = ProcessInfo.processInfo.environment["BILING_LORA_SCALE"],
              let value = Float(raw), value > 0 else { return 1.0 }
        return value
    }

    /// The LoRA-personalized full model produced by scripts/train_lora.sh
    /// (mlx-lm fuse → llama-quantize). Preferred over the bundled model when
    /// present; `BILING_PERSONAL_MODEL=0` ignores it without deleting it.
    public static func personalModelURL() -> URL? {
        if ProcessInfo.processInfo.environment["BILING_PERSONAL_MODEL"] == "0" {
            return nil
        }
        let candidate = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BiLing/adapters/qwen-personal-q4_k_m.gguf")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

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
