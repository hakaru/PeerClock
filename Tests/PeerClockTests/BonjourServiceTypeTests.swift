import Testing
import Foundation
@testable import PeerClock

/// Locks the mesh Bonjour service type to its v0.2.x constant.
///
/// Changing `Configuration.default.serviceType` breaks Bonjour discovery
/// between v0.2.x peers and v0.4.0 mesh peers (PeerClockMetronome v1.0
/// compatibility). See `docs/spec/v1-wire-compat.md`.
@Suite("Bonjour service type")
struct BonjourServiceTypeTests {

    @Test("mesh default serviceType is _peerclock._udp (v0.2.x compat)")
    func meshServiceTypeLock() {
        #expect(Configuration.default.serviceType == "_peerclock._udp")
    }

    @Test("star Bonjour service type is _peerclockstar._tcp (distinct from mesh)")
    func starServiceTypeDistinct() {
        #expect(StarRuntime.serviceType == "_peerclockstar._tcp")
        #expect(StarRuntime.serviceType != Configuration.default.serviceType)
    }
}
