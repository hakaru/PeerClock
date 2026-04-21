import Foundation

actor NTPClient {
    private static let servers = [
        "time.apple.com",
        "ntp.nict.jp",
        "pool.ntp.org",
        "time.google.com",
        "time.cloudflare.com"
    ]
    private static let samplesPerSync = 8

    private let sntp = SNTPClient()
    private(set) var bestResult: NTPServerResult?
    private(set) var offsetHistory: [Double] = []
    private var syncTask: Task<Void, Never>?

    var currentOffset: TimeInterval? { bestResult?.offset }

    func syncAll() async {
        let results = await withTaskGroup(of: NTPServerResult?.self, returning: [NTPServerResult].self) { group in
            for server in Self.servers {
                group.addTask {
                    try? await self.sntp.query(host: server)
                }
            }
            var collected: [NTPServerResult] = []
            for await result in group {
                if let result { collected.append(result) }
            }
            return collected
        }

        guard let best = results.min(by: { $0.rtt < $1.rtt }) else { return }

        let refined = await refine(host: best.host, count: Self.samplesPerSync)
        if let refined {
            bestResult = refined
            appendHistory(refined.offset)
        }
    }

    func startPeriodicSync(interval: Duration = .seconds(5)) {
        syncTask?.cancel()
        syncTask = Task {
            await syncAll()
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                await periodicRefresh()
            }
        }
    }

    func stop() {
        syncTask?.cancel()
        syncTask = nil
    }

    private func periodicRefresh() async {
        guard let host = bestResult?.host else {
            await syncAll()
            return
        }
        let refined = await refine(host: host, count: 4)
        if let refined {
            bestResult = refined
            appendHistory(refined.offset)
        }
    }

    private func refine(host: String, count: Int) async -> NTPServerResult? {
        var samples: [NTPServerResult] = []
        for _ in 0..<count {
            if let result = try? await sntp.query(host: host) {
                samples.append(result)
            }
        }

        guard !samples.isEmpty else { return nil }

        // best-half filtering: sort by RTT, keep lower half
        samples.sort { $0.rtt < $1.rtt }
        let half = max(samples.count / 2, 1)
        let bestHalf = samples.prefix(half)

        let avgOffset = bestHalf.map(\.offset).reduce(0, +) / Double(bestHalf.count)
        let minRtt = bestHalf.map(\.rtt).min() ?? samples[0].rtt

        return NTPServerResult(
            host: host,
            offset: avgOffset,
            rtt: minRtt,
            stratum: samples[0].stratum,
            sampledAt: Date()
        )
    }

    private func appendHistory(_ offset: Double) {
        offsetHistory.append(offset)
        if offsetHistory.count > 60 {
            offsetHistory.removeFirst(offsetHistory.count - 60)
        }
    }
}
