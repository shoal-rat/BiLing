/// What is on the strings right now: pieces already chosen from a long input
/// (fixed), and the keys not yet read (keys). Choosing a candidate that reads
/// only part of the keys fixes that part and keeps composing the rest, so a
/// long sentence can be taken apart piece by piece.
public struct Composition: Sendable, Equatable {
    public struct Piece: Sendable, Equatable {
        public let text: String
        public let keys: String
    }

    public private(set) var fixed: [Piece] = []
    public private(set) var keys: String = ""

    public init() {}

    public var isEmpty: Bool { fixed.isEmpty && keys.isEmpty }
    public var fixedText: String { fixed.map(\.text).joined() }
    public var allKeys: String { fixed.map(\.keys).joined() + keys }

    public mutating func append(_ key: Character) {
        if key == "'" {
            // A separator only between letters, never two in a row.
            guard let last = keys.last, last != "'" else { return }
        }
        keys.append(key)
    }

    /// Backspace: the last key; with no keys left, un-fix the last piece.
    public mutating func deleteBackward() {
        if !keys.isEmpty {
            keys.removeLast()
        } else if let piece = fixed.popLast() {
            keys = piece.keys
        }
    }

    public enum Outcome: Equatable {
        /// Everything is read: commit this text.
        case commit(String)
        /// Part was read; keep composing.
        case continuing
    }

    public mutating func choose(_ candidate: Candidate) -> Outcome {
        let bytes = Array(keys.utf8)
        let consumed = min(candidate.consumed, bytes.count)
        if consumed >= bytes.count {
            fixed.append(Piece(text: candidate.text, keys: keys))
            let text = fixedText
            return .commit(text)
        }
        let read = String(decoding: bytes[..<consumed], as: UTF8.self)
        var rest = String(decoding: bytes[consumed...], as: UTF8.self)
        if rest.hasPrefix("'") { rest.removeFirst() }
        fixed.append(Piece(text: candidate.text, keys: read))
        keys = rest
        // Only a separator was left: everything is read.
        return rest.isEmpty ? .commit(fixedText) : .continuing
    }

    /// The pieces chosen so far, as (keys, text) — what 默契 learns from.
    public var choices: [Piece] { fixed }

    public mutating func clear() {
        fixed = []
        keys = ""
    }
}
