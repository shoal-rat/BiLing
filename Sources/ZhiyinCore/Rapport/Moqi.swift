import CryptoKit
import Foundation
import Security

/// 默契 · Rapport.
///
/// The understanding that grows between player and listener. 默契 remembers
/// what you chose for which keys, and how recently, so the second time is
/// easier than the first. Everything stays on this Mac, sealed with AES-GCM
/// under a key kept in your login Keychain; without that key the file is
/// noise. Nothing is learned while Secure Input is on (password fields), and
/// nothing that looks like a URL, an address or a number.
public final class Moqi: @unchecked Sendable {
    public struct Memory: Codable, Sendable, Hashable {
        public let keys: String
        public let text: String
        /// Uses, decayed with a three-week half-life.
        public internal(set) var weight: Double
        public internal(set) var last: Double
        /// Chosen at least once when it was not the first candidate offered.
        public internal(set) var chosenOverTop: Bool

        public var strength: Double {
            weight * pow(0.5, (Date().timeIntervalSince1970 - last) / Moqi.halfLife)
        }
    }

    static let halfLife: Double = 21 * 86400
    static let capacity = 20000

    private var byKeys: [String: [Memory]] = [:]
    private let lock = NSLock()
    private let store: URL?
    private var key: SymmetricKey?
    private var dirty = false

    /// A memory that is never written to disk (tests, evaluation).
    public init() {
        store = nil
    }

    public init(directory: URL) {
        store = directory.appendingPathComponent("moqi.sealed")
        key = Moqi.keychainKey()
        load()
    }

    public var count: Int { lock.withLock { byKeys.values.reduce(0) { $0 + $1.count } } }

    public func recall(_ keys: String) -> [Memory] {
        lock.withLock {
            // Exact entries plus entries for every prefix of the keys, so a
            // remembered word is offered when it starts a longer input.
            var out: [Memory] = []
            var prefix = ""
            for ch in keys {
                prefix.append(ch)
                if let list = byKeys[prefix] { out.append(contentsOf: list) }
            }
            return out
        }
    }

    public var all: [Memory] {
        lock.withLock { byKeys.values.flatMap { $0 }.sorted { $0.last > $1.last } }
    }

    /// Records a choice. `overTop` is true when the user passed over the
    /// first candidate to make it.
    public func remember(keys: String, text: String, overTop: Bool) {
        guard Moqi.learnable(keys: keys, text: text) else { return }
        let now = Date().timeIntervalSince1970
        lock.withLock {
            var list = byKeys[keys] ?? []
            if let i = list.firstIndex(where: { $0.text == text }) {
                var m = list[i]
                m.weight = m.strength + 1
                m.last = now
                m.chosenOverTop = m.chosenOverTop || overTop
                list[i] = m
            } else {
                list.append(Memory(keys: keys, text: text, weight: 1, last: now, chosenOverTop: overTop))
            }
            byKeys[keys] = list
            dirty = true
        }
        trim()
    }

    public func forget(keys: String, text: String) {
        lock.withLock {
            byKeys[keys]?.removeAll { $0.text == text }
            if byKeys[keys]?.isEmpty == true { byKeys[keys] = nil }
            dirty = true
        }
        save()
    }

    public func forgetAll() {
        lock.withLock {
            byKeys = [:]
            dirty = true
        }
        save()
    }

    /// Plain JSON of everything remembered — your data, to take with you.
    public func export() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(all)
    }

    static func learnable(keys: String, text: String) -> Bool {
        guard !keys.isEmpty, !text.isEmpty, text.count <= 24 else { return false }
        if text.contains("@") || text.contains("://") || text.hasPrefix("www.") { return false }
        if text.unicodeScalars.filter({ CharacterSet.decimalDigits.contains($0) }).count >= 4 { return false }
        // Only Han text is learned; Latin words are typed letter for letter anyway.
        return text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
    }

    private func trim() {
        lock.withLock {
            let total = byKeys.values.reduce(0) { $0 + $1.count }
            guard total > Moqi.capacity else { return }
            let all = byKeys.values.flatMap { $0 }.sorted { $0.strength < $1.strength }
            for m in all.prefix(total - Moqi.capacity) {
                byKeys[m.keys]?.removeAll { $0.text == m.text }
                if byKeys[m.keys]?.isEmpty == true { byKeys[m.keys] = nil }
            }
        }
    }

    // MARK: - Sealed storage

    public func save() {
        guard let store, let key else { return }
        let snapshot: [Memory]? = lock.withLock {
            guard dirty else { return nil }
            dirty = false
            return byKeys.values.flatMap { $0 }
        }
        guard let snapshot, let plain = try? JSONEncoder().encode(snapshot),
              let sealed = try? AES.GCM.seal(plain, using: key).combined else { return }
        try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? sealed.write(to: store, options: [.atomic, .completeFileProtection])
        var url = store
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func load() {
        guard let store, let key, let sealed = try? Data(contentsOf: store),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: key),
              let list = try? JSONDecoder().decode([Memory].self, from: plain) else { return }
        for m in list { byKeys[m.keys, default: []].append(m) }
    }

    static let keychainService = "com.zhiyin.inputmethod.moqi"

    static func keychainKey() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "sealing-key",
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        let fresh = SymmetricKey(size: .bits256)
        let data = fresh.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "sealing-key",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        // Without a Keychain we keep memories in memory only, never in plain text.
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? fresh : nil
    }
}
