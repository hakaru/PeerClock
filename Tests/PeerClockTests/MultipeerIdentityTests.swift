import Foundation
import Testing
@testable import PeerClock

@Suite("MultipeerIdentity")
struct MultipeerIdentityTests {
    @Test("encode and decode round-trip")
    func roundTrip() {
        let peerID = PeerID(rawValue: UUID())
        let encoded = MultipeerIdentity.encode(peerID)
        let decoded = MultipeerIdentity.decode(encoded)
        #expect(decoded == peerID)
    }

    @Test("decode returns nil for non-UUID strings")
    func decodeRejectsGarbage() {
        #expect(MultipeerIdentity.decode("hello") == nil)
        #expect(MultipeerIdentity.decode("") == nil)
        #expect(MultipeerIdentity.decode("not-a-uuid-string-1234") == nil)
    }

    @Test("shouldInitiateInvitation uses < ordering")
    func invitationDirection() {
        let a = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let b = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        #expect(MultipeerIdentity.shouldInitiateInvitation(local: a, remote: b) == true)
        #expect(MultipeerIdentity.shouldInitiateInvitation(local: b, remote: a) == false)
    }

    @Test("verifyInvitation accepts correct marker")
    func verifyAcceptsMarker() {
        let correct = Data("peerclock-v1".utf8)
        #expect(MultipeerIdentity.verifyInvitation(context: correct) == true)
    }

    @Test("verifyInvitation rejects nil and wrong markers")
    func verifyRejectsBadContext() {
        #expect(MultipeerIdentity.verifyInvitation(context: nil) == false)
        #expect(MultipeerIdentity.verifyInvitation(context: Data()) == false)
        #expect(MultipeerIdentity.verifyInvitation(context: Data("other".utf8)) == false)
    }

    @Test("invitationContextMarker is stable")
    func markerStable() {
        #expect(MultipeerIdentity.invitationContextMarker == Data("peerclock-v1".utf8))
    }
}
