import AppKit
import Carbon
@preconcurrency import InputMethodKit
import OSLog
import ZhiyinCore
import ZhiyinListener

/// One input session per client app. Keys go onto the strings (the inline
/// composition); 琴谱 answers at once, 子期 answers a moment later, and the
/// panel shows whichever is the better reading by the time it is drawn.
@objc(ZhiyinInputController)
final class ZhiyinInputController: IMKInputController {
    private static let log = Logger(subsystem: "com.zhiyin.inputmethod", category: "session")

    private var composition = Composition()
    private var overTop: [Bool] = []
    private var candidates: [Candidate] = []
    private var highlighted = 0
    private var generation: UInt64 = 0
    private var heard = false
    private var listening = false
    private var navigated = false
    private var pendingShow: DispatchWorkItem?
    private var documentContext = ""
    private var history = ""
    private var english = false
    private var shiftClean = false
    private var doubleQuoteOpen = false
    private var singleQuoteOpen = false
    private let panel = StringsPanel()

    @MainActor private var runtime: Runtime { Runtime.shared }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask([.keyDown, .flagsChanged]).rawValue)
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        MainActor.assumeIsolated {
            if runtime.listenerActive { runtime.listener?.preload() }
        }
    }

    override func deactivateServer(_ sender: Any!) {
        if !composition.isEmpty { commitHighlighted(client: sender) }
        panel.hide()
        // Text committed in one app must never shape readings in another.
        history = ""
        documentContext = ""
        super.deactivateServer(sender)
    }

    override func commitComposition(_ sender: Any!) {
        if !composition.isEmpty { commitHighlighted(client: sender) }
    }

    override func cancelComposition() {
        clear(client: client())
        super.cancelComposition()
    }

    override func hidePalettes() {
        panel.hide()
    }

    // MARK: - Events

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.type == .flagsChanged {
            handleShift(flags, client: sender)
            return false
        }
        guard event.type == .keyDown else { return false }
        shiftClean = false

        let composing = !composition.isEmpty
        if !flags.intersection([.command, .control, .option]).isEmpty {
            if composing { commitHighlighted(client: sender) }
            return false
        }
        let characters = event.characters ?? ""
        let code = Int(event.keyCode)

        if english {
            return false
        }

        if composing {
            switch code {
            case kVK_Delete:
                composition.deleteBackward()
                overTop = Array(overTop.prefix(composition.fixed.count))
                if composition.isEmpty { clear(client: sender) } else { refresh(client: sender) }
                return true
            case kVK_Escape:
                clear(client: sender)
                return true
            case kVK_Return, kVK_ANSI_KeypadEnter:
                commitLiteral(client: sender)
                return true
            case kVK_Space:
                choose(highlighted, client: sender)
                return true
            case kVK_LeftArrow:
                move(-1)
                return true
            case kVK_RightArrow, kVK_Tab:
                move(+1)
                return true
            case kVK_UpArrow, kVK_PageUp:
                turnPage(-1)
                return true
            case kVK_DownArrow, kVK_PageDown:
                turnPage(+1)
                return true
            default:
                break
            }
            if let ch = characters.first {
                if let digit = ch.wholeNumberValue, (1...9).contains(digit) {
                    let index = pageStart + digit - 1
                    if index < min(candidates.count, pageStart + pageSize) { choose(index, client: sender) }
                    return true
                }
                if ch == "=" { turnPage(+1); return true }
                if ch == "-" { turnPage(-1); return true }
                if ch.isASCII, ch.isLetter {
                    composition.append(Character(ch.lowercased()))
                    refresh(client: sender)
                    return true
                }
                if ch == "'" {
                    composition.append("'")
                    refresh(client: sender)
                    return true
                }
                if let mark = punctuation(for: ch, client: sender) {
                    commitHighlighted(client: sender)
                    insert(mark, client: sender)
                    return true
                }
            }
            commitHighlighted(client: sender)
            return false
        }

        // Not composing.
        guard let ch = characters.first, characters.count == 1 else { return false }
        if ch.isASCII, ch.isLowercase, ch.isLetter {
            beginComposition(client: sender)
            composition.append(ch)
            refresh(client: sender)
            return true
        }
        if let mark = punctuation(for: ch, client: sender) {
            insert(mark, client: sender)
            return true
        }
        return false
    }

    private func handleShift(_ flags: NSEvent.ModifierFlags, client: Any!) {
        guard Preferences.shared.shiftToggles else { return }
        if flags == .shift {
            shiftClean = true
        } else if flags.isEmpty, shiftClean {
            shiftClean = false
            // A lone tap of Shift: switch between 中 and 英. Keys already on
            // the strings go out as typed, as with Apple's pinyin.
            if !composition.isEmpty { commitLiteral(client: client) }
            english.toggle()
            ModeBadge.shared.show(english ? "英" : "中", near: caretRect(client))
        } else {
            shiftClean = false
        }
    }

    // MARK: - Composing

    private var pageSize: Int { Preferences.shared.pageSize }
    private var pageStart: Int { (highlighted / pageSize) * pageSize }

    private func beginComposition(client sender: Any!) {
        documentContext = ""
        let prefs = Preferences.shared
        guard prefs.readContext, !IsSecureEventInputEnabled(),
              let client = sender as? IMKTextInput else { return }
        let selection = client.selectedRange()
        guard selection.location != NSNotFound, selection.location > 0 else { return }
        let start = max(0, selection.location - 64)
        let range = NSRange(location: start, length: selection.location - start)
        if let text = client.attributedSubstring(from: range)?.string {
            documentContext = text
        }
    }

    private var context: String {
        let before = documentContext.isEmpty ? history : documentContext
        return before + composition.fixedText
    }

    @MainActor private func compose(heard answer: Heard?) -> [Candidate] {
        let keys = composition.keys
        let reader = KeyReader(keys, syllables: runtime.syllables)
        let remembered = Preferences.shared.learning ? runtime.moqi.recall(keys) : []
        return Composer.compose(keys: keys, reader: reader, heard: answer, qinpu: runtime.qinpu, remembered: remembered)
    }

    private func refresh(client sender: Any!) {
        MainActor.assumeIsolated { refreshOnMain(client: sender) }
    }

    @MainActor private func refreshOnMain(client sender: Any!) {
        pendingShow?.cancel()
        let previous = generation
        generation = runtime.nextGeneration()
        runtime.listener?.cancel(through: previous)
        navigated = false
        updateMarkedText(client: sender)
        guard !composition.keys.isEmpty else {
            // Everything is fixed but not yet committed (after deleting back).
            candidates = []
            panel.hide()
            return
        }
        let immediate = compose(heard: nil)
        guard runtime.listenerActive else {
            present(immediate, heard: false, listening: false, client: sender)
            return
        }
        // Give 子期 a moment before drawing, so the panel changes once per
        // keystroke instead of flashing 琴谱's list and then 子期's.
        let gen = generation
        let budget = panel.isVisible ? 0.075 : 0.05
        let show = DispatchWorkItem { [weak self] in
            guard let self, self.generation == gen else { return }
            self.present(immediate, heard: false, listening: true, client: sender)
        }
        pendingShow = show
        DispatchQueue.main.asyncAfter(deadline: .now() + budget, execute: show)
        let keys = composition.keys
        // 琴谱补漏: the dictionary's whole readings and 默契's memories go to
        // 子期 too, scored by both ears alongside its own beam.
        let rescue = Array(immediate.filter { $0.consumed >= keys.utf8.count && $0.voice != .literal }
            .prefix(4).map(\.text))
        runtime.listener?.listen(context: context, keys: keys, rescue: rescue, generation: gen) { [weak self] answer, _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == gen else { return }
                show.cancel()
                guard let answer, !answer.readings.isEmpty else {
                    self.present(immediate, heard: false, listening: false, client: sender)
                    return
                }
                // Once the user has moved along the strings, a late answer
                // must not move the notes under their finger.
                if self.navigated { return }
                self.present(self.compose(heard: answer), heard: true, listening: false, client: sender)
            }
        }
    }

    private func present(_ list: [Candidate], heard: Bool, listening: Bool, client sender: Any!) {
        candidates = list
        self.heard = heard
        self.listening = listening
        if !navigated { highlighted = 0 }
        highlighted = min(highlighted, max(0, candidates.count - 1))
        showPanel(client: sender)
    }

    private func showPanel(client sender: Any!) {
        guard !candidates.isEmpty else { panel.hide(); return }
        let start = pageStart
        let slice = Array(candidates[start..<min(candidates.count, start + pageSize)])
        let pages = (candidates.count + pageSize - 1) / pageSize
        panel.show(
            .init(candidates: slice, highlighted: highlighted - start, page: start / pageSize,
                  pageCount: pages, heard: heard, listening: listening),
            below: caretRect(sender)
        )
    }

    private func caretRect(_ sender: Any!) -> NSRect {
        var rect = NSRect.zero
        if let client = sender as? IMKTextInput {
            _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        }
        if rect == .zero {
            let mouse = NSEvent.mouseLocation
            rect = NSRect(x: mouse.x, y: mouse.y - 20, width: 1, height: 20)
        }
        return rect
    }

    private func updateMarkedText(client sender: Any!) {
        guard let client = sender as? IMKTextInput else { return }
        let keys = MainActor.assumeIsolated { Syllabify.display(composition.keys, syllables: runtime.syllables) }
        let text = composition.fixedText + keys
        let attributes: [NSAttributedString.Key: Any] = [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .markedClauseSegment: 0,
        ]
        let marked = NSAttributedString(string: text, attributes: attributes)
        client.setMarkedText(
            marked,
            selectionRange: NSRange(location: (text as NSString).length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }

    private func move(_ delta: Int) {
        guard !candidates.isEmpty else { return }
        navigated = true
        highlighted = max(0, min(candidates.count - 1, highlighted + delta))
        showPanel(client: client())
    }

    private func turnPage(_ delta: Int) {
        guard !candidates.isEmpty else { return }
        navigated = true
        let target = pageStart + delta * pageSize
        guard target >= 0, target < candidates.count else { return }
        highlighted = target
        showPanel(client: client())
    }

    private func choose(_ index: Int, client sender: Any!) {
        guard index < candidates.count else {
            if !composition.keys.isEmpty { commitLiteral(client: sender) }
            return
        }
        let candidate = candidates[index]
        if candidate.voice == .literal {
            commitLiteral(client: sender)
            return
        }
        overTop.append(index > 0)
        switch composition.choose(candidate) {
        case .commit(let text):
            learnAndCommit(text, client: sender)
        case .continuing:
            refresh(client: sender)
        }
    }

    private func commitHighlighted(client sender: Any!) {
        guard !composition.isEmpty else { return }
        if composition.keys.isEmpty {
            learnAndCommit(composition.fixedText, client: sender)
        } else if highlighted < candidates.count, candidates[highlighted].consumed >= composition.keys.utf8.count {
            choose(highlighted, client: sender)
        } else if let whole = candidates.first(where: { $0.consumed >= composition.keys.utf8.count }), whole.voice != .literal {
            overTop.append(false)
            if case .commit(let text) = composition.choose(whole) { learnAndCommit(text, client: sender) }
        } else {
            commitLiteral(client: sender)
        }
    }

    private func learnAndCommit(_ text: String, client sender: Any!) {
        MainActor.assumeIsolated {
            if Preferences.shared.learning, !IsSecureEventInputEnabled() {
                let pieces = composition.choices
                for (i, piece) in pieces.enumerated() {
                    runtime.moqi.remember(keys: piece.keys, text: piece.text, overTop: i < overTop.count ? overTop[i] : false)
                }
                if pieces.count > 1 {
                    runtime.moqi.remember(keys: composition.allKeys, text: text, overTop: true)
                }
                runtime.moqi.save()
            }
        }
        insert(text, client: sender)
        clear(client: sender, keepMarked: true)
    }

    private func commitLiteral(client sender: Any!) {
        let text = composition.fixedText + composition.keys.replacingOccurrences(of: "'", with: "")
        insert(text, client: sender)
        clear(client: sender, keepMarked: true)
    }

    private func insert(_ text: String, client sender: Any!) {
        guard let client = sender as? IMKTextInput else { return }
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        history = String((history + text).suffix(64))
        documentContext = ""
    }

    private func clear(client sender: Any!, keepMarked: Bool = false) {
        pendingShow?.cancel()
        MainActor.assumeIsolated { runtime.listener?.cancel(through: generation) }
        composition.clear()
        overTop = []
        candidates = []
        highlighted = 0
        navigated = false
        panel.hide()
        if !keepMarked, let client = sender as? IMKTextInput {
            client.setMarkedText("", selectionRange: NSRange(location: 0, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        }
    }

    // MARK: - Punctuation

    private func punctuation(for ch: Character, client sender: Any!) -> String? {
        guard Preferences.shared.fullWidthPunctuation else { return nil }
        // After a digit, keep . , : as they are: 3.14, 1,000, 12:30.
        if ".,:".contains(ch), let last = (lastCharacter(sender) ?? history.last), last.isASCII, last.isNumber {
            return nil
        }
        switch ch {
        case ",": return "，"
        case ".": return "。"
        case "?": return "？"
        case "!": return "！"
        case ":": return "："
        case ";": return "；"
        case "\\": return "、"
        case "(": return "（"
        case ")": return "）"
        case "[": return "【"
        case "]": return "】"
        case "<": return "《"
        case ">": return "》"
        case "~": return "～"
        case "^": return "……"
        case "_": return "——"
        case "$": return "￥"
        case "`": return "·"
        case "\"":
            doubleQuoteOpen.toggle()
            return doubleQuoteOpen ? "“" : "”"
        case "'":
            singleQuoteOpen.toggle()
            return singleQuoteOpen ? "‘" : "’"
        default: return nil
        }
    }

    private func lastCharacter(_ sender: Any!) -> Character? {
        guard let client = sender as? IMKTextInput else { return nil }
        let selection = client.selectedRange()
        guard selection.location != NSNotFound, selection.location > 0 else { return nil }
        return client.attributedSubstring(from: NSRange(location: selection.location - 1, length: 1))?.string.last
    }

    // MARK: - Menu

    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "知音")
        let qintai = NSMenuItem(title: "琴台…", action: #selector(openQintai(_:)), keyEquivalent: "")
        qintai.target = self
        menu.addItem(qintai)
        menu.addItem(.separator())
        let status = NSMenuItem(title: MainActor.assumeIsolated { runtime.listenerStatus }, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let solo = NSMenuItem(title: "独奏（暂歇子期）", action: #selector(toggleSolo(_:)), keyEquivalent: "")
        solo.target = self
        solo.state = Preferences.shared.listenerEnabled ? .off : .on
        menu.addItem(solo)
        return menu
    }

    @objc private func openQintai(_ sender: Any?) {
        MainActor.assumeIsolated { QintaiWindow.shared.show() }
    }

    @objc private func toggleSolo(_ sender: Any?) {
        Preferences.shared.listenerEnabled.toggle()
        MainActor.assumeIsolated {
            if !Preferences.shared.listenerEnabled { runtime.listener?.release() }
        }
    }
}
