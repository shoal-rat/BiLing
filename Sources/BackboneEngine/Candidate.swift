import Foundation
import PinyinLattice

public enum CandidateSource: String, Codable, Sendable {
    case system
    case learned
    case sentence
    case english
    case literal
}

public struct Candidate: Codable, Hashable, Identifiable, Sendable {
    public var id: String { "\(text)\u{1f}\(pinyin)" }
    public let text: String
    public let pinyin: String
    public let source: CandidateSource
    public let consumed: Int
    public var score: Double

    public init(
        text: String,
        pinyin: String,
        source: CandidateSource,
        consumed: Int,
        score: Double
    ) {
        self.text = text
        self.pinyin = pinyin
        self.source = source
        self.consumed = consumed
        self.score = score
    }
}

public struct CandidatePage: Sendable {
    public let items: [Candidate]
    public let page: Int
    public let pageSize: Int
    public let totalCount: Int

    public var hasPrevious: Bool { page > 0 }
    public var hasNext: Bool { (page + 1) * pageSize < totalCount }
}

public struct EngineResult: Sendable {
    public let input: String
    public let mode: PinyinMode
    public let candidates: [Candidate]
    public let generation: UInt64

    public func page(_ index: Int, size: Int = 9) -> CandidatePage {
        let safePage = max(0, index)
        let start = safePage * size
        let slice: [Candidate]
        if start < candidates.count {
            slice = Array(candidates[start..<min(start + size, candidates.count)])
        } else {
            slice = []
        }
        return CandidatePage(items: slice, page: safePage, pageSize: size, totalCount: candidates.count)
    }
}
