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
    public private(set) var syllables: Set<String> = []
    public private(set) var entryCount = 0

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
        syllables = SyllableInventory.standard.syllables
    }

    deinit {
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
        guard let database else {
            var nodeIndex = 0
            for character in key {
                guard let child = nodes[nodeIndex].children[character] else { return [] }
                nodeIndex = child
            }
            return Array(nodes[nodeIndex].entries.prefix(limit))
        }

        return databaseQueue.sync {
            var statement: OpaquePointer?
            let sql = """
                SELECT key, text, weight, pinyin
                FROM entries
                WHERE key = ?
                ORDER BY weight DESC
                LIMIT ?;
                """
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { return [] }
            defer { sqlite3_finalize(statement) }
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
        for cursor in start..<characters.count {
            prefix.append(characters[cursor])
            for entry in exact(prefix, limit: maxEntriesPerKey) {
                output.append((cursor + 1, entry))
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
