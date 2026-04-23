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

    struct RemotePeerView: Identifiable {
        let id: PeerID
        let name: String
        let connectionState: ConnectionState
        let statusSummary: String
    }

    enum TransportMode: String, CaseIterable, Sendable {
        case wifi = "WiFi"
        case mc = "MC"
        case auto = "Auto"
    }

    private(set) var runState: RunState = .stopped
    private(set) var localPeerID: String = "-"
    private(set) var lastScheduledFireLog: String = "-"
    private(set) var coordinatorLabel: String = "none"
    private(set) var isLocalCoordinator: Bool = false
    private(set) var syncStateLabel: String = "idle"
    private(set) var syncOffsetMs: Double = 0
    private(set) var syncConfidence: Double = 0
    private(set) var syncRoundTripMs: Double = 0
    private(set) var peers: [String] = []
    private(set) var remotePeers: [RemotePeerView] = []
    private(set) var logs: [LogEntry] = []
    private(set) var commandLog: [CommandLogEntry] = []
    var transportMode: TransportMode = .wifi

    // MARK: - Private

    private var clock: PeerClock?
    private var scheduleHandle: ScheduledEventHandle?
    private var syncStateTask: Task<Void, Never>?
    private var peersTask: Task<Void, Never>?
    private var commandsTask: Task<Void, Never>?
    private var coordinatorPollTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func start() async {
        guard case .stopped = runState else { return }
        runState = .starting

        let clock: PeerClock
        switch transportMode {
        case .wifi:
            clock = PeerClock()
            appendLog("Using WiFiTransport (default)")
        case .mc:
            clock = PeerClock(transportFactory: { peerID in
                MultipeerTransport(localPeerID: peerID, configuration: .default)
            })
            appendLog("Using MultipeerTransport (MC)")
        case .auto:
            clock = PeerClock(transportFactory: { peerID in
                FailoverTransport(options: [
                    .init(label: "WiFi") {
                        WiFiTransport(localPeerID: peerID, configuration: .default)
                    },
                    .init(label: "MC") {
                        MultipeerTransport(localPeerID: peerID, configuration: .default)
                    }
                ])
            })
            appendLog("Using FailoverTransport (Auto)")
        }
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

        statusTask = Task { [weak self] in
            guard let self, let clock = await self.clock else { return }
            for await snapshot in clock.statusUpdates {
                await self.handleStatus(snapshot)
            }
        }

        connectionTask = Task { [weak self] in
            guard let self, let clock = await self.clock else { return }
            for await event in clock.heartbeatEvents {
                await self.handleConnection(event)
            }
        }
    }

    func stop() async {
        syncStateTask?.cancel()
        peersTask?.cancel()
        commandsTask?.cancel()
        coordinatorPollTask?.cancel()
        statusTask?.cancel()
        connectionTask?.cancel()
        await scheduleHandle?.cancel()
        scheduleHandle = nil
        lastScheduledFireLog = "-"
        await clock?.stop()
        clock = nil
        runState = .stopped
        remotePeers = []
        appendLog("Stopped.")
    }

    var isStopped: Bool {
        if case .stopped = runState { return true }
        return false
    }

    var activeTransportLabel: String? {
        clock?.activeTransportLabel
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

    func scheduleBeepIn3Seconds() async {
        guard let clock else { return }
        let target = clock.now + 3_000_000_000
        appendLog("Scheduling fire at +3s (synced)")
        do {
            let handle = try await clock.schedule(atSyncedTime: target) { [weak self] in
                Task { @MainActor in
                    let stamp = ISO8601DateFormatter().string(from: Date())
                    self?.lastScheduledFireLog = "🔔 fired at \(stamp)"
                    self?.appendLog("🔔 Scheduled event fired")
                }
            }
            scheduleHandle = handle
        } catch {
            appendLog("⚠️ schedule failed: \(error)")
        }
    }

    func cancelScheduledBeep() async {
        await scheduleHandle?.cancel()
        scheduleHandle = nil
        appendLog("Cancelled scheduled event")
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
        for p in newPeers {
            upsertPeer(p.id) // ensure presence with default state
        }
        let currentSet = Set(newPeers.map { $0.id })
        remotePeers.removeAll { !currentSet.contains($0.id) }
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

    private func handleStatus(_ snapshot: RemotePeerStatus) {
        let keys = snapshot.entries.keys.sorted()
        appendLog("Status from \(snapshot.peerID): gen=\(snapshot.generation), keys=\(keys.count)")
        upsertPeer(snapshot.peerID, statusEntries: snapshot.entries)
    }

    private func handleConnection(_ event: HeartbeatMonitor.Event) {
        appendLog("\(event.peerID): \(event.state)")
        upsertPeer(event.peerID, connectionState: event.state)
    }

    private func upsertPeer(
        _ id: PeerID,
        connectionState: ConnectionState? = nil,
        statusEntries: [String: Data]? = nil
    ) {
        let current = remotePeers.first { $0.id == id }
        let cs = connectionState ?? current?.connectionState ?? .connected
        var summary = current?.statusSummary ?? "-"
        if let entries = statusEntries {
            let keys = entries.keys.sorted().prefix(3)
            summary = keys.isEmpty ? "-" : keys.joined(separator: ", ")
        }
        let view = RemotePeerView(
            id: id,
            name: "\(id)",
            connectionState: cs,
            statusSummary: summary
        )
        if let idx = remotePeers.firstIndex(where: { $0.id == id }) {
            remotePeers[idx] = view
        } else {
            remotePeers.append(view)
        }
    }

    private func appendLog(_ message: String) {
        logs.insert(LogEntry(timestamp: Date(), message: message), at: 0)
        if logs.count > 200 {
            logs.removeLast(logs.count - 200)
        }
    }
}
