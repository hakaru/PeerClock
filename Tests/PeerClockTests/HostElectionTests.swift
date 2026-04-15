import Testing
import Foundation
import Network
@testable import PeerClock

@Suite("HostElection")
struct HostElectionTests {

    private func makeStore() -> TermStore {
        let suite = "HostElectionTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return TermStore(defaults: d)
    }

    private func makeElection(peerID: UUID = UUID(), timing: HostElection.Timing = .init()) -> HostElection {
        let transport = StarTransport(localPeerID: PeerID(peerID))
        let browser = BonjourBrowser()
        let advertiser = BonjourAdvertiser(initialTXT: BonjourAdvertiser.TXTRecord(
            role: "client",
            peerID: peerID.uuidString,
            term: 0,
            scoreBase64: ""
        ))
        return HostElection(
            localPeerID: peerID,
            transport: transport,
            browser: browser,
            advertiser: advertiser,
            termStore: makeStore(),
            timing: timing
        )
    }

    @Test func initialStateIsIdle() async {
        let election = makeElection()
        let state = await election.state
        #expect(state == .idle)
    }

    @Test func sessionGenerationIncrements() async {
        let election = makeElection()
        // Verify monotonic increment without going through promotion
        let g1 = await election.nextSessionGeneration()
        let g2 = await election.nextSessionGeneration()
        let g3 = await election.nextSessionGeneration()
        #expect(g1 == 1)
        #expect(g2 == 2)
        #expect(g3 == 3)
    }

    @Test func setManualPinDoesNotCrash() async {
        let election = makeElection()
        await election.setManualPin(true)
        await election.setManualPin(false)
        // No crash and state remains idle
        let state = await election.state
        #expect(state == .idle)
    }

    @Test func stateStreamYieldsTransitions() async {
        let election = makeElection()

        // Collect states via actor-isolated task — avoids data-race on local var
        let collectTask = Task<[ElectionState], Never> {
            var collected: [ElectionState] = []
            for await s in await election.stateStream {
                collected.append(s)
                // Break after first element to avoid blocking
                if collected.count >= 1 { break }
            }
            return collected
        }

        // stop() calls transitionTo(.idle) and finishes the stream
        await election.stop()
        let received = await collectTask.value

        // The stop() transition yields .idle
        #expect(received.contains(.idle))
    }

    @Test func stopFromIdleIsIdempotent() async {
        let election = makeElection()
        await election.stop()
        // Second stop should not crash
        let election2 = makeElection()
        await election2.stop()
        await election2.stop()
    }

    @Test func validateIncomingCommandTermAcceptsAtIdleState() async {
        // In idle state (term=0), any observed term >= 0 should be accepted
        let election = makeElection()
        let accepted = await election.validateIncomingCommandTerm(0)
        #expect(accepted)
    }

    @Test func validateIncomingCommandTermRejectsStale() async {
        // Seed a high term into the store so term 0 looks stale
        let store = makeStore()
        store.update(observed: 10)

        let peerID = UUID()
        let transport = StarTransport(localPeerID: PeerID(peerID))
        let browser = BonjourBrowser()
        let advertiser = BonjourAdvertiser(initialTXT: BonjourAdvertiser.TXTRecord(
            role: "client",
            peerID: peerID.uuidString,
            term: 0,
            scoreBase64: ""
        ))
        let election = HostElection(
            localPeerID: peerID,
            transport: transport,
            browser: browser,
            advertiser: advertiser,
            termStore: store
        )

        // term=0 is stale vs maxSeen=10
        let accepted = await election.validateIncomingCommandTerm(0)
        #expect(!accepted)
    }

    @Test func validateIncomingCommandTermAcceptsCurrentTerm() async {
        let store = makeStore()
        store.update(observed: 5)

        let peerID = UUID()
        let transport = StarTransport(localPeerID: PeerID(peerID))
        let browser = BonjourBrowser()
        let advertiser = BonjourAdvertiser(initialTXT: BonjourAdvertiser.TXTRecord(
            role: "client",
            peerID: peerID.uuidString,
            term: 5,
            scoreBase64: ""
        ))
        let election = HostElection(
            localPeerID: peerID,
            transport: transport,
            browser: browser,
            advertiser: advertiser,
            termStore: store
        )

        let accepted = await election.validateIncomingCommandTerm(5)
        #expect(accepted)
    }

    @Test func electionStateEquality() {
        let idle1 = ElectionState.idle
        let idle2 = ElectionState.idle
        #expect(idle1 == idle2)

        let host1 = ElectionState.host(term: 1, sessionGeneration: 0)
        let host2 = ElectionState.host(term: 1, sessionGeneration: 0)
        let host3 = ElectionState.host(term: 2, sessionGeneration: 0)
        #expect(host1 == host2)
        #expect(host1 != host3)

        let uuid = UUID()
        let joining1 = ElectionState.joining(hostPeerID: uuid, term: 5)
        let joining2 = ElectionState.joining(hostPeerID: uuid, term: 5)
        let joining3 = ElectionState.joining(hostPeerID: UUID(), term: 5)
        #expect(joining1 == joining2)
        #expect(joining1 != joining3)
    }
}
