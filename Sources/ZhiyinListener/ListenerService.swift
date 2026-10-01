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
    public let vocabularyPath: String
    public var config: Ziqi.Config
    /// Release the model after this long without a request.
    public var idleRelease: TimeInterval = 15 * 60

    private let queue = DispatchQueue(label: "com.zhiyin.ziqi", qos: .userInteractive)
    private let latest = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    private let stateLock = OSAllocatedUnfairLock<State>(initialState: .resting)
    private var ziqi: Ziqi?
    private var releaseWork: DispatchWorkItem?
    private var failures = 0

    public var onStateChange: (@Sendable (State) -> Void)?

    public init(modelPath: String, vocabularyPath: String, config: Ziqi.Config = Ziqi.Config()) {
        self.modelPath = modelPath
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
            let z = try Ziqi(modelPath: modelPath, vocabularyPath: vocabularyPath, config: config)
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
        generation: UInt64,
        completion: @escaping @Sendable (Heard?, Ziqi.Answer?) -> Void
    ) {
        latest.withLock { $0 = max($0, generation) }
        queue.async { [self] in
            let isCurrent = { self.latest.withLock { $0 } == generation }
            guard isCurrent(), let z = ensureLoaded() else {
                DispatchQueue.main.async { completion(nil, nil) }
                return
            }
            z.config = config
            let answer = z.listen(context: context, keys: keys) { !isCurrent() }
            scheduleRelease()
            let heard = answer.map { a in
                Heard(
                    keys: keys,
                    readings: a.results.map { Heard.Reading(text: $0.text, logp: $0.logp) },
                    leads: a.leads.map { Heard.Lead(text: $0.text, end: $0.end, logp: $0.logp) }
                )
            }
            DispatchQueue.main.async { completion(heard, answer) }
        }
    }

    /// Synchronous variant for tools and tests.
    public func listenNow(context: String, keys: String) -> Ziqi.Answer? {
        queue.sync { ensureLoaded()?.listen(context: context, keys: keys) }
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

    /// Release now (memory pressure, or the user turned 子期 off).
    public func release() {
        queue.async { [self] in
            releaseWork?.cancel()
            ziqi = nil
            setState(.resting)
        }
    }
}
