// Examples/PeerClockDemo/PeerClockDemo/PeerClockViewModel.swift
import Foundation
import Observation
import PeerClock

@Observable
@MainActor
final class PeerClockViewModel {

    // MARK: - Public State

    enum RunState {
        case stopped
        case starting
        case running
        case error(String)
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
    }

    struct CommandLogEntry: Identifiable {
        enum Direction { case sent, received }
        let id = UUID()
        let timestamp: Date
        let direction: Direction
        let peerLabel: String
        let type: String
        let payload: String
    }

    private(set) var runState: RunState = .stopped
    private(set) var localPeerID: String = "-"
    private(set) var coordinatorLabel: String = "none"
    private(set) var isLocalCoordinator: Bool = false
    private(set) var syncStateLabel: String = "idle"
    private(set) var syncOffsetMs: Double = 0
    private(set) var syncConfidence: Double = 0
    private(set) var syncRoundTripMs: Double = 0
    private(set) var peers: [String] = []
    private(set) var logs: [LogEntry] = []
    private(set) var commandLog: [CommandLogEntry] = []

    // MARK: - Private

    private var clock: PeerClock?
    private var syncStateTask: Task<Void, Never>?
    private var peersTask: Task<Void, Never>?
    private var commandsTask: Task<Void, Never>?
    private var coordinatorPollTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func start() async {
        guard case .stopped = runState else { return }
        runState = .starting

        let clock = PeerClock()
        self.clock = clock
        self.localPeerID = "\(clock.localPeerID)"
        appendLog("Starting PeerClock (peer: \(localPeerID))")

        do {
            try await clock.start()
        } catch {
            runState = .error("start failed: \(error.localizedDescription)")
            appendLog("ERROR: \(error.localizedDescription)")
            return
        }

        runState = .running
        appendLog("Running. Discovering peers...")

        syncStateTask = Task { [weak self] in
            guard let self, let clock = await self.clock else { return }
            for await state in clock.syncState {
                await self.handleSyncState(state)
            }
        }

        peersTask = Task { [weak self] in
            guard let self, let clock = await self.clock else { return }
            for await peers in clock.peers {
                await self.handlePeers(peers)
            }
        }

        commandsTask = Task { [weak self] in
            guard let self, let clock = await self.clock else { return }
            for await (sender, command) in clock.commands {
                await self.handleCommand(from: sender, command: command)
            }
        }

        coordinatorPollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let clock = await self.clock else { return }
                let coord = clock.coordinatorID
                await self.updateCoordinator(coord)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop() async {
        syncStateTask?.cancel()
        peersTask?.cancel()
        commandsTask?.cancel()
        coordinatorPollTask?.cancel()
        await clock?.stop()
        clock = nil
        runState = .stopped
        appendLog("Stopped.")
    }

    // MARK: - Broadcast

    func broadcastPing() async {
        guard let clock else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let command = Command(
            type: "com.demo.ping",
            payload: Data(timestamp.utf8)
        )
        do {
            try await clock.broadcast(command)
            commandLog.insert(
                CommandLogEntry(
                    timestamp: Date(),
                    direction: .sent,
                    peerLabel: "all",
                    type: command.type,
                    payload: timestamp
                ),
                at: 0
            )
            appendLog("Broadcast: \(command.type)")
        } catch {
            appendLog("ERROR: broadcast failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Handlers

    private func handleSyncState(_ state: SyncState) {
        switch state {
        case .idle:
            syncStateLabel = "idle"
        case .discovering:
            syncStateLabel = "discovering"
        case .syncing:
            syncStateLabel = "syncing"
        case .synced(let offset, let quality):
            syncStateLabel = "synced"
            syncOffsetMs = offset * 1000
            syncConfidence = quality.confidence
            syncRoundTripMs = Double(quality.roundTripDelayNs) / 1_000_000
            appendLog(String(
                format: "Synced: offset=%+.2fms, RTT=%.2fms, conf=%.2f",
                syncOffsetMs, syncRoundTripMs, syncConfidence
            ))
        case .error(let msg):
            syncStateLabel = "error"
            appendLog("Sync error: \(msg)")
        }
    }

    private func handlePeers(_ newPeers: [Peer]) {
        peers = newPeers.map { "\($0.id)" }
        appendLog("Peers: \(peers.count) connected")
    }

    private func handleCommand(from sender: PeerID, command: Command) {
        let payloadStr = String(data: command.payload, encoding: .utf8) ?? "<binary>"
        commandLog.insert(
            CommandLogEntry(
                timestamp: Date(),
                direction: .received,
                peerLabel: "\(sender)",
                type: command.type,
                payload: payloadStr
            ),
            at: 0
        )
        appendLog("Received: \(command.type) from \(sender)")
    }

    private func updateCoordinator(_ coord: PeerID?) {
        if let coord {
            coordinatorLabel = "\(coord)"
            isLocalCoordinator = (coord == clock?.localPeerID)
        } else {
            coordinatorLabel = "none"
            isLocalCoordinator = false
        }
        // Coordinator 自身は常に自分の時計が基準なので synced 扱いにする
        if isLocalCoordinator, case .running = runState {
            syncStateLabel = "synced"
            syncOffsetMs = 0
            syncConfidence = 1.0
            syncRoundTripMs = 0
        }
    }

    private func appendLog(_ message: String) {
        logs.insert(LogEntry(timestamp: Date(), message: message), at: 0)
        if logs.count > 200 {
            logs.removeLast(logs.count - 200)
        }
    }
}
