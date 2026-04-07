import Foundation

public enum Message: Sendable, Equatable {
    case hello(peerID: PeerID, protocolVersion: UInt16)
    case ping(peerID: PeerID, t0: UInt64)
    case pong(peerID: PeerID, t0: UInt64, t1: UInt64, t2: UInt64)
    case commandBroadcast(Command)
    case commandUnicast(Command)
    case heartbeat
    case disconnect

    internal var typeByte: UInt8 {
        switch self {
        case .hello: return 0x01
        case .ping: return 0x02
        case .pong: return 0x03
        case .commandBroadcast: return 0x10
        case .commandUnicast: return 0x11
        case .heartbeat: return 0x20
        case .disconnect: return 0xFF
        }
    }
}
