import Foundation
import MultipeerConnectivity
import os

public final class MultipeerTransport: NSObject, Transport, @unchecked Sendable {

    public let peers: AsyncStream<Set<PeerID>>
    public let incomingMessages: AsyncStream<(PeerID, Data)>

    private let localPeerID: PeerID
    private let configuration: Configuration
    private let logger: Logger
    private let lock = NSLock()

    private var mcPeerID: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var pcToMC: [PeerID: MCPeerID] = [:]
    private var mcToPC: [MCPeerID: PeerID] = [:]

    private let peersContinuation: AsyncStream<Set<PeerID>>.Continuation
    private let incomingMessagesContinuation: AsyncStream<(PeerID, Data)>.Continuation

    public init(localPeerID: PeerID, configuration: Configuration) {
        self.localPeerID = localPeerID
        self.configuration = configuration
        self.logger = Logger(subsystem: "net.hakaru.PeerClock", category: "MultipeerTransport")
        var peersCont: AsyncStream<Set<PeerID>>.Continuation!
        self.peers = AsyncStream { peersCont = $0 }
        self.peersContinuation = peersCont
        var incomingCont: AsyncStream<(PeerID, Data)>.Continuation!
        self.incomingMessages = AsyncStream { incomingCont = $0 }
        self.incomingMessagesContinuation = incomingCont
        super.init()
    }

    public func start() async throws {
        let displayName = MultipeerIdentity.encode(localPeerID)
        let mcID = MultipeerPeerIDStore.loadOrCreate(displayName: displayName)
        let session = MCSession(peer: mcID, securityIdentity: nil, encryptionPreference: .optional)
        session.delegate = self
        let advertiser = MCNearbyServiceAdvertiser(peer: mcID, discoveryInfo: nil, serviceType: configuration.mcServiceType)
        advertiser.delegate = self
        let browser = MCNearbyServiceBrowser(peer: mcID, serviceType: configuration.mcServiceType)
        browser.delegate = self
        lock.withLock {
            self.mcPeerID = mcID
            self.session = session
            self.advertiser = advertiser
            self.browser = browser
        }
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        logger.info("MultipeerTransport started as \(displayName, privacy: .public)")
    }

    public func stop() async {
        let (session, advertiser, browser) = lock.withLock { () -> (MCSession?, MCNearbyServiceAdvertiser?, MCNearbyServiceBrowser?) in
            let s = self.session; let a = self.advertiser; let b = self.browser
            self.session?.delegate = nil; self.advertiser?.delegate = nil; self.browser?.delegate = nil
            self.session = nil; self.advertiser = nil; self.browser = nil; self.mcPeerID = nil
            self.pcToMC.removeAll(); self.mcToPC.removeAll()
            return (s, a, b)
        }
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        peersContinuation.yield([])
        logger.info("MultipeerTransport stopped")
    }

    public func send(_ data: Data, to peer: PeerID) async throws {
        let (session, mcPeer) = lock.withLock { (self.session, self.pcToMC[peer]) }
        guard let session, let mcPeer, session.connectedPeers.contains(mcPeer) else {
            throw MultipeerTransportError.notConnected
        }
        try session.send(data, toPeers: [mcPeer], with: .reliable)
    }

    public func broadcast(_ data: Data) async throws {
        let (session, connected) = lock.withLock { (self.session, self.session?.connectedPeers ?? []) }
        guard let session, !connected.isEmpty else { return }
        try session.send(data, toPeers: connected, with: .reliable)
    }

    public func broadcastUnreliable(_ data: Data) async throws {
        let (session, connected) = lock.withLock { (self.session, self.session?.connectedPeers ?? []) }
        guard let session, !connected.isEmpty else { return }
        try session.send(data, toPeers: connected, with: .unreliable)
    }

    fileprivate func currentPeerSet() -> Set<PeerID> {
        lock.withLock { Set(pcToMC.keys) }
    }
}

public enum MultipeerTransportError: Error, Sendable {
    case notConnected
}

extension MultipeerTransport: MCSessionDelegate {

    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        guard let pcPeerID = MultipeerIdentity.decode(peerID.displayName) else {
            logger.warning("Ignoring MC peer with non-UUID displayName: \(peerID.displayName, privacy: .public)")
            return
        }
        switch state {
        case .connected:
            lock.withLock { pcToMC[pcPeerID] = peerID; mcToPC[peerID] = pcPeerID }
            peersContinuation.yield(currentPeerSet())
            logger.info("MC peer connected: \(pcPeerID.description, privacy: .public)")
        case .notConnected:
            lock.withLock { pcToMC.removeValue(forKey: pcPeerID); mcToPC.removeValue(forKey: peerID) }
            peersContinuation.yield(currentPeerSet())
            logger.info("MC peer disconnected: \(pcPeerID.description, privacy: .public)")
        case .connecting: break
        @unknown default: break
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let pcPeerID = lock.withLock { mcToPC[peerID] }
        guard let pcPeerID else { return }
        incomingMessagesContinuation.yield((pcPeerID, data))
    }

    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension MultipeerTransport: MCNearbyServiceBrowserDelegate {

    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        guard let remotePeerID = MultipeerIdentity.decode(peerID.displayName) else {
            logger.warning("Ignoring found peer with non-UUID displayName: \(peerID.displayName, privacy: .public)")
            return
        }
        guard MultipeerIdentity.shouldInitiateInvitation(local: localPeerID, remote: remotePeerID) else { return }
        let (shouldInvite, session) = lock.withLock { () -> (Bool, MCSession?) in
            guard let session = self.session else { return (false, nil) }
            if session.connectedPeers.count >= self.configuration.mcMaxPeers - 1 { return (false, session) }
            if let existing = self.pcToMC[remotePeerID], session.connectedPeers.contains(existing) { return (false, session) }
            return (true, session)
        }
        guard shouldInvite, let session else { return }
        browser.invitePeer(peerID, to: session, withContext: MultipeerIdentity.invitationContextMarker, timeout: 10)
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        logger.error("Browser failed to start: \(error.localizedDescription, privacy: .public)")
    }
}

extension MultipeerTransport: MCNearbyServiceAdvertiserDelegate {

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        guard MultipeerIdentity.verifyInvitation(context: context) else {
            logger.warning("Rejecting invitation with bad context from \(peerID.displayName, privacy: .public)")
            invitationHandler(false, nil); return
        }
        guard let remotePeerID = MultipeerIdentity.decode(peerID.displayName) else {
            logger.warning("Rejecting invitation with non-UUID displayName: \(peerID.displayName, privacy: .public)")
            invitationHandler(false, nil); return
        }
        let (session, accept) = lock.withLock { () -> (MCSession?, Bool) in
            guard let session = self.session else { return (nil, false) }
            if session.connectedPeers.count >= self.configuration.mcMaxPeers - 1 { return (session, false) }
            if let existing = self.pcToMC[remotePeerID], session.connectedPeers.contains(existing) { return (session, false) }
            return (session, true)
        }
        guard accept, let session else { invitationHandler(false, nil); return }
        invitationHandler(true, session)
    }

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        logger.error("Advertiser failed to start: \(error.localizedDescription, privacy: .public)")
    }
}
