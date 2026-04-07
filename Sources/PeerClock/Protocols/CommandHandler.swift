import Foundation

public protocol CommandHandler: Sendable {
    func send(_ command: Command, to peer: PeerID) async throws
    func broadcast(_ command: Command) async throws
    var incomingCommands: AsyncStream<(PeerID, Command)> { get }
}
