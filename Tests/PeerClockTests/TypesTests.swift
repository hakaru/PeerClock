import Foundation
import Testing
@testable import PeerClock

@Suite("Types")
struct TypesTests {

    // MARK: - PeerID

    @Test("PeerID is comparable by UUID")
    func peerIDComparable() {
        let a = PeerID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let b = PeerID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        #expect(a < b)
        #expect(!(b < a))
    }

    @Test("PeerID is hashable")
    func peerIDHashable() {
        let id = PeerID(UUID())
        var set = Set<PeerID>()
        set.insert(id)
        set.insert(id)
        #expect(set.count == 1)
    }

    // MARK: - Command

    @Test("Command stores type and payload")
    func commandStoresTypeAndPayload() {
        let payload = Data([0x01, 0x02, 0x03])
        let cmd = Command(type: "ping", payload: payload)
        #expect(cmd.type == "ping")
        #expect(cmd.payload == payload)
    }

    @Test("Command has empty payload by default")
    func commandDefaultPayload() {
        let cmd = Command(type: "ping")
        #expect(cmd.payload.isEmpty)
    }

    // MARK: - Configuration

    @Test("Configuration has sensible defaults")
    func configurationDefaults() {
        let config = Configuration.default
        #expect(config.heartbeatInterval == 1.0)
        #expect(config.disconnectThreshold == 3)
        #expect(config.syncInterval == 5.0)
        #expect(config.syncMeasurements == 40)
        #expect(config.syncMeasurementInterval == 0.03)
        #expect(config.serviceName == "_peerclock._tcp")
    }

    // MARK: - SyncState

    @Test("SyncState has idle case")
    func syncStateIdle() {
        let state = SyncState.idle
        if case .idle = state {
            #expect(true)
        } else {
            #expect(Bool(false))
        }
    }

    // MARK: - ConnectionState

    @Test("ConnectionState has 3 cases")
    func connectionStateHas3Cases() {
        let connected = ConnectionState.connected
        let degraded = ConnectionState.degraded
        let disconnected = ConnectionState.disconnected
        #expect(connected != degraded)
        #expect(degraded != disconnected)
        #expect(connected != disconnected)
    }

    // MARK: - DeviceInfo

    @Test("DeviceInfo stores platform")
    func deviceInfoStoresPlatform() {
        let info = DeviceInfo(name: "iPhone", platform: .iOS, batteryLevel: 0.8, storageAvailable: 1024)
        #expect(info.platform == .iOS)
        #expect(info.name == "iPhone")
    }
}
