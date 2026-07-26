import Darwin
import Foundation
import IPCProtocol
import LLMRanker
import Security

/// Owns the Qwen instance with a lazy-load / idle-unload lifecycle.
///
/// The daemon starts at login, but weights are mapped only when the first
/// ranking request arrives and are released again after ten minutes without
/// requests. Idle cost is a few megabytes; reloading from the mmap'd GGUF on
/// the next keystroke takes well under a second, during which the input
/// method's deterministic candidates remain fully usable.
final class RankerManager: @unchecked Sendable {
    private let modelURL: URL
    private let lock = NSLock()
    private var ranker: QwenRanker?
    private var lastUse = ContinuousClock.now
    private var lastLoadError: String?
    private let idleTimer: DispatchSourceTimer

    private static let idleUnloadAfter: Duration = .seconds(600)

    init(modelURL: URL) {
        self.modelURL = modelURL
        idleTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.biling.engine-idle", qos: .utility))
        idleTimer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
        idleTimer.setEventHandler { [weak self] in
            self?.unloadIfIdle()
        }
        idleTimer.resume()
    }

    func currentRanker() throws -> QwenRanker {
        lock.lock()
        defer { lock.unlock() }
        lastUse = .now
        if let ranker {
            return ranker
        }
        do {
            let loaded = try QwenRanker(modelURL: modelURL)
            ranker = loaded
            lastLoadError = nil
            return loaded
        } catch {
            lastLoadError = error.localizedDescription
            throw error
        }
    }

    func cancel(clientID: UUID, generation: UInt64) {
        lock.lock()
        let active = ranker
        lock.unlock()
        active?.cancel(clientID: clientID, generation: generation)
    }

    func statusLine() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let ranker {
            return "ready|\(ranker.modelDescription)"
        }
        if let lastLoadError {
            return "error|\(lastLoadError)"
        }
        return "ready|Qwen 待机中，首次输入时加载"
    }

    func modelDescription() -> String {
        lock.lock()
        defer { lock.unlock() }
        return ranker?.modelDescription ?? "Qwen3-0.6B-Base（待机）"
    }

    private func unloadIfIdle() {
        lock.lock()
        defer { lock.unlock() }
        guard ranker != nil, ContinuousClock.now - lastUse > Self.idleUnloadAfter else { return }
        ranker = nil
        FileHandle.standardOutput.write(Data("BiLing engine: released idle Qwen instance\n".utf8))
    }
}

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
