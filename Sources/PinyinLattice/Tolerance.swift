import Foundation

/// Why a span of the keystroke buffer may be read as a syllable it does not
/// literally spell.
public enum AlternateOrigin: Hashable, Sendable {
    /// A dialect merger the user opted into (z/zh, n/l, an/ang, …). The typed
    /// and intended syllables are interchangeable *to the user*, so these are
    /// not errors and may surface even where the input reads fine as typed.
    case fuzzy
    /// One key hit instead of a physical neighbour on QWERTY.
    case substitution
    /// One letter left out.
    case omission
    /// One letter doubled.
    case duplication
    /// Two adjacent letters swapped.
    case transposition
}

/// A span of the typed buffer read as an alternative syllable.
public struct AlternateSyllable: Hashable, Sendable {
    public let start: Int
    public let end: Int
    public let syllable: String
    public let origin: AlternateOrigin

    public init(start: Int, end: Int, syllable: String, origin: AlternateOrigin) {
        self.start = start
        self.end = end
        self.syllable = syllable
        self.origin = origin
    }
}

/// A single-deviation rewrite of the whole buffer that reads as pinyin.
public struct WholeKeyVariant: Hashable, Sendable {
    public let key: String
    public let origin: AlternateOrigin

    public init(key: String, origin: AlternateOrigin) {
        self.key = key
        self.origin = origin
    }
}

/// Produces the alternative readings behind fuzzy pinyin and typing-error
/// tolerance. This type only *generates* alternates; what each one costs is
/// the score model's business, so the two concerns cannot drift apart.
public struct ToleranceGenerator: Sendable {
    public let inventory: SyllableInventory
    private let segmenter: Segmenter

    /// A generated syllable must consume at most this many typed letters —
    /// the longest real syllables (zhuang, chuang) have six.
    private static let maxSyllableLength = 6

    /// Hard ceiling on alternates per buffer. The decoder's lattice grows by a
    /// couple of edges per alternate, so this bounds the whole feature's cost
    /// on the keystroke path no matter how pathological the input.
    private static let maxAlternates = 24

    public init(inventory: SyllableInventory = .standard) {
        self.inventory = inventory
        self.segmenter = Segmenter(inventory: inventory)
    }

    /// Physical neighbours on QWERTY, the substitution model. Letters only:
    /// the buffer never contains anything else by the time it is segmented.
    static let qwertyNeighbours: [Character: [Character]] = [
        "q": ["w", "a"], "w": ["q", "e", "a", "s"], "e": ["w", "r", "s", "d"],
        "r": ["e", "t", "d", "f"], "t": ["r", "y", "f", "g"], "y": ["t", "u", "g", "h"],
        "u": ["y", "i", "h", "j"], "i": ["u", "o", "j", "k"], "o": ["i", "p", "k", "l"],
        "p": ["o", "l"],
        "a": ["q", "w", "s", "z"], "s": ["a", "d", "w", "e", "z", "x"],
        "d": ["s", "f", "e", "r", "x", "c"], "f": ["d", "g", "r", "t", "c", "v"],
        "g": ["f", "h", "t", "y", "v", "b"], "h": ["g", "j", "y", "u", "b", "n"],
        "j": ["h", "k", "u", "i", "n", "m"], "k": ["j", "l", "i", "o", "m"],
        "l": ["k", "o", "p"],
        "z": ["a", "s", "x"], "x": ["z", "c", "s", "d"], "c": ["x", "v", "d", "f"],
        "v": ["c", "b", "f", "g"], "b": ["v", "n", "g", "h"], "n": ["b", "m", "h", "j"],
        "m": ["n", "j", "k"],
    ]

    /// The fuzzy images of a span, one rule applied at a time.
    ///
    /// Initials pair the retroflex/flat mergers plus n/l and f/h; finals need
    /// only an/ang, en/eng, in/ing, because ian/iang and uan/uang are the
    /// an/ang rewrite occurring after i or u — the same suffix edit covers all
    /// five listed pairs. The span itself need not be a valid syllable (biang
    /// still maps to bian); the *result* must be, or it names nothing.
    public func fuzzyRewrites(of span: String) -> [String] {
        guard let first = span.first else { return [] }
        var rewrites: [String] = []
        func emit(_ candidate: String) {
            if candidate != span, inventory.syllables.contains(candidate),
               !rewrites.contains(candidate) {
                rewrites.append(candidate)
            }
        }
        switch first {
        case "z", "c", "s":
            // Check the retroflex form first: "zh" also has prefix "z", and
            // rewriting that "z" alone would produce "zhh…".
            if span.dropFirst().first == "h" {
                emit(String(first) + span.dropFirst(2))
            } else {
                emit("\(first)h" + span.dropFirst(1))
            }
        case "n": emit("l" + span.dropFirst(1))
        case "l": emit("n" + span.dropFirst(1))
        case "f": emit("h" + span.dropFirst(1))
        case "h": emit("f" + span.dropFirst(1))
        default: break
        }
        for (nasal, plain) in [("ang", "an"), ("eng", "en"), ("ing", "in")] {
            // Suffix checks are mutually exclusive (a span ending "ang" does
            // not end "an"), so the first hit is the only hit.
            if span.hasSuffix(nasal) {
                emit(String(span.dropLast(3)) + plain)
                break
            }
            if span.hasSuffix(plain) {
                emit(String(span.dropLast(2)) + nasal)
                break
            }
        }
        return rewrites
    }

    /// Alternative syllable readings of spans of `key`.
    ///
    /// Fuzzy alternates are generated everywhere: to a user who merges z/zh
    /// the two spellings are the same sound, so a cleanly parsing buffer is
    /// still fair game. Typo alternates are confined to `typoStarts` — the
    /// caller passes the positions where exact segmentation dead-ends —
    /// except duplication, whose doubled letter is its own evidence and is
    /// cheap to detect anywhere. Each alternate embodies exactly one
    /// deviation, which is what keeps the lattice from exploding.
    public func alternates(
        in key: String,
        fuzzy: Bool,
        typoStarts: Set<Int>
    ) -> [AlternateSyllable] {
        let characters = Array(key)
        let count = characters.count
        guard count > 0 else { return [] }

        // Dedupe on the reading itself, keeping the cheapest origin: the same
        // span can reach the same syllable several ways, and the candidate
        // should pay the most plausible one.
        struct SpanReading: Hashable {
            let start: Int
            let end: Int
            let syllable: String
        }
        var collected: [SpanReading: AlternateOrigin] = [:]
        func admit(_ start: Int, _ end: Int, _ syllable: String, _ origin: AlternateOrigin) {
            let reading = SpanReading(start: start, end: end, syllable: syllable)
            if let existing = collected[reading], rank(existing) <= rank(origin) { return }
            collected[reading] = origin
        }

        if fuzzy {
            for start in 0..<count {
                // One-letter spans cannot host a rewrite that lands on a real
                // syllable, so start at two.
                for length in 2...Self.maxSyllableLength {
                    guard start + length <= count else { break }
                    let span = String(characters[start..<(start + length)])
                    for rewrite in fuzzyRewrites(of: span) {
                        admit(start, start + length, rewrite, .fuzzy)
                    }
                }
            }
        }

        for start in typoStarts.sorted() {
            guard start >= 0, start < count else { continue }
            for length in 1...Self.maxSyllableLength {
                guard start + length <= count else { break }
                var span = Array(characters[start..<(start + length)])
                // Substitution: each position replaced by a physical neighbour.
                for index in span.indices {
                    let original = span[index]
                    for neighbour in Self.qwertyNeighbours[original] ?? [] {
                        span[index] = neighbour
                        let candidate = String(span)
                        if inventory.syllables.contains(candidate) {
                            admit(start, start + length, candidate, .substitution)
                        }
                    }
                    span[index] = original
                }
                // Transposition: adjacent letters swapped back.
                for index in 0..<(length - 1) where span[index] != span[index + 1] {
                    span.swapAt(index, index + 1)
                    let candidate = String(span)
                    if inventory.syllables.contains(candidate) {
                        admit(start, start + length, candidate, .transposition)
                    }
                    span.swapAt(index, index + 1)
                }
                // Omission: the intended syllable has one letter the user
                // skipped, so try every insertion point.
                if length < Self.maxSyllableLength {
                    for index in 0...length {
                        for letter in "abcdefghijklmnopqrstuvwxyz" {
                            var candidate = span
                            candidate.insert(letter, at: index)
                            let text = String(candidate)
                            if inventory.syllables.contains(text) {
                                admit(start, start + length, text, .omission)
                            }
                        }
                    }
                }
            }
        }

        // Duplication: a doubled letter is visible without any dead-end
        // signal, so hunt for it directly wherever it occurs.
        for index in 1..<count where characters[index] == characters[index - 1] {
            let earliest = max(0, index - Self.maxSyllableLength)
            for start in earliest..<index {
                let lastEnd = min(count, start + Self.maxSyllableLength + 1)
                guard index + 1 <= lastEnd else { continue }
                for end in (index + 1)...lastEnd {
                    var repaired = Array(characters[start..<end])
                    repaired.remove(at: index - start)
                    let candidate = String(repaired)
                    if inventory.syllables.contains(candidate) {
                        admit(start, end, candidate, .duplication)
                    }
                }
            }
        }

        return collected
            .map { AlternateSyllable(start: $0.key.start, end: $0.key.end, syllable: $0.key.syllable, origin: $0.value) }
            .sorted {
                if rank($0.origin) != rank($1.origin) { return rank($0.origin) < rank($1.origin) }
                if ($0.end - $0.start) != ($1.end - $1.start) { return ($0.end - $0.start) > ($1.end - $1.start) }
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.syllable < $1.syllable
            }
            .prefix(Self.maxAlternates)
            .map { $0 }
    }

    /// Single-deviation rewrites of the whole buffer that read as pinyin end
    /// to end, for the whole-word lookup path (nihoa → nihao → 你好 as one
    /// lexicon entry rather than a stitch of characters).
    ///
    /// Which edits are tried depends on how the buffer already reads:
    ///
    /// * **Fuzzy** and **duplication** run on any buffer — the first is not an
    ///   error at all, and the second announces itself with the doubled letter.
    /// * **Transposition** runs only when the buffer does not parse: repairing
    ///   readable input would mean second-guessing it (gou is a word; guo was
    ///   probably not meant).
    /// * **Substitution** and **omission** are the widest nets, so they
    ///   additionally require a short buffer: on long input the lattice-level
    ///   alternates repair locally instead, and enumerating 26 insertions per
    ///   position would tax every keystroke of ordinary abbreviated typing.
    public func wholeKeyVariants(of key: String, fuzzy: Bool, typos: Bool) -> [WholeKeyVariant] {
        let characters = Array(key)
        let count = characters.count
        guard count >= 2, count <= 16 else { return [] }
        let parsesCleanly = segmenter.segment(key).isComplete

        var variants: [WholeKeyVariant] = []
        var seen: Set<String> = [key]
        func emit(_ candidate: [Character], _ origin: AlternateOrigin) {
            let text = String(candidate)
            guard !seen.contains(text) else { return }
            seen.insert(text)
            guard segmenter.segment(text).isComplete else { return }
            variants.append(WholeKeyVariant(key: text, origin: origin))
        }

        if fuzzy {
            for start in 0..<count {
                for length in 2...Self.maxSyllableLength {
                    guard start + length <= count else { break }
                    let span = String(characters[start..<(start + length)])
                    for rewrite in fuzzyRewrites(of: span) {
                        emit(Array(characters[0..<start]) + Array(rewrite) + Array(characters[(start + length)...]), .fuzzy)
                    }
                }
            }
        }

        guard typos else { return variants }

        for index in 1..<count where characters[index] == characters[index - 1] {
            var repaired = characters
            repaired.remove(at: index)
            emit(repaired, .duplication)
        }

        guard !parsesCleanly else { return variants }

        for index in 0..<(count - 1) where characters[index] != characters[index + 1] {
            var repaired = characters
            repaired.swapAt(index, index + 1)
            emit(repaired, .transposition)
        }

        guard count <= 8 else { return variants }

        for index in 0..<count {
            var repaired = characters
            for neighbour in Self.qwertyNeighbours[characters[index]] ?? [] {
                repaired[index] = neighbour
                emit(repaired, .substitution)
            }
            repaired[index] = characters[index]
        }
        for index in 0...count {
            for letter in "abcdefghijklmnopqrstuvwxyz" {
                var repaired = characters
                repaired.insert(letter, at: index)
                emit(repaired, .omission)
            }
        }
        return variants
    }

    /// Origins ordered by prior plausibility, for dedupe and for the alternate
    /// cap: when the budget runs out, the likelier explanations survive.
    private func rank(_ origin: AlternateOrigin) -> Int {
        switch origin {
        case .fuzzy: 0
        case .duplication: 1
        case .transposition: 2
        case .substitution: 3
        case .omission: 4
        }
    }
}
