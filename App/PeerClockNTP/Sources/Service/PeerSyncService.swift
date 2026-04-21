import Foundation
import PeerClock

@MainActor
@Observable
final class PeerSyncService {
    private(set) var peerCount: Int = 0
    private(set) var isRunning: Bool = false
    var onFlash: (() -> Void)?

    private var peerClock: PeerClock?
    private var commandTask: Task<Void, Never>?
    private var peerTask: Task<Void, Never>?

    private static let flashCommand = Command(type: "flash")

    func start() async {
        guard peerClock == nil else { return }
        let pc = PeerClock()
        peerClock = pc

        try? await pc.start()
        isRunning = true

        commandTask = Task {
            for await (_, command) in pc.commands {
                if command.type == "flash" {
                    self.onFlash?()
                }
            }
        }

        peerTask = Task {
            for await peers in pc.peers {
                self.peerCount = peers.count
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
        isRunning = false
        peerCount = 0
    }

    func sendFlash() async {
        guard let pc = peerClock else { return }
        try? await pc.broadcast(Self.flashCommand)
        onFlash?()
    }
}
