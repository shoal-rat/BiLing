import AppKit
import BackboneEngine
import InputSessionCore

@MainActor
enum InputControllerSmokeTest {
    struct Result {
        let succeeded: Bool
        let message: String
    }

    static func run() -> Result {
        let letter = InputEventRouter.route(
            InputKeyEvent(text: "x", keyCode: 7),
            hasComposition: false,
            candidateCount: 0,
            page: 0,
            pageSize: 9
        )
        let commit = InputEventRouter.route(
            InputKeyEvent(text: "\r", keyCode: 36),
            hasComposition: true,
            candidateCount: 1,
            page: 0,
            pageSize: 9
        )
        guard letter == .append("x"), commit == .commitLiteral else {
            return Result(
                succeeded: false,
                message: "The production key-event router failed its composition path."
            )
        }

        do {
            let engine = try PinyinEngine(
                dictionary: .bundled(),
                learningStore: MemoryLearningStore()
            )
            let candidates = engine.candidates(for: "jilindaxue").candidates
            guard candidates.first?.text == "吉林大学" else {
                return Result(
                    succeeded: false,
                    message: "The bundled lexicon did not rank 吉林大学 first."
                )
            }
        } catch {
            return Result(
                succeeded: false,
                message: "The bundled candidate engine failed: \(error.localizedDescription)"
            )
        }

        let panelResult = verifyCandidatePanel()
        guard panelResult.succeeded else { return panelResult }
        return Result(
            succeeded: true,
            message: "IMKServer, event routing, lexicon, and candidate-panel layout passed."
        )
    }

    static func renderCandidatePanel(to url: URL) -> Result {
        let panel = configuredCandidatePanel()
        guard panel.hasRenderableContent(expectedCount: sampleCandidates.count) else {
            return Result(
                succeeded: false,
                message: "The candidate panel produced empty or zero-width labels."
            )
        }
        do {
            try panel.writeSnapshot(to: url)
            return Result(
                succeeded: true,
                message: "Candidate-panel snapshot written to \(url.path)."
            )
        } catch {
            return Result(
                succeeded: false,
                message: "Could not render the candidate panel: \(error.localizedDescription)"
            )
        }
    }

    private static func verifyCandidatePanel() -> Result {
        let panel = configuredCandidatePanel()
        guard panel.hasRenderableContent(expectedCount: sampleCandidates.count) else {
            return Result(
                succeeded: false,
                message: "The candidate panel produced empty or zero-width labels."
            )
        }
        return Result(succeeded: true, message: "Candidate-panel layout passed.")
    }

    private static func configuredCandidatePanel() -> CandidatePanel {
        let panel = CandidatePanel()
        panel.update(
            candidates: sampleCandidates,
            selected: 0,
            page: 0,
            total: sampleCandidates.count,
            modelLatency: 47,
            modelError: nil,
            onSelect: { _ in }
        )
        return panel
    }

    private static let sampleCandidates = [
        Candidate(text: "吉林大学", pinyin: "jilin daxue", source: .system, consumed: 11, score: 8),
        Candidate(text: "吉林大雪", pinyin: "jilin daxue", source: .sentence, consumed: 11, score: 7),
        Candidate(text: "吉林", pinyin: "jilin", source: .system, consumed: 5, score: 6),
        Candidate(text: "记录", pinyin: "jilu", source: .system, consumed: 4, score: 5),
        Candidate(text: "距离", pinyin: "juli", source: .system, consumed: 4, score: 4),
    ]
}
