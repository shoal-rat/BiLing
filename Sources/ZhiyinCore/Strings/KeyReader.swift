import Foundation

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
// and a fourth, for the fingers rather than the ear — 走音, a slip:
//
//   4. a syllable spelled with one slip — a neighbouring key (nihap), two
//      letters swapped (nihoa), one missing (zhogguo) or one extra (niihao) —
//      at a cost, and at most `maxSlips` per reading of the whole input.
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
    /// slipMask[q * S + s]: s spelled with one slip at q, ending at
    /// q + L - 1 (bit 0, a letter missing), q + L (bit 1, a neighbour key or a
    /// swap) or q + L + 1 (bit 2, a letter extra), L = the spelling's length.
    private var slipMask: [UInt8]
    /// Syllables that can start at q in any of the three ways.
    public private(set) var startable: [[UInt16]]
    /// Whether slip readings were computed (see init).
    public private(set) var slipsEnabled = false

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
        slipMask = [UInt8](repeating: 0, count: max(1, n * s))
        startable = Array(repeating: [], count: n + 1)

        // Where does the next apostrophe sit? A prefix may not span one.
        var nextApostrophe = [Int](repeating: n, count: n + 1)
        if n > 0 {
            for q in stride(from: n - 1, through: 0, by: -1) {
                nextApostrophe[q] = keys[q] == KeyReader.apostrophe ? q : nextApostrophe[q + 1]
            }
        }

        // Keys that read cleanly as complete syllables are taken at their
        // word: no slip readings at all. Slips are for keys that only read
        // with initials, a half-typed tail, or not at all.
        slipsEnabled = KeyReader.forceSlips || !KeyReader.cleanlyReadable(keys, syllables: syllables, nextApostrophe: nextApostrophe)

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
            // Slips may change any letter, including the first.
            if n >= 3, slipsEnabled {
                for sid in 0..<UInt16(s) {
                    let mask = KeyReader.slips(keys, at: q, limit: nextApostrophe[q], syllables.spelling(sid))
                    guard mask != 0 else { continue }
                    slipMask[q * s + Int(sid)] = mask
                    if syllables.spelling(sid).first != first { starts.append(sid) }
                }
            }
            startable[q] = starts
        }
    }

    /// Do the keys read as complete full syllables end to end? (A half-typed
    /// last syllable does not count: `nihap` may well be 你好 with p for o.)
    /// Apostrophes separate.
    static func cleanlyReadable(_ keys: [UInt8], syllables: SyllableTable, nextApostrophe: [Int]) -> Bool {
        let n = keys.count
        guard n > 0 else { return true }
        var reach = [Bool](repeating: false, count: n + 1)
        reach[0] = true
        for q in 0..<n where reach[q] {
            if keys[q] == KeyReader.apostrophe { reach[q + 1] = true; continue }
            for sid in syllables.startingWith(keys[q]) {
                for sp in syllables.spellings(sid) {
                    if hasPrefix(keys, at: q, sp) { reach[q + sp.count] = true }
                }
            }
        }
        return reach[n]
    }

    /// Testing hook: compute slips for every input.
    nonisolated(unsafe) public static var forceSlips = ProcessInfo.processInfo.environment["ZHIYIN_FORCE_SLIPS"] != nil

    /// At most this many slips in one reading of the whole input.
    public static let maxSlips = 2

    /// QWERTY neighbours, for "a neighbouring key was hit instead".
    static let neighbours: [[Bool]] = {
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { Array($0.utf8) }
        var table = [[Bool]](repeating: [Bool](repeating: false, count: 26), count: 26)
        func link(_ a: UInt8, _ b: UInt8) {
            table[Int(a - 97)][Int(b - 97)] = true
            table[Int(b - 97)][Int(a - 97)] = true
        }
        for (r, row) in rows.enumerated() {
            for (i, ch) in row.enumerated() {
                if i + 1 < row.count { link(ch, row[i + 1]) }
                if r + 1 < rows.count {
                    let below = rows[r + 1]
                    // The row below is offset half a key to the right.
                    if i < below.count { link(ch, below[i]) }
                    if i - 1 >= 0, i - 1 < below.count { link(ch, below[i - 1]) }
                }
            }
        }
        return table
    }()

    static func near(_ a: UInt8, _ b: UInt8) -> Bool {
        guard a >= 97, a <= 122, b >= 97, b <= 122 else { return false }
        return neighbours[Int(a - 97)][Int(b - 97)]
    }

    /// Which one-slip spellings of `sp` start at q (see slipMask), never
    /// reading across an apostrophe at `limit`.
    static func slips(_ keys: [UInt8], at q: Int, limit: Int, _ sp: [UInt8]) -> UInt8 {
        let L = sp.count
        guard L >= 2 else { return 0 }
        var mask: UInt8 = 0
        // A neighbouring key, or two letters swapped: same length.
        if q + L <= limit {
            var diffs: [Int] = []
            for i in 0..<L where keys[q + i] != sp[i] {
                diffs.append(i)
                if diffs.count > 2 { break }
            }
            if diffs.count == 1, near(keys[q + diffs[0]], sp[diffs[0]]) { mask |= 2 }
            if diffs.count == 2, diffs[1] == diffs[0] + 1,
               keys[q + diffs[0]] == sp[diffs[1]], keys[q + diffs[1]] == sp[diffs[0]] { mask |= 2 }
        }
        // One letter missing (never the first).
        if L >= 3, q + L - 1 <= limit {
            for skip in 1..<L {
                var ok = true
                var k = q
                for i in 0..<L where i != skip {
                    if keys[k] != sp[i] { ok = false; break }
                    k += 1
                }
                if ok { mask |= 1; break }
            }
        }
        // One letter extra (never before the first): a doubled letter or a
        // neighbour of the letter beside it.
        if q + L + 1 <= limit {
            for extra in 1...L {
                var ok = true
                for i in 0..<L where keys[q + (i < extra ? i : i + 1)] != sp[i] { ok = false; break }
                guard ok else { continue }
                let x = keys[q + extra]
                let before = sp[extra - 1]
                let after: UInt8 = extra < L ? sp[extra] : 0
                if x == before || x == after || near(x, before) || (after != 0 && near(x, after)) {
                    mask |= 4
                    break
                }
            }
        }
        return mask
    }

    public static let apostrophe = UInt8(ascii: "'")

    /// Skip a syllable-separating apostrophe at a character boundary.
    @inline(__always)
    public func skipSeparator(_ p: Int) -> Int {
        p < keys.count && keys[p] == KeyReader.apostrophe ? p + 1 : p
    }
    // `startable` has n + 1 rows; row n (end of keys) is always empty.

    public enum Reading: UInt8, Sendable {
        case full = 0
        /// By initial, or by prefix where the keys run out.
        case abbreviated = 1
        /// Through a slip of the finger (走音).
        case slip = 2
    }

    /// Calls `body(end, how)` for every end position reachable by reading one
    /// character with `readings` from position p.
    @inline(__always)
    public func forEachEnd(
        from p: Int,
        readings: UnsafeBufferPointer<UInt16>,
        _ body: (Int, Reading) -> Void
    ) {
        let q = skipSeparator(p)
        let n = keys.count
        guard q < n, !readings.isEmpty else { return }
        let s = syllables.count
        let row = q * s
        // Distinct ends, the cheapest way of reaching each kept, on the stack
        // (this runs for every trie node visited). Bounded: ≤2 spellings, an
        // initial pair, a prefix end, three slip lengths.
        var store: (Int, Int, Int, Int, Int, Int, Int, Int) = (0, 0, 0, 0, 0, 0, 0, 0)
        var count = 0
        withUnsafeMutableBytes(of: &store) { raw in
            let slots = raw.baseAddress!.assumingMemoryBound(to: Int.self)
            // slot = end << 2 | kind
            func add(_ end: Int, _ how: Reading) {
                guard end <= n else { return }
                for i in 0..<count where slots[i] >> 2 == end {
                    if Int(how.rawValue) < slots[i] & 3 { slots[i] = end << 2 | Int(how.rawValue) }
                    return
                }
                guard count < 8 else { return }
                slots[count] = end << 2 | Int(how.rawValue)
                count += 1
            }
            var spelledOut = false
            for r in readings {
                let length = fullLength[row + Int(r)]
                if length > 0 {
                    add(q + Int(length), .full)
                    spelledOut = true
                }
            }
            if !spelledOut {
                for r in readings {
                    let mask = initialMask[row + Int(r)]
                    if mask & 1 != 0 { add(q + 1, .abbreviated) }
                    if mask & 2 != 0 { add(q + 2, .abbreviated) }
                }
            }
            for r in readings where partial[row + Int(r)] {
                add(n, .abbreviated)
            }
            // Slips are offered even beside a full spelling (niihao: 你 spells
            // ni, then the doubled i is a slip); their cost keeps them from
            // winning unless the clean reading leads nowhere.
            if slipsEnabled {
                for r in readings {
                    let mask = slipMask[row + Int(r)]
                    guard mask != 0 else { continue }
                    let L = syllables.spelling(r).count
                    if mask & 1 != 0 { add(q + L - 1, .slip) }
                    if mask & 2 != 0 { add(q + L, .slip) }
                    if mask & 4 != 0 { add(q + L + 1, .slip) }
                }
            }
            for i in 0..<count { body(slots[i] >> 2, Reading(rawValue: UInt8(slots[i] & 3))!) }
        }
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
