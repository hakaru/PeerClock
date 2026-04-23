import Testing
import Foundation
import Network
@testable import PeerClock

@Suite("HostElection integration")
struct HostElectionIntegrationTests {
    private func makeStore() -> TermStore {
        let suite = "ElectionIntegration-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return TermStore(defaults: d)
    }

    private func makeElection(peerID: UUID) -> (HostElection, BonjourBrowser, StarTransport) {
        let transport = StarTransport(localPeerID: PeerID(peerID))
        let browser = BonjourBrowser()
        let advertiser = BonjourAdvertiser(initialTXT: .init(
            role: "client", peerID: peerID.uuidString, term: 0, scoreBase64: ""
        ))
        var timing = HostElection.Timing()
        timing.discoverPeriod = .milliseconds(200)
        timing.candidacyJitterRange = 0.05...0.1
        timing.settlePeriod = .milliseconds(50)
        let election = HostElection(
            localPeerID: peerID,
            transport: transport,
            browser: browser,
            advertiser: advertiser,
            termStore: makeStore(),
            timing: timing
        )
        return (election, browser, transport)
    }

    /// Test 11: With no peers visible, single node becomes host.
    @Test func soloNodeBecomesHost() async throws {
        let peerID = UUID()
        let (election, _, _) = makeElection(peerID: peerID)

        // Collect states before start to avoid missing transitions
        let collectTask = Task<Bool, Never> {
            var sawHost = false
            for await state in await election.stateStream {
                if case .host = state { sawHost = true; break }
            }
            return sawHost
        }

        await election.start()
        // Allow discovery + candidacy timeout
        try await Task.sleep(for: .milliseconds(800))
        collectTask.cancel()

        let sawHost = await collectTask.value
        let finalState = await election.state
        if case .host(let term, _) = finalState {
            #expect(term >= 1)
            #expect(sawHost)
        } else {
            Issue.record("Expected host state, got \(finalState)")
        }

        await election.stop()
    }

    /// Test 11 variant: When a peer with role=host is visible, node becomes client.
    @Test func seesHostBecomesClient() async throws {
        let peerID = UUID()
        let (election, browser, _) = makeElection(peerID: peerID)

        // Inject a fake host peer
        let hostPeerID = UUID()
        let fakeHost = BonjourBrowser.DiscoveredPeer(
            id: "fake-host",
            serviceName: "fake-host",
            endpoint: NWEndpoint.hostPort(host: .ipv4(.loopback), port: 12345),
            txt: [
                "role": "host",
                "peer_id": hostPeerID.uuidString,
                "term": "5",
                "score": "",
                "version": "3"
            ]
        )

        await election.start()
        // Inject after start so observer is wired
        browser.injectForTest([fakeHost])

        // Allow election to react
        try await Task.sleep(for: .milliseconds(500))

        let finalState = await election.state
        if case .joining(let observedHostPeerID, let term) = finalState {
            #expect(observedHostPeerID == hostPeerID)
            #expect(term == 5)
        } else {
            Issue.record("Expected joining state, got \(finalState)")
        }

        await election.stop()
    }

    /// Test 12: Split-brain recovery — host observing higher term demotes.
    @Test func hostDemotesOnHigherTerm() async throws {
        let peerID = UUID()
        let (election, browser, _) = makeElection(peerID: peerID)

        await election.start()
        // Wait to become solo host
        try await Task.sleep(for: .milliseconds(800))

        guard case .host(let myTerm, _) = await election.state else {
            Issue.record("Failed to become host first")
            await election.stop()
            return
        }

        // Inject a higher-term host (simulating partition reconnect)
        let competingHostID = UUID()
        let higherTerm = myTerm + 10
        let fakeHost = BonjourBrowser.DiscoveredPeer(
            id: "competing",
            serviceName: "competing",
            endpoint: NWEndpoint.hostPort(host: .ipv4(.loopback), port: 12346),
            txt: [
                "role": "host",
                "peer_id": competingHostID.uuidString,
                "term": String(higherTerm),
                "score": "",
                "version": "3"
            ]
        )
        browser.injectForTest([fakeHost])

        // Allow demote + re-election to proceed
        try await Task.sleep(for: .milliseconds(800))

        let finalState = await election.state
        // Should have demoted from host. Could be in discovering, joining, or another state
        // depending on timing — main assertion: NOT .host with our original term.
        if case .host(let t, _) = finalState, t == myTerm {
            Issue.record("Should have demoted from original host term")
        }

        await election.stop()
    }
}
