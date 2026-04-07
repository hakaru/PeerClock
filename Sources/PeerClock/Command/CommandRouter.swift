import Foundation

/// Transport 経由でピア間のアプリケーションコマンドを送受信するルーター。
public final class CommandRouter: CommandHandler, @unchecked Sendable {

    private let transport: any Transport
    private var listenTask: Task<Void, Never>?
    private var commandContinuation: AsyncStream<(PeerID, Command)>.Continuation?
    private var syncMessageContinuation: AsyncStream<(PeerID, Data)>.Continuation?

    public let incomingCommands: AsyncStream<(PeerID, Command)>
    /// 同期メッセージ (SYNC_REQUEST/SYNC_RESPONSE) の生データを流す副ストリーム。
    /// reliableMessages の単一コンシューマ制約を回避するため CommandRouter が中央分配する。
    let syncMessages: AsyncStream<(PeerID, Data)>

    public init(transport: any Transport) {
        self.transport = transport

        var continuation: AsyncStream<(PeerID, Command)>.Continuation!
        incomingCommands = AsyncStream { continuation = $0 }
        commandContinuation = continuation

        var syncCont: AsyncStream<(PeerID, Data)>.Continuation!
        syncMessages = AsyncStream { syncCont = $0 }
        syncMessageContinuation = syncCont

        startListening()
    }

    public func send(_ command: Command, to peer: PeerID) async throws {
        let payload = MessageCodec.encodeCommand(command)
        let wire = WireMessage(category: .appCommand, payload: payload)
        let data = MessageCodec.encode(wire)
        try await transport.sendReliable(data, to: peer)
    }

    public func broadcast(_ command: Command) async throws {
        let payload = MessageCodec.encodeCommand(command)
        let wire = WireMessage(category: .appCommand, payload: payload)
        let data = MessageCodec.encode(wire)
        try await transport.broadcastReliable(data)
    }

    private func startListening() {
        listenTask = Task { [weak self] in
            guard let self else { return }
            for await (sender, data) in self.transport.reliableMessages {
                guard let wire = try? MessageCodec.decode(data) else { continue }
                switch wire.category {
                case .appCommand:
                    if let command = try? MessageCodec.decodeCommand(wire.payload) {
                        self.commandContinuation?.yield((sender, command))
                    }
                case .syncRequest, .syncResponse:
                    self.syncMessageContinuation?.yield((sender, data))
                default:
                    continue
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
