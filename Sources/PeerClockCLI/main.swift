import Foundation
import PeerClock

@main
struct PeerClockCLI {
    static func main() async {
        setbuf(stdout, nil)
        let clock = PeerClock()

        log("Local peer: \(clock.localPeerID)")
        log("Starting...")

        do {
            try await clock.start()
        } catch {
            log("ERROR: failed to start: \(error)")
            return
        }

        log("Discovering peers on local network (_peerclock._tcp)...")

        // Monitor sync state
        Task.detached {
            for await state in clock.syncState {
                switch state {
                case .idle:
                    log("Sync state: idle")
                case .discovering:
                    log("Sync state: discovering")
                case .syncing:
                    log("Sync state: syncing")
                case .synced(let offset, let quality):
                    let offsetMs = offset * 1000
                    let rttMs = Double(quality.roundTripDelayNs) / 1_000_000
                    log(String(
                        format: "Synced: offset=%+.2fms, RTT=%.2fms, confidence=%.2f",
                        offsetMs, rttMs, quality.confidence
                    ))
                case .error(let message):
                    log("Sync error: \(message)")
                }
            }
        }

        // Monitor peers
        Task.detached {
            for await peers in clock.peers {
                let names = peers.map { "\($0.id)" }.joined(separator: ", ")
                log("Peers (\(peers.count)): [\(names)]")
            }
        }

        // Monitor incoming commands
        Task.detached {
            for await (sender, command) in clock.commands {
                let payloadStr = String(data: command.payload, encoding: .utf8) ?? "<binary>"
                log("Received: \(command.type) \"\(payloadStr)\" from \(sender)")
            }
        }

        // stdin command loop
        log("Type 'help' for commands.")
        while let line = readLine() {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let cmd = parts.first else { continue }

            switch cmd {
            case "help":
                print("Commands: send <message>, peers, status, quit")
            case "send":
                let message = parts.count > 1 ? parts[1] : ""
                let command = Command(
                    type: "com.demo.message",
                    payload: Data(message.utf8)
                )
                do {
                    try await clock.broadcast(command)
                    log("Broadcast: com.demo.message \"\(message)\"")
                } catch {
                    log("ERROR: broadcast failed: \(error)")
                }
            case "peers":
                log("(peers are reported continuously above)")
            case "status":
                if let coord = clock.coordinatorID {
                    let isSelf = coord == clock.localPeerID
                    log("Coordinator: \(coord)\(isSelf ? " (self)" : "")")
                } else {
                    log("Coordinator: none")
                }
                log("Current now: \(clock.now) ns")
            case "quit":
                log("Stopping...")
                await clock.stop()
                log("Stopped.")
                return
            default:
                print("Unknown command: \(cmd). Type 'help'.")
            }
        }

        await clock.stop()
    }

    static func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        print("[\(timestamp)] \(message)")
    }
}
