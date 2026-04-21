import Foundation
import Observation

enum SyncState: Sendable {
    case idle
    case syncing
    case synced
    case offline
    case error(String)
}

@Observable
@MainActor
final class ClockViewModel {
    var ntpOffset: TimeInterval?
    var rtt: TimeInterval?
    var serverHost: String?
    var stratum: Int?
    var isOnline: Bool = true
    var offsetHistory: [Double] = []
    var syncState: SyncState = .idle

    private let ntpClient = NTPClient()
    private let networkMonitor = NetworkMonitor()
    private var monitorTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    func start() async {
        guard monitorTask == nil else { return }
        syncState = .syncing

        monitorTask = Task {
            for await connected in networkMonitor.pathUpdates {
                isOnline = connected
                if connected {
                    await refresh()
                } else {
                    syncState = .offline
                }
            }
        }

        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                await updateFromClient()
            }
        }

        await networkMonitor.start()
        await ntpClient.startPeriodicSync()
    }

    func stop() async {
        monitorTask?.cancel()
        monitorTask = nil
        pollTask?.cancel()
        pollTask = nil
        await ntpClient.stop()
        await networkMonitor.stop()
    }

    private func refresh() async {
        syncState = .syncing
        await ntpClient.syncAll()
        await updateFromClient()
    }

    func pollUpdate() async {
        await updateFromClient()
    }

    private func updateFromClient() async {
        if let result = await ntpClient.bestResult {
            ntpOffset = result.offset
            rtt = result.rtt
            serverHost = result.host
            stratum = result.stratum
            syncState = .synced
        }
        offsetHistory = await ntpClient.offsetHistory
    }
}
