import Foundation

public protocol Transport: Sendable {
    func start() async throws
    func stop() async
    var peers: AsyncStream<Set<PeerID>> { get }
    var incomingMessages: AsyncStream<(PeerID, Data)> { get }
    func send(_ data: Data, to peer: PeerID) async throws
    func broadcast(_ data: Data) async throws
}
