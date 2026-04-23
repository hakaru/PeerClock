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

    // Task 13: Waiting-state timeout (10s)
    private var waitingTimeoutWork: DispatchWorkItem?

    // Task 13: Handshake partial-read timeout (5s)
    private var handshakeDeadline: DispatchWorkItem?

    // Task 13: Reconnect with exponential backoff — protected by `lock`
    private var lastEndpoint: NWEndpoint?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5

    // Task 13: Suppress reconnect when user explicitly closed — protected by `lock`
    private var userClosed = false

    /// Optional observer for high-level connection events
    /// (handshake failures, deadlines). Wired from `StarTransport`.
    /// Kept as a plain stored property — called on `connectionQueue` /
    /// send-completion callbacks. The closure itself is `@Sendable` so
    /// hopping to another actor is fine if the consumer wants.
    private var onConnectionEvent: (@Sendable (ConnectionEvent) -> Void)?

    public init(onConnectionEvent: (@Sendable (ConnectionEvent) -> Void)? = nil) {
        self.onConnectionEvent = onConnectionEvent

        var ic: AsyncStream<Data>.Continuation!
        self.incomingMessages = AsyncStream { ic = $0 }
        self.incomingContinuation = ic

        var sc: AsyncStream<ClientState>.Continuation!
        self.stateStream = AsyncStream { sc = $0 }
        self.stateContinuation = sc
    }

    public func connect(to endpoint: NWEndpoint) {
        lock.withLock {
            lastEndpoint = endpoint
            reconnectAttempts = 0
            userClosed = false
        }
        _connect(to: endpoint)
    }

    private func _connect(to endpoint: NWEndpoint) {
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
        lock.withLock { userClosed = true }
        cancelWaitingTimeout()
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
            cancelWaitingTimeout()
            lock.withLock { reconnectAttempts = 0 }
            performHandshake(connection: connection)
        case .waiting(let error):
            logger.warning("[StarClient] waiting: \(error.localizedDescription, privacy: .public)")
            scheduleWaitingTimeout(connection: connection)
        case .failed(let error):
            cancelWaitingTimeout()
            updateState(.closed("failed: \(error)"))
            let shouldReconnect = lock.withLock { !userClosed }
            if shouldReconnect {
                attemptReconnect()
            }
        case .cancelled:
            cancelWaitingTimeout()
            updateState(.closed("cancelled"))
        default:
            break
        }
    }

    // MARK: - Waiting timeout (Task 13)

    private func scheduleWaitingTimeout(connection: NWConnection) {
        cancelWaitingTimeout()
        let work = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection else { return }
            if case .waiting = connection.state {
                logger.warning("[StarClient] waiting timeout — cancelling")
                connection.cancel()  // triggers .cancelled → .closed
            }
        }
        waitingTimeoutWork = work
        connectionQueue.asyncAfter(deadline: .now() + 10.0, execute: work)
    }

    private func cancelWaitingTimeout() {
        waitingTimeoutWork?.cancel()
        waitingTimeoutWork = nil
    }

    // MARK: - Handshake (with 5s timeout, Task 13)

    private func performHandshake(connection: NWConnection) {
        updateState(.handshaking)

        // Schedule 5s handshake deadline
        let deadline = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection else { return }
            if case .handshaking = self.lock.withLock({ self.currentState }) {
                logger.error("[StarClient] handshake timeout (5s)")
                self.onConnectionEvent?(ConnectionEvent(reason: .timeout))
                connection.cancel()
            }
        }
        handshakeDeadline = deadline
        connectionQueue.asyncAfter(deadline: .now() + 5.0, execute: deadline)

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
                            self?.onConnectionEvent?(ConnectionEvent(reason: .handshakeFailed(.badAcceptHash)))
                            self?.updateState(.closed("handshake accept mismatch: expected \(self?.expectedAccept ?? "nil"), got \(accept ?? "nil")"))
                            return
                        }
                        self?.updateState(.ready)
                        let leftover = buffer[end.upperBound...]
                        self?.startFrameLoop(connection: connection, initial: Data(leftover))
                    } else {
                        self?.onConnectionEvent?(ConnectionEvent(reason: .handshakeFailed(.invalidUpgrade)))
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
            // DoS guard: cap buffer at 2 MiB (one max in-flight frame + next chunk)
            let maxBufferSize = 2 * 1_048_576
            if buffer.count > maxBufferSize {
                logger.error("[StarClient] buffer overflow (\(buffer.count) bytes) — closing connection")
                self.onConnectionEvent?(ConnectionEvent(reason: .handshakeFailed(.oversizedFrame)))
                connection.cancel()
                return
            }
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

    // MARK: - Reconnect with exponential backoff (Task 13)

    private func attemptReconnect() {
        // Snapshot mutable state atomically before use
        let (endpoint, attempts, isClosed) = lock.withLock {
            (lastEndpoint, reconnectAttempts, userClosed)
        }
        guard !isClosed, let endpoint else { return }
        guard attempts < maxReconnectAttempts else {
            logger.error("[StarClient] max reconnect attempts reached")
            return
        }
        let nextAttempt = lock.withLock { () -> Int in
            reconnectAttempts += 1
            return reconnectAttempts
        }
        let backoff = min(30.0, pow(2.0, Double(nextAttempt)))
        logger.info("[StarClient] scheduling reconnect attempt \(nextAttempt) in \(backoff, format: .fixed(precision: 1))s")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(backoff))
            guard let self else { return }
            let stillOpen = self.lock.withLock { !self.userClosed }
            guard stillOpen else { return }
            logger.info("[StarClient] reconnecting (attempt \(nextAttempt))")
            self._connect(to: endpoint)
        }
    }

    // MARK: - State management

    private func updateState(_ new: ClientState) {
        lock.withLock { currentState = new }
        stateContinuation.yield(new)
        if case .ready = new {
            handshakeDeadline?.cancel()
            handshakeDeadline = nil
        }
        if case .closed = new {
            handshakeDeadline?.cancel()
            handshakeDeadline = nil
            // NOTE: streams remain open to allow reconnect. Call destroy() for permanent teardown.
        }
    }

    /// Permanently tears down the client. Closes the connection and finishes both
    /// async streams. After destroy(), the client cannot be reused — all iterators
    /// will see stream termination. This is distinct from `.closed` state, which
    /// represents a transient disconnect that may be followed by reconnect.
    public func destroy() {
        close()
        incomingContinuation.finish()
        stateContinuation.finish()
    }
}
