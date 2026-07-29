#!/usr/bin/env swift
// Measures macOS's own Simplified Chinese input method on the same corpus, so
// BiLing's numbers have a competitive reference rather than only an internal
// ablation.
//
// Apple exposes no API for querying its converter, so the only honest way to
// measure it is to drive it exactly as a person would: select the input source,
// type the keystrokes into a real text view, commit with space, and read what
// landed. Synthetic key events require Accessibility permission for this
// process; without it the run aborts rather than reporting silence as failure.
//
// Usage: swift scripts/apple_baseline.swift corpus.tsv [limit] [--context] > results.tsv
//
// --context seeds each item's committed context into the text view before the
// keystrokes, caret at the end — the same surrounding-text channel a real app
// gives any IME, and the same committed text BiLing conditions on. Both
// systems then see identical evidence, which is what makes the with-context
// comparison paired rather than rhetorical.

import AppKit
import Carbon

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("Usage: apple_baseline.swift corpus.tsv [limit]\n".utf8))
    exit(64)
}
let corpusPath = arguments[1]
let useContext = arguments.contains("--context")
let limit = arguments.dropFirst(2).compactMap(Int.init).first ?? 200
let appleSource = "com.apple.inputmethod.SCIM.ITABC"

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("""
        This tool must be trusted for Accessibility to post key events.
        Grant it in System Settings › Privacy & Security › Accessibility for the
        terminal running it, then re-run. Refusing to continue, because without
        permission every item would silently look like a failure.

        """.utf8))
    exit(77)
}

// a–z keycodes on the ANSI layout; the buffer only ever holds lowercase letters.
let keyCodes: [Character: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
]
let spaceKey: CGKeyCode = 49
let deleteKey: CGKeyCode = 51
let escapeKey: CGKeyCode = 53

func inputSources() -> [TISInputSource] {
    guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue()
        as? [TISInputSource] else { return [] }
    return list
}

func identifier(_ source: TISInputSource) -> String? {
    guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
    else { return nil }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}

func currentIdentifier() -> String? {
    identifier(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
}

@discardableResult
func select(_ wanted: String) -> Bool {
    for source in inputSources() where identifier(source) == wanted {
        return TISSelectInputSource(source) == noErr
    }
    return false
}

func post(_ code: CGKeyCode) {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
    else { return }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

/// Pumps AppKit's own event queue. Spinning only the run loop is not enough:
/// synthesized key events are delivered through NSApplication, so without
/// dequeuing and dispatching them here they never reach the text view and every
/// item looks like a silent failure.
func spin(_ seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        // Wait in short slices and keep going when the queue is momentarily
        // empty. Returning as soon as no event is pending would not give the
        // input method time to convert, and its composition would still be
        // uncommitted when we read the view — which reads as an empty answer.
        if let event = NSApp.nextEvent(
            matching: .any,
            until: Date().addingTimeInterval(0.004),
            inMode: .default,
            dequeue: true
        ) {
            NSApp.sendEvent(event)
        }
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)

let window = NSWindow(
    contentRect: NSRect(x: 200, y: 200, width: 560, height: 120),
    styleMask: [.titled],
    backing: .buffered,
    defer: false
)
let textView = NSTextView(frame: window.contentLayoutRect)
textView.isRichText = false
textView.font = .systemFont(ofSize: 15)
window.contentView = textView
window.title = "BiLing baseline harness"
window.makeKeyAndOrderFront(nil)
application.activate(ignoringOtherApps: true)
window.makeFirstResponder(textView)
NSApp.finishLaunching()
spin(1.5)
FileHandle.standardError.write(
    Data("active=\(NSApp.isActive) key=\(window.isKeyWindow) responder=\(window.firstResponder === textView)\n".utf8)
)

let original = currentIdentifier()
guard select(appleSource) else {
    FileHandle.standardError.write(Data("Could not select \(appleSource).\n".utf8))
    exit(70)
}
spin(1.0)

struct Row { let category: String; let context: String; let pinyin: String; let expected: String }
var rows: [Row] = []
for line in (try? String(contentsOfFile: corpusPath, encoding: .utf8))?
    .split(separator: "\n") ?? [] {
    if line.hasPrefix("#") { continue }
    let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard fields.count >= 4 else { continue }
    // Only keys the harness can actually type.
    guard fields[2].allSatisfy({ keyCodes[$0] != nil }) else { continue }
    rows.append(Row(
        category: fields[0],
        context: fields[1] == "-" ? "" : fields[1],
        pinyin: fields[2],
        expected: fields[3]
    ))
}
rows = Array(rows.prefix(limit))

print("category\tcontext\tpinyin\texpected\tapple\tcorrect")
var correct = 0
for (index, row) in rows.enumerated() {
    let seeded = useContext ? row.context : ""
    textView.string = seeded
    textView.setSelectedRange(NSRange(location: (seeded as NSString).length, length: 0))
    spin(0.05)
    for character in row.pinyin {
        guard let code = keyCodes[character] else { continue }
        post(code)
        spin(0.012)
    }
    // Space commits the highlighted candidate, which is the IME's top-1.
    spin(0.45)
    post(spaceKey)
    spin(0.45)
    func converted() -> String {
        // Only what appeared after the seeded context is the IME's answer.
        let whole = textView.string as NSString
        let seededLength = (seeded as NSString).length
        guard whole.length >= seededLength else { return "" }
        return whole.substring(from: seededLength)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var produced = converted()
    // Long input can convert in several segments: keep committing until the
    // view stops growing, so the comparison sees the whole sentence.
    var attempts = 0
    while produced.isEmpty || attempts < 3 {
        let before = produced
        post(spaceKey)
        spin(0.35)
        produced = converted()
        attempts += 1
        if produced == before && !produced.isEmpty { break }
        if attempts >= 6 { break }
    }
    let matched = produced == row.expected
    if matched { correct += 1 }
    print("\(row.category)\t\(row.context)\t\(row.pinyin)\t\(row.expected)\t\(produced)\t\(matched ? 1 : 0)")
    // Clear any composition the IME is still holding.
    post(escapeKey)
    spin(0.06)
    if (index + 1) % 25 == 0 {
        FileHandle.standardError.write(
            Data("… \(index + 1)/\(rows.count)  running top-1 \(100 * correct / (index + 1))%\n".utf8)
        )
    }
}

if let original { select(original) }
FileHandle.standardError.write(
    Data("Apple Pinyin top-1: \(correct)/\(rows.count)\n".utf8)
)
exit(0)
