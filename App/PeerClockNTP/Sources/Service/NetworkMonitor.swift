import Network

actor NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "net.hakaru.PeerClockNTP.networkMonitor")

    private(set) var isConnected: Bool = false
    private var streamContinuation: AsyncStream<Bool>.Continuation?

    nonisolated var pathUpdates: AsyncStream<Bool> {
        AsyncStream { continuation in
            Task { await self.setContinuation(continuation) }
        }
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let connected = path.status == .satisfied
            Task { await self.update(connected: connected) }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
        streamContinuation?.finish()
        streamContinuation = nil
    }

    private func setContinuation(_ continuation: AsyncStream<Bool>.Continuation) {
        streamContinuation?.finish()
        streamContinuation = continuation
        continuation.yield(isConnected)
    }

    private func update(connected: Bool) {
        isConnected = connected
        streamContinuation?.yield(connected)
    }
}
