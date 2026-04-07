import Foundation

/// Encodes `Codable` values for status transport. Kept separate so tests can
/// verify behaviour without touching the network path.
public enum StatusValueEncoder {
    /// Encodes a Codable value to binary property list bytes.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        // plist top level must be array or dict — wrap.
        return try encoder.encode([value])
    }

    /// Decodes a value previously encoded with `encode(_:)`.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = PropertyListDecoder()
        let wrapper = try decoder.decode([T].self, from: data)
        guard let value = wrapper.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "empty wrapper"))
        }
        return value
    }
}

/// Actor responsible for local status state, debounced flush and generation numbering.
///
/// Contract:
/// - `setStatus` only marks state dirty; actual `STATUS_PUSH` is emitted by the
///   scheduled flush task after `debounce` seconds.
/// - `generation` advances once per flush (snapshot-unit), never per key.
public actor StatusRegistry {

    // MARK: - Dependencies

    private let localPeerID: PeerID
    private let debounce: TimeInterval
    private let broadcast: @Sendable (Message) async throws -> Void

    // MARK: - State

    private var entries: [String: Data] = [:]
    private var dirty = false
    private var generation: UInt64 = 0
    private var flushTask: Task<Void, Never>?

    public init(
        localPeerID: PeerID,
        debounce: TimeInterval,
        broadcast: @escaping @Sendable (Message) async throws -> Void
    ) {
        self.localPeerID = localPeerID
        self.debounce = debounce
        self.broadcast = broadcast
    }

    // MARK: - Public API

    /// Sets a raw-bytes status value and schedules a debounced flush.
    public func setStatus(_ data: Data, forKey key: String) {
        entries[key] = data
        dirty = true
        scheduleFlush()
    }

    /// Sets a Codable value (encoded via binary property list).
    public func setStatus<T: Codable & Sendable>(_ value: T, forKey key: String) throws {
        let data = try StatusValueEncoder.encode(value)
        setStatus(data, forKey: key)
    }

    /// Returns a snapshot of the current local entries (for tests/introspection).
    public func snapshot() -> (generation: UInt64, entries: [String: Data]) {
        (generation, entries)
    }

    /// Forces an immediate flush (used on explicit status requests, peer join, etc.).
    public func flushNow() async {
        flushTask?.cancel()
        flushTask = nil
        await performFlush()
    }

    /// Cancels any pending flush. Called during shutdown.
    public func shutdown() {
        flushTask?.cancel()
        flushTask = nil
    }

    // MARK: - Internals

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        let delay = debounce
        flushTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self.performFlush()
        }
    }

    private func performFlush() async {
        flushTask = nil
        guard dirty else { return }
        dirty = false
        generation &+= 1
        let snapshotEntries = entries.map { StatusEntry(key: $0.key, value: $0.value) }
        let message = Message.statusPush(
            senderID: localPeerID,
            generation: generation,
            entries: snapshotEntries
        )
        try? await broadcast(message)
    }
}
