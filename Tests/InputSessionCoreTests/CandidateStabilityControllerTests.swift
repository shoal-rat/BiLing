import InputSessionCore
import Testing

/// A minimal stand-in for the engine's candidate type: an identity and a
/// log-domain score in nats.
private struct Entry: Equatable {
    let text: String
    let score: Double
}

private func resolve(
    _ controller: inout CandidateStabilityController,
    shown: [Entry],
    proposed: [Entry],
    update: CandidateStabilityController.Update
) -> [Entry] {
    controller.resolve(
        shown: shown,
        proposed: proposed,
        update: update,
        id: \.text,
        score: \.score
    )
}

@Suite("Candidate stability controller")
struct CandidateStabilityControllerTests {
    // MARK: Rule 1 — manual interaction locks the order

    @Test("After navigation an async rescore may only append")
    func navigationLocksOrder() {
        var controller = CandidateStabilityController()
        controller.keystroke(buffer: "nihao")
        let shown = [
            Entry(text: "你好", score: 5),
            Entry(text: "尼豪", score: 4),
            Entry(text: "泥壕", score: 3),
        ]
        controller.noteUserNavigation()
        // The rescore wants a completely different order, with huge margins,
        // and brings a new candidate.
        let proposed = [
            Entry(text: "泥壕", score: 90),
            Entry(text: "妮好", score: 80),
            Entry(text: "你好", score: 5),
            Entry(text: "尼豪", score: 1),
        ]
        let result = resolve(&controller, shown: shown, proposed: proposed, update: .asyncRescore)
        #expect(result.map(\.text) == ["你好", "尼豪", "泥壕", "妮好"])
        // Displayed candidates carry the proposal's refreshed scores.
        #expect(result[2].score == 90)
    }

    @Test("Without navigation a decisive rescore may reorder")
    func noNavigationAllowsReorder() {
        var controller = CandidateStabilityController()
        controller.keystroke(buffer: "nihao")
        let shown = [Entry(text: "你好", score: 1), Entry(text: "尼豪", score: 0)]
        let proposed = [Entry(text: "尼豪", score: 5), Entry(text: "你好", score: 1)]
        let result = resolve(&controller, shown: shown, proposed: proposed, update: .asyncRescore)
        #expect(result.map(\.text) == ["尼豪", "你好"])
    }

    // MARK: Rule 2 — negligible-gain suppression

    @Test("A swap below the gain threshold keeps the displayed order")
    func negligibleGainIsSuppressed() {
        var controller = CandidateStabilityController()
        controller.keystroke(buffer: "shi")
        let shown = [Entry(text: "是", score: 1.0), Entry(text: "时", score: 0.8)]
        // 时 improves to 1.05: a 0.05-nat lead over 是, below the 0.1 default.
        let proposed = [Entry(text: "时", score: 1.05), Entry(text: "是", score: 1.0)]
        let result = resolve(&controller, shown: shown, proposed: proposed, update: .asyncRescore)
        #expect(result.map(\.text) == ["是", "时"])
    }

    @Test("A swap at or above the gain threshold is applied")
    func sufficientGainReorders() {
        var controller = CandidateStabilityController()
        controller.keystroke(buffer: "shi")
        let shown = [Entry(text: "是", score: 1.0), Entry(text: "时", score: 0.8)]
        let proposed = [Entry(text: "时", score: 1.6), Entry(text: "是", score: 1.0)]
        let result = resolve(&controller, shown: shown, proposed: proposed, update: .asyncRescore)
        #expect(result.map(\.text) == ["时", "是"])
    }

    @Test("The gain threshold is a parameter")
    func gainThresholdIsConfigurable() {
        var controller = CandidateStabilityController(
            parameters: .init(negligibleGainThreshold: 1.0)
        )
        controller.keystroke(buffer: "shi")
        let shown = [Entry(text: "是", score: 1.0), Entry(text: "时", score: 0.8)]
        // A 0.6-nat lead clears the 0.1 default but not this run's 1.0.
        let proposed = [Entry(text: "时", score: 1.6), Entry(text: "是", score: 1.0)]
        let result = resolve(&controller, shown: shown, proposed: proposed, update: .asyncRescore)
        #expect(result.map(\.text) == ["是", "时"])
    }

    @Test("A new candidate climbs only past those it beats by the threshold")
    func newCandidateEntersByThreshold() {
        var controller = CandidateStabilityController()
        controller.keystroke(buffer: "ma")
        let shown = [Entry(text: "吗", score: 2.0), Entry(text: "妈", score: 1.0)]
        let proposed = [
            Entry(text: "吗", score: 2.0),
            Entry(text: "码", score: 2.05),
            Entry(text: "妈", score: 1.0),
        ]
        let result = resolve(&controller, shown: shown, proposed: proposed, update: .asyncRescore)
        // 码 beats 妈 by 1.05 nats (moves above) but 吗 by 0.05 (stays below).
        #expect(result.map(\.text) == ["吗", "码", "妈"])
    }

    @Test("A candidate the proposal dropped stays visible")
    func droppedCandidateIsKept() {
        var controller = CandidateStabilityController()
        controller.keystroke(buffer: "ma")
        let shown = [Entry(text: "吗", score: 2.0), Entry(text: "妈", score: 1.0)]
        let proposed = [Entry(text: "吗", score: 2.0)]
        let result = resolve(&controller, shown: shown, proposed: proposed, update: .asyncRescore)
        #expect(result.map(\.text) == ["吗", "妈"])
    }

    // MARK: Rule 3 — oscillation damping

    @Test("A demoted top is not re-promoted on a small margin")
    func demotedTopStaysDemoted() {
        var controller = CandidateStabilityController()
        controller.keystroke(buffer: "ni")
        var list = resolve(
            &controller,
            shown: [],
            proposed: [Entry(text: "你", score: 3), Entry(text: "尼", score: 2)],
            update: .keystroke
        )
        #expect(list.map(\.text) == ["你", "尼"])

        // The rescore demotes 你 decisively (1.0-nat gain clears rule 2).
        list = resolve(
            &controller,
            shown: list,
            proposed: [Entry(text: "尼", score: 4), Entry(text: "你", score: 3)],
            update: .asyncRescore
        )
        #expect(list.map(\.text) == ["尼", "你"])

        // Next keystroke: the engine proposes 你 on top again, but only by
        // 0.5 nats — far below the 2.0-nat re-promotion margin.
        controller.keystroke(buffer: "nih")
        list = resolve(
            &controller,
            shown: list,
            proposed: [Entry(text: "你", score: 4.5), Entry(text: "尼", score: 4.0)],
            update: .keystroke
        )
        #expect(list.map(\.text) == ["尼", "你"])
    }

    @Test("A demoted top returns when its margin is decisive")
    func largeMarginRepromotes() {
        var controller = CandidateStabilityController()
        controller.keystroke(buffer: "ni")
        var list = resolve(
            &controller,
            shown: [],
            proposed: [Entry(text: "你", score: 3), Entry(text: "尼", score: 2)],
            update: .keystroke
        )
        list = resolve(
            &controller,
            shown: list,
            proposed: [Entry(text: "尼", score: 4), Entry(text: "你", score: 3)],
            update: .asyncRescore
        )
        controller.keystroke(buffer: "nih")
        list = resolve(
            &controller,
            shown: list,
            proposed: [Entry(text: "你", score: 7), Entry(text: "尼", score: 4)],
            update: .keystroke
        )
        // 3.0 nats over every alternative clears the 2.0-nat margin.
        #expect(list.map(\.text) == ["你", "尼"])
    }

    @Test("The re-promotion margin is a parameter")
    func repromotionMarginIsConfigurable() {
        var controller = CandidateStabilityController(
            parameters: .init(repromotionMargin: 4.0)
        )
        controller.keystroke(buffer: "ni")
        var list = resolve(
            &controller,
            shown: [],
            proposed: [Entry(text: "你", score: 3), Entry(text: "尼", score: 2)],
            update: .keystroke
        )
        list = resolve(
            &controller,
            shown: list,
            proposed: [Entry(text: "尼", score: 4), Entry(text: "你", score: 3)],
            update: .asyncRescore
        )
        controller.keystroke(buffer: "nih")
        list = resolve(
            &controller,
            shown: list,
            proposed: [Entry(text: "你", score: 7), Entry(text: "尼", score: 4)],
            update: .keystroke
        )
        // The same 3.0-nat lead is not enough at a 4.0-nat margin.
        #expect(list.map(\.text) == ["尼", "你"])
    }

    @Test("The reigning top is never damped for staying on top")
    func reigningTopIsExempt() {
        var controller = CandidateStabilityController()
        controller.keystroke(buffer: "ni")
        var list = resolve(
            &controller,
            shown: [],
            proposed: [Entry(text: "你", score: 3), Entry(text: "尼", score: 2)],
            update: .keystroke
        )
        // Demote 你, then re-promote it decisively: it reigns again.
        list = resolve(
            &controller,
            shown: list,
            proposed: [Entry(text: "尼", score: 4), Entry(text: "你", score: 3)],
            update: .asyncRescore
        )
        list = resolve(
            &controller,
            shown: list,
            proposed: [Entry(text: "你", score: 8), Entry(text: "尼", score: 4)],
            update: .asyncRescore
        )
        #expect(list.map(\.text) == ["你", "尼"])
        // A later rescore keeps 你 on top by a hair. Staying is not flapping.
        list = resolve(
            &controller,
            shown: list,
            proposed: [Entry(text: "你", score: 4.1), Entry(text: "尼", score: 4.0)],
            update: .asyncRescore
        )
        #expect(list.map(\.text) == ["你", "尼"])
    }

    // MARK: Rule 4 — keystroke and composition resets

    @Test("A keystroke clears the navigation lock")
    func keystrokeClearsNavigationLock() {
        var controller = CandidateStabilityController()
        controller.keystroke(buffer: "shi")
        controller.noteUserNavigation()
        controller.keystroke(buffer: "shij")
        let shown = [Entry(text: "时间", score: 1), Entry(text: "事件", score: 0)]
        let proposed = [Entry(text: "事件", score: 5), Entry(text: "时间", score: 1)]
        // Were the lock still held, this decisive rescore could only append.
        let result = resolve(&controller, shown: shown, proposed: proposed, update: .asyncRescore)
        #expect(result.map(\.text) == ["事件", "时间"])
    }

    @Test("A keystroke accepts the fresh list without rule-2 hysteresis")
    func keystrokeAcceptsFreshOrder() {
        var controller = CandidateStabilityController()
        controller.keystroke(buffer: "shi")
        let shown = [Entry(text: "是", score: 1.0), Entry(text: "时", score: 0.9)]
        controller.keystroke(buffer: "shij")
        // Tiny margins everywhere: a new buffer's list stands as proposed.
        let proposed = [Entry(text: "时间", score: 0.5), Entry(text: "是", score: 0.4)]
        let result = resolve(&controller, shown: shown, proposed: proposed, update: .keystroke)
        #expect(result.map(\.text) == ["时间", "是"])
    }

    @Test("Demotion memory survives keystrokes but not composition end")
    func compositionEndClearsDemotionMemory() {
        var controller = CandidateStabilityController()
        controller.keystroke(buffer: "ni")
        var list = resolve(
            &controller,
            shown: [],
            proposed: [Entry(text: "你", score: 3), Entry(text: "尼", score: 2)],
            update: .keystroke
        )
        list = resolve(
            &controller,
            shown: list,
            proposed: [Entry(text: "尼", score: 4), Entry(text: "你", score: 3)],
            update: .asyncRescore
        )
        controller.compositionEnded()

        // A fresh composition: 你 tops on a slim margin without objection.
        controller.keystroke(buffer: "ni")
        list = resolve(
            &controller,
            shown: [],
            proposed: [Entry(text: "你", score: 3.1), Entry(text: "尼", score: 3.0)],
            update: .keystroke
        )
        #expect(list.map(\.text) == ["你", "尼"])
    }

    @Test("Backspacing past a demotion point forgets it")
    func backspaceForgetsLongerPrefixDemotions() {
        var controller = CandidateStabilityController()
        controller.keystroke(buffer: "ni")
        var list = resolve(
            &controller,
            shown: [],
            proposed: [Entry(text: "你", score: 3), Entry(text: "尼", score: 2)],
            update: .keystroke
        )
        // At "nih" the rescorer dethrones 你 (recorded at buffer "nih").
        controller.keystroke(buffer: "nih")
        list = resolve(
            &controller,
            shown: list,
            proposed: [Entry(text: "你", score: 4), Entry(text: "尼", score: 3)],
            update: .keystroke
        )
        list = resolve(
            &controller,
            shown: list,
            proposed: [Entry(text: "尼", score: 5), Entry(text: "你", score: 4)],
            update: .asyncRescore
        )
        #expect(list.map(\.text) == ["尼", "你"])
        // Backspace to "ni": that judgement concerned "nih", not "ni", so 你
        // may top again on an ordinary margin.
        controller.keystroke(buffer: "ni")
        list = resolve(
            &controller,
            shown: list,
            proposed: [Entry(text: "你", score: 3.1), Entry(text: "尼", score: 3.0)],
            update: .keystroke
        )
        #expect(list.map(\.text) == ["你", "尼"])
    }

    @Test("The engine replacing its own top across keystrokes is not an oscillation")
    func keystrokeDemotionsDoNotArmTheDamper() {
        var controller = CandidateStabilityController()
        controller.keystroke(buffer: "ni")
        var list = resolve(
            &controller,
            shown: [],
            proposed: [Entry(text: "你", score: 3), Entry(text: "尼", score: 2)],
            update: .keystroke
        )
        // The engine dethrones 你 for the grown buffer: ordinary composition.
        controller.keystroke(buffer: "nih")
        list = resolve(
            &controller,
            shown: list,
            proposed: [Entry(text: "你好", score: 6), Entry(text: "你", score: 3)],
            update: .keystroke
        )
        #expect(list.map(\.text) == ["你好", "你"])
        // When the engine later prefers 你 again on a slim margin, that
        // choice stands: only asynchronous demotions arm the damper.
        controller.keystroke(buffer: "niha")
        list = resolve(
            &controller,
            shown: list,
            proposed: [Entry(text: "你", score: 4.1), Entry(text: "你好", score: 4.0)],
            update: .keystroke
        )
        #expect(list.map(\.text) == ["你", "你好"])
    }

    @Test("A demotion recorded at the current buffer survives a backspace to it")
    func backspaceKeepsSameBufferDemotions() {
        var controller = CandidateStabilityController()
        controller.keystroke(buffer: "ni")
        var list = resolve(
            &controller,
            shown: [],
            proposed: [Entry(text: "你", score: 3), Entry(text: "尼", score: 2)],
            update: .keystroke
        )
        // The rescore demotes 你 while the buffer is "ni".
        list = resolve(
            &controller,
            shown: list,
            proposed: [Entry(text: "尼", score: 4), Entry(text: "你", score: 3)],
            update: .asyncRescore
        )
        controller.keystroke(buffer: "nih")
        controller.keystroke(buffer: "ni")
        // Back at "ni", the judgement made *at* "ni" still stands.
        list = resolve(
            &controller,
            shown: list,
            proposed: [Entry(text: "你", score: 4.5), Entry(text: "尼", score: 4.0)],
            update: .keystroke
        )
        #expect(list.map(\.text) == ["尼", "你"])
    }

    // MARK: Bypass

    @Test("A disabled controller is a pure pass-through")
    func disabledControllerPassesThrough() {
        var controller = CandidateStabilityController(enabled: false)
        controller.keystroke(buffer: "nihao")
        controller.noteUserNavigation()
        let shown = [Entry(text: "你好", score: 5), Entry(text: "尼豪", score: 4)]
        let proposed = [Entry(text: "尼豪", score: 5.1), Entry(text: "你好", score: 5)]
        let result = resolve(&controller, shown: shown, proposed: proposed, update: .asyncRescore)
        #expect(result == proposed)
    }
}
