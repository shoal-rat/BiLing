import Foundation

/// Keeps the visible candidate list still while asynchronous rescoring runs
/// underneath it.
///
/// The engine is deterministic and immediate, but the Qwen reranker replies
/// later, with a generation counter; when its reply lands, the list the user
/// is already reading can reorder under their eyes. This component decides,
/// purely and deterministically, what may actually change on screen. It owns
/// no timers and no queues: callers hand it the currently shown list and the
/// incoming proposed list, and it returns the list to show.
///
/// Rules, in the order they are applied:
///
/// 1. **Manual interaction locks the order** (`noteUserNavigation`). Once the
///    user has moved the selection or paged within the current composition
///    state, an asynchronous rescoring may not reorder what is displayed;
///    new candidates may only append at the end.
/// 2. **Negligible-gain suppression** (`negligibleGainThreshold`, default
///    0.5 nats). An asynchronous update may only move a candidate above
///    another if its score exceeds the other's by at least the threshold.
///    Realised moves are composed of adjacent swaps that each clear the
///    threshold, so a candidate never climbs past one it beats only barely —
///    order changes the user can actually perceive as *better* survive,
///    cosmetic ones do not.
/// 3. **Oscillation damping** (`repromotionMargin`, default 2.0 nats). A
///    candidate that already held rank 1 in this composition and lost it is
///    not promoted back to rank 1 unless it now beats every alternative by
///    the margin. This stops rank 1 from flapping A→B→A while deterministic
///    and model rankings disagree.
/// 4. **Keystroke reset**. A buffer change is a new composition state: the
///    interaction lock clears and the freshly decoded list is accepted as
///    proposed (rules 1–2 do not constrain it). Only rule 3's demotion
///    memory survives keystrokes — and it, too, forgets judgements made at
///    prefixes the buffer has since backspaced away — until the composition
///    ends (`compositionEnded`), which clears everything.
public struct CandidateStabilityController: Sendable {
    public struct Parameters: Sendable {
        /// Minimum score improvement, in nats, before an asynchronous update
        /// may lift one displayed candidate above another. Below this the
        /// reranker's preference is treated as noise and the displayed order
        /// is kept. Default 0.5 nats (≈ e^0.5 ≈ 1.6× probability ratio).
        public var negligibleGainThreshold: Double

        /// Minimum lead, in nats, over every other candidate before a
        /// candidate that was demoted from rank 1 within this composition may
        /// take rank 1 again. Default 2.0 nats (≈ 7.4× probability ratio).
        public var repromotionMargin: Double

        public init(
            negligibleGainThreshold: Double = 0.5,
            repromotionMargin: Double = 2.0
        ) {
            self.negligibleGainThreshold = negligibleGainThreshold
            self.repromotionMargin = repromotionMargin
        }
    }

    /// What kind of update the proposed list is.
    public enum Update: Sendable {
        /// The deterministic result for a changed buffer. Resets the
        /// per-state constraints (rule 4) before being shown.
        case keystroke
        /// An asynchronous rescoring of the *same* buffer, arriving after a
        /// list is already on screen. Subject to rules 1–3.
        case asyncRescore
    }

    /// When false the controller is a pure pass-through: `resolve` returns
    /// the proposed list untouched and no memory is kept. Exists so the
    /// replay harness can A/B the exact same input stream.
    public let isEnabled: Bool

    public let parameters: Parameters

    private var buffer = ""
    private var userHasNavigated = false
    /// Candidate identity → the buffer at the moment it lost rank 1.
    private var demotedFromTop: [String: String] = [:]

    public init(enabled: Bool = true, parameters: Parameters = Parameters()) {
        self.isEnabled = enabled
        self.parameters = parameters
    }

    /// The composition buffer changed (letter appended or deleted). Clears
    /// the interaction lock; keeps rule 3's demotion memory, minus any
    /// entries recorded at prefixes that no longer lead to the new buffer.
    public mutating func keystroke(buffer newBuffer: String) {
        guard isEnabled else { return }
        if !newBuffer.hasPrefix(buffer) {
            // The user backspaced (or the buffer diverged): demotions decided
            // while looking at a longer input were judgements about *that*
            // input and must not veto the shorter one's natural top choice.
            demotedFromTop = demotedFromTop.filter { newBuffer.hasPrefix($0.value) }
        }
        buffer = newBuffer
        userHasNavigated = false
    }

    /// The user moved the selection or changed page in the current list.
    public mutating func noteUserNavigation() {
        guard isEnabled else { return }
        userHasNavigated = true
    }

    /// The composition ended (commit or cancel). Clears all memory,
    /// including rule 3's.
    public mutating func compositionEnded() {
        buffer = ""
        userHasNavigated = false
        demotedFromTop = [:]
    }

    /// The reducer: given the list currently on screen and an incoming
    /// proposal, returns the list to show. `id` must be a stable identity
    /// (the candidate text) and `score` its current log-domain score in nats.
    public mutating func resolve<C>(
        shown: [C],
        proposed: [C],
        update: Update,
        id: (C) -> String,
        score: (C) -> Double
    ) -> [C] {
        guard isEnabled else { return proposed }

        let shownTopID = shown.first.map(id)
        var result: [C]

        switch update {
        case .keystroke:
            // Rule 4: a new buffer means a new list; only rule 3 below
            // constrains it.
            result = proposed
        case .asyncRescore where userHasNavigated:
            // Rule 1: the user is pointing at this list. Keep every displayed
            // candidate exactly where it is (taking refreshed metadata for
            // ones the proposal still contains) and append the rest.
            result = appendOnlyMerge(shown: shown, proposed: proposed, id: id)
        case .asyncRescore:
            // Rule 2: displayed order is the baseline; the proposal's scores
            // may only move a candidate up past neighbours it beats by the
            // threshold.
            result = thresholdMerge(shown: shown, proposed: proposed, id: id, score: score)
        }

        applyOscillationDamping(to: &result, shownTopID: shownTopID, id: id, score: score)
        recordTopTransition(from: shownTopID, in: result, id: id)
        return result
    }

    // MARK: - Rule 1

    private func appendOnlyMerge<C>(
        shown: [C],
        proposed: [C],
        id: (C) -> String
    ) -> [C] {
        var freshByID: [String: C] = [:]
        for candidate in proposed where freshByID[id(candidate)] == nil {
            freshByID[id(candidate)] = candidate
        }
        var result = shown.map { freshByID.removeValue(forKey: id($0)) ?? $0 }
        for candidate in proposed {
            if freshByID.removeValue(forKey: id(candidate)) != nil {
                result.append(candidate)
            }
        }
        return result
    }

    // MARK: - Rule 2

    private func thresholdMerge<C>(
        shown: [C],
        proposed: [C],
        id: (C) -> String,
        score: (C) -> Double
    ) -> [C] {
        // Base order: the displayed candidates first (carrying the proposal's
        // fresh scores where available; a candidate the proposal dropped
        // keeps its place and its old score rather than vanishing mid-read),
        // then genuinely new candidates in the proposal's own order.
        var firstIndexByID: [String: Int] = [:]
        for (index, candidate) in proposed.enumerated() where firstIndexByID[id(candidate)] == nil {
            firstIndexByID[id(candidate)] = index
        }
        var base: [C] = []
        for candidate in shown {
            if let index = firstIndexByID.removeValue(forKey: id(candidate)) {
                base.append(proposed[index])
            } else {
                base.append(candidate)
            }
        }
        for (index, candidate) in proposed.enumerated()
        where firstIndexByID[id(candidate)] == index {
            base.append(candidate)
        }

        // Bubble to a fixpoint where no adjacent pair violates the
        // threshold. Every swap strictly reduces score-order inversions, so
        // this terminates; the result is deterministic in the base order.
        var swapped = true
        while swapped {
            swapped = false
            guard base.count > 1 else { break }
            for index in 0..<(base.count - 1)
            where score(base[index + 1]) - score(base[index])
                >= parameters.negligibleGainThreshold {
                base.swapAt(index, index + 1)
                swapped = true
            }
        }
        return base
    }

    // MARK: - Rule 3

    private func applyOscillationDamping<C>(
        to result: inout [C],
        shownTopID: String?,
        id: (C) -> String,
        score: (C) -> Double
    ) {
        guard result.count >= 2, let electedTop = result.first else { return }
        let electedID = id(electedTop)
        // The reigning top staying on top is never an oscillation.
        guard electedID != shownTopID, demotedFromTop[electedID] != nil else { return }
        let bestOther = result.dropFirst().map(score).max() ?? -.infinity
        guard score(electedTop) - bestOther < parameters.repromotionMargin else { return }

        // Blocked: promote the first candidate with a clean claim instead —
        // the current top or one never demoted — leaving relative order of
        // the rest untouched. If every candidate has been demoted before,
        // damping would just thrash; accept the proposal.
        let eligible = result.dropFirst().firstIndex { candidate in
            id(candidate) == shownTopID || demotedFromTop[id(candidate)] == nil
        }
        if let index = eligible {
            let promoted = result.remove(at: index)
            result.insert(promoted, at: 0)
        }
    }

    private mutating func recordTopTransition<C>(
        from shownTopID: String?,
        in result: [C],
        id: (C) -> String
    ) {
        guard let newTopID = result.first.map(id) else { return }
        if let shownTopID, shownTopID != newTopID {
            demotedFromTop[shownTopID] = buffer
        }
        // Holding rank 1 again clears the mark: the next demotion is a fresh
        // event, not a lingering veto.
        demotedFromTop.removeValue(forKey: newTopID)
    }
}
