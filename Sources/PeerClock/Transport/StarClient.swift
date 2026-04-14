import Foundation
import Network
import os
import Security

private let logger = Logger(subsystem: "net.hakaru.PeerClock", category: "StarClient")

/// Client-side connection to the Host's WebSocket server.
/// Performs HTTP upgrade handshake, then frames WebSocket messages.
public final class StarClient: @unchecked Sendable {

    public enum ClientState: Equatable, Sendable {
        case idle
        case connecting
        case handshaking
        case ready
        case closed(String)
    }

    public let incomingMessages: AsyncStream<Data>
    public let stateStream: AsyncStream<ClientState>

    private let incomingContinuation: AsyncStream<Data>.Continuation
    private let stateContinuation: AsyncStream<ClientState>.Continuation

    private var connection: NWConnection?
    private let lock = NSLock()
    private var currentState: ClientState = .idle
    private var expectedAccept: String?
    private let connectionQueue = DispatchQueue(label: "net.hakaru.PeerClock.StarClient")

    public init() {
        var ic: AsyncStream<Data>.Continuation!
        self.incomingMessages = AsyncStream { ic = $0 }
        self.incomingContinuation = ic

        var sc: AsyncStream<ClientState>.Continuation!
        self.stateStream = AsyncStream { sc = $0 }
        self.stateContinuation = sc
    }

    public func connect(to endpoint: NWEndpoint) {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let conn = NWConnection(to: endpoint, using: params)

        conn.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state, connection: conn)
        }
        conn.start(queue: connectionQueue)

        lock.withLock { connection = conn }
        updateState(.connecting)
    }

    public func send(_ data: Data) {
        let frame = WebSocketFrame.encode(binary: data, masked: true)
        let conn = lock.withLock { connection }
        conn?.send(content: frame, completion: .contentProcessed { error in
            if let error {
                logger.error("[StarClient] send failed: \(error.localizedDescription, privacy: .public)")
            }
        })
    }

    public func close() {
        let conn = lock.withLock { () -> NWConnection? in
            let c = connection
            connection = nil
            return c
        }
        conn?.cancel()
        updateState(.closed("user requested"))
    }

    private func handleConnectionState(_ state: NWConnection.State, connection: NWConnection) {
        logger.info("[StarClient] nw state=\(String(describing: state), privacy: .public)")
        switch state {
        case .ready:
            performHandshake(connection: connection)
        case .failed(let error):
            updateState(.closed("failed: \(error)"))
        case .cancelled:
            updateState(.closed("cancelled"))
        default:
            break
        }
    }

    private func performHandshake(connection: NWConnection) {
        updateState(.handshaking)
        var key = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, 16, &key)
        guard status == errSecSuccess else {
            fatalError("SecRandomCopyBytes failed: \(status)")
        }
        let keyB64 = Data(key).base64EncodedString()
        self.expectedAccept = WebSocketHandshake.computeAccept(clientKey: keyB64)

        let request = """
        GET / HTTP/1.1\r
        Host: peerclock\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: \(keyB64)\r
        Sec-WebSocket-Version: 13\r
        \r

        """
        connection.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
            if let error {
                self?.updateState(.closed("handshake send failed: \(error)"))
                return
            }
            self?.receiveHandshakeResponse(connection: connection)
        })
    }

    private func receiveHandshakeResponse(connection: NWConnection) {
        var buffer = Data()
        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
                if let error {
                    self?.updateState(.closed("handshake recv failed: \(error)"))
                    return
                }
                guard let data else { return }
                buffer.append(data)
                if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let headers = String(data: buffer[..<end.lowerBound], encoding: .utf8) ?? ""
                    if headers.contains("101 Switching Protocols") {
                        let accept = WebSocketHandshake.extractAccept(from: headers)
                        guard accept == self?.expectedAccept else {
                            self?.updateState(.closed("handshake accept mismatch: expected \(self?.expectedAccept ?? "nil"), got \(accept ?? "nil")"))
                            return
                        }
                        self?.updateState(.ready)
                        let leftover = buffer[end.upperBound...]
                        self?.startFrameLoop(connection: connection, initial: Data(leftover))
                    } else {
                        self?.updateState(.closed("handshake rejected: \(headers)"))
                    }
                } else {
                    readMore()
                }
            }
        }
        readMore()
    }

    private func startFrameLoop(connection: NWConnection, initial: Data) {
        var buffer = initial
        // I-4: Use closure-based pattern so [weak self] avoids retain cycle
        var loop: (() -> Void)!
        loop = { [weak self] in
            guard let self else { return }
            while true {
                do {
                    guard let (frame, consumed) = try WebSocketFrame.decode(buffer) else { break }
                    buffer.removeFirst(consumed)
                    switch frame {
                    case .binary(let d):
                        self.incomingContinuation.yield(d)
                    case .text(let s):
                        self.incomingContinuation.yield(Data(s.utf8))
                    case .close:
                        self.updateState(.closed("peer close"))
                        connection.cancel()
                        return
                    case .ping(let p):
                        let pong = WebSocketFrame.encodePong(p, masked: true)
                        connection.send(content: pong, completion: .idempotent)
                    case .pong:
                        break
                    }
                } catch {
                    self.updateState(.closed("frame decode error: \(error)"))
                    return
                }
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
                if let error {
                    self?.updateState(.closed("recv failed: \(error)"))
                    return
                }
                if let data, !data.isEmpty {
                    buffer.append(data)
                    loop()
                }
            }
        }
        loop()
    }

    private func updateState(_ new: ClientState) {
        lock.withLock { currentState = new }
        stateContinuation.yield(new)
        if case .closed = new {
            incomingContinuation.finish()
            stateContinuation.finish()
        }
    }
}
