import Foundation

/// Decrypts the local learning store into mlx-lm-format JSONL for LoRA
/// training. Runs only when the user invokes it (`biling-cli
/// --export-training-data`); macOS may show a Keychain prompt because a
/// different binary is reading the store's key — that is expected.
public enum TrainingDataExporter {
    public static func export(to directory: URL) throws -> Int {
        let storeURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BiLing/learning.sqlite3")
        let store = try EncryptedUserDictionary(url: storeURL)
        let items = store.learnedItems()

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var lines: [String] = []
        for item in items {
            // Weight by usage, capped so no single phrase dominates.
            for _ in 0..<max(1, min(item.count, 4)) {
                lines.append(jsonLine(item.text))
            }
        }
        guard !lines.isEmpty else {
            try write([], to: directory)
            return 0
        }
        lines.shuffle()
        try write(lines, to: directory)
        return items.count
    }

    private static func write(_ lines: [String], to directory: URL) throws {
        // mlx-lm requires a non-empty validation set; hold out every tenth
        // line and fall back to duplicating when there is little data.
        var train: [String] = []
        var valid: [String] = []
        for (index, line) in lines.enumerated() {
            if index % 10 == 9 { valid.append(line) } else { train.append(line) }
        }
        if valid.isEmpty { valid = Array(train.prefix(2)) }
        if train.isEmpty { train = valid }
        try (train.joined(separator: "\n") + "\n")
            .write(to: directory.appendingPathComponent("train.jsonl"), atomically: true, encoding: .utf8)
        try (valid.joined(separator: "\n") + "\n")
            .write(to: directory.appendingPathComponent("valid.jsonl"), atomically: true, encoding: .utf8)
    }

    private static func jsonLine(_ text: String) -> String {
        let data = (try? JSONEncoder().encode(["text": text])) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"text": ""}"#
    }
}
