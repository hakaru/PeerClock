import Foundation

/// Protocol for the command routing layer.
public protocol CommandHandler: Sendable {
    /// Sends a command to a specific peer.
    func send(_ command: Command, to peer: PeerID) async throws
    /// Broadcasts a command to all connected peers.
    func broadcast(_ command: Command) async throws
    /// Stream of incoming commands from remote peers.
    var incomingCommands: AsyncStream<(PeerID, Command)> { get }
}
