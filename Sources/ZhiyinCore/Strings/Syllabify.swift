/// Splits keys into syllables for display on the strings (the inline
/// composition): `jilindaxue` → `ji lin da xue`, `jldx` → `j l d x`.
public enum Syllabify {
    public static func pieces(_ keys: [UInt8], syllables: SyllableTable) -> [String] {
        let n = keys.count
        guard n > 0 else { return [] }
        // cost = (letters left unread as syllables, pieces), minimised.
        var cost = [(Int, Int)](repeating: (Int.max, Int.max), count: n + 1)
        var back = [Int](repeating: -1, count: n + 1)
        cost[0] = (0, 0)
        func relax(_ from: Int, _ to: Int, _ loose: Int) {
            let c = (cost[from].0 + loose, cost[from].1 + 1)
            if c < cost[to] { cost[to] = c; back[to] = from }
        }
        for i in 0..<n where cost[i].0 != Int.max {
            if keys[i] == KeyReader.apostrophe {
                relax(i, i + 1, 0)
                continue
            }
            var matched = false
            for sid in syllables.startingWith(keys[i]) {
                for spelling in syllables.spellings(sid) {
                    if KeyReader.hasPrefix(keys, at: i, spelling) {
                        relax(i, i + spelling.count, 0)
                        matched = true
                    } else if KeyReader.isPrefix(keys, from: i, of: spelling) {
                        relax(i, n, 0)
                        matched = true
                    }
                }
            }
            relax(i, i + 1, matched ? 2 : 1)
        }
        var out: [String] = []
        var j = n
        while j > 0, back[j] >= 0 {
            let i = back[j]
            out.append(String(decoding: keys[i..<j], as: UTF8.self))
            j = i
        }
        return out.reversed()
    }

    public static func display(_ keys: String, syllables: SyllableTable) -> String {
        pieces(Array(keys.utf8), syllables: syllables)
            .filter { $0 != "'" }
            .joined(separator: " ")
    }
}
