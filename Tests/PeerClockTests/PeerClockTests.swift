import Testing
@testable import PeerClock

@Suite("PeerClock Facade")
struct PeerClockTests {
    @Test("PeerClock version is defined")
    func version() { #expect(!PeerClock.version.isEmpty) }

    @Test("PeerClock can be initialized with default configuration")
    func initDefault() { let clock = PeerClock(); #expect(clock != nil) }

    @Test("PeerClock can be initialized with custom configuration")
    func initCustom() {
        let config = Configuration(heartbeatInterval: 2.0, disconnectThreshold: 5)
        let clock = PeerClock(configuration: config); #expect(clock != nil)
    }
}
