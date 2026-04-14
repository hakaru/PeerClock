import Testing
@testable import PeerClock

@Suite("WebSocketHandshake")
struct WebSocketHandshakeTests {
    @Test func rfc6455ExampleComputesAccept() {
        // RFC 6455 §1.3 example: key "dGhlIHNhbXBsZSBub25jZQ=="
        // → accept "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        let accept = WebSocketHandshake.computeAccept(clientKey: "dGhlIHNhbXBsZSBub25jZQ==")
        #expect(accept == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    @Test func extractsKeyFromRequest() {
        let request = "GET / HTTP/1.1\r\nHost: x\r\nSec-WebSocket-Key: abc123==\r\n\r\n"
        #expect(WebSocketHandshake.extractKey(from: request) == "abc123==")
    }

    @Test func extractsAcceptFromResponse() {
        let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: xyz==\r\n\r\n"
        #expect(WebSocketHandshake.extractAccept(from: response) == "xyz==")
    }

    @Test func extractKeyHandlesMissingHeader() {
        let request = "GET / HTTP/1.1\r\nHost: x\r\n\r\n"
        #expect(WebSocketHandshake.extractKey(from: request) == nil)
    }
}
