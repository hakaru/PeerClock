import Testing
import Foundation
@testable import PeerClock

@Suite("TermStore")
struct TermStoreTests {
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "TermStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func initialIsZero() {
        let store = TermStore(defaults: makeIsolatedDefaults())
        #expect(store.current == 0)
    }

    @Test func updateAdvances() {
        let store = TermStore(defaults: makeIsolatedDefaults())
        let new = store.update(observed: 42)
        #expect(new == 42)
        #expect(store.current == 42)
    }

    @Test func updateIgnoresLower() {
        let store = TermStore(defaults: makeIsolatedDefaults())
        store.update(observed: 100)
        let new = store.update(observed: 50)
        #expect(new == 100)
        #expect(store.current == 100)
    }

    @Test func persistsAcrossInstances() {
        let suiteName = "TermStoreTests-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store1 = TermStore(defaults: defaults)
        store1.update(observed: 7)

        let store2 = TermStore(defaults: defaults)
        #expect(store2.current == 7)
    }
}
