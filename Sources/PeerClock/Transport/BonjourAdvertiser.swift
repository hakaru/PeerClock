import Foundation
import Network
import os

private let logger = Logger(subsystem: "net.hakaru.PeerClock", category: "BonjourAdvertiser")

/// Publishes a Bonjour service announcing the local host's presence.
public final class BonjourAdvertiser: @unchecked Sendable {

    public struct TXTRecord: Sendable, Equatable {
        public var role: String         // "host" | "candidate" | "client"
        public var peerID: String       // UUID string
        public var term: UInt64
        public var scoreBase64: String  // base64-encoded HostScore JSON
        public var version: Int         // protocol version, currently 3

        public init(role: String, peerID: String, term: UInt64, scoreBase64: String, version: Int = 3) {
            self.role = role
            self.peerID = peerID
            self.term = term
            self.scoreBase64 = scoreBase64
            self.version = version
        }

        func asNWTXTRecord() -> NWTXTRecord {
            var record = NWTXTRecord()
            record["role"] = role
            record["peer_id"] = peerID
            record["term"] = String(term)
            record["score"] = scoreBase64
            record["version"] = String(version)
            return record
        }
    }

    private let serviceType: String
    private var listener: NWListener?
    private var currentTXT: TXTRecord

    public init(serviceType: String = PeerClockService.type, initialTXT: TXTRecord) {
        self.serviceType = serviceType
        self.currentTXT = initialTXT
    }

    /// Start advertising. Must be paired with an NWListener (host mode).
    public func start(listener: NWListener) {
        self.listener = listener
        let txt = currentTXT.asNWTXTRecord()
        listener.service = NWListener.Service(type: serviceType, txtRecord: txt)
        logger.info("[Advertiser] started with TXT: role=\(self.currentTXT.role, privacy: .public), term=\(self.currentTXT.term)")
    }

    public func stop() {
        listener?.service = nil
        listener = nil
        logger.info("[Advertiser] stopped")
    }

    /// Update TXT record (e.g. when term changes or incumbent bit flips).
    public func updateTXT(_ newTXT: TXTRecord) {
        currentTXT = newTXT
        if let listener {
            let txt = newTXT.asNWTXTRecord()
            listener.service = NWListener.Service(type: serviceType, txtRecord: txt)
            logger.info("[Advertiser] TXT updated: role=\(newTXT.role, privacy: .public), term=\(newTXT.term)")
        }
    }
}
