import Foundation
import Network

// MARK: - Discovery

/// Bonjour を使ったピア探索。全ノードが同時にアドバタイズとブラウズを行う。
final class Discovery: @unchecked Sendable {

    // MARK: - Types

    enum DiscoveryEvent: Sendable {
        case peerFound(NWEndpoint, PeerID?)
        case peerLost(NWEndpoint, PeerID?)
        case listenerReady(NWEndpoint.Port)
    }

    // MARK: - Properties

    private let serviceType: String
    private let localPeerID: PeerID
    private let listener: NWListener
    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "PeerClock.Discovery")

    private var discoveredContinuation: AsyncStream<DiscoveryEvent>.Continuation?
    let events: AsyncStream<DiscoveryEvent>

    /// 新しい inbound 接続を WiFiTransport へ引き渡すコールバック。
    /// WiFiTransport が start 前にセットする。
    var inboundConnectionHandler: ((NWConnection) -> Void)?

    // MARK: - Init

    init(serviceType: String, localPeerID: PeerID) throws {
        self.serviceType = serviceType
        self.localPeerID = localPeerID

        // TCP パラメータでリスナーを作成
        let tcpParams = NWParameters.tcp
        let listener = try NWListener(using: tcpParams, on: .any)
        var txt = NWTXTRecord()
        txt["peerID"] = localPeerID.rawValue.uuidString
        listener.service = NWListener.Service(
            name: localPeerID.rawValue.uuidString,
            type: serviceType,
            txtRecord: txt
        )
        self.listener = listener

        // Bonjourブラウザーを作成
        let browserDescriptor = NWBrowser.Descriptor.bonjour(type: serviceType, domain: nil)
        let browserParams = NWParameters.tcp
        self.browser = NWBrowser(for: browserDescriptor, using: browserParams)

        // AsyncStream のセットアップ
        var cont: AsyncStream<DiscoveryEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.discoveredContinuation = cont
    }

    // MARK: - Public API

    func start() {
        // Network.framework validates that a listener can accept inbound connections
        // before it transitions out of setup; without a handler, start() fails with EINVAL.
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.inboundConnectionHandler?(connection)
        }

        // リスナーの状態ハンドラ
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state, let port = self.listener.port {
                self.discoveredContinuation?.yield(.listenerReady(port))
            }
        }
        listener.start(queue: queue)

        // ブラウザーの結果変更ハンドラ
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self else { return }
            for change in changes {
                switch change {
                case .added(let result):
                    // 自分自身のサービスはスキップ
                    let peerID = self.extractPeerID(from: result)
                    if peerID == self.localPeerID { continue }
                    self.discoveredContinuation?.yield(.peerFound(result.endpoint, peerID))

                case .removed(let result):
                    let peerID = self.extractPeerID(from: result)
                    if peerID == self.localPeerID { continue }
                    self.discoveredContinuation?.yield(.peerLost(result.endpoint, peerID))

                case .changed(let old, let new, _):
                    let peerID = self.extractPeerID(from: old)
                    if peerID == self.localPeerID { continue }
                    self.discoveredContinuation?.yield(.peerLost(old.endpoint, peerID))
                    self.discoveredContinuation?.yield(.peerFound(new.endpoint, self.extractPeerID(from: new)))

                case .identical:
                    break

                @unknown default:
                    break
                }
            }
        }
        browser.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        browser.cancel()
        discoveredContinuation?.finish()
    }

    // MARK: - Private

    private func extractPeerID(from result: NWBrowser.Result) -> PeerID? {
        if case .service(let name, _, _, _) = result.endpoint,
           let uuid = UUID(uuidString: name) {
            return PeerID(rawValue: uuid)
        }
        return nil
    }
}
