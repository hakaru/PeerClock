import Testing
import Foundation
@testable import PeerClock

@Suite("HostFencing")
struct HostFencingTests {
    private func makeStore() -> TermStore {
        let suite = "HostFencingTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return TermStore(defaults: d)
    }

    @Test func acceptsEqualTerm() {
        let store = makeStore()
        store.update(observed: 5)
        let fencing = HostFencing(termStore: store)
        #expect(fencing.validate(observedTerm: 5, localIsHost: false) == .accept)
    }

    @Test func rejectsLowerTerm() {
        let store = makeStore()
        store.update(observed: 5)
        let fencing = HostFencing(termStore: store)
        #expect(fencing.validate(observedTerm: 3, localIsHost: false) == .rejectStale)
    }

    @Test func acceptsHigherTermAndUpdatesStore() {
        let store = makeStore()
        store.update(observed: 5)
        let fencing = HostFencing(termStore: store)
        #expect(fencing.validate(observedTerm: 10, localIsHost: false) == .accept)
        #expect(store.current == 10)
    }

    @Test func forceDemoteWhenHostObservesHigherTerm() {
        let store = makeStore()
        let fencing = HostFencing(termStore: store)
        // We're host at term 5, observe term 10 from another host
        let decision = fencing.validate(observedTerm: 10, localIsHost: true, localTerm: 5)
        #expect(decision == .forceDemote)
    }

    @Test func hostStaysAtSameTerm() {
        let store = makeStore()
        let fencing = HostFencing(termStore: store)
        // We're host at term 5, observe term 5 (e.g. our own broadcast looped back)
        let decision = fencing.validate(observedTerm: 5, localIsHost: true, localTerm: 5)
        #expect(decision == .accept)
    }
}
