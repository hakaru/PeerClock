import Foundation
import Network
import os
import os.signpost

private let logger = Logger(subsystem: "net.hakaru.PeerClock", category: "HostElection")
private let signposter = OSSignposter(subsystem: "net.hakaru.PeerClock", category: "ElectionTiming")

/// Election state per spec §4.2.
public enum ElectionState: Sendable, Equatable {
    case idle
    case discovering
    case candidacy
    case host(term: UInt64, sessionGeneration: UInt64)
    case joining(hostPeerID: UUID, term: UInt64)
    case joinFailed
    case hostLost
    case demoted
}

/// Drives host election based on Bonjour discovery + term/score-based selection.
/// Owns lifecycle of StarTransport role transitions.
public actor HostElection {
    public private(set) var state: ElectionState = .idle

    private let localPeerID: UUID
    private let transport: StarTransport
    private let browser: BonjourBrowser
    private let advertiser: BonjourAdvertiser
    private let termStore: TermStore
    private let fencing: HostFencing

    /// Configurable timing
    public struct Timing: Sendable {
        public var discoverPeriod: Duration = .seconds(2)
        public var candidacyJitterRange: ClosedRange<Double> = 0.5...1.0  // seconds
        public var settlePeriod: Duration = .milliseconds(500)
        public var joinRetryBackoff: Duration = .seconds(5)
        public var maxJoinRetries: Int = 3

        public init() {}
    }

    private let timing: Timing

    /// Stream of state transitions for observation.
    public let stateStream: AsyncStream<ElectionState>
    private let stateContinuation: AsyncStream<ElectionState>.Continuation

    private var observerTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var candidacyTask: Task<Void, Never>?
    private var manualPin: Bool = false

    private var lastPeers: [BonjourBrowser.DiscoveredPeer] = []
    private var joinRetryCount: Int = 0
    private var currentSessionGeneration: UInt64 = 0

    public init(
        localPeerID: UUID,
        transport: StarTransport,
        browser: BonjourBrowser,
        advertiser: BonjourAdvertiser,
        termStore: TermStore,
        timing: Timing = Timing()
    ) {
        self.localPeerID = localPeerID
        self.transport = transport
        self.browser = browser
        self.advertiser = advertiser
        self.termStore = termStore
        self.fencing = HostFencing(termStore: termStore)
        self.timing = timing

        var cont: AsyncStream<ElectionState>.Continuation!
        self.stateStream = AsyncStream { cont = $0 }
        self.stateContinuation = cont
    }

    public func setManualPin(_ pinned: Bool) {
        self.manualPin = pinned
    }

    /// Begin election. Idempotent — no-op if already running.
    public func start() async {
        guard case .idle = state else { return }

        let signpostID = signposter.makeSignpostID()
        let interval = signposter.beginInterval("Election", id: signpostID)
        defer { signposter.endInterval("Election", interval) }

        await transitionTo(.discovering)

        // Start Bonjour browsing (critical: without this, peer discovery never runs)
        browser.start()

        // Subscribe to BonjourBrowser
        observerTask = Task { [weak self] in
            guard let self else { return }
            for await peers in await self.browser.peers {
                await self.handlePeerSetChange(peers)
            }
        }

        // Initial discovery period
        try? await Task.sleep(for: timing.discoverPeriod)
        await evaluatePeerSet()
    }

    /// Stop election and cleanup. Cancels all tasks and transitions to idle.
    public func stop() async {
        observerTask?.cancel()
        observerTask = nil
        settleTask?.cancel()
        settleTask = nil
        candidacyTask?.cancel()
        candidacyTask = nil

        await transport.stop()
        advertiser.stop()
        browser.stop()

        await transitionTo(.idle)
        stateContinuation.finish()
    }

    // MARK: - State machine

    private func transitionTo(_ new: ElectionState) async {
        let old = state
        state = new
        logger.info("[Election] \(String(describing: old), privacy: .public) → \(String(describing: new), privacy: .public)")
        stateContinuation.yield(new)
    }

    private func handlePeerSetChange(_ peers: [BonjourBrowser.DiscoveredPeer]) async {
        lastPeers = peers
        // Settle period: wait after last change before re-evaluating (debounce thrashing)
        settleTask?.cancel()
        let settlePeriod = timing.settlePeriod
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: settlePeriod)
            guard !Task.isCancelled else { return }
            await self?.evaluatePeerSet()
        }
    }

    private func evaluatePeerSet() async {
        // Find any peers advertising as host
        let hosts = lastPeers.compactMap { peer -> (peerID: UUID, term: UInt64, endpoint: NWEndpoint)? in
            guard peer.role == "host" else { return nil }
            guard let peerIDStr = peer.peerID, let peerID = UUID(uuidString: peerIDStr) else { return nil }
            guard let term = peer.term else { return nil }
            return (peerID, term, peer.endpoint)
        }

        // Filter out stale (term < maxSeenTerm)
        let maxSeenTerm = termStore.current
        let validHosts = hosts.filter { $0.term >= maxSeenTerm }

        // Pick the host with the highest term, then smallest peerID for tiebreak
        let bestHost = validHosts.max(by: { a, b in
            if a.term != b.term { return a.term < b.term }
            return a.peerID.uuidString > b.peerID.uuidString  // smaller wins
        })

        switch state {
        case .idle, .demoted:
            return
        case .discovering, .candidacy, .hostLost, .joinFailed:
            if let host = bestHost {
                await joinHost(peerID: host.peerID, term: host.term, endpoint: host.endpoint)
            } else {
                await beginCandidacy()
            }
        case .host(let myTerm, _):
            // Check for higher-term host (split-brain recovery)
            if let host = bestHost, host.term > myTerm {
                logger.warning("[Election] observed higher-term host — demoting")
                await transitionTo(.demoted)
                await transport.stop()
                advertiser.stop()
                // Re-enter discovering after settle
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    await self?.transitionTo(.discovering)
                    await self?.evaluatePeerSet()
                }
            }
        case .joining(let currentHostPeerID, _):
            // Verify our host is still in the peer set
            let hostStillPresent = bestHost?.peerID == currentHostPeerID
            if !hostStillPresent {
                logger.warning("[Election] joined host disappeared — entering hostLost")
                await transitionTo(.hostLost)
                await evaluatePeerSet()
            }
        }
    }

    // MARK: - Candidacy (Task 6)

    private func beginCandidacy() async {
        candidacyTask?.cancel()
        await transitionTo(.candidacy)

        // Update TXT to advertise candidacy
        let score = HostScore.current(localPeerID: localPeerID, manualPin: manualPin)
        let scoreData = (try? JSONEncoder().encode(score)) ?? Data()
        let nextTerm = termStore.current + 1
        let txt = BonjourAdvertiser.TXTRecord(
            role: "candidate",
            peerID: localPeerID.uuidString,
            term: nextTerm,
            scoreBase64: scoreData.base64EncodedString()
        )
        advertiser.updateTXT(txt)

        // Jittered timeout
        let jitter = Double.random(in: timing.candidacyJitterRange)
        candidacyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(jitter))
            guard !Task.isCancelled else { return }
            await self?.completeCandidacyIfStillEligible()
        }
    }

    private func completeCandidacyIfStillEligible() async {
        guard case .candidacy = state else { return }

        // Check for higher-scoring competing candidates
        let myScore = HostScore.current(localPeerID: localPeerID, manualPin: manualPin)
        let competingCandidates = lastPeers.compactMap { peer -> HostScore? in
            guard peer.role == "candidate" else { return nil }
            guard let scoreB64 = peer.txt["score"],
                  let scoreData = Data(base64Encoded: scoreB64),
                  let score = try? JSONDecoder().decode(HostScore.self, from: scoreData)
            else { return nil }
            return score
        }

        let higherCandidate = competingCandidates.first(where: { $0 > myScore })
        if higherCandidate != nil {
            logger.info("[Election] higher candidate observed — yielding")
            await evaluatePeerSet()  // will join the winning host eventually
            return
        }

        // Check for any newly-appeared host
        let hostExists = lastPeers.contains(where: { $0.role == "host" })
        if hostExists {
            await evaluatePeerSet()
            return
        }

        // Promote
        await promoteToHost()
    }

    // MARK: - Host promotion (Task 7)

    private func promoteToHost() async {
        let newTerm = termStore.update(observed: termStore.current + 1)
        currentSessionGeneration = 0  // new term → reset generation

        let listener: NWListener
        do {
            listener = try await transport.promoteToHost()
        } catch {
            logger.error("[Election] promoteToHost failed: \(error.localizedDescription, privacy: .public)")
            await transitionTo(.idle)
            return
        }

        // Attach Bonjour advertising to the listener and update TXT (incumbent=true).
        // advertiser.start(listener:) must be called before updateTXT so the service
        // is published with the correct record from the start.
        let score = HostScore.current(localPeerID: localPeerID, incumbent: true, manualPin: manualPin)
        let scoreData = (try? JSONEncoder().encode(score)) ?? Data()
        let txt = BonjourAdvertiser.TXTRecord(
            role: "host",
            peerID: localPeerID.uuidString,
            term: newTerm,
            scoreBase64: scoreData.base64EncodedString()
        )
        advertiser.start(listener: listener)  // critical: actually begin advertising
        advertiser.updateTXT(txt)

        await transitionTo(.host(term: newTerm, sessionGeneration: 0))
        joinRetryCount = 0
    }

    /// Validate an incoming command's term against local state.
    ///
    /// Returns `true` if the command should be accepted, `false` if it is stale
    /// and must be dropped. If we are currently host but the observed term is
    /// higher than ours, triggers a force-demote (split-brain recovery) and
    /// returns `false` — the command belongs to a newer coordinator.
    ///
    /// This is the entry point that wires `HostFencing` into the command plane
    /// so that `startRecording`/`stopRecording` messages carrying a term can be
    /// fenced at message granularity (Raft-style term propagation).
    public func validateIncomingCommandTerm(_ observedTerm: UInt64) async -> Bool {
        let (localIsHost, localTerm) = currentRoleInfo()
        let decision = fencing.validate(
            observedTerm: observedTerm,
            localIsHost: localIsHost,
            localTerm: localTerm
        )
        switch decision {
        case .accept:
            return true
        case .rejectStale:
            return false
        case .forceDemote:
            logger.warning("[Election] force demote triggered by incoming command term \(observedTerm)")
            await transitionTo(.demoted)
            await transport.stop()
            advertiser.stop()
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                await self?.transitionTo(.discovering)
                await self?.evaluatePeerSet()
            }
            return false  // no longer coordinating; drop the command
        }
    }

    private func currentRoleInfo() -> (isHost: Bool, term: UInt64) {
        switch state {
        case .host(let term, _):
            return (true, term)
        default:
            return (false, 0)
        }
    }

    /// Increment sessionGeneration (e.g. for next recording session within same term).
    public func nextSessionGeneration() async -> UInt64 {
        currentSessionGeneration += 1
        if case .host(let term, _) = state {
            await transitionTo(.host(term: term, sessionGeneration: currentSessionGeneration))
        }
        return currentSessionGeneration
    }

    // MARK: - Joining (Task 8)

    private func joinHost(peerID: UUID, term: UInt64, endpoint: NWEndpoint) async {
        // Update term store
        termStore.update(observed: term)

        await transitionTo(.joining(hostPeerID: peerID, term: term))

        await transport.demoteToClient(connectingTo: endpoint, hostPeerID: PeerID(peerID))

        // Advertise as client (no longer candidate)
        let score = HostScore.current(localPeerID: localPeerID, manualPin: manualPin)
        let scoreData = (try? JSONEncoder().encode(score)) ?? Data()
        let txt = BonjourAdvertiser.TXTRecord(
            role: "client",
            peerID: localPeerID.uuidString,
            term: term,
            scoreBase64: scoreData.base64EncodedString()
        )
        advertiser.updateTXT(txt)

        joinRetryCount = 0
    }
}
