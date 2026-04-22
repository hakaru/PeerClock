import Foundation
import os
import PeerClock

private let logger = Logger(subsystem: "net.hakaru.PeerClockMetronome", category: "PeerSync")

enum PeerSyncState: Sendable {
    case disconnected
    case searching
    case synced(offsetMs: Double, rttMs: Double)
}

struct PeerSyncSnapshot: Sendable {
    let peerCount: Int
    let syncState: PeerSyncState
    let debugStatus: String
    let isConnected: Bool
}

/// Actor-isolated transport facade for PeerClock.
/// Publishes events as AsyncStreams so consumers (e.g. MetronomeEngine, UI) can
/// handle them without MainActor hops on the audio path.
actor PeerMetronomeService {
    private var peerClock: PeerClock?
    private var timebase: PeerClockTimebase?

    private var commandTask: Task<Void, Never>?
    private var peerTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?

    private let snapshotStream: AsyncStream<PeerSyncSnapshot>
    private let snapshotContinuation: AsyncStream<PeerSyncSnapshot>.Continuation
    private let beatStream: AsyncStream<BeatEvent>
    private let beatContinuation: AsyncStream<BeatEvent>.Continuation
    private let playStream: AsyncStream<Bool>
    private let playContinuation: AsyncStream<Bool>.Continuation
    private let configStream: AsyncStream<(MetronomeConfig, UInt64)>
    private let configContinuation: AsyncStream<(MetronomeConfig, UInt64)>.Continuation

    private var currentPeerCount: Int = 0
    private var currentSyncState: PeerSyncState = .disconnected
    private var currentDebugStatus: String = "Not started"
    private var currentIsConnected: Bool = false

    nonisolated var snapshots: AsyncStream<PeerSyncSnapshot> { snapshotStream }
    nonisolated var beatEvents: AsyncStream<BeatEvent> { beatStream }
    nonisolated var playEvents: AsyncStream<Bool> { playStream }
    nonisolated var configEvents: AsyncStream<(MetronomeConfig, UInt64)> { configStream }

    init() {
        (snapshotStream, snapshotContinuation) = AsyncStream.makeStream()
        (beatStream, beatContinuation) = AsyncStream.makeStream()
        (playStream, playContinuation) = AsyncStream.makeStream()
        (configStream, configContinuation) = AsyncStream.makeStream()
    }

    /// Timebase facade — safe to call from any isolation after start().
    /// Returns nil until start() completes.
    nonisolated func getTimebase() async -> PeerClockTimebase? {
        await timebase
    }

    func start() async {
        guard peerClock == nil else { return }
        let pc = PeerClock()
        peerClock = pc
        timebase = PeerClockTimebase(clock: pc)

        updateDebug("Starting... ID: \(pc.localPeerID.description.prefix(8))")
        do {
            try await pc.start()
            updateDebug("Running. ID: \(pc.localPeerID.description.prefix(8))")
        } catch {
            updateDebug("Error: \(error.localizedDescription)")
        }
        currentIsConnected = true
        publishSnapshot()

        commandTask = Task { [weak self] in
            for await (_, command) in pc.commands {
                await self?.handleCommand(command)
            }
        }

        peerTask = Task { [weak self] in
            for await peers in pc.peers {
                logger.info("Peers updated: \(peers.count) peers")
                await self?.handlePeersUpdate(count: peers.count, isEmpty: peers.isEmpty)
            }
        }

        snapshotTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                await self?.pollSyncState(pc)
            }
        }
    }

    func stop() async {
        commandTask?.cancel()
        commandTask = nil
        peerTask?.cancel()
        peerTask = nil
        snapshotTask?.cancel()
        snapshotTask = nil

        if let pc = peerClock {
            await pc.stop()
        }
        peerClock = nil
        timebase = nil
        currentIsConnected = false
        currentPeerCount = 0
        publishSnapshot()
    }

    var hasPeers: Bool { currentPeerCount > 0 }

    // MARK: - Broadcast

    func broadcastPlay(_ playing: Bool) async {
        guard let pc = peerClock else { return }
        let payload = Data([playing ? 1 : 0])
        let command = Command(type: "metronome.play", payload: payload)
        try? await pc.broadcast(command)
    }

    func broadcastConfig(_ config: MetronomeConfig, applyAtNs: UInt64) async {
        guard let pc = peerClock else { return }
        var payload = Data()
        if let encoded = try? JSONEncoder().encode(config) {
            var applyAtBE = applyAtNs.bigEndian
            payload.append(Data(bytes: &applyAtBE, count: 8))
            payload.append(encoded)
        }
        let command = Command(type: "metronome.config", payload: payload)
        try? await pc.broadcast(command)
    }

    func broadcastBeat(_ event: BeatEvent) async {
        guard let pc = peerClock else { return }
        guard let payload = try? JSONEncoder().encode(event) else { return }
        let command = Command(type: "metronome.beat", payload: payload)
        try? await pc.broadcast(command)
    }

    // MARK: - Internal

    private func handleCommand(_ command: Command) {
        switch command.type {
        case "metronome.config":
            guard command.payload.count > 8 else { return }
            let applyAtNs = command.payload.withUnsafeBytes {
                UInt64(bigEndian: $0.load(as: UInt64.self))
            }
            let configData = command.payload.dropFirst(8)
            if let config = try? JSONDecoder().decode(MetronomeConfig.self, from: Data(configData)) {
                configContinuation.yield((config, applyAtNs))
            }

        case "metronome.play":
            let playing = command.payload.first == 1
            playContinuation.yield(playing)

        case "metronome.beat":
            if let event = try? JSONDecoder().decode(BeatEvent.self, from: command.payload) {
                beatContinuation.yield(event)
            }

        default:
            break
        }
    }

    private func handlePeersUpdate(count: Int, isEmpty: Bool) {
        currentPeerCount = count
        if isEmpty {
            currentSyncState = .searching
        }
        publishSnapshot()
    }

    private func pollSyncState(_ pc: PeerClock) {
        guard currentPeerCount > 0 else {
            currentSyncState = .disconnected
            publishSnapshot()
            return
        }
        let snapshot = pc.currentSync
        switch snapshot.state {
        case .synced(let offset, let quality):
            currentSyncState = .synced(
                offsetMs: offset * 1000,
                rttMs: Double(quality.roundTripDelayNs) / 1_000_000
            )
        case .syncing, .discovering, .idle, .error:
            currentSyncState = .searching
        }
        publishSnapshot()
    }

    private func updateDebug(_ msg: String) {
        currentDebugStatus = msg
        publishSnapshot()
    }

    private func publishSnapshot() {
        snapshotContinuation.yield(PeerSyncSnapshot(
            peerCount: currentPeerCount,
            syncState: currentSyncState,
            debugStatus: currentDebugStatus,
            isConnected: currentIsConnected
        ))
    }
}
