import Foundation

public struct SyllableEdge: Hashable, Codable, Sendable {
    public let start: Int
    public let end: Int
    public let syllable: String

    public init(start: Int, end: Int, syllable: String) {
        self.start = start
        self.end = end
        self.syllable = syllable
    }
}

public struct Segmentation: Equatable, Sendable {
    public let paths: [[String]]
    public let consumedCharacters: Int
    public let inputLength: Int

    public var isComplete: Bool { consumedCharacters == inputLength }
}

public struct Segmenter: Sendable {
    public let inventory: SyllableInventory
    public let maxPaths: Int

    public init(inventory: SyllableInventory = .standard, maxPaths: Int = 64) {
        self.inventory = inventory
        self.maxPaths = maxPaths
    }

    public func edges(in input: String) -> [[SyllableEdge]] {
        let normalized = PinyinNormalizer.normalize(input)
        let characters = Array(normalized)
        var result = Array(repeating: [SyllableEdge](), count: characters.count + 1)
        for start in characters.indices {
            if characters[start] == "'" {
                result[start].append(.init(start: start, end: start + 1, syllable: "'"))
                continue
            }
            let upper = min(characters.count, start + 6)
            guard start < upper else { continue }
            for end in (start + 1)...upper {
                let part = String(characters[start..<end])
                if inventory.syllables.contains(part) {
                    result[start].append(.init(start: start, end: end, syllable: part))
                }
            }
            result[start].sort {
                if $0.end - $0.start != $1.end - $1.start {
                    return $0.end - $0.start > $1.end - $1.start
                }
                return $0.syllable < $1.syllable
            }
        }
        return result
    }

    public func segment(_ input: String) -> Segmentation {
        let normalized = PinyinNormalizer.normalize(input)
        let graph = edges(in: normalized)
        let count = normalized.count
        var memo: [Int: [[String]]] = [:]

        func paths(from position: Int) -> [[String]] {
            if position == count { return [[]] }
            if let cached = memo[position] { return cached }
            var output: [[String]] = []
            for edge in graph[position] {
                for suffix in paths(from: edge.end) {
                    let prefix = edge.syllable == "'" ? [] : [edge.syllable]
                    output.append(prefix + suffix)
                    if output.count >= maxPaths {
                        memo[position] = output
                        return output
                    }
                }
            }
            memo[position] = output
            return output
        }

        let complete = paths(from: 0)
        if !complete.isEmpty {
            return Segmentation(paths: complete, consumedCharacters: count, inputLength: count)
        }

        var reachable: Set<Int> = [0]
        for position in 0..<count where reachable.contains(position) {
            for edge in graph[position] { reachable.insert(edge.end) }
        }
        return Segmentation(paths: [], consumedCharacters: reachable.max() ?? 0, inputLength: count)
    }
}
