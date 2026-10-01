// 弦 · The strings.
//
// Keys the user has pressed are the strings being plucked. A KeyReader answers
// one question for the score (琴谱) and the listener (子期) alike: starting at
// key position p, where can a character with these readings end?
//
// Three rules, identical to Tools/zhuoqin/pinyin.py (training data is
// generated under them, so the decoder must read keys exactly the same way):
//
//   1. a syllable may be spelled in full                      zhong
//   2. or by its initial (zh/ch/sh may be one or two letters) — only when no
//      reading of the character is spelled out in full here   z, zh
//   3. or by a prefix, only where the keys run out             zho
//
// The reader precomputes, per key position, which syllables match in each way,
// so a character check is a handful of table lookups.

public struct KeyReader: Sendable {
    public let keys: [UInt8]
    public let syllables: SyllableTable
    /// fullLength[q * S + s]: length of a full spelling of s at q, 0 if none.
    private var fullLength: [UInt8]
    /// initialMask[q * S + s]: bit 0 = one-letter initial, bit 1 = two-letter.
    private var initialMask: [UInt8]
    /// partial[q * S + s]: the keys from q to the end are a proper prefix of s.
    private var partial: [Bool]
    /// Syllables that can start at q in any of the three ways.
    public private(set) var startable: [[UInt16]]

    public var count: Int { keys.count }

    public init(_ text: String, syllables: SyllableTable) {
        self.init(Array(text.utf8), syllables: syllables)
    }

    public init(_ keys: [UInt8], syllables: SyllableTable) {
        self.keys = keys
        self.syllables = syllables
        let n = keys.count
        let s = syllables.count
        fullLength = [UInt8](repeating: 0, count: max(1, n * s))
        initialMask = [UInt8](repeating: 0, count: max(1, n * s))
        partial = [Bool](repeating: false, count: max(1, n * s))
        startable = Array(repeating: [], count: n + 1)

        // Where does the next apostrophe sit? A prefix may not span one.
        var nextApostrophe = [Int](repeating: n, count: n + 1)
        if n > 0 {
            for q in stride(from: n - 1, through: 0, by: -1) {
                nextApostrophe[q] = keys[q] == KeyReader.apostrophe ? q : nextApostrophe[q + 1]
            }
        }

        for q in 0..<n {
            let first = keys[q]
            guard first >= 97, first <= 122 else { continue }
            var starts: [UInt16] = []
            for sid in syllables.startingWith(first) {
                let base = q * s + Int(sid)
                var any = false
                for spelling in syllables.spellings(sid) {
                    if KeyReader.hasPrefix(keys, at: q, spelling) {
                        fullLength[base] = UInt8(spelling.count)
                        any = true
                    }
                    let rest = n - q
                    if nextApostrophe[q] == n, rest < spelling.count,
                       KeyReader.isPrefix(keys, from: q, of: spelling) {
                        partial[base] = true
                        any = true
                    }
                }
                // One-letter initial always matches here (same first letter).
                var mask: UInt8 = 1
                let spelling = syllables.spelling(sid)
                if spelling.count >= 2, SyllableTable.isRetroflex(spelling),
                   q + 1 < n, keys[q + 1] == spelling[1] {
                    mask |= 2
                }
                initialMask[base] = mask
                any = true
                if any { starts.append(sid) }
            }
            startable[q] = starts
        }
    }

    public static let apostrophe = UInt8(ascii: "'")

    /// Skip a syllable-separating apostrophe at a character boundary.
    @inline(__always)
    public func skipSeparator(_ p: Int) -> Int {
        p < keys.count && keys[p] == KeyReader.apostrophe ? p + 1 : p
    }
    // `startable` has n + 1 rows; row n (end of keys) is always empty.

    /// Calls `body(end, spelledInFull)` for every end position reachable by
    /// reading one character with `readings` from position p.
    @inline(__always)
    public func forEachEnd(
        from p: Int,
        readings: UnsafeBufferPointer<UInt16>,
        _ body: (Int, Bool) -> Void
    ) {
        let q = skipSeparator(p)
        let n = keys.count
        guard q < n, !readings.isEmpty else { return }
        let s = syllables.count
        let row = q * s
        var ends: (Int, Int, Int, Int) = (-1, -1, -1, -1)
        var full: (Bool, Bool, Bool, Bool) = (false, false, false, false)
        var count = 0
        func add(_ end: Int, _ isFull: Bool) {
            // Up to four distinct ends; a fifth is impossible with ≤2 spellings
            // per syllable, an initial pair, and the prefix end.
            if ends.0 == end || ends.1 == end || ends.2 == end || ends.3 == end { return }
            switch count {
            case 0: ends.0 = end; full.0 = isFull
            case 1: ends.1 = end; full.1 = isFull
            case 2: ends.2 = end; full.2 = isFull
            case 3: ends.3 = end; full.3 = isFull
            default: return
            }
            count += 1
        }
        var spelledOut = false
        for r in readings {
            let length = fullLength[row + Int(r)]
            if length > 0 {
                add(q + Int(length), true)
                spelledOut = true
            }
        }
        if !spelledOut {
            for r in readings {
                let mask = initialMask[row + Int(r)]
                if mask & 1 != 0 { add(q + 1, false) }
                if mask & 2 != 0 { add(q + 2, false) }
            }
        }
        for r in readings where partial[row + Int(r)] {
            add(n, false)
        }
        if count > 0 { body(ends.0, full.0) }
        if count > 1 { body(ends.1, full.1) }
        if count > 2 { body(ends.2, full.2) }
        if count > 3 { body(ends.3, full.3) }
    }

    /// Latin output is typed letter for letter.
    public func latinEnd(from p: Int, letters: UnsafeBufferPointer<UInt8>) -> Int? {
        let q = skipSeparator(p)
        guard q + letters.count <= keys.count else { return nil }
        for i in 0..<letters.count where keys[q + i] != letters[i] { return nil }
        return q + letters.count
    }

    @inline(__always)
    static func hasPrefix(_ keys: [UInt8], at q: Int, _ spelling: [UInt8]) -> Bool {
        guard q + spelling.count <= keys.count else { return false }
        for i in 0..<spelling.count where keys[q + i] != spelling[i] { return false }
        return true
    }

    @inline(__always)
    static func isPrefix(_ keys: [UInt8], from q: Int, of spelling: [UInt8]) -> Bool {
        let rest = keys.count - q
        guard rest > 0, rest <= spelling.count else { return false }
        for i in 0..<rest where keys[q + i] != spelling[i] { return false }
        return true
    }
}
