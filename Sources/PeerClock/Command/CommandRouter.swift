import Foundation

/// Transport 経由でピア間のアプリケーションコマンドを送受信するルーター。
public final class CommandRouter: CommandHandler, @unchecked Sendable {

    private let transport: any Transport
    private var listenTask: Task<Void, Never>?
    private var commandContinuation: AsyncStream<(PeerID, Command)>.Continuation?

    public let incomingCommands: AsyncStream<(PeerID, Command)>

    public init(transport: any Transport) {
        self.transport = transport

        var continuation: AsyncStream<(PeerID, Command)>.Continuation!
        incomingCommands = AsyncStream { continuation = $0 }
        commandContinuation = continuation

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
                guard let wire = try? MessageCodec.decode(data),
                      wire.category == .appCommand,
                      let command = try? MessageCodec.decodeCommand(wire.payload)
                else { continue }
                self.commandContinuation?.yield((sender, command))
            }
        }
    }

    deinit {
        listenTask?.cancel()
        commandContinuation?.finish()
    }
}
