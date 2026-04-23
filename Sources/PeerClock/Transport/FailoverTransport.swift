// Sources/PeerClock/Transport/FailoverTransport.swift
import Foundation
import os

/// A Transport wrapper that tries each option in order at start() time and
/// keeps the first one that does not throw.
public final class FailoverTransport: Transport, @unchecked Sendable {

    // MARK: - Types

    public struct Option: Sendable {
        public let label: String
        public let factory: @Sendable () -> any Transport
        public init(label: String, factory: @escaping @Sendable () -> any Transport) {
            self.label = label
            self.factory = factory
        }
    }

    private enum State {
        case idle
        case starting
        case running
        case stopping
    }

    // MARK: - Public streams (Transport protocol)

    public let peers: AsyncStream<Set<PeerID>>
    public let incomingMessages: AsyncStream<(PeerID, Data)>

    // MARK: - Private

    private let options: [Option]
    private let logger: Logger
    private let lock = NSLock()

    private var state: State = .idle
    private var active: (label: String, transport: any Transport)?
    private var peersForwardTask: Task<Void, Never>?
    private var incomingForwardTask: Task<Void, Never>?

    private let peersContinuation: AsyncStream<Set<PeerID>>.Continuation
    private let incomingContinuation: AsyncStream<(PeerID, Data)>.Continuation

    // MARK: - Init

    public init(options: [Option]) {
        self.options = options
        self.logger = Logger(subsystem: "net.hakaru.PeerClock", category: "FailoverTransport")

        var peersCont: AsyncStream<Set<PeerID>>.Continuation!
        self.peers = AsyncStream { peersCont = $0 }
        self.peersContinuation = peersCont

        var incomingCont: AsyncStream<(PeerID, Data)>.Continuation!
        self.incomingMessages = AsyncStream { incomingCont = $0 }
        self.incomingContinuation = incomingCont
    }

    // MARK: - Public

    public var activeLabel: String? {
        lock.withLock { active?.label }
    }

    // MARK: - Transport protocol

    public func start() async throws {
        try lock.withLock {
            switch state {
            case .idle:
                state = .starting
            case .starting, .running, .stopping:
                throw FailoverTransportError.alreadyStarted
            }
        }

        guard !options.isEmpty else {
            lock.withLock { state = .idle }
            throw FailoverTransportError.noOptionsAvailable
        }

        var errors: [Error] = []
        for option in options {
            let shouldAbort = lock.withLock { state != .starting }
            if shouldAbort {
                lock.withLock { state = .idle }
                throw FailoverTransportError.alreadyStarted
            }

            let transport = option.factory()
            do {
                try await transport.start()
            } catch {
                await transport.stop()
                logger.warning("FailoverTransport option \(option.label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                errors.append(error)
                continue
            }

            let acceptedActive: Bool = lock.withLock {
                guard state == .starting else { return false }
                self.active = (option.label, transport)
                self.state = .running
                return true
            }
            if !acceptedActive {
                await transport.stop()
                lock.withLock { state = .idle }
                throw FailoverTransportError.alreadyStarted
            }

            startForwarding(from: transport)
            logger.info("FailoverTransport active: \(option.label, privacy: .public)")
            return
        }

        lock.withLock { state = .idle }
        throw FailoverTransportError.allOptionsFailed(underlying: errors)
    }

    public func stop() async {
        let (shouldStop, peersTask, incomingTask, active) = lock.withLock {
            () -> (Bool, Task<Void, Never>?, Task<Void, Never>?, (label: String, transport: any Transport)?) in
            switch state {
            case .idle, .stopping:
                return (false, nil, nil, nil)
            case .starting, .running:
                state = .stopping
                let pt = peersForwardTask
                let it = incomingForwardTask
                let act = self.active
                self.peersForwardTask = nil
                self.incomingForwardTask = nil
                self.active = nil
                return (true, pt, it, act)
            }
        }

        guard shouldStop else { return }

        if let active {
            await active.transport.stop()
        }

        peersTask?.cancel()
        incomingTask?.cancel()
        await peersTask?.value
        await incomingTask?.value

        peersContinuation.finish()
        incomingContinuation.finish()

        lock.withLock { state = .idle }
        logger.info("FailoverTransport stopped")
    }

    public func broadcast(_ data: Data) async throws {
        let transport = lock.withLock { active?.transport }
        guard let transport else {
            throw FailoverTransportError.notStarted
        }
        try await transport.broadcast(data)
    }

    public func broadcastUnreliable(_ data: Data) async throws {
        let transport = lock.withLock { active?.transport }
        guard let transport else {
            throw FailoverTransportError.notStarted
        }
        try await transport.broadcastUnreliable(data)
    }

    // MARK: - Forwarding

    private func startForwarding(from transport: any Transport) {
        let peersCont = peersContinuation
        let incomingCont = incomingContinuation

        let peersTask = Task {
            for await snapshot in transport.peers {
                if Task.isCancelled { break }
                peersCont.yield(snapshot)
            }
        }
        let incomingTask = Task {
            for await message in transport.incomingMessages {
                if Task.isCancelled { break }
                incomingCont.yield(message)
            }
        }
        lock.withLock {
            self.peersForwardTask = peersTask
            self.incomingForwardTask = incomingTask
        }
    }
}

// MARK: - Errors

public enum FailoverTransportError: Error, Sendable {
    case noOptionsAvailable
    case allOptionsFailed(underlying: [Error])
    case notStarted
    case alreadyStarted
}
