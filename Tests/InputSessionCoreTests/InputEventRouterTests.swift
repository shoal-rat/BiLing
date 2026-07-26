import InputSessionCore
import Testing

@Test func lettersAppendToComposition() {
    #expect(
        InputEventRouter.route(
            InputKeyEvent(text: "x", keyCode: 7),
            hasComposition: false,
            candidateCount: 0,
            page: 0,
            pageSize: 9
        ) == .append("x")
    )
}

@Test func spaceCommitsSelectedCandidate() {
    #expect(
        InputEventRouter.route(
            InputKeyEvent(text: " ", keyCode: 49),
            hasComposition: true,
            candidateCount: 12,
            page: 0,
            pageSize: 9
        ) == .commitSelected
    )
}

@Test func returnIsTheLiteralEscapeHatch() {
    #expect(
        InputEventRouter.route(
            InputKeyEvent(text: "\r", keyCode: 36),
            hasComposition: true,
            candidateCount: 12,
            page: 0,
            pageSize: 9
        ) == .commitLiteral
    )
}

@Test func numberedCandidatesRespectTheCurrentPage() {
    #expect(
        InputEventRouter.route(
            InputKeyEvent(text: "3", keyCode: 20),
            hasComposition: true,
            candidateCount: 20,
            page: 1,
            pageSize: 9
        ) == .selectCandidate(11)
    )
}

@Test func outOfRangeCandidateNumberIsConsumed() {
    #expect(
        InputEventRouter.route(
            InputKeyEvent(text: "9", keyCode: 25),
            hasComposition: true,
            candidateCount: 3,
            page: 0,
            pageSize: 9
        ) == .consume
    )
}

@Test func backspacePassesThroughWithoutComposition() {
    #expect(
        InputEventRouter.route(
            InputKeyEvent(text: "", keyCode: 51),
            hasComposition: false,
            candidateCount: 0,
            page: 0,
            pageSize: 9
        ) == .passThrough
    )
}

@Test func punctuationCommitsThenPassesThrough() {
    #expect(
        InputEventRouter.route(
            InputKeyEvent(text: ",", keyCode: 43),
            hasComposition: true,
            candidateCount: 8,
            page: 0,
            pageSize: 9
        ) == .commitSelectedAndPassThrough
    )
}

@Test func shortcutsNeverGetSwallowed() {
    #expect(
        InputEventRouter.route(
            InputKeyEvent(text: "c", keyCode: 8, modifiers: [.command]),
            hasComposition: true,
            candidateCount: 8,
            page: 0,
            pageSize: 9
        ) == .commitLiteralAndPassThrough
    )
}
