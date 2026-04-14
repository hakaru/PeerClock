import Foundation
import Network
import os

private let logger = Logger(subsystem: "net.hakaru.PeerClock", category: "StarHost")

/// Host-side WebSocket server. Listens for client connections, performs
/// HTTP upgrade, and manages per-client session state.
public final class StarHost: @unchecked Sendable {

    public struct ClientConnection: Sendable, Identifiable {
        public let id: UUID
        public let peerID: PeerID?
    }

    public let clients: AsyncStream<[ClientConnection]>
    public let incomingMessages: AsyncStream<(clientID: UUID, data: Data)>

    private let clientsContinuation: AsyncStream<[ClientConnection]>.Continuation
    private let messagesContinuation: AsyncStream<(clientID: UUID, data: Data)>.Continuation

    private var listener: NWListener?
    private var sessions: [UUID: ClientSession] = [:]
    private let lock = NSLock()
    // Serial queue for NWListener callbacks (Lesson #1)
    private let listenerQueue = DispatchQueue(label: "net.hakaru.PeerClock.StarHost.listener")

    public init() {
        var cc: AsyncStream<[ClientConnection]>.Continuation!
        self.clients = AsyncStream { cc = $0 }
        self.clientsContinuation = cc

        var mc: AsyncStream<(clientID: UUID, data: Data)>.Continuation!
        self.incomingMessages = AsyncStream { mc = $0 }
        self.messagesContinuation = mc
    }

    /// Start listening. Returns the NWListener (for BonjourAdvertiser attach).
    @discardableResult
    public func start() throws -> NWListener {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let l = try NWListener(using: params)

        l.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        l.stateUpdateHandler = { state in
            logger.info("[StarHost] listener state=\(String(describing: state), privacy: .public)")
        }
        // Use serial listenerQueue, not .global (Lesson #1)
        l.start(queue: listenerQueue)

        lock.withLock { listener = l }
        return l
    }

    public func stop() {
        let l = lock.withLock { () -> NWListener? in
            let captured = listener
            listener = nil
            return captured
        }
        l?.cancel()

        // Snapshot sessions inside lock before iterating (Lesson #2)
        let snapshot = lock.withLock { () -> [ClientSession] in
            let all = Array(sessions.values)
            sessions.removeAll()
            return all
        }
        for session in snapshot {
            session.connection.cancel()
        }

        // Yield empty list to notify consumers of full disconnect, then finish stream.
        publishClients()

        // Finish both streams on stop (Lesson #3)
        clientsContinuation.finish()
        messagesContinuation.finish()
    }

    /// Broadcast a binary payload to all clients (independently, best-effort).
    public func broadcast(_ data: Data) {
        let frame = WebSocketFrame.encode(binary: data, masked: false)
        // Snapshot inside lock before iterating (Lesson #2)
        let snapshot = lock.withLock { Array(sessions.values) }
        for session in snapshot {
            session.send(frame)
        }
    }

    /// Unicast to a specific client.
    public func send(_ data: Data, to clientID: UUID) {
        let frame = WebSocketFrame.encode(binary: data, masked: false)
        // Snapshot inside lock (Lesson #2)
        let session = lock.withLock { sessions[clientID] }
        session?.send(frame)
    }

    private func accept(_ connection: NWConnection) {
        let sessionID = UUID()
        let session = ClientSession(id: sessionID, connection: connection)

        session.onHandshakeComplete = { [weak self] in
            self?.publishClients()
            session.startFrameLoop { [weak self] data in
                self?.messagesContinuation.yield((clientID: sessionID, data: data))
            } onClose: { [weak self] in
                self?.removeSession(sessionID)
            }
        }

        lock.withLock { sessions[sessionID] = session }
        session.startHandshake(onConnectionLost: { [weak self] in
            self?.removeSession(sessionID)
        })
    }

    private func removeSession(_ id: UUID) {
        lock.withLock { sessions.removeValue(forKey: id) }
        publishClients()
    }

    private func publishClients() {
        // Snapshot inside lock (Lesson #2)
        let list = lock.withLock {
            sessions.values.map { ClientConnection(id: $0.id, peerID: $0.assignedPeerID) }
        }
        clientsContinuation.yield(list)
    }

    // MARK: - Test-only accessors

    #if DEBUG
    internal var listenerForTest: NWListener? { lock.withLock { listener } }
    #endif
}

// MARK: - ClientSession (private)

final class ClientSession: @unchecked Sendable {
    let id: UUID
    let connection: NWConnection
    private(set) var assignedPeerID: PeerID?
    var onHandshakeComplete: (() -> Void)?

    private var buffer = Data()
    private var onConnectionLost: (() -> Void)?
    // Serial queue per session (Lesson #1) — includes id prefix for diagnostics (N-2)
    private let sessionQueue: DispatchQueue

    init(id: UUID, connection: NWConnection) {
        self.id = id
        self.connection = connection
        self.sessionQueue = DispatchQueue(label: "net.hakaru.PeerClock.StarHost.session.\(id.uuidString.prefix(8))")
    }

    func setAssignedPeerID(_ peerID: PeerID) {
        sessionQueue.async { [weak self] in
            self?.assignedPeerID = peerID
        }
    }

    func startHandshake(onConnectionLost: @escaping () -> Void) {
        self.onConnectionLost = onConnectionLost
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveHandshakeRequest()
            case .failed, .cancelled:
                self?.onConnectionLost?()
            default:
                break
            }
        }
        // Use serial sessionQueue, not .global (Lesson #1)
        connection.start(queue: sessionQueue)
    }

    private func receiveHandshakeRequest() {
        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let error {
                    logger.error("[ClientSession \(self.id)] handshake recv error: \(error.localizedDescription, privacy: .public)")
                    self.connection.cancel()
                    return  // stateUpdateHandler will fire onConnectionLost
                }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    if let end = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                        let requestHeaders = String(data: self.buffer[..<end.lowerBound], encoding: .utf8) ?? ""
                        self.sendHandshakeResponse(request: requestHeaders)
                        self.buffer.removeSubrange(..<end.upperBound)
                    } else if self.buffer.count > 16_384 {
                        // N-1: cap buffer size to prevent memory exhaustion
                        logger.warning("[ClientSession \(self.id)] handshake buffer overflow")
                        self.connection.cancel()
                        return
                    } else {
                        read()
                    }
                } else if isComplete {
                    self.connection.cancel()
                    return
                }
            }
        }
        read()
    }

    private func sendHandshakeResponse(request: String) {
        guard let key = WebSocketHandshake.extractKey(from: request) else {
            sendHandshakeError(reason: "missing Sec-WebSocket-Key")
            return
        }
        let accept = WebSocketHandshake.computeAccept(clientKey: key)
        let response = """
        HTTP/1.1 101 Switching Protocols\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Accept: \(accept)\r
        \r

        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            self?.onHandshakeComplete?()
        })
    }

    private func sendHandshakeError(reason: String) {
        let response = "HTTP/1.1 400 Bad Request\r\n\r\n\(reason)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    func startFrameLoop(onData: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        // I-4: Use closure-based pattern so [weak self] avoids retain cycle
        var loop: (() -> Void)!
        loop = { [weak self] in
            guard let self else { return }
            while true {
                do {
                    guard let (frame, consumed) = try WebSocketFrame.decode(self.buffer) else { break }
                    self.buffer.removeFirst(consumed)
                    switch frame {
                    case .binary(let d):
                        onData(d)
                    case .text(let s):
                        onData(Data(s.utf8))
                    case .close:
                        // C-3: Disable onConnectionLost before cancel to prevent double removeSession
                        self.onConnectionLost = nil
                        self.connection.stateUpdateHandler = nil
                        self.connection.cancel()
                        onClose()
                        return
                    case .ping(let p):
                        // Server uses encodePong (opcode 0xA), unmasked (Lesson #4)
                        let pong = WebSocketFrame.encodePong(p, masked: false)
                        self.connection.send(content: pong, completion: .idempotent)
                    case .pong:
                        break
                    }
                } catch {
                    logger.error("[ClientSession \(self.id)] frame decode error: \(error.localizedDescription, privacy: .public)")
                    self.onConnectionLost = nil
                    self.connection.stateUpdateHandler = nil
                    self.connection.cancel()
                    onClose()
                    return
                }
            }
            self.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
                guard let self, let data, !data.isEmpty else {
                    onClose()
                    return
                }
                self.buffer.append(data)
                loop()
            }
        }
        loop()
    }

    func send(_ frame: Data) {
        connection.send(content: frame, completion: .contentProcessed { error in
            if let error {
                logger.error("[ClientSession] send failed: \(error.localizedDescription, privacy: .public)")
            }
        })
    }
}
