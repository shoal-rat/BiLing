import Foundation

public let biLingMachServiceName = "com.biling.inputmethod.engine"

public struct RankRequest: Codable, Sendable {
    public let clientID: UUID
    public let generation: UInt64
    public let input: String
    public let committedContext: String
    public let candidates: [String]

    public init(
        clientID: UUID,
        generation: UInt64,
        input: String,
        committedContext: String,
        candidates: [String]
    ) {
        self.clientID = clientID
        self.generation = generation
        self.input = input
        self.committedContext = committedContext
        self.candidates = candidates
    }
}

public struct RankReply: Codable, Sendable {
    public let clientID: UUID
    public let generation: UInt64
    public let orderedCandidates: [String]
    public let scores: [String: Double]
    public let latencyMilliseconds: Double
    public let modelDescription: String
    public let error: String?

    public init(
        clientID: UUID,
        generation: UInt64,
        orderedCandidates: [String],
        scores: [String: Double],
        latencyMilliseconds: Double,
        modelDescription: String,
        error: String? = nil
    ) {
        self.clientID = clientID
        self.generation = generation
        self.orderedCandidates = orderedCandidates
        self.scores = scores
        self.latencyMilliseconds = latencyMilliseconds
        self.modelDescription = modelDescription
        self.error = error
    }
}

@objc public protocol BiLingEngineXPC {
    func rank(_ request: Data, reply: @escaping (Data) -> Void)
    func status(_ reply: @escaping (String) -> Void)
    func cancel(clientID: String, generation: UInt64)
}

public enum IPCCoder {
    public static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
