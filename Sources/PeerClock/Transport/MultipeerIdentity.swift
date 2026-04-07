import Foundation

enum MultipeerIdentity {
    static let invitationContextMarker = Data("peerclock-v1".utf8)

    static func encode(_ peerID: PeerID) -> String {
        peerID.rawValue.uuidString
    }

    static func decode(_ displayName: String) -> PeerID? {
        guard let uuid = UUID(uuidString: displayName) else { return nil }
        return PeerID(rawValue: uuid)
    }

    static func shouldInitiateInvitation(local: PeerID, remote: PeerID) -> Bool {
        local < remote
    }

    static func verifyInvitation(context: Data?) -> Bool {
        context == invitationContextMarker
    }
}
