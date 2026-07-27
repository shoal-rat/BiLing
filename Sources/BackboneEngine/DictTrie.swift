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
    /// "previous word\u{1}next word" → P(next | previous), held in memory
    /// because the beam asks thousands of times per keystroke.
    private var transitions: [String: Double] = [:]
    public private(set) var transitionCount = 0

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
        entryCount = Self.scalarInt(handle, sql: "SELECT COUNT(*) FROM entries;")
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

    public static func bundled() throws -> DictTrie {
        if let packagedBundleURL = Bundle.main.resourceURL?
            .appendingPathComponent("BiLing_BackboneEngine.bundle"),
           let packagedBundle = Bundle(url: packagedBundleURL),
           let url = packagedBundle.url(forResource: "lexicon", withExtension: "sqlite3") {
            return try DictTrie(databaseURL: url)
        }
        if let url = Bundle.module.url(forResource: "lexicon", withExtension: "sqlite3") {
            return try DictTrie(databaseURL: url)
        }
        // Keep the text loader for development migrations and small fixtures.
        if let url = Bundle.module.url(forResource: "lexicon", withExtension: "tsv") {
            return try DictTrie(contentsOf: url)
        }
        throw BackboneError.lexiconMissing
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
        transitions.reserveCapacity(120_000)
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let previous = Self.columnText(statement, index: 0),
                  let next = Self.columnText(statement, index: 1) else { continue }
            transitions[previous + "\u{1}" + next] = sqlite3_column_double(statement, 2)
        }
        transitionCount = transitions.count
    }

    /// P(next | previous), or 0 when the pair was never observed.
    public func transition(from previous: String, to next: String) -> Double {
        transitions[previous + "\u{1}" + next] ?? 0
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

    public var errorDescription: String? {
        switch self {
        case .lexiconMissing:
            return "The bundled pinyin lexicon is missing."
        case .lexiconOpenFailed:
            return "The bundled pinyin lexicon could not be opened."
        }
    }
}
