import Foundation
import os
import ZhiyinCore

/// Keeps 子期 on one serial queue and decides when it should listen at all.
///
/// * Every request carries a generation; a newer keystroke cancels older
///   searches between decode steps, so stale work is bounded to one step.
/// * The model loads on first use and is released after a quiet spell — a
///   single one-shot timer, rescheduled per request; no polling, ever.
public final class ListenerService: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        /// Not loaded; will load on the next keystroke. (子期小憩)
        case resting
        /// Loading the model. (子期将至)
        case arriving
        /// Ready. (子期在听)
        case listening
        /// Could not load; the score (琴谱) plays alone. (独奏)
        case absent(String)
    }

    public let modelPath: String
    public let adapterPath: String?
    public let vocabularyPath: String
    public var config: Ziqi.Config?
    /// Release the model after this long without a request.
    public var idleRelease: TimeInterval = 15 * 60

    private let queue = DispatchQueue(label: "com.zhiyin.ziqi", qos: .userInteractive)
    private let latest = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private let stateLock = OSAllocatedUnfairLock<State>(initialState: .resting)
    private var ziqi: Ziqi?
    private var releaseWork: DispatchWorkItem?
    private var failures = 0

    public var onStateChange: (@Sendable (State) -> Void)?

    /// The latest finished answer, for a commit that cannot wait for the
    /// main-queue completion (see awaitAnswer).
    private let lastAnswer = OSAllocatedUnfairLock<(UInt64, Heard)?>(initialState: nil)
    private let inFlight = DispatchGroup()

    public init(modelPath: String, adapterPath: String?, vocabularyPath: String, config: Ziqi.Config? = nil) {
        self.modelPath = modelPath
        self.adapterPath = adapterPath
        self.vocabularyPath = vocabularyPath
        self.config = config
    }

    public var state: State { stateLock.withLock { $0 } }

    private func setState(_ s: State) {
        let changed = stateLock.withLock { current -> Bool in
            guard current != s else { return false }
            current = s
            return true
        }
        if changed { onStateChange?(s) }
    }

    /// Supersedes any search in flight without starting a new one.
    public func cancel(through generation: UInt64) {
        latest.withLock { $0 = max($0, generation) }
    }

    public func preload() {
        queue.async { [self] in _ = ensureLoaded() }
    }

    private func ensureLoaded() -> Ziqi? {
        if let ziqi { return ziqi }
        if case .absent = state, failures >= 3 { return nil }
        setState(.arriving)
        do {
            let z = try Ziqi(modelPath: modelPath, adapterPath: adapterPath, vocabularyPath: vocabularyPath, config: config)
            ziqi = z
            failures = 0
            setState(.listening)
            return z
        } catch {
            failures += 1
            setState(.absent("\(error)"))
            return nil
        }
    }

    /// Listens to `keys` after `context`. `completion` runs on the main queue
    /// with nil when superseded, cancelled or unavailable.
    public func listen(
        context: String,
        keys: String,
        rescue: [String] = [],
        generation: UInt64,
        completion: @escaping @Sendable (Heard?, Ziqi.Answer?) -> Void
    ) {
        latest.withLock { $0 = max($0, generation) }
        inFlight.enter()
        queue.async { [self] in
            defer { inFlight.leave() }
            let isCurrent = { self.latest.withLock { $0 } == generation }
            guard isCurrent(), let z = ensureLoaded() else {
                DispatchQueue.main.async { completion(nil, nil) }
                return
            }
            if let config { z.config = config }
            let answer = z.listen(context: context, keys: keys, rescue: rescue) { !isCurrent() }
            scheduleRelease()
            let heard = answer.map { a in
                Heard(
                    keys: keys,
                    readings: a.results.map { Heard.Reading(text: $0.text, logp: $0.logp) },
                    leads: a.leads.map { Heard.Lead(text: $0.text, end: $0.end, logp: $0.logp) }
                )
            }
            if let heard { lastAnswer.withLock { $0 = (generation, heard) } }
            DispatchQueue.main.async { completion(heard, answer) }
        }
    }

    /// Waits (at most `timeout`) for the search of `generation` to finish and
    /// returns its answer. For a commit made before 子期 has spoken: a short
    /// wait beats committing 琴谱's guess.
    public func awaitAnswer(generation: UInt64, timeout: TimeInterval) -> Heard? {
        if let hit = lastAnswer.withLock({ $0 }), hit.0 == generation { return hit.1 }
        _ = inFlight.wait(timeout: .now() + timeout)
        guard let hit = lastAnswer.withLock({ $0 }), hit.0 == generation else { return nil }
        return hit.1
    }

    /// Synchronous variant for tools and tests.
    public func listenNow(context: String, keys: String, rescue: [String] = []) -> Ziqi.Answer? {
        queue.sync { ensureLoaded()?.listen(context: context, keys: keys, rescue: rescue) }
    }

    private func scheduleRelease() {
        releaseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.ziqi = nil
            self.setState(.resting)
        }
        releaseWork = work
        queue.asyncAfter(deadline: .now() + idleRelease, execute: work)
    }

    /// Release synchronously (before the process exits: ggml's Metal device
    /// asserts if a model is still resident when static destructors run).
    public func releaseNow() {
        queue.sync {
            releaseWork?.cancel()
            ziqi = nil
            setState(.resting)
        }
    }

    /// Release now (memory pressure, or the user turned 子期 off).
    public func release() {
        queue.async { [self] in
            releaseWork?.cancel()
            ziqi = nil
            setState(.resting)
        }
    }
}
