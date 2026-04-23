import Foundation

/// Owns the star-topology component stack behind the ``PeerClock`` facade.
///
/// Phase 2 scope: assembles `StarTransport` + `BonjourBrowser` +
/// `BonjourAdvertiser` + `TermStore` + `HostElection`.
///
/// `peerStream` and `commandStream` are placeholders (never yield) pending a
/// fan-out refactor — `browser.peers` is a single-consumer `AsyncStream` and
/// is already consumed by `HostElection` internally (see `HostElection.start()`).
/// Full wiring into `PeerClock`'s app-level streams lands in later tasks of the
/// v0.4.0 dual-topology plan.
internal final class StarRuntime: TopologyRuntime, @unchecked Sendable {
    /// Bonjour service type used for star-topology peers.
    ///
    /// Intentionally distinct from mesh's service type so mesh and star nodes
    /// never interconnect. Kept private to this file — no public API added
    /// by Task 2.4 (see v0.4.0 dual-topology plan).
    ///
    /// Note: `HostElection.start()` calls `browser.start()` with its default
    /// service type argument (`PeerClockService.type`). When the `.auto` role
    /// path runs election, that default takes precedence over the value below.
    /// Unifying service types is tracked by the fan-out refactor follow-up.
    private static let serviceType = "_peerclockstar._tcp"

    let transport: any Transport
    let peerStream: AsyncStream<[Peer]>
    let commandStream: AsyncStream<(PeerID, Command)>

    private let localPeerID: PeerID
    private let role: StarRole
    private let configuration: Configuration
    private let browser: BonjourBrowser
    private let advertiser: BonjourAdvertiser
    private let termStore: TermStore
    private var election: HostElection?

    private let peerContinuation: AsyncStream<[Peer]>.Continuation
    private let commandContinuation: AsyncStream<(PeerID, Command)>.Continuation

    init(localPeerID: PeerID, role: StarRole, configuration: Configuration) {
        self.localPeerID = localPeerID
        self.role = role
        self.configuration = configuration

        let star = StarTransport(localPeerID: localPeerID)
        self.transport = star
        self.browser = BonjourBrowser()

        // Initial TXT reflects role. Score/term are populated by `HostElection`
        // once it transitions into candidacy / host. `.clientOnly` never
        // volunteers, so it publishes as `client-only` from the start.
        let initialRole = (role == .clientOnly) ? "client-only" : "candidate"
        let initialTXT = BonjourAdvertiser.TXTRecord(
            role: initialRole,
            peerID: localPeerID.rawValue.uuidString,
            term: 0,
            scoreBase64: ""
        )
        self.advertiser = BonjourAdvertiser(serviceType: Self.serviceType, initialTXT: initialTXT)
        self.termStore = TermStore()

        var pc: AsyncStream<[Peer]>.Continuation!
        self.peerStream = AsyncStream { pc = $0 }
        self.peerContinuation = pc

        var cc: AsyncStream<(PeerID, Command)>.Continuation!
        self.commandStream = AsyncStream { cc = $0 }
        self.commandContinuation = cc
    }

    func start() async throws {
        // `HostElection` only runs when the node is allowed to volunteer as host.
        // `.clientOnly` never runs it (see docs/spec/client-only-role.md —
        // Task 2.6 will harden this and add clientOnly-specific coverage).
        //
        // When election runs, it also owns `browser.start()` / `browser.stop()`
        // and `advertiser.start(listener:)` during promotion. So in `.auto`
        // mode we deliberately do NOT start the browser here.
        //
        // For `.clientOnly` we start the browser ourselves so discovery of the
        // host is still possible. Client-only wiring into an actual connection
        // is handled by later tasks.
        if role == .auto {
            guard let star = transport as? StarTransport else {
                preconditionFailure("StarRuntime requires StarTransport")
            }
            let election = HostElection(
                localPeerID: localPeerID.rawValue,
                transport: star,
                browser: browser,
                advertiser: advertiser,
                termStore: termStore
            )
            self.election = election
            await election.start()
        } else {
            // clientOnly: browser only, no election, no advertising as candidate.
            browser.start(serviceType: Self.serviceType)
        }

        // `StarTransport.start()` is effectively a no-op today (role transitions
        // drive its lifecycle); still call it for symmetry with the Transport
        // protocol contract.
        try await transport.start()
    }

    func stop() async {
        // `HostElection.stop()` cancels its observer tasks and internally stops
        // `transport` / `advertiser` / `browser`. Prefer that path when present
        // to avoid double-stop. For `.clientOnly` where no election exists, we
        // stop the pieces we started directly.
        if let election {
            await election.stop()
        } else {
            await transport.stop()
            advertiser.stop()
            browser.stop()
        }
        election = nil
        peerContinuation.finish()
        commandContinuation.finish()
    }

    /// Placeholder — always `0` in Phase 2. See type-level doc comment.
    var currentPeerCount: Int {
        get async { 0 }
    }

    #if DEBUG
    /// Test-only accessor to observe whether `HostElection` was wired.
    /// Used by Task 2.6 to assert `.clientOnly` skips election.
    internal var testHook_election: HostElection? { election }
    #endif
}
