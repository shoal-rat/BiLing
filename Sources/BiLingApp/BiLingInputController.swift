import AppKit
import BackboneEngine
import Carbon
@preconcurrency import InputMethodKit
import InputSessionCore
import IPCProtocol
import OSLog

@MainActor
@objc(BiLingInputController)
final class BiLingInputController: IMKInputController, @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "com.biling.inputmethod.BiLing",
        category: "input-controller"
    )
    private let runtime = Runtime.shared
    private let panel = CandidatePanel()
    private let clientID = UUID()
    private var rawInput = ""
    private var candidates: [Candidate] = []
    private var generation: UInt64 = 0
    private var page = 0
    private var selectedInPage = 0
    private var stability = CandidateStabilityController()
    private var committedContext = CommittedContext()
    private var documentContext = ""
    private var fetchedContextThisComposition = false
    private var activeContext = ""
    private var llmLatency: Double?
    private var engineFailure: String?
    private let pageSize = 9

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        Self.logger.notice("Created an InputMethodKit client session")
    }

    /// Apple's Simplified Chinese pinyin input mode.
    private static let applePinyinSourceID = "com.apple.inputmethod.SCIM.ITABC"

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        // In Low Power Mode, hand the session to Apple's pinyin instead of
        // burning battery on model inference. If that source is not enabled
        // on this machine, BiLing stays active and skips the model instead.
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            _ = InputSourceRegistration.select(identifier: Self.applePinyinSourceID)
        }
    }

    override func inputText(
        _ string: String!,
        key keyCode: Int,
        modifiers flags: Int,
        client sender: Any!
    ) -> Bool {
        guard sender is IMKTextInput else {
            Self.logger.error("Rejected an invalid InputMethodKit client")
            return false
        }

        if ProcessInfo.processInfo.isLowPowerModeEnabled, rawInput.isEmpty,
           InputSourceRegistration.select(identifier: Self.applePinyinSourceID) {
            // Apple pinyin takes over from the next event; let the client
            // handle this one so no keystroke is swallowed.
            return false
        }

        let eventFlags = NSEvent.ModifierFlags(rawValue: UInt(bitPattern: flags))
            .intersection(.deviceIndependentFlagsMask)
        var modifiers: InputModifiers = []
        if eventFlags.contains(.command) { modifiers.insert(.command) }
        if eventFlags.contains(.control) { modifiers.insert(.control) }
        if eventFlags.contains(.option) { modifiers.insert(.option) }
        if eventFlags.contains(.shift) { modifiers.insert(.shift) }

        let action = InputEventRouter.route(
            InputKeyEvent(text: string ?? "", keyCode: keyCode, modifiers: modifiers),
            hasComposition: !rawInput.isEmpty,
            candidateCount: candidates.count,
            page: page,
            pageSize: pageSize
        )

        switch action {
        case .append(let text):
            rawInput.append(contentsOf: text)
            refreshCandidates(sender)
            return true
        case .deleteBackward:
            rawInput.removeLast()
            if rawInput.isEmpty {
                clearComposition(sender)
            } else {
                refreshCandidates(sender)
            }
            return true
        case .cancelComposition:
            clearComposition(sender)
            return true
        case .commitLiteral:
            commitRaw(sender)
            return true
        case .commitSelected:
            commitSelected(sender)
            return true
        case .commitSelectedAndPassThrough:
            commitSelected(sender)
            return insertFullWidthPunctuationIfNeeded(string ?? "", sender: sender)
        case .commitLiteralAndPassThrough:
            commitRaw(sender)
            return false
        case .selectCandidate(let index):
            selectedInPage = index - page * pageSize
            commitSelected(sender)
            return true
        case .moveSelection(let delta):
            moveSelection(delta, sender: sender)
            return true
        case .changePage(let delta):
            changePage(delta, sender: sender)
            return true
        case .passThrough:
            return insertFullWidthPunctuationIfNeeded(string ?? "", sender: sender)
        case .consume:
            return true
        }
    }

    override func composedString(_ sender: Any!) -> Any! {
        rawInput
    }

    override func originalString(_ sender: Any!) -> NSAttributedString! {
        NSAttributedString(string: rawInput)
    }

    override func commitComposition(_ sender: Any!) {
        if !rawInput.isEmpty { commitSelected(sender) }
    }

    override func deactivateServer(_ sender: Any!) {
        if !rawInput.isEmpty { commitSelected(sender) }
        panel.dismiss()
        // The user is switching apps or fields. Text committed here belongs
        // to this client; it must never influence the ranking - or surface in
        // any form - in the next one.
        committedContext.clientChanged()
    }

    override func inputControllerWillClose() {
        Self.logger.notice("Closing an InputMethodKit client session")
        resetState()
        committedContext.clientChanged()
    }

    override func hidePalettes() {
        panel.dismiss()
    }

    override func menu() -> NSMenu! {
        runtime.llm.refreshStatus()
        let menu = NSMenu(title: "笔灵")
        let settings = NSMenuItem(title: "笔灵设置…", action: #selector(openPreferences), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let status = NSMenuItem(
            title: runtime.llm.isReady ? "Qwen 已就绪" : "Qwen 正在启动或恢复…",
            action: nil,
            keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)
        return menu
    }

    @objc private func openPreferences() {
        PreferencesWindowController.shared.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshCandidates(_ sender: Any!) {
        generation &+= 1
        runtime.llm.cancel(clientID: clientID, generation: generation &- 1)
        page = 0
        selectedInPage = 0
        llmLatency = nil
        engineFailure = nil

        // Read the text already sitting before the caret once per composition.
        // It is truer context than our own session history (it survives app
        // switches and covers text typed by other means), and fetching it only
        // at composition start keeps the daemon's KV prefix stable per word.
        if !fetchedContextThisComposition {
            fetchedContextThisComposition = true
            documentContext = Self.documentContext(from: sender as? IMKTextInput)
        }
        activeContext = documentContext.isEmpty ? committedContext.text : documentContext

        // Read the fuzzy preference per keystroke: the preferences window is
        // reachable mid-composition, and a toggle should apply to the next
        // candidate list, not the next launch.
        runtime.engine.tolerance = AppSettings.shared.fuzzyPinyin ? .all : .off
        let result = runtime.engine.candidates(
            for: rawInput,
            context: activeContext,
            generation: generation
        )
        stability.keystroke(buffer: rawInput)
        candidates = stability.resolve(
            shown: candidates,
            proposed: result.candidates,
            update: .keystroke,
            id: \.text,
            score: \.score
        )
        updateMarkedText(sender)
        showPanel(sender)

        // Fallback for Low Power Mode when Apple pinyin was not available to
        // switch to: stay usable on the lexicon alone, never call the model.
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            engineFailure = "低电量模式：已暂停 Qwen 排序，词典候选不受影响"
            showPanel(sender)
            return
        }

        // When the deterministic ranking is already decided, asking the model
        // to confirm it burns a wakeup and ~25 ms of GPU for nothing; the
        // margin threshold is calibrated in Docs/results/gate-calibration.txt.
        guard ScoreModel.shouldInvokeModel(
            topScore: candidates.first?.score ?? 0,
            secondScore: candidates.count > 1 ? candidates[1].score : nil
        ) else { return }

        let request = RankRequest(
            clientID: clientID,
            generation: generation,
            input: rawInput,
            committedContext: activeContext,
            candidates: candidates.prefix(40).map(\.text)
        )
        runtime.llm.rank(request) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                // A reply may only touch the exact composition it was
                // computed for: same client, same generation, same buffer.
                let stamp = CompositionStamp(generation: self.generation, buffer: self.rawInput)
                switch result {
                case .success(let reply):
                    guard reply.clientID == self.clientID,
                          AsyncReplyGate.shouldApply(
                              replyGeneration: reply.generation,
                              requestBuffer: request.input,
                              current: stamp
                          ) else { return }
                    self.apply(reply)
                    self.showPanel(self.client())
                case .failure(let error):
                    guard AsyncReplyGate.shouldApply(
                        replyGeneration: request.generation,
                        requestBuffer: request.input,
                        current: stamp
                    ) else { return }
                    // The deterministic candidate list is already on screen and
                    // stays fully usable; the panel only flips its Qwen badge.
                    self.engineFailure = error.localizedDescription
                    self.showPanel(self.client())
                }
            }
        }
    }

    private func apply(_ reply: RankReply) {
        let blended = CandidateBlender.blend(
            candidates,
            orderedCandidates: reply.orderedCandidates,
            scores: reply.scores,
            hasContext: !activeContext.isEmpty
        )
        // The model's reordering arrives while the deterministic list is
        // already on screen; the stability controller decides how much of it
        // the user actually sees move.
        candidates = stability.resolve(
            shown: candidates,
            proposed: blended,
            update: .asyncRescore,
            id: \.text,
            score: \.score
        )
        llmLatency = reply.latencyMilliseconds
        runtime.llm.noteRankSuccess(model: reply.modelDescription)
    }

    /// Up to ~600 UTF-16 units of document text before the caret, or empty
    /// when the client cannot provide it (Terminal, some Electron apps).
    private static func documentContext(from client: IMKTextInput?) -> String {
        guard let client else { return "" }
        let selection = client.selectedRange()
        guard selection.location != NSNotFound, selection.location > 0 else { return "" }
        let length = min(selection.location, 600)
        let range = NSRange(location: selection.location - length, length: length)
        guard let text = client.attributedSubstring(from: range)?.string else { return "" }
        return text
    }

    private func updateMarkedText(_ sender: Any!) {
        guard let client = sender as? IMKTextInput else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor.systemIndigo,
        ]
        let marked = NSAttributedString(string: rawInput, attributes: attributes)
        client.setMarkedText(
            marked,
            selectionRange: NSRange(location: rawInput.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    private func showPanel(_ sender: Any!) {
        guard !rawInput.isEmpty else {
            panel.dismiss()
            return
        }
        let current = pageCandidates()
        panel.update(
            candidates: current,
            selected: min(selectedInPage, max(0, current.count - 1)),
            page: page,
            total: candidates.count,
            modelLatency: llmLatency,
            modelError: engineFailure
        ) { [weak self] index in
            guard let self else { return }
            self.selectedInPage = index
            self.commitSelected(sender)
        }
        var caret = NSRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y, width: 1, height: 22)
        if let client = sender as? IMKTextInput {
            _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &caret)
        }
        panel.show(relativeTo: caret)
    }

    private func pageCandidates() -> [Candidate] {
        let start = page * pageSize
        guard start < candidates.count else { return [] }
        return Array(candidates[start..<min(start + pageSize, candidates.count)])
    }

    private func moveSelection(_ delta: Int, sender: Any!) {
        let count = pageCandidates().count
        guard count > 0 else { return }
        selectedInPage = (selectedInPage + delta + count) % count
        // The user is now pointing at this list; a late rescoring may append
        // candidates but no longer reorder the ones on display.
        stability.noteUserNavigation()
        showPanel(sender)
    }

    private func changePage(_ delta: Int, sender: Any!) {
        let maxPage = max(0, (candidates.count - 1) / pageSize)
        page = min(max(0, page + delta), maxPage)
        selectedInPage = 0
        stability.noteUserNavigation()
        showPanel(sender)
    }

    private func commitSelected(_ sender: Any!) {
        let index = page * pageSize + selectedInPage
        guard index < candidates.count else {
            commitRaw(sender)
            return
        }
        let candidate = candidates[index]
        let value = applyAutoSpacing(candidate.text)
        let bundleIdentifier = (sender as? IMKTextInput)?.bundleIdentifier()
        if AppSettings.shared.learningEnabled,
           !IsSecureEventInputEnabled(),
           PrivacyGuard.shouldLearn(
               text: candidate.text,
               source: candidate.source,
               bundleIdentifier: bundleIdentifier
           ) {
            runtime.engine.recordSelection(input: rawInput, candidate: candidate, shown: candidates, index: index)
        }
        insert(value, sender: sender)
        appendToContext(value)
        resetState()
    }

    private func commitRaw(_ sender: Any!) {
        insert(rawInput, sender: sender)
        appendToContext(rawInput)
        resetState()
    }

    private func appendToContext(_ text: String) {
        committedContext.append(text)
    }

    private func applyAutoSpacing(_ text: String) -> String {
        guard AppSettings.shared.autoSpacing,
              let previous = committedContext.text.last,
              let next = text.first else { return text }
        let previousLatin = previous.isASCII && previous.isLetter
        let nextLatin = next.isASCII && next.isLetter
        return previousLatin != nextLatin ? " " + text : text
    }

    private func insert(_ text: String, sender: Any!) {
        (sender as? IMKTextInput)?.insertText(
            text,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    private func insertFullWidthPunctuationIfNeeded(_ text: String, sender: Any!) -> Bool {
        guard AppSettings.shared.fullWidthPunctuation,
              let previous = committedContext.text.last,
              isCJK(previous),
              let punctuation = [
                  ",": "，",
                  ".": "。",
                  "?": "？",
                  "!": "！",
                  ":": "：",
                  ";": "；",
              ][text] else { return false }
        insert(punctuation, sender: sender)
        appendToContext(punctuation)
        return true
    }

    private func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            (0x3400...0x4DBF).contains($0.value)
                || (0x4E00...0x9FFF).contains($0.value)
                || (0xF900...0xFAFF).contains($0.value)
        }
    }

    private func clearComposition(_ sender: Any!) {
        (sender as? IMKTextInput)?.setMarkedText(
            "",
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        resetState()
    }

    private func resetState() {
        let cancelledGeneration = generation
        generation &+= 1
        runtime.llm.cancel(clientID: clientID, generation: cancelledGeneration)
        rawInput = ""
        candidates = []
        page = 0
        selectedInPage = 0
        stability.compositionEnded()
        documentContext = ""
        // Holds a copy of client text; drop it as soon as the composition
        // ends rather than carrying it until the next one begins.
        activeContext = ""
        fetchedContextThisComposition = false
        panel.dismiss()
    }
}
