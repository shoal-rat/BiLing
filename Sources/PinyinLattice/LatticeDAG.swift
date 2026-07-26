import Foundation

public struct LatticeDAG: Sendable {
    public private(set) var rawInput: String
    public private(set) var generation: UInt64
    public private(set) var graph: [[SyllableEdge]]
    public private(set) var segmentation: Segmentation

    private let segmenter: Segmenter

    public init(rawInput: String = "", segmenter: Segmenter = Segmenter()) {
        self.rawInput = PinyinNormalizer.normalize(rawInput)
        self.generation = 0
        self.segmenter = segmenter
        self.graph = segmenter.edges(in: self.rawInput)
        self.segmentation = segmenter.segment(self.rawInput)
    }

    public mutating func append(_ text: String) {
        rawInput.append(contentsOf: PinyinNormalizer.normalize(text))
        rebuild()
    }

    public mutating func backspace() {
        guard !rawInput.isEmpty else { return }
        rawInput.removeLast()
        rebuild()
    }

    public mutating func replace(with text: String) {
        rawInput = PinyinNormalizer.normalize(text)
        rebuild()
    }

    public mutating func clear() {
        rawInput = ""
        rebuild()
    }

    private mutating func rebuild() {
        generation &+= 1
        graph = segmenter.edges(in: rawInput)
        segmentation = segmenter.segment(rawInput)
    }
}
