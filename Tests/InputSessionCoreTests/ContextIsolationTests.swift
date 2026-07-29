import InputSessionCore
import Testing

/// Phase 11 audit: context must never cross an app/field boundary, and an
/// asynchronous reply must never apply to a composition it was not computed
/// for — neither a later generation nor a different buffer.
@Suite("Context isolation")
struct ContextIsolationTests {
    // MARK: (a) App/field switches reset the committed context

    @Test("Switching clients clears the committed context")
    func clientSwitchClearsContext() {
        var context = CommittedContext()
        context.append("这句话属于第一个应用")
        #expect(!context.text.isEmpty)
        // deactivateServer fires on an app or field switch; nothing typed in
        // the first client may influence rankings in the second.
        context.clientChanged()
        #expect(context.text.isEmpty)
        context.append("第二个应用")
        #expect(context.text == "第二个应用")
    }

    @Test("The context window trims with hysteresis")
    func contextTrimsWithHysteresis() {
        var context = CommittedContext(maximumLength: 8, trimmedLength: 4)
        context.append("一二三四五六七")
        // Below the maximum: untouched, so the KV prefix stays stable.
        #expect(context.text == "一二三四五六七")
        context.append("八九")
        // Above it: cut to the trimmed suffix in one step, not per commit.
        #expect(context.text == "六七八九")
    }

    // MARK: (b) Stale generations are ignored

    @Test("A reply for generation N is ignored once state advanced to N+1")
    func staleGenerationIsRejected() {
        // The user typed another key: generation moved from 6 to 7 and the
        // buffer grew. The in-flight reply for generation 6 must be dropped.
        let current = CompositionStamp(generation: 7, buffer: "nihao")
        #expect(
            !AsyncReplyGate.shouldApply(
                replyGeneration: 6,
                requestBuffer: "niha",
                current: current
            )
        )
        // Even a stale generation that somehow carries the current buffer is
        // still stale.
        #expect(
            !AsyncReplyGate.shouldApply(
                replyGeneration: 6,
                requestBuffer: "nihao",
                current: current
            )
        )
        // The reply actually issued for this state applies.
        #expect(
            AsyncReplyGate.shouldApply(
                replyGeneration: 7,
                requestBuffer: "nihao",
                current: current
            )
        )
    }

    // MARK: (c) Per-composition identity

    @Test("A reply for a previous buffer cannot apply even if generations collide")
    func bufferMismatchIsRejectedOnGenerationCollision() {
        // Hypothetical collision after a reset: the counters match but the
        // reply was computed for a different composition's text. The buffer
        // check makes the identity structural instead of temporal.
        let current = CompositionStamp(generation: 3, buffer: "women")
        #expect(
            !AsyncReplyGate.shouldApply(
                replyGeneration: 3,
                requestBuffer: "nihao",
                current: current
            )
        )
        #expect(
            AsyncReplyGate.shouldApply(
                replyGeneration: 3,
                requestBuffer: "women",
                current: current
            )
        )
    }
}
