/// One thing the panel can offer.
public struct Candidate: Sendable, Hashable {
    public enum Voice: String, Sendable {
        /// 子期 heard it: a reading of the keys by the listener model.
        case ziqi
        /// From 琴谱, the dictionary.
        case qinpu
        /// From 默契: you chose this before for these keys.
        case moqi
        /// The keys themselves, as typed.
        case literal
    }

    public let text: String
    /// How many keys this candidate reads (from the start of the keys).
    public let consumed: Int
    public let score: Float
    public let voice: Voice

    public init(text: String, consumed: Int, score: Float, voice: Voice) {
        self.text = text
        self.consumed = consumed
        self.score = score
        self.voice = voice
    }
}
