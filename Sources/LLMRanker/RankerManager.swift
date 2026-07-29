import Foundation
import os

/// Owns the Qwen instance with a lazy-load / idle-unload lifecycle and a
/// fail-closed load policy.
///
/// The daemon starts at login, but weights are mapped only when the first
/// ranking request arrives and are released again after ten minutes without
/// requests. Idle cost is a few megabytes; reloading from the mmap'd GGUF on
/// the next keystroke takes well under a second, during which the input
/// method's deterministic candidates remain fully usable.
///
/// Load failures are terminal for the session: a GGUF that is missing,
/// corrupt, or too large to map will not become loadable by retrying on
/// every keystroke, so the first bundled-model failure disables the ranker
/// permanently (logged once via os_log) and every later call fails fast
/// without touching the file system. A broken *personal* model falls back to
/// the bundled model once and is not retried either.
public final class RankerManager: @unchecked Sendable {
    private let modelURL: URL
    private let personalModelProvider: @Sendable () -> URL?
    private let timeoutMilliseconds: Int?
    private let lock = NSLock()
    private var ranker: QwenRanker?
    private var usingPersonalModel = false
    private var personalModelBroken = false
    private var disabledReason: String?
    private var lastUse = ContinuousClock.now
    private var lastLoadError: String?
    private let idleTimer: DispatchSourceTimer
    /// Number of QwenRanker load attempts, for tests asserting that a failed
    /// load is never retried.
    private(set) var loadAttemptCount = 0

    private static let logger = Logger(
        subsystem: "com.biling.inputmethod.engine",
        category: "ranker"
    )
    private static let idleUnloadAfter: Duration = .seconds(600)

    public init(
        modelURL: URL,
        personalModelProvider: @escaping @Sendable () -> URL? = { ModelLocator.personalModelURL() },
        timeoutMilliseconds: Int? = nil
    ) {
        self.modelURL = modelURL
        self.personalModelProvider = personalModelProvider
        self.timeoutMilliseconds = timeoutMilliseconds
        idleTimer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "com.biling.engine-idle", qos: .utility)
        )
        idleTimer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
        idleTimer.setEventHandler { [weak self] in
            self?.unloadIfIdle()
        }
        idleTimer.resume()
    }

    deinit {
        idleTimer.cancel()
    }

    public var isPermanentlyDisabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return disabledReason != nil
    }

    public func currentRanker() throws -> QwenRanker {
        lock.lock()
        defer { lock.unlock() }
        if let disabledReason {
            throw RankerError.permanentlyDisabled(disabledReason)
        }
        lastUse = .now
        if let ranker {
            return ranker
        }
        // Personal model first, re-resolved on every load so a model trained
        // five minutes ago is picked up at the next lazy load without a
        // reinstall. If it is broken it must never take typing enhancement
        // down while a valid bundled model exists: log once, fall back, and
        // stop retrying it for this session.
        if !personalModelBroken, let personalURL = personalModelProvider() {
            loadAttemptCount += 1
            do {
                let loaded = try QwenRanker(
                    modelURL: personalURL,
                    adapterURL: ModelLocator.adapterURL(),
                    adapterScale: ModelLocator.adapterScale(),
                    timeoutMilliseconds: timeoutMilliseconds
                )
                usingPersonalModel = true
                ranker = loaded
                lastLoadError = nil
                return loaded
            } catch {
                personalModelBroken = true
                Self.logger.error(
                    "Personal Qwen model failed to load; falling back to the bundled model for this session: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        loadAttemptCount += 1
        do {
            let loaded = try QwenRanker(
                modelURL: modelURL,
                adapterURL: ModelLocator.adapterURL(),
                adapterScale: ModelLocator.adapterScale(),
                timeoutMilliseconds: timeoutMilliseconds
            )
            usingPersonalModel = false
            ranker = loaded
            lastLoadError = nil
            return loaded
        } catch {
            let reason = error.localizedDescription
            disabledReason = reason
            lastLoadError = reason
            Self.logger.fault(
                "Qwen model failed to load; LLM re-ranking is disabled for this session, deterministic ranking continues: \(reason, privacy: .public)"
            )
            throw RankerError.permanentlyDisabled(reason)
        }
    }

    public func cancel(clientID: UUID, generation: UInt64) {
        lock.lock()
        let active = ranker
        lock.unlock()
        active?.cancel(clientID: clientID, generation: generation)
    }

    public func statusLine() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let disabledReason {
            return "error|已停用：\(disabledReason)"
        }
        if let ranker {
            let marker = usingPersonalModel ? " · 个人模型" : ""
            return "ready|\(ranker.modelDescription)\(marker)"
        }
        if let lastLoadError {
            return "error|\(lastLoadError)"
        }
        return "ready|Qwen 待机中，首次输入时加载"
    }

    public func modelDescription() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let ranker else { return "Qwen3-0.6B-Base（待机）" }
        return ranker.modelDescription + (usingPersonalModel ? " · 个人模型" : "")
    }

    private func unloadIfIdle() {
        lock.lock()
        defer { lock.unlock() }
        guard ranker != nil, ContinuousClock.now - lastUse > Self.idleUnloadAfter else { return }
        ranker = nil
        Self.logger.info("Released idle Qwen instance")
    }
}
