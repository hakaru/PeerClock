import Foundation
import Network
import os

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
        conn.start(queue: .global(qos: .userInitiated))

        lock.withLock { connection = conn }
        updateState(.connecting)
    }

    public func send(_ data: Data) {
        let frame = WebSocketFrame.encode(binary: data, masked: true)
        connection?.send(content: frame, completion: .contentProcessed { error in
            if let error {
                logger.error("[StarClient] send failed: \(error.localizedDescription, privacy: .public)")
            }
        })
    }

    public func close() {
        connection?.cancel()
        lock.withLock { connection = nil }
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
        let key = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let keyB64 = Data(key).base64EncodedString()
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
        func read() {
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
                        self?.updateState(.ready)
                        let leftover = buffer[end.upperBound...]
                        self?.startFrameLoop(connection: connection, initial: Data(leftover))
                    } else {
                        self?.updateState(.closed("handshake rejected: \(headers)"))
                    }
                } else {
                    read()
                }
            }
        }
        read()
    }

    private func startFrameLoop(connection: NWConnection, initial: Data) {
        var buffer = initial
        func loop() {
            while true {
                do {
                    guard let (frame, consumed) = try WebSocketFrame.decode(buffer) else { break }
                    buffer.removeFirst(consumed)
                    switch frame {
                    case .binary(let d):
                        incomingContinuation.yield(d)
                    case .text(let s):
                        incomingContinuation.yield(Data(s.utf8))
                    case .close:
                        updateState(.closed("peer close"))
                        connection.cancel()
                        return
                    case .ping(let p):
                        let pong = WebSocketFrame.encodePong(p, masked: true)
                        connection.send(content: pong, completion: .idempotent)
                    case .pong:
                        break
                    }
                } catch {
                    updateState(.closed("frame decode error: \(error)"))
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
    }
}
