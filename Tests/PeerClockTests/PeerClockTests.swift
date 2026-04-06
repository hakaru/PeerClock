import Testing
@testable import PeerClock

@Suite("PeerClock Tests")
struct PeerClockTests {

    @Test("PeerClock version is defined")
    func version() {
        #expect(!PeerClock.version.isEmpty)
    }

    @Test("PeerClock can be initialized as master")
    func initMaster() {
        let clock = PeerClock(role: .master)
        #expect(clock != nil)
    }

    @Test("PeerClock can be initialized as slave")
    func initSlave() {
        let clock = PeerClock(role: .slave)
        #expect(clock != nil)
    }
}
