import Darwin
import Foundation
import IPCProtocol
import LLMRanker
import Security

final class EngineService: NSObject, BiLingEngineXPC {
    private let ranker: QwenRanker

    init(ranker: QwenRanker) {
        self.ranker = ranker
    }

    func rank(_ requestData: Data, reply: @escaping (Data) -> Void) {
        guard let request = IPCCoder.decode(RankRequest.self, from: requestData) else {
            reply(Data())
            return
        }
        Task {
            do {
                reply(IPCCoder.encode(try await ranker.rank(request)))
            } catch {
                reply(
                    IPCCoder.encode(
                        RankReply(
                            clientID: request.clientID,
                            generation: request.generation,
                            orderedCandidates: request.candidates,
                            scores: [:],
                            latencyMilliseconds: 0,
                            modelDescription: ranker.modelDescription,
                            error: error.localizedDescription
                        )
                    )
                )
            }
        }
    }

    func status(_ reply: @escaping (String) -> Void) {
        reply("ready|\(ranker.modelDescription)")
    }

    func cancel(clientID: String, generation: UInt64) {
        guard let clientID = UUID(uuidString: clientID) else { return }
        ranker.cancel(clientID: clientID, generation: generation)
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

do {
    let modelURL = ModelLocator.bundledModelURL()
    let ranker = try QwenRanker(modelURL: modelURL)
    let service = EngineService(ranker: ranker)
    let delegate = ListenerDelegate(service: service)
    let listener = NSXPCListener(machServiceName: biLingMachServiceName)
    listener.delegate = delegate
    listener.resume()
    RunLoop.current.run()
} catch {
    FileHandle.standardError.write(Data("BiLing engine fatal: \(error.localizedDescription)\n".utf8))
    exit(78)
}
