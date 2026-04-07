import Foundation
import MultipeerConnectivity

enum MultipeerPeerIDStore {
    static func loadOrCreate(
        displayName: String,
        userDefaults: UserDefaults = .standard
    ) -> MCPeerID {
        let key = storageKey(for: displayName)

        if let archivedPeerID = userDefaults.data(forKey: key),
           let peerID = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: archivedPeerID),
           peerID.displayName == displayName {
            return peerID
        }

        let peerID = MCPeerID(displayName: displayName)
        if let archivedPeerID = try? NSKeyedArchiver.archivedData(withRootObject: peerID, requiringSecureCoding: true) {
            userDefaults.set(archivedPeerID, forKey: key)
        }
        return peerID
    }

    static func reset(
        displayName: String,
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.removeObject(forKey: storageKey(for: displayName))
    }

    private static func storageKey(for displayName: String) -> String {
        "PeerClock.MCPeerID.\(displayName)"
    }
}
