import Foundation
import IPCProtocol
import OSLog

@MainActor
final class EngineClient {
    static let shared = EngineClient()

    private static let logger = Logger(
        subsystem: "com.biling.inputmethod.BiLing",
        category: "qwen-client"
    )
    private var connection: NSXPCConnection?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private(set) var statusText = "Qwen 正在启动…"
    private(set) var isReady = false

    private init() {
        // Status is refreshed on demand (connect, menu, preferences, failures).
        // A periodic health poll would wake both processes forever while idle.
        connect()
        refreshStatus()
    }

    deinit {
        reconnectTask?.cancel()
        connection?.invalidate()
    }

    func refreshStatus(completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard let proxy = proxy(errorHandler: { [weak self] error in
            Task { @MainActor in
                self?.markUnavailable(error.localizedDescription)
                completion?()
            }
        }) else {
            markUnavailable(EngineClientError.unavailable.localizedDescription)
            completion?()
            return
        }

        proxy.status { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                let parts = status.split(separator: "|", maxSplits: 1).map(String.init)
                self.isReady = parts.first == "ready"
                self.statusText = parts.count > 1 ? parts[1] : status
                if self.isReady {
                    self.reconnectAttempt = 0
                    self.reconnectTask?.cancel()
                    self.reconnectTask = nil
                } else {
                    self.scheduleReconnect()
                }
                completion?()
            }
        }
    }

    func noteRankSuccess(model: String) {
        isReady = true
        statusText = model
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    func rank(
        _ request: RankRequest,
        completion: @escaping @Sendable (Result<RankReply, Error>) -> Void
    ) {
        guard let proxy = proxy(errorHandler: { [weak self] error in
            Task { @MainActor in
                self?.markUnavailable(error.localizedDescription)
            }
            completion(.failure(error))
        }) else {
            completion(.failure(EngineClientError.unavailable))
            return
        }

        proxy.rank(IPCCoder.encode(request)) { data in
            guard let reply = IPCCoder.decode(RankReply.self, from: data) else {
                completion(.failure(EngineClientError.invalidReply))
                return
            }
            if let error = reply.error {
                completion(.failure(EngineClientError.remote(error)))
            } else {
                completion(.success(reply))
            }
        }
    }

    func cancel(clientID: UUID, generation: UInt64) {
        guard let proxy = proxy(errorHandler: { _ in }) else { return }
        proxy.cancel(clientID: clientID.uuidString, generation: generation)
    }

    private func connect() {
        guard connection == nil else { return }
        let newConnection = NSXPCConnection(machServiceName: biLingMachServiceName)
        newConnection.remoteObjectInterface = NSXPCInterface(with: BiLingEngineXPC.self)
        newConnection.interruptionHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.connection === newConnection else { return }
                self.connection = nil
                self.markUnavailable("XPC connection interrupted")
            }
        }
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            Task { @MainActor in
                guard let self, self.connection === newConnection else { return }
                self.connection = nil
                self.markUnavailable("Qwen 服务不可用，正在重连…")
            }
        }
        connection = newConnection
        newConnection.resume()
    }

    private func proxy(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) -> BiLingEngineXPC? {
        if connection == nil {
            connect()
        }
        return connection?.remoteObjectProxyWithErrorHandler(errorHandler) as? BiLingEngineXPC
    }

    private func markUnavailable(_ message: String) {
        Self.logger.error("Qwen connection is unavailable: \(message, privacy: .public)")
        isReady = false
        statusText = "Qwen 正在启动或恢复…"
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil else { return }
        let delay = min(pow(2.0, Double(reconnectAttempt)), 15)
        reconnectAttempt = min(reconnectAttempt + 1, 4)
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            let staleConnection = self.connection
            self.connection = nil
            staleConnection?.invalidate()
            self.connect()
            self.refreshStatus()
        }
    }
}

enum EngineClientError: LocalizedError {
    case unavailable
    case invalidReply
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Qwen 正在启动或恢复，请稍后重试。"
        case .invalidReply: "Qwen 返回了无效响应。"
        case .remote(let message): message
        }
    }
}
