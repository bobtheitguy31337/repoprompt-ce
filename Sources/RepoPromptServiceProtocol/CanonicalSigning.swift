import Crypto
import Foundation

public enum CanonicalSigning {
    public static func bodyDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func requestString(method: String, pathAndQuery: String, timestamp: String, nonce: String, bodyDigest: String, authorizationDecisionDigest: String, keyID: String) -> String {
        [method.uppercased(), pathAndQuery, timestamp, nonce, bodyDigest, authorizationDecisionDigest, keyID].joined(separator: "\n")
    }

    public static func hmacSHA256(message: String, key: Data) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))
        return Data(code).base64EncodedString()
    }

    public static func secureEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
