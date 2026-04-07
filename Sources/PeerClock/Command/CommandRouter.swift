import Foundation

/// Transport 経由でピア間のアプリケーションコマンドを送受信するルーター。
public final class CommandRouter: CommandHandler, @unchecked Sendable {

    private let transport: any Transport
    private var listenTask: Task<Void, Never>?
    private var commandContinuation: AsyncStream<(PeerID, Command)>.Continuation?
    private var syncMessageContinuation: AsyncStream<(PeerID, Message)>.Continuation?

    public let incomingCommands: AsyncStream<(PeerID, Command)>
    /// 同期メッセージ (PING/PONG) の単一コンシューマ制約を回避するため中央分配する。
    let syncMessages: AsyncStream<(PeerID, Message)>

    public init(transport: any Transport) {
        self.transport = transport

        var continuation: AsyncStream<(PeerID, Command)>.Continuation!
        incomingCommands = AsyncStream { continuation = $0 }
        commandContinuation = continuation

        var syncCont: AsyncStream<(PeerID, Message)>.Continuation!
        syncMessages = AsyncStream { syncCont = $0 }
        syncMessageContinuation = syncCont

        startListening()
    }

    public func send(_ command: Command, to peer: PeerID) async throws {
        let data = MessageCodec.encode(.commandUnicast(command))
        try await transport.send(data, to: peer)
    }

    public func broadcast(_ command: Command) async throws {
        let data = MessageCodec.encode(.commandBroadcast(command))
        try await transport.broadcast(data)
    }

    private func startListening() {
        listenTask = Task { [weak self] in
            guard let self else { return }
            for await (sender, data) in self.transport.incomingMessages {
                guard let message = try? MessageCodec.decode(data) else { continue }
                switch message {
                case .commandBroadcast(let command), .commandUnicast(let command):
                    self.commandContinuation?.yield((sender, command))
                case .ping, .pong:
                    self.syncMessageContinuation?.yield((sender, message))
                default:
                    break
                }
            }
        }
    }

    deinit {
        listenTask?.cancel()
        commandContinuation?.finish()
        syncMessageContinuation?.finish()
    }
}
