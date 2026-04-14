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
    private let lock = NSLock()

    public init() {
        var c: AsyncStream<[DiscoveredPeer]>.Continuation!
        self.peers = AsyncStream { c = $0 }
        self.peersContinuation = c
    }

    public func start(serviceType: String = "_1take-sync._tcp") {
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
        b.start(queue: .global(qos: .userInitiated))
        self.browser = b
        logger.info("[Browser] started for \(serviceType, privacy: .public)")
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        lock.withLock { current.removeAll() }
        peersContinuation.yield([])
    }

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
        lock.withLock { current = next }
        peersContinuation.yield(Array(next.values))
    }
}
