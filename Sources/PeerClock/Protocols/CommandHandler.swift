import Foundation

/// Protocol for the command routing layer.
public protocol CommandHandler: Sendable {
    /// Sends a command to a specific peer.
    ///
    /// Since v0.4.0 transport-level unicast is removed (Q5:B). Implementations
    /// broadcast the command and the `to peer:` argument is treated as a hint
    /// only — receivers do not filter by recipient at the wire layer. Use
    /// ``broadcast(_:)`` or embed a recipient in the application-level
    /// `Command.payload` and filter at receive.
    @available(*, deprecated, message: "Transport-level unicast was removed in v0.4.0 (Q5:B). Use broadcast(_:) and filter recipients in the application payload.")
    func send(_ command: Command, to peer: PeerID) async throws
    /// Broadcasts a command to all connected peers.
    func broadcast(_ command: Command) async throws
    /// Stream of incoming commands from remote peers.
    var incomingCommands: AsyncStream<(PeerID, Command)> { get }
}
