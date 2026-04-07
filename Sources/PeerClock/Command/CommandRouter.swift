import Foundation

/// Transport 経由でピア間のアプリケーションコマンドを送受信するルーター。
///
/// 送信時に commandID と logicalVersion を自動付与し、受信時は sender 単位で
/// 重複排除と論理バージョンの前進保証を行う。
public final class CommandRouter: CommandHandler, @unchecked Sendable {

    private let transport: any Transport
    private let localPeerID: PeerID
    private let lock = NSLock()

    private var listenTask: Task<Void, Never>?
    private var commandContinuation: AsyncStream<(PeerID, Command)>.Continuation?
    private var syncRequestsContinuation: AsyncStream<(PeerID, Message)>.Continuation?
    private var syncResponsesContinuation: AsyncStream<(PeerID, Message)>.Continuation?
    private var heartbeatContinuation: AsyncStream<PeerID>.Continuation?
    private var statusPushContinuation: AsyncStream<(PeerID, UInt64, [StatusEntry])>.Continuation?

    private var nextLogicalVersion: UInt64 = 1
    private var seenCommands: [PeerID: Set<UUID>] = [:]
    private var seenOrder: [PeerID: [UUID]] = [:]
    private var highestVersionPerSender: [PeerID: UInt64] = [:]
    private let maxSeenPerSender: Int

    public let incomingCommands: AsyncStream<(PeerID, Command)>
    /// 受信した PING メッセージを流すストリーム。
    let syncRequests: AsyncStream<(PeerID, Message)>
    /// 受信した PONG メッセージを流すストリーム。
    let syncResponses: AsyncStream<(PeerID, Message)>
    /// 受信した HEARTBEAT メッセージの送信元 PeerID を流すストリーム。
    let heartbeatSenders: AsyncStream<PeerID>
    /// 受信した STATUS_PUSH の (sender, generation, entries) を流すストリーム。
    let statusPushes: AsyncStream<(PeerID, UInt64, [StatusEntry])>

    public init(transport: any Transport, localPeerID: PeerID, maxSeenPerSender: Int = 1000) {
        self.transport = transport
        self.localPeerID = localPeerID
        self.maxSeenPerSender = maxSeenPerSender

        var commandCont: AsyncStream<(PeerID, Command)>.Continuation!
        incomingCommands = AsyncStream { commandCont = $0 }
        commandContinuation = commandCont

        var requestCont: AsyncStream<(PeerID, Message)>.Continuation!
        syncRequests = AsyncStream { requestCont = $0 }
        syncRequestsContinuation = requestCont

        var responseCont: AsyncStream<(PeerID, Message)>.Continuation!
        syncResponses = AsyncStream { responseCont = $0 }
        syncResponsesContinuation = responseCont

        var hbCont: AsyncStream<PeerID>.Continuation!
        heartbeatSenders = AsyncStream { hbCont = $0 }
        heartbeatContinuation = hbCont

        var statusCont: AsyncStream<(PeerID, UInt64, [StatusEntry])>.Continuation!
        statusPushes = AsyncStream { statusCont = $0 }
        statusPushContinuation = statusCont

        startListening()
    }

    public func send(_ command: Command, to peer: PeerID) async throws {
        let (commandID, logicalVersion) = nextIdentity()
        let message = Message.commandUnicast(
            commandID: commandID,
            logicalVersion: logicalVersion,
            senderID: localPeerID,
            command: command
        )
        try await transport.send(MessageCodec.encode(message), to: peer)
    }

    public func broadcast(_ command: Command) async throws {
        let (commandID, logicalVersion) = nextIdentity()
        let message = Message.commandBroadcast(
            commandID: commandID,
            logicalVersion: logicalVersion,
            senderID: localPeerID,
            command: command
        )
        try await transport.broadcast(MessageCodec.encode(message))
    }

    /// Clear all deduplication/version state for a disconnected peer.
    public func forgetPeer(_ peer: PeerID) {
        lock.withLock {
            seenCommands[peer] = nil
            seenOrder[peer] = nil
            highestVersionPerSender[peer] = nil
        }
    }

    private func nextIdentity() -> (UUID, UInt64) {
        lock.withLock {
            let version = nextLogicalVersion
            nextLogicalVersion += 1
            return (UUID(), version)
        }
    }

    /// Returns true when the command should be delivered to incomingCommands.
    private func shouldDeliver(sender: PeerID, commandID: UUID, version: UInt64) -> Bool {
        lock.withLock {
            if seenCommands[sender, default: []].contains(commandID) {
                return false
            }
            if let highest = highestVersionPerSender[sender], version < highest {
                return false
            }

            var seen = seenCommands[sender, default: []]
            var order = seenOrder[sender, default: []]
            seen.insert(commandID)
            order.append(commandID)
            if order.count > maxSeenPerSender {
                let evicted = order.removeFirst()
                seen.remove(evicted)
            }
            seenCommands[sender] = seen
            seenOrder[sender] = order
            highestVersionPerSender[sender] = max(highestVersionPerSender[sender] ?? 0, version)
            return true
        }
    }

    private func startListening() {
        listenTask = Task { [weak self] in
            guard let self else { return }
            for await (peer, data) in transport.incomingMessages {
                guard let message = try? MessageCodec.decode(data) else { continue }
                switch message {
                case .commandBroadcast(let commandID, let logicalVersion, let senderID, let command),
                     .commandUnicast(let commandID, let logicalVersion, let senderID, let command):
                    if shouldDeliver(sender: senderID, commandID: commandID, version: logicalVersion) {
                        commandContinuation?.yield((senderID, command))
                    }
                case .ping:
                    syncRequestsContinuation?.yield((peer, message))
                case .pong:
                    syncResponsesContinuation?.yield((peer, message))
                case .heartbeat:
                    heartbeatContinuation?.yield(peer)
                case .statusPush(_, let generation, let entries):
                    statusPushContinuation?.yield((peer, generation, entries))
                default:
                    break
                }
            }
        }
    }

    deinit {
        listenTask?.cancel()
        commandContinuation?.finish()
        syncRequestsContinuation?.finish()
        syncResponsesContinuation?.finish()
        heartbeatContinuation?.finish()
        statusPushContinuation?.finish()
    }
}
