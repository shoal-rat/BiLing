import CSQLite
import Foundation
import PinyinLattice

public struct LexiconEntry: Hashable, Sendable {
    public let key: String
    public let text: String
    public let weight: Double
    public let displayPinyin: String
}

public final class DictTrie: @unchecked Sendable {
    private struct Node {
        var children: [Character: Int] = [:]
        var entries: [LexiconEntry] = []
    }

    private var nodes: [Node] = [Node()]
    private var database: OpaquePointer?
    private let databaseQueue = DispatchQueue(label: "com.biling.lexicon-database")
    private var exactStatement: OpaquePointer?
    private var prefixProbeStatement: OpaquePointer?
    private var abbrevStatement: OpaquePointer?
    private var mixedStatement: OpaquePointer?
    private var maxKeyLength = 24
    public private(set) var syllables: Set<String> = []
    public private(set) var entryCount = 0
    /// log of the summed corpus weight; the unigram normaliser.
    public private(set) var logTotalWeight: Double = 22.0
    /// log of the largest corpus weight; anchors personalised entries.
    public private(set) var logMaxWeight: Double = 16.0
    /// Transition tables, keyed by a 64-bit hash of the word sequence rather
    /// than by the words themselves. The decoder asks thousands of times per
    /// keystroke so these must be in memory, but string keys cost far more than
    /// the numbers they index — 1.8M of them held 215 MB, which is not a price
    /// an always-running input method should pay. Hashing drops that to a
    /// fraction; over this many entries a 64-bit collision is a ~10⁻⁷ event and
    /// would cost one candidate one wrong probability, not correctness.
    private var transitions: [UInt64: Float] = [:]
    public private(set) var transitionCount = 0
    /// "w-2\u{1}w-1\u{1}w" → P(w | w-2, w-1), used to rescore the n-best list.
    private var trigrams: [UInt64: Float] = [:]
    private var unigramByText: [String: Double] = [:]
    private var characterCache: [String: [LexiconEntry]] = [:]
    /// Personal-name model: how likely a character opens a name, and how
    /// likely it sits at given-name position 1 or 2.
    private var surnameLogP: [String: Double] = [:]
    private var givenLogP: [String: Double] = [:]
    public private(set) var hasNameModel = false

    public init(entries: [LexiconEntry]) {
        for entry in entries {
            insert(entry)
            for syllable in entry.displayPinyin.split(separator: " ") {
                syllables.insert(String(syllable))
            }
        }
        for index in nodes.indices {
            nodes[index].entries.sort(by: Self.entryOrder)
        }
    }

    private init(databaseURL: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw BackboneError.lexiconOpenFailed
        }
        database = handle
        // Validate before reading anything else. SQLite opens lazily, so a
        // Git LFS pointer file (a checkout without `git lfs pull`) or a
        // truncated copy "opens" fine and would otherwise surface as an
        // engine with zero entries that silently returns nothing. Probing the
        // entries table forces the first real read and turns that state into
        // a diagnosis.
        var probe: OpaquePointer?
        let prepared = sqlite3_prepare_v2(
            handle,
            "SELECT COUNT(*) FROM entries;",
            -1,
            &probe,
            nil
        )
        guard prepared == SQLITE_OK, probe != nil else {
            let detail = String(cString: sqlite3_errmsg(handle))
            sqlite3_finalize(probe)
            sqlite3_close(handle)
            database = nil
            throw BackboneError.lexiconInvalid(path: databaseURL.path, detail: detail)
        }
        let stepped = sqlite3_step(probe)
        let probedCount = Int(sqlite3_column_int64(probe, 0))
        sqlite3_finalize(probe)
        guard stepped == SQLITE_ROW, probedCount > 0 else {
            let detail = stepped == SQLITE_ROW
                ? "the entries table is empty"
                : String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            database = nil
            throw BackboneError.lexiconInvalid(path: databaseURL.path, detail: detail)
        }
        entryCount = probedCount
        if let stored = Self.scalarText(
            handle,
            sql: "SELECT value FROM metadata WHERE name = 'log_total_weight';"
        ), let parsed = Double(stored) {
            logTotalWeight = parsed
        }
        if let stored = Self.scalarText(
            handle,
            sql: "SELECT value FROM metadata WHERE name = 'log_max_weight';"
        ), let parsed = Double(stored) {
            logMaxWeight = parsed
        }
        loadTransitions(handle)
        loadTrigrams(handle)
        loadNameModel(handle)
        maxKeyLength = max(1, Self.scalarInt(handle, sql: "SELECT MAX(LENGTH(key)) FROM entries;"))
        syllables = SyllableInventory.standard.syllables
        sqlite3_prepare_v2(
            handle,
            "SELECT key, text, weight, pinyin FROM entries WHERE key = ? ORDER BY weight DESC LIMIT ?;",
            -1,
            &exactStatement,
            nil
        )
        // Pinyin keys are pure a–z, so [prefix, prefix + "{") covers exactly the
        // keys that start with prefix; one index probe replaces a full query per
        // dead-end prefix during sentence search.
        sqlite3_prepare_v2(
            handle,
            "SELECT 1 FROM entries WHERE key >= ? AND key < ? LIMIT 1;",
            -1,
            &prefixProbeStatement,
            nil
        )
        // Fails harmlessly on format-1 databases without the abbrev column;
        // abbreviation lookup then just returns nothing.
        sqlite3_prepare_v2(
            handle,
            "SELECT key, text, weight, pinyin FROM entries WHERE abbrev = ? ORDER BY weight DESC LIMIT ?;",
            -1,
            &abbrevStatement,
            nil
        )
        sqlite3_prepare_v2(
            handle,
            "SELECT key, text, weight, pinyin FROM entries WHERE mixed = ? AND mixed <> '' ORDER BY weight DESC LIMIT ?;",
            -1,
            &mixedStatement,
            nil
        )
    }

    deinit {
        if let exactStatement { sqlite3_finalize(exactStatement) }
        if let prefixProbeStatement { sqlite3_finalize(prefixProbeStatement) }
        if let abbrevStatement { sqlite3_finalize(abbrevStatement) }
        if let mixedStatement { sqlite3_finalize(mixedStatement) }
        if let database {
            sqlite3_close(database)
        }
    }

    /// Environment variable that redirects `bundled()` to an absolute lexicon
    /// path. CI uses it to run against the checked-in fixture, because the
    /// real lexicon is a Git LFS object the runner never downloads.
    public static let lexiconPathVariable = "BILING_LEXICON_PATH"

    /// The database `bundled()` will open, in resolution order, without
    /// opening anything. Exposed so tests can decide up front whether the
    /// full production lexicon is present — an LFS checkout without
    /// `git lfs pull` leaves a small ASCII pointer file at the bundle path.
    public static func resolvedLexiconURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment[lexiconPathVariable] {
            return URL(fileURLWithPath: override)
        }
        if let packagedBundleURL = Bundle.main.resourceURL?
            .appendingPathComponent("BiLing_BackboneEngine.bundle"),
           let packagedBundle = Bundle(url: packagedBundleURL),
           let url = packagedBundle.url(forResource: "lexicon", withExtension: "sqlite3") {
            return url
        }
        if let url = Bundle.module.url(forResource: "lexicon", withExtension: "sqlite3") {
            return url
        }
        // Keep the text loader for development migrations and small fixtures.
        if let url = Bundle.module.url(forResource: "lexicon", withExtension: "tsv") {
            return url
        }
        return nil
    }

    public static func bundled() throws -> DictTrie {
        if let override = ProcessInfo.processInfo.environment[lexiconPathVariable],
           !FileManager.default.isReadableFile(atPath: override) {
            // A set-but-wrong override must stop the process rather than fall
            // through to a bundle that may itself be an LFS pointer; silently
            // loading a different lexicon than the caller asked for is worse
            // than crashing.
            fatalError(
                "\(lexiconPathVariable) is set to '\(override)', but no readable file exists there. "
                    + "Unset the variable to use the bundled lexicon, or point it at a database built by "
                    + "scripts/build_dictionary.py or scripts/build_fixture_lexicon.py."
            )
        }
        guard let url = resolvedLexiconURL() else {
            throw BackboneError.lexiconMissing
        }
        return try DictTrie(contentsOf: url)
    }

    public convenience init(contentsOf url: URL) throws {
        if url.pathExtension == "sqlite3" {
            try self.init(databaseURL: url)
            return
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var entries: [LexiconEntry] = []
        entries.reserveCapacity(80_000)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.first == "#" { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 4, let weight = Double(fields[2]) else { continue }
            entries.append(
                LexiconEntry(
                    key: String(fields[0]),
                    text: String(fields[1]),
                    weight: weight,
                    displayPinyin: String(fields[3])
                )
            )
        }
        self.init(entries: entries)
    }

    public func exact(_ key: String, limit: Int = 200) -> [LexiconEntry] {
        guard database != nil else {
            var nodeIndex = 0
            for character in key {
                guard let child = nodes[nodeIndex].children[character] else { return [] }
                nodeIndex = child
            }
            return Array(nodes[nodeIndex].entries.prefix(limit))
        }

        return databaseQueue.sync {
            guard let statement = exactStatement else { return [] }
            defer {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
            sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 2, Int32(limit))
            var result: [LexiconEntry] = []
            result.reserveCapacity(min(limit, 64))
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let storedKey = Self.columnText(statement, index: 0),
                      let text = Self.columnText(statement, index: 1),
                      let pinyin = Self.columnText(statement, index: 3) else { continue }
                result.append(
                    LexiconEntry(
                        key: storedKey,
                        text: text,
                        weight: sqlite3_column_double(statement, 2),
                        displayPinyin: pinyin
                    )
                )
            }
            return result
        }
    }

    /// Entries whose syllable initials spell `abbrev` exactly (简拼):
    /// "jldx" → 吉林大学, "hy" → 还有 / 行业 / 会议. Empty on format-1
    /// databases that predate the abbrev column.
    /// Entries whose syllable initials spell `abbrev` (jldx → 吉林大学).
    public func abbreviated(_ abbrev: String, limit: Int = 8) -> [LexiconEntry] {
        coded(abbrev, statement: abbrevStatement, limit: limit)
    }

    /// Entries written first-syllable-in-full then initials (meiy → 没有,
    /// kongt → 空调) — the way people abbreviate in the middle of a sentence.
    public func mixedCoded(_ code: String, limit: Int = 4) -> [LexiconEntry] {
        coded(code, statement: mixedStatement, limit: limit)
    }

    private func coded(
        _ code: String,
        statement candidateStatement: OpaquePointer?,
        limit: Int
    ) -> [LexiconEntry] {
        guard database != nil else { return [] }
        return databaseQueue.sync {
            guard let statement = candidateStatement else { return [] }
            defer {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
            sqlite3_bind_text(statement, 1, code, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 2, Int32(limit))
            var result: [LexiconEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let storedKey = Self.columnText(statement, index: 0),
                      let text = Self.columnText(statement, index: 1),
                      let pinyin = Self.columnText(statement, index: 3) else { continue }
                result.append(
                    LexiconEntry(
                        key: storedKey,
                        text: text,
                        weight: sqlite3_column_double(statement, 2),
                        displayPinyin: pinyin
                    )
                )
            }
            return result
        }
    }

    /// Reads the whole transition table once. It is small (~95k rows) and a
    /// per-extension SQLite lookup would cost more than the beam itself.
    private func loadTransitions(_ handle: OpaquePointer) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            handle,
            "SELECT prev, next, cond FROM bigrams;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return }
        transitions.reserveCapacity(800_000)
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let previous = Self.columnText(statement, index: 0),
                  let next = Self.columnText(statement, index: 1) else { continue }
            transitions[Self.key(previous, next)] = Float(sqlite3_column_double(statement, 2))
        }
        transitionCount = transitions.count
    }

    private func loadTrigrams(_ handle: OpaquePointer) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            handle,
            "SELECT first, second, next, cond FROM trigrams;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let a = Self.columnText(statement, index: 0),
                  let b = Self.columnText(statement, index: 1),
                  let c = Self.columnText(statement, index: 2) else { continue }
                trigrams[Self.key(a, b, c)] = Float(sqlite3_column_double(statement, 3))
        }
    }

    /// P(next | first, second), or 0 when the triple was never observed.
    public func trigram(_ first: String, _ second: String, _ next: String) -> Double {
        trigrams[Self.key(first, second, next)].map(Double.init) ?? 0
    }

    private func loadNameModel(_ handle: OpaquePointer) {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(handle, "SELECT char, logp FROM surnames;", -1, &statement, nil) == SQLITE_OK,
           let statement {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let character = Self.columnText(statement, index: 0) {
                    surnameLogP[character] = sqlite3_column_double(statement, 1)
                }
            }
        }
        sqlite3_finalize(statement)
        statement = nil
        if sqlite3_prepare_v2(handle, "SELECT char, position, logp FROM given_chars;", -1, &statement, nil) == SQLITE_OK,
           let statement {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let character = Self.columnText(statement, index: 0) {
                    let position = Int(sqlite3_column_int(statement, 1))
                    givenLogP["\(position)\u{1}" + character] = sqlite3_column_double(statement, 2)
                }
            }
        }
        sqlite3_finalize(statement)
        hasNameModel = !surnameLogP.isEmpty && !givenLogP.isEmpty
    }

    /// Log-probability that this character opens a personal name, or nil when
    /// it is not a surname.
    public func surnameLogProbability(_ character: String) -> Double? {
        surnameLogP[character]
    }

    /// Log-probability of a character at the given position of a given name.
    public func givenNameLogProbability(_ character: String, position: Int) -> Double? {
        givenLogP["\(position)\u{1}" + character]
    }

    /// Characters for this syllable that are surnames, with their weights.
    public func surnameCharacters(forSyllable syllable: String) -> [(text: String, logp: Double)] {
        var found: [(text: String, logp: Double)] = []
        for entry in charactersForSyllable(syllable, limit: 40) {
            guard let logp = surnameLogP[entry.text] else { continue }
            found.append((text: entry.text, logp: logp))
        }
        return found
    }

    /// Characters for this syllable that are plausible at a given-name
    /// position, best first.
    public func givenNameCharacters(
        forSyllable syllable: String,
        position: Int,
        limit: Int = 6
    ) -> [(text: String, logp: Double)] {
        var scored: [(text: String, logp: Double)] = []
        for entry in charactersForSyllable(syllable, limit: 40) {
            guard let logp = givenLogP["\(position)\u{1}" + entry.text] else { continue }
            scored.append((text: entry.text, logp: logp))
        }
        scored.sort { $0.logp > $1.logp }
        return Array(scored.prefix(limit))
    }

    /// Single characters that can be written for one syllable, most frequent
    /// first.
    ///
    /// This is the character-level half of the lattice. Word edges alone can
    /// only produce sequences the lexicon already contains as entries, so a
    /// name or coinage nobody has listed is unreachable no matter how the
    /// search is tuned. Letting every valid syllable also stand for its
    /// individual characters makes those constructible, at the cost of a wider
    /// lattice — which the per-segment cost already prices, since a path of
    /// many single characters pays the segment penalty many times.
    public func charactersForSyllable(_ syllable: String, limit: Int = 12) -> [LexiconEntry] {
        if let cached = characterCache[syllable] { return Array(cached.prefix(limit)) }
        let entries = exact(syllable, limit: 64).filter { $0.text.count == 1 }
        characterCache[syllable] = entries
        return Array(entries.prefix(limit))
    }

    /// Corpus weight of a word by its text, for rescoring a finished path
    /// where the originating lexicon entry is no longer to hand.
    public func unigramWeight(of text: String) -> Double {
        if let cached = unigramByText[text] { return cached }
        guard let database else { return 1 }
        let weight: Double = databaseQueue.sync {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(
                database,
                "SELECT MAX(weight) FROM entries WHERE text = ?;",
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement else { return 1 }
            sqlite3_bind_text(statement, 1, text, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(statement) == SQLITE_ROW else { return 1 }
            let value = sqlite3_column_double(statement, 0)
            return value > 0 ? value : 1
        }
        unigramByText[text] = weight
        return weight
    }

    /// P(next | previous), or 0 when the pair was never observed.
    public func transition(from previous: String, to next: String) -> Double {
        transitions[Self.key(previous, next)].map(Double.init) ?? 0
    }

    /// FNV-1a over the words with a separator, so the table needs no strings.
    private static func key(_ parts: String...) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for (index, part) in parts.enumerated() {
            if index > 0 {
                hash = (hash ^ 0x1f) &* 0x100000001b3
            }
            for byte in part.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100000001b3
            }
        }
        return hash
    }

    /// Context marker for the first word of a composition.
    public static let sentenceStart = "\u{2}"

    private func hasKeyPrefix(_ prefix: String) -> Bool {
        databaseQueue.sync {
            guard let statement = prefixProbeStatement else { return true }
            defer {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
            sqlite3_bind_text(statement, 1, prefix, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, prefix + "{", -1, SQLITE_TRANSIENT)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    public func matches(
        in characters: [Character],
        from start: Int,
        maxEntriesPerKey: Int = 4
    ) -> [(Int, LexiconEntry)] {
        guard start < characters.count else { return [] }
        if database == nil {
            var output: [(Int, LexiconEntry)] = []
            var nodeIndex = 0
            var cursor = start
            while cursor < characters.count,
                  let child = nodes[nodeIndex].children[characters[cursor]] {
                nodeIndex = child
                cursor += 1
                for entry in nodes[nodeIndex].entries.prefix(maxEntriesPerKey) {
                    output.append((cursor, entry))
                }
            }
            return output
        }

        var output: [(Int, LexiconEntry)] = []
        var prefix = ""
        let upper = min(characters.count, start + maxKeyLength)
        for cursor in start..<upper {
            prefix.append(characters[cursor])
            let entries = exact(prefix, limit: maxEntriesPerKey)
            if entries.isEmpty {
                // Only pay for the range probe when there is nothing to return.
                // Asking "does any key start with this?" before every lookup
                // doubled the statement dispatches for the common case, where
                // the lookup itself would have answered.
                if !hasKeyPrefix(prefix) { break }
            } else {
                for entry in entries {
                    output.append((cursor + 1, entry))
                }
            }
        }
        return output
    }

    private func insert(_ entry: LexiconEntry) {
        var nodeIndex = 0
        for character in entry.key {
            if let child = nodes[nodeIndex].children[character] {
                nodeIndex = child
            } else {
                let child = nodes.count
                nodes.append(Node())
                nodes[nodeIndex].children[character] = child
                nodeIndex = child
            }
        }
        if !nodes[nodeIndex].entries.contains(where: { $0.text == entry.text }) {
            nodes[nodeIndex].entries.append(entry)
            entryCount += 1
        }
    }

    private static func entryOrder(_ lhs: LexiconEntry, _ rhs: LexiconEntry) -> Bool {
        if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
        return lhs.text.count < rhs.text.count
    }

    private static func columnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private static func scalarText(_ database: OpaquePointer, sql: String) -> String? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let statement else { return nil }
        return columnText(statement, index: 0)
    }

    private static func scalarInt(_ database: OpaquePointer, sql: String) -> Int {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum BackboneError: LocalizedError {
    case lexiconMissing
    case lexiconOpenFailed
    case lexiconInvalid(path: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .lexiconMissing:
            return "The bundled pinyin lexicon is missing."
        case .lexiconOpenFailed:
            return "The bundled pinyin lexicon could not be opened."
        case .lexiconInvalid(let path, let detail):
            return "The pinyin lexicon at \(path) is not a usable database (\(detail)). "
                + "If this is a Git LFS checkout, run `git lfs pull`; otherwise set "
                + "\(DictTrie.lexiconPathVariable) to a lexicon built by scripts/build_dictionary.py "
                + "or scripts/build_fixture_lexicon.py."
        }
    }
}
