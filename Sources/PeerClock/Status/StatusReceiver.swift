import Foundation

/// Snapshot of a remote peer's status as observed locally.
public struct RemotePeerStatus: Sendable, Equatable {
    public let peerID: PeerID
    public let generation: UInt64
    public let entries: [String: Data]

    public init(peerID: PeerID, generation: UInt64, entries: [String: Data]) {
        self.peerID = peerID
        self.generation = generation
        self.entries = entries
    }
}

/// Actor holding remote peer status with receive-side debounce.
///
/// Contract:
/// - Drops `STATUS_PUSH` with a `generation` less than or equal to the cached one.
/// - Collapses rapid updates from the same peer into a single event on
///   `updates` stream using `debounce` window.
/// - `status(of:)` returns the last known entries even after disconnect; callers
///   decide staleness via a separate signal (e.g. heartbeat connection state).
public actor StatusReceiver {

    private let debounce: TimeInterval

    private var store: [PeerID: RemotePeerStatus] = [:]
    private var pendingEmit: [PeerID: Task<Void, Never>] = [:]

    private let (stream, continuation) = AsyncStream<RemotePeerStatus>.makeStream()

    public nonisolated var updates: AsyncStream<RemotePeerStatus> { stream }

    public init(debounce: TimeInterval) {
        self.debounce = debounce
    }

    /// Feed an incoming STATUS_PUSH. Returns true if the push was accepted
    /// (not dropped as stale).
    @discardableResult
    public func ingestPush(
        from peerID: PeerID,
        generation: UInt64,
        entries: [StatusEntry]
    ) -> Bool {
        if let existing = store[peerID], existing.generation >= generation {
            return false
        }
        let dict = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
        let snapshot = RemotePeerStatus(peerID: peerID, generation: generation, entries: dict)
        store[peerID] = snapshot
        scheduleEmit(for: peerID)
        return true
    }

    /// Returns the last known snapshot for a peer, or nil if none has been seen.
    public func status(of peerID: PeerID) -> RemotePeerStatus? {
        store[peerID]
    }

    /// Removes a peer entry (e.g. on hard disconnect cleanup).
    public func forget(_ peerID: PeerID) {
        store.removeValue(forKey: peerID)
        pendingEmit[peerID]?.cancel()
        pendingEmit.removeValue(forKey: peerID)
    }

    public func shutdown() {
        for (_, task) in pendingEmit { task.cancel() }
        pendingEmit.removeAll()
        continuation.finish()
    }

    // MARK: - Debounce

    private func scheduleEmit(for peerID: PeerID) {
        pendingEmit[peerID]?.cancel()
        let delay = debounce
        pendingEmit[peerID] = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.emit(peerID: peerID)
        }
    }

    private func emit(peerID: PeerID) {
        pendingEmit[peerID] = nil
        guard let snapshot = store[peerID] else { return }
        continuation.yield(snapshot)
    }
}
