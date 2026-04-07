import Foundation
import Network

// MARK: - WiFiTransport

/// Network.framework を使ったリアルデバイス向けトランスポート実装。
/// UDP = 非信頼性（同期パケット）、TCP = 信頼性（コマンド等）。
final class WiFiTransport: Transport, @unchecked Sendable {

    // MARK: - Properties

    private let localPeerID: PeerID
    private let configuration: Configuration
    private let queue = DispatchQueue(label: "PeerClock.WiFiTransport")
    private let lock = NSLock()

    private var discovery: Discovery?
    private var tcpConnections: [PeerID: NWConnection] = [:]
    private var udpConnections: [PeerID: NWConnection] = [:]
    private var _connectedPeers: Set<PeerID> = []
    private var discoveryTask: Task<Void, Never>?

    // MARK: - Streams

    let unreliableMessages: AsyncStream<(PeerID, Data)>
    let reliableMessages: AsyncStream<(PeerID, Data)>
    let connectionEvents: AsyncStream<ConnectionEvent>

    private let unreliableCont: AsyncStream<(PeerID, Data)>.Continuation
    private let reliableCont: AsyncStream<(PeerID, Data)>.Continuation
    private let connectionCont: AsyncStream<ConnectionEvent>.Continuation

    // MARK: - Computed

    var connectedPeers: [PeerID] {
        lock.withLock { Array(_connectedPeers) }
    }

    // MARK: - Init

    init(localPeerID: PeerID, configuration: Configuration) {
        self.localPeerID = localPeerID
        self.configuration = configuration

        var unreliableC: AsyncStream<(PeerID, Data)>.Continuation!
        var reliableC: AsyncStream<(PeerID, Data)>.Continuation!
        var connectionC: AsyncStream<ConnectionEvent>.Continuation!

        unreliableMessages = AsyncStream { unreliableC = $0 }
        reliableMessages = AsyncStream { reliableC = $0 }
        connectionEvents = AsyncStream { connectionC = $0 }

        unreliableCont = unreliableC
        reliableCont = reliableC
        connectionCont = connectionC
    }

    // MARK: - Transport API

    func start() throws {
        let disc = try Discovery(serviceName: configuration.serviceName, localPeerID: localPeerID)
        lock.withLock { self.discovery = disc }

        disc.start()

        // Discovery イベントを非同期で処理するタスクを起動
        let task = Task { [weak self] in
            guard let self else { return }
            for await event in disc.events {
                guard !Task.isCancelled else { break }
                switch event {
                case .peerFound(let endpoint, let peerID):
                    if let peerID {
                        self.connectToPeer(peerID, endpoint: endpoint)
                    }
                case .peerLost(let endpoint):
                    // エンドポイントに対応するピアIDを検索して切断イベントを発行
                    self.handlePeerLost(endpoint: endpoint)
                case .listenerReady:
                    break
                }
            }
        }
        lock.withLock { self.discoveryTask = task }
    }

    func stop() {
        let (disc, task, tcpConns, udpConns) = lock.withLock { () -> (Discovery?, Task<Void, Never>?, [NWConnection], [NWConnection]) in
            let d = discovery
            discovery = nil
            let t = discoveryTask
            discoveryTask = nil
            let tcp = Array(tcpConnections.values)
            let udp = Array(udpConnections.values)
            tcpConnections = [:]
            udpConnections = [:]
            _connectedPeers = []
            return (d, t, tcp, udp)
        }

        task?.cancel()
        disc?.stop()
        tcpConns.forEach { $0.cancel() }
        udpConns.forEach { $0.cancel() }

        unreliableCont.finish()
        reliableCont.finish()
        connectionCont.finish()
    }

    func sendUnreliable(_ data: Data, to peer: PeerID) async throws {
        let connection = lock.withLock { udpConnections[peer] }
        guard let connection else { return }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            )
        }
    }

    func sendReliable(_ data: Data, to peer: PeerID) async throws {
        let connection = lock.withLock { tcpConnections[peer] }
        guard let connection else { return }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let lengthPrefix = withUnsafeBytes(of: UInt32(data.count).bigEndian) { Data($0) }
            let framed = lengthPrefix + data
            connection.send(
                content: framed,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            )
        }
    }

    func broadcastReliable(_ data: Data) async throws {
        let peers = lock.withLock { Array(_connectedPeers) }
        for peer in peers {
            try await sendReliable(data, to: peer)
        }
    }

    // MARK: - Private: Connection Management

    private func connectToPeer(_ peerID: PeerID, endpoint: NWEndpoint) {
        // 既に接続済みの場合はスキップ
        let alreadyConnected = lock.withLock { _connectedPeers.contains(peerID) }
        if alreadyConnected { return }

        // 自分自身への接続をスキップ
        if peerID == localPeerID { return }

        // TCP接続の作成
        let tcpParams = NWParameters.tcp
        let tcpConnection = NWConnection(to: endpoint, using: tcpParams)

        // UDP接続の作成
        let udpParams = NWParameters.udp
        let udpConnection = NWConnection(to: endpoint, using: udpParams)

        lock.withLock {
            tcpConnections[peerID] = tcpConnection
            udpConnections[peerID] = udpConnection
        }

        FileHandle.standardError.write(Data("[WiFiTransport] connectToPeer \(peerID) endpoint=\(endpoint)\n".utf8))
        // TCP状態ハンドラ
        tcpConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            FileHandle.standardError.write(Data("[WiFiTransport] tcp \(peerID) state: \(state)\n".utf8))
            switch state {
            case .ready:
                _ = self.lock.withLock { self._connectedPeers.insert(peerID) }
                self.connectionCont.yield(.peerJoined(peerID))
                self.receiveReliable(from: peerID, connection: tcpConnection)

            case .failed, .cancelled:
                self.lock.withLock {
                    self._connectedPeers.remove(peerID)
                    self.tcpConnections.removeValue(forKey: peerID)
                }
                self.connectionCont.yield(.peerLeft(peerID))

            default:
                break
            }
        }

        // UDP状態ハンドラ
        udpConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveUnreliable(from: peerID, connection: udpConnection)

            case .failed, .cancelled:
                _ = self.lock.withLock {
                    self.udpConnections.removeValue(forKey: peerID)
                }

            default:
                break
            }
        }

        tcpConnection.start(queue: queue)
        udpConnection.start(queue: queue)
    }

    private func handlePeerLost(endpoint: NWEndpoint) {
        // エンドポイントに対応するピアを検索して切断処理
        // Discovery が peerLost を出した時点で peerID を直接得ることができないため、
        // 接続済みピアの接続状態を確認して切断されたものを除去する
        // 実際には stateUpdateHandler の .failed/.cancelled で処理されるが、
        // Discovery の peerLost をトリガーとして明示的にキャンセルも行う
        let affectedPeers = lock.withLock { () -> [(PeerID, NWConnection?, NWConnection?)] in
            // エンドポイントが一致する接続を探す（簡易実装: 切断されたピアの接続をキャンセル）
            // NWConnection のエンドポイントを取得して比較
            var result: [(PeerID, NWConnection?, NWConnection?)] = []
            for (peerID, tcpConn) in tcpConnections {
                if tcpConn.endpoint == endpoint {
                    result.append((peerID, tcpConn, udpConnections[peerID]))
                }
            }
            return result
        }

        for (_, tcpConn, udpConn) in affectedPeers {
            tcpConn?.cancel()
            udpConn?.cancel()
        }
    }

    // MARK: - Private: Receive Loops

    private func receiveReliable(from peerID: PeerID, connection: NWConnection) {
        // 4バイトの長さプレフィックスを読み取り、続いてペイロードを読み取る
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil, let lengthData = data, lengthData.count == 4 else {
                if isComplete { connection.cancel() }
                return
            }

            let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let payloadLength = Int(length)
            guard payloadLength > 0, payloadLength <= 65536 else { return }

            connection.receive(minimumIncompleteLength: payloadLength, maximumLength: payloadLength) { [weak self] payload, _, isComplete, error in
                guard let self else { return }
                if let payload, error == nil {
                    self.reliableCont.yield((peerID, payload))
                }
                if !isComplete && error == nil {
                    self.receiveReliable(from: peerID, connection: connection)
                } else {
                    connection.cancel()
                }
            }
        }
    }

    private func receiveUnreliable(from peerID: PeerID, connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, error == nil {
                self.unreliableCont.yield((peerID, data))
            }
            if error == nil {
                self.receiveUnreliable(from: peerID, connection: connection)
            }
        }
    }
}
