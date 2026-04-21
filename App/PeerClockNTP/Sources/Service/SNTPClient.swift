import Foundation
import Network

struct SNTPClient: Sendable {
    private static let ntpEpochOffset: TimeInterval = 2_208_988_800

    func query(host: String, timeout: Duration = .seconds(3)) async throws -> NTPServerResult {
        try await withThrowingTaskGroup(of: NTPServerResult.self) { group in
            group.addTask {
                try await self.performQuery(host: host)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SNTPError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func performQuery(host: String) async throws -> NTPServerResult {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: 123,
            using: .udp
        )
        defer { connection.cancel() }

        try await waitForReady(connection)

        let t0 = Date()
        let packet = Self.buildPacket()

        try await send(packet, on: connection)
        let data = try await receive(on: connection)
        let t3 = Date()

        guard data.count >= 48 else {
            throw SNTPError.invalidResponse
        }

        return Self.parseResponse(data: data, t0: t0, t3: t3, host: host)
    }

    private func waitForReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: SNTPError.cancelled)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func receive(on connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receiveMessage { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: SNTPError.invalidResponse)
                }
            }
        }
    }

    private static func buildPacket() -> Data {
        var packet = Data(count: 48)
        packet[0] = 0b00_100_011 // LI=0, Version=4, Mode=3 (client)
        return packet
    }

    private static func parseResponse(data: Data, t0: Date, t3: Date, host: String) -> NTPServerResult {
        let t1 = extractTimestamp(from: data, offset: 32)
        let t2 = extractTimestamp(from: data, offset: 40)

        let t0Ntp = t0.timeIntervalSince1970 + ntpEpochOffset
        let t3Ntp = t3.timeIntervalSince1970 + ntpEpochOffset

        let offset = ((t1 - t0Ntp) + (t2 - t3Ntp)) / 2.0
        let rtt = (t3Ntp - t0Ntp) - (t2 - t1)
        let stratum = Int(data[1])

        return NTPServerResult(
            host: host,
            offset: offset,
            rtt: rtt,
            stratum: stratum,
            sampledAt: t3
        )
    }

    private static func extractTimestamp(from data: Data, offset: Int) -> TimeInterval {
        let seconds = data.withUnsafeBytes { buffer in
            buffer.load(fromByteOffset: offset, as: UInt32.self).bigEndian
        }
        let fraction = data.withUnsafeBytes { buffer in
            buffer.load(fromByteOffset: offset + 4, as: UInt32.self).bigEndian
        }
        return TimeInterval(seconds) + TimeInterval(fraction) / 4_294_967_296.0
    }
}

enum SNTPError: Error {
    case invalidResponse
    case cancelled
    case timeout
}
