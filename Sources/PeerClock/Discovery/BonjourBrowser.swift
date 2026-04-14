import Foundation
import Network
import os

private let logger = Logger(subsystem: "net.hakaru.PeerClock", category: "BonjourBrowser")

public final class BonjourBrowser: @unchecked Sendable {

    public struct DiscoveredPeer: Sendable, Equatable, Identifiable {
        public let id: String          // serviceName
        public let serviceName: String
        public let endpoint: NWEndpoint
        public let txt: [String: String]

        public var role: String? { txt["role"] }
        public var peerID: String? { txt["peer_id"] }
        public var term: UInt64? { txt["term"].flatMap(UInt64.init) }
    }

    public let peers: AsyncStream<[DiscoveredPeer]>
    private let peersContinuation: AsyncStream<[DiscoveredPeer]>.Continuation

    private var browser: NWBrowser?
    private var current: [String: DiscoveredPeer] = [:]
    private let queue = DispatchQueue(label: "net.hakaru.PeerClock.BonjourBrowser")

    public init() {
        var c: AsyncStream<[DiscoveredPeer]>.Continuation!
        self.peers = AsyncStream { c = $0 }
        self.peersContinuation = c
    }

    public func start(serviceType: String = PeerClockService.type) {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: nil)
        let b = NWBrowser(for: descriptor, using: params)

        b.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleResults(results)
        }
        b.stateUpdateHandler = { state in
            logger.info("[Browser] state=\(String(describing: state), privacy: .public)")
        }
        b.start(queue: queue)
        self.browser = b
        logger.info("[Browser] started for \(serviceType, privacy: .public)")
    }

    public func stop() {
        queue.async { [self] in
            browser?.cancel()
            browser = nil
            current.removeAll()
            peersContinuation.yield([])
            peersContinuation.finish()
        }
    }

    // Note: We use the full results snapshot rather than `changes` deltas.
    // For 10-device scale this is simpler and correct; if peer counts grow
    // larger, switch to processing changes (.added/.removed/.changed).
    private func handleResults(_ results: Set<NWBrowser.Result>) {
        var next: [String: DiscoveredPeer] = [:]
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            var txt: [String: String] = [:]
            if case .bonjour(let record) = result.metadata {
                for (k, v) in record.dictionary { txt[k] = v }
            }
            next[name] = DiscoveredPeer(
                id: name,
                serviceName: name,
                endpoint: result.endpoint,
                txt: txt
            )
        }
        current = next
        peersContinuation.yield(Array(next.values))
    }
}
