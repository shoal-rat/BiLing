import Darwin
import Foundation
import IPCProtocol
import LLMRanker
import Security

// RankerManager (lazy load, idle unload, permanent disable on load failure)
// lives in LLMRanker so its lifecycle policy is unit-testable.

final class EngineService: NSObject, BiLingEngineXPC {
    private let manager: RankerManager

    init(manager: RankerManager) {
        self.manager = manager
    }

    func rank(_ requestData: Data, reply: @escaping (Data) -> Void) {
        guard let request = IPCCoder.decode(RankRequest.self, from: requestData) else {
            reply(Data())
            return
        }
        Task {
            do {
                let ranker = try manager.currentRanker()
                guard let ranked = try await ranker.rank(request) else {
                    // The model ran out of wall-clock budget: ship the
                    // deterministic order untouched, flagged so the client
                    // keeps its own ranking and shows the badge.
                    reply(
                        IPCCoder.encode(
                            RankReply(
                                clientID: request.clientID,
                                generation: request.generation,
                                orderedCandidates: request.candidates,
                                scores: [:],
                                latencyMilliseconds: 0,
                                modelDescription: manager.modelDescription(),
                                error: "Qwen 超时，已保留确定性排序"
                            )
                        )
                    )
                    return
                }
                // Report the manager's description so callers see the
                // 个人模型 marker; the ranker itself only knows the file.
                reply(
                    IPCCoder.encode(
                        RankReply(
                            clientID: ranked.clientID,
                            generation: ranked.generation,
                            orderedCandidates: ranked.orderedCandidates,
                            scores: ranked.scores,
                            latencyMilliseconds: ranked.latencyMilliseconds,
                            modelDescription: manager.modelDescription(),
                            error: ranked.error
                        )
                    )
                )
            } catch {
                reply(
                    IPCCoder.encode(
                        RankReply(
                            clientID: request.clientID,
                            generation: request.generation,
                            orderedCandidates: request.candidates,
                            scores: [:],
                            latencyMilliseconds: 0,
                            modelDescription: manager.modelDescription(),
                            error: error.localizedDescription
                        )
                    )
                )
            }
        }
    }

    func status(_ reply: @escaping (String) -> Void) {
        reply(manager.statusLine())
    }

    func cancel(clientID: String, generation: UInt64) {
        guard let clientID = UUID(uuidString: clientID) else { return }
        manager.cancel(clientID: clientID, generation: generation)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let service: EngineService
    private let allowedClientPaths: Set<String>

    init(service: EngineService) {
        self.service = service
        let engineURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let contentsURL = engineURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        allowedClientPaths = [
            contentsURL.appendingPathComponent("MacOS/BiLingApp").path,
            contentsURL.appendingPathComponent("Helpers/biling-cli").path,
        ]
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard validate(connection) else { return false }
        connection.exportedInterface = NSXPCInterface(with: BiLingEngineXPC.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }

    private func validate(_ connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }

        var pathBuffer = [CChar](repeating: 0, count: 4_096)
        guard proc_pidpath(connection.processIdentifier, &pathBuffer, UInt32(pathBuffer.count)) > 0 else {
            return false
        }
        let path = URL(fileURLWithPath: String(cString: pathBuffer))
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        guard allowedClientPaths.contains(path) else { return false }

        let attributes = [kSecGuestAttributePid as String: connection.processIdentifier] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return false }
        return SecCodeCheckValidity(code, [], nil) == errSecSuccess
    }
}

let modelURL = ModelLocator.bundledModelURL()
guard FileManager.default.fileExists(atPath: modelURL.path) else {
    FileHandle.standardError.write(
        Data("BiLing engine fatal: the bundled Qwen model is missing at \(modelURL.path)\n".utf8)
    )
    exit(78)
}
let manager = RankerManager(modelURL: modelURL)
let service = EngineService(manager: manager)
let delegate = ListenerDelegate(service: service)
let listener = NSXPCListener(machServiceName: biLingMachServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
