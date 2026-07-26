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
    private var committedContext = ""
    private var llmLatency: Double?
    private var engineFailure: String?
    private let pageSize = 9

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        Self.logger.notice("Created an InputMethodKit client session")
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
    }

    override func inputControllerWillClose() {
        Self.logger.notice("Closing an InputMethodKit client session")
        resetState()
    }

    override func hidePalettes() {
        panel.dismiss()
    }

    override func menu() -> NSMenu! {
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

        let result = runtime.engine.candidates(
            for: rawInput,
            context: committedContext,
            generation: generation
        )
        candidates = result.candidates
        updateMarkedText(sender)
        showPanel(sender)

        let request = RankRequest(
            clientID: clientID,
            generation: generation,
            input: rawInput,
            committedContext: String(committedContext.suffix(2_048)),
            candidates: candidates.prefix(40).map(\.text)
        )
        runtime.llm.rank(request) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let reply):
                    guard reply.clientID == self.clientID, reply.generation == self.generation else { return }
                    self.apply(reply)
                    self.showPanel(self.client())
                case .failure(let error):
                    guard request.generation == self.generation else { return }
                    self.engineFailure = error.localizedDescription
                    self.candidates = [
                        Candidate(
                            text: self.rawInput,
                            pinyin: self.rawInput,
                            source: .literal,
                            consumed: self.rawInput.count,
                            score: 0
                        )
                    ]
                    self.showPanel(self.client())
                }
            }
        }
    }

    private func apply(_ reply: RankReply) {
        var byText = Dictionary(uniqueKeysWithValues: candidates.map { ($0.text, $0) })
        var rescored: [Candidate] = []
        for text in reply.orderedCandidates {
            guard var candidate = byText.removeValue(forKey: text) else { continue }
            candidate.score += (reply.scores[text] ?? 0) * 0.42
            if candidate.source == .learned {
                candidate.score += 4
            } else if candidate.source == .system {
                candidate.score += 1
            }
            rescored.append(candidate)
        }
        rescored.sort { $0.score > $1.score }
        rescored.append(contentsOf: candidates.filter { byText[$0.text] != nil })
        candidates = rescored
        llmLatency = reply.latencyMilliseconds
        runtime.llm.refreshStatus()
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
        showPanel(sender)
    }

    private func changePage(_ delta: Int, sender: Any!) {
        let maxPage = max(0, (candidates.count - 1) / pageSize)
        page = min(max(0, page + delta), maxPage)
        selectedInPage = 0
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
        committedContext = String((committedContext + value).suffix(2_048))
        resetState()
    }

    private func commitRaw(_ sender: Any!) {
        insert(rawInput, sender: sender)
        committedContext = String((committedContext + rawInput).suffix(2_048))
        resetState()
    }

    private func applyAutoSpacing(_ text: String) -> String {
        guard AppSettings.shared.autoSpacing,
              let previous = committedContext.last,
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
              let previous = committedContext.last,
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
        committedContext = String((committedContext + punctuation).suffix(2_048))
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
        panel.dismiss()
    }
}
