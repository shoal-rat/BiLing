// The syllable inventory. Ids are positions in the list stored in each trie
// file's header, so the score, the listener's vocabulary and the training
// pipeline always agree on what syllable 17 is.

public struct SyllableTable: Sendable {
    public let names: [String]
    private let bytes: [[UInt8]]
    private let alternates: [[[UInt8]]]
    private let byFirstLetter: [[UInt16]]
    private let index: [String: UInt16]

    public var count: Int { names.count }

    /// ü is typed v; many people also type u after l and n.
    static let aliases: [String: [String]] = ["lve": ["lue"], "nve": ["nue"]]

    public init(names: [String]) {
        self.names = names
        bytes = names.map { Array($0.utf8) }
        alternates = names.map { name in
            [Array(name.utf8)] + (SyllableTable.aliases[name] ?? []).map { Array($0.utf8) }
        }
        var letters = [[UInt16]](repeating: [], count: 26)
        var index: [String: UInt16] = [:]
        for (i, name) in names.enumerated() {
            index[name] = UInt16(i)
            if let first = name.utf8.first, first >= 97, first <= 122 {
                letters[Int(first - 97)].append(UInt16(i))
            }
        }
        byFirstLetter = letters
        self.index = index
    }

    public func id(_ name: String) -> UInt16? { index[name] }

    public func spelling(_ sid: UInt16) -> [UInt8] { bytes[Int(sid)] }

    public func spellings(_ sid: UInt16) -> [[UInt8]] { alternates[Int(sid)] }

    public func startingWith(_ letter: UInt8) -> [UInt16] {
        guard letter >= 97, letter <= 122 else { return [] }
        return byFirstLetter[Int(letter - 97)]
    }

    static func isRetroflex(_ spelling: [UInt8]) -> Bool {
        spelling.count >= 2 && spelling[1] == UInt8(ascii: "h")
            && (spelling[0] == UInt8(ascii: "z") || spelling[0] == UInt8(ascii: "c")
                || spelling[0] == UInt8(ascii: "s"))
    }
}
