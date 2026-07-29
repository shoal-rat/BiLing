import Foundation

/// Identity of one engine query: which composition state it was issued for.
///
/// The generation counter alone orders queries in time, but on its own it is
/// the only thing binding an asynchronous reply to the text it was computed
/// for. Pairing it with the buffer makes the binding structural: a reply can
/// only apply to the exact (generation, buffer) it was requested against,
/// even if a counter were ever reused after a reset.
public struct CompositionStamp: Equatable, Sendable {
    public let generation: UInt64
    public let buffer: String

    public init(generation: UInt64, buffer: String) {
        self.generation = generation
        self.buffer = buffer
    }
}

/// Decides whether an asynchronous rescoring reply may still be applied.
public enum AsyncReplyGate {
    /// True only when the reply's generation matches the session's current
    /// generation AND the buffer the request was issued for is still the
    /// buffer being composed. Either mismatch means the user has moved on;
    /// the reply must be dropped, never blended into the newer list.
    public static func shouldApply(
        replyGeneration: UInt64,
        requestBuffer: String,
        current: CompositionStamp
    ) -> Bool {
        replyGeneration == current.generation && requestBuffer == current.buffer
    }
}

/// The session's committed-text ranking context.
///
/// Text the user committed feeds the reranker as context for the next word.
/// That text belongs to the application it was typed into: when the input
/// method deactivates for a client (the user switched apps or fields), the
/// context must be cleared so nothing typed in one application can influence
/// — or leak into rankings shown in — another.
public struct CommittedContext: Equatable, Sendable {
    public private(set) var text: String = ""

    /// Trim with hysteresis: a hard per-commit suffix would shift the window
    /// on every commit and defeat the inference daemon's KV prefix cache.
    public let maximumLength: Int
    public let trimmedLength: Int

    public init(maximumLength: Int = 3_072, trimmedLength: Int = 1_536) {
        self.maximumLength = maximumLength
        self.trimmedLength = trimmedLength
    }

    public mutating func append(_ committed: String) {
        text += committed
        if text.count > maximumLength {
            text = String(text.suffix(trimmedLength))
        }
    }

    /// The client changed (app switch, field switch, session close): drop
    /// everything. Privacy boundary, not an optimisation.
    public mutating func clientChanged() {
        text = ""
    }
}
