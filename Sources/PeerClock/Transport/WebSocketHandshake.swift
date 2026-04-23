import Foundation
import CommonCrypto

/// RFC 6455 §4.1 handshake helpers.
public enum WebSocketHandshake {
    /// Magic GUID from RFC 6455 §1.3
    private static let magicGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    /// Compute Sec-WebSocket-Accept from client's Sec-WebSocket-Key.
    public static func computeAccept(clientKey: String) -> String {
        let combined = clientKey + magicGUID
        let data = Data(combined.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &hash) }
        return Data(hash).base64EncodedString()
    }

    /// Parse "Sec-WebSocket-Key: <value>" header from raw request.
    public static func extractKey(from request: String) -> String? {
        for line in request.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased().trimmingCharacters(in: .whitespaces) == "sec-websocket-key" {
                return String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Parse "Sec-WebSocket-Accept: <value>" header from raw response.
    public static func extractAccept(from response: String) -> String? {
        for line in response.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased().trimmingCharacters(in: .whitespaces) == "sec-websocket-accept" {
                return String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
