import Foundation
import os
import PeerClock

private let logger = Logger(subsystem: "net.hakaru.PeerClockMetronome", category: "PeerSync")

enum PeerSyncState: Sendable {
    case disconnected
    case searching
    case synced(offsetMs: Double, rttMs: Double)
}

@MainActor
@Observable
final class PeerMetronomeService {
    private(set) var peerCount: Int = 0
    private(set) var isConnected: Bool = false
    private(set) var syncState: PeerSyncState = .disconnected
    private(set) var debugStatus: String = "Not started"

    private let _peerClockLock = OSAllocatedUnfairLock<PeerClock?>(initialState: nil)
    private var peerClock: PeerClock? {
        get { _peerClockLock.withLock { $0 } }
        set { _peerClockLock.withLock { $0 = newValue } }
    }
    private var commandTask: Task<Void, Never>?
    private var peerTask: Task<Void, Never>?

    var onConfigReceived: ((MetronomeConfig, UInt64) -> Void)?
    var onPlayReceived: ((Bool) -> Void)?

    nonisolated var syncedNow: UInt64 {
        _peerClockLock.withLock { $0 }?.now ?? 0
    }

    var hasPeers: Bool {
        peerCount > 0
    }

    func start() async {
        guard peerClock == nil else { return }
        let pc = PeerClock()
        peerClock = pc
        debugStatus = "Starting... ID: \(pc.localPeerID.description.prefix(8))"
        do {
            try await pc.start()
            debugStatus = "Running. ID: \(pc.localPeerID.description.prefix(8))"
        } catch {
            debugStatus = "Error: \(error.localizedDescription)"
        }
        isConnected = true

        commandTask = Task {
            for await (_, command) in pc.commands {
                switch command.type {
                case "metronome.config":
                    self.handleConfigCommand(command.payload)
                case "metronome.play":
                    let playing = command.payload.first == 1
                    self.onPlayReceived?(playing)
                default:
                    break
                }
            }
        }

        peerTask = Task {
            for await peers in pc.peers {
                logger.info("Peers updated: \(peers.count) peers")
                self.peerCount = peers.count
                if peers.isEmpty {
                    self.syncState = .searching
                }
            }
        }

        // Poll sync state via currentSync (handles coordinator case correctly)
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard self.peerCount > 0 else {
                    self.syncState = .disconnected
                    continue
                }
                let snapshot = pc.currentSync
                switch snapshot.state {
                case .synced(let offset, let quality):
                    let offsetMs = offset * 1000
                    let rttMs = Double(quality.roundTripDelayNs) / 1_000_000
                    self.syncState = .synced(offsetMs: offsetMs, rttMs: rttMs)
                case .syncing, .discovering:
                    self.syncState = .searching
                case .idle, .error:
                    self.syncState = .searching
                }
            }
        }
    }

    func stop() async {
        commandTask?.cancel()
        commandTask = nil
        peerTask?.cancel()
        peerTask = nil
        if let pc = peerClock {
            await pc.stop()
        }
        peerClock = nil
        isConnected = false
        peerCount = 0
    }

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

    private func handleConfigCommand(_ payload: Data) {
        guard payload.count > 8 else { return }
        let applyAtNs = payload.withUnsafeBytes {
            UInt64(bigEndian: $0.load(as: UInt64.self))
        }
        let configData = payload.dropFirst(8)
        guard let config = try? JSONDecoder().decode(MetronomeConfig.self, from: Data(configData)) else { return }
        onConfigReceived?(config, applyAtNs)
    }
}
