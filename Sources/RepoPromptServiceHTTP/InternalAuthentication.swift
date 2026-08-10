import Foundation
import HTTPTypes
import Hummingbird
import RepoPromptServicePersistence
import RepoPromptServiceProtocol

public enum InternalRouteRole: String, Codable, Sendable { case goblinApp = "goblin-app", goblinSync = "goblin-sync", operatorRole = "repoprompt-operator" }

public struct InternalSigningKey: Sendable {
    public let keyID: String
    public let role: InternalRouteRole
    public let direction: String
    public let secret: Data
    public let active: Bool
    public init(keyID: String, role: InternalRouteRole, direction: String, secret: Data, active: Bool = true) {
        self.keyID = keyID
        self.role = role
        self.direction = direction
        self.secret = secret
        self.active = active
    }
}

public struct SignedInternalRequest: Sendable {
    public let method: String
    public let pathAndQuery: String
    public let timestamp: String
    public let nonce: String
    public let body: Data
    public let authorizationDecisionData: Data?
    public let keyID: String
    public let signature: String
    public init(method: String, pathAndQuery: String, timestamp: String, nonce: String, body: Data, authorizationDecisionData: Data?, keyID: String, signature: String) {
        self.method = method
        self.pathAndQuery = pathAndQuery
        self.timestamp = timestamp
        self.nonce = nonce
        self.body = body
        self.authorizationDecisionData = authorizationDecisionData
        self.keyID = keyID
        self.signature = signature
    }
}

public struct AuthenticatedInternalRequest: Sendable {
    public let role: InternalRouteRole
    public let decision: GoblinAuthorizationDecision?
}

public actor InternalRequestAuthenticator {
    private let keys: [String: InternalSigningKey]
    private let store: SQLiteServiceStore
    private let now: @Sendable () -> Date

    public init(keys: [InternalSigningKey], store: SQLiteServiceStore, now: @escaping @Sendable () -> Date = Date.init) {
        self.keys = Dictionary(uniqueKeysWithValues: keys.map { ($0.keyID, $0) })
        self.store = store
        self.now = now
    }

    public func verify(_ request: SignedInternalRequest, allowedRoles: Set<InternalRouteRole>, operation: String, projectID: UUID? = nil, sessionID: UUID? = nil) async throws -> AuthenticatedInternalRequest {
        guard let key = keys[request.keyID], allowedRoles.contains(key.role) else { throw ServiceAPIError(code: .internalAuthFailed, message: "Signing identity is not allowed for this route") }
        guard request.nonce.range(of: "^[A-Za-z0-9_-]{16,128}$", options: .regularExpression) != nil else { throw ServiceAPIError(code: .internalAuthFailed, message: "Nonce format is invalid") }
        guard let timestampSeconds = Double(request.timestamp) else { throw ServiceAPIError(code: .internalAuthFailed, message: "Timestamp is invalid") }
        let observed = now(), signedAt = Date(timeIntervalSince1970: timestampSeconds)
        guard abs(observed.timeIntervalSince(signedAt)) <= 5 else { throw ServiceAPIError(code: .internalAuthFailed, message: "Timestamp is outside the allowed skew") }
        let decisionDigest = CanonicalSigning.bodyDigest(request.authorizationDecisionData ?? Data())
        let canonical = CanonicalSigning.requestString(method: request.method, pathAndQuery: request.pathAndQuery, timestamp: request.timestamp, nonce: request.nonce, bodyDigest: CanonicalSigning.bodyDigest(request.body), authorizationDecisionDigest: decisionDigest, keyID: request.keyID)
        let expected = CanonicalSigning.hmacSHA256(message: canonical, key: key.secret)
        guard CanonicalSigning.secureEquals(expected, request.signature) else { throw ServiceAPIError(code: .internalAuthFailed, message: "Request signature is invalid") }
        try await store.consumeNonce(direction: key.direction, keyID: key.keyID, nonce: request.nonce, observedAt: observed, expiresAt: observed.addingTimeInterval(60))

        if key.role == .goblinApp {
            guard let data = request.authorizationDecisionData else { throw ServiceAPIError(code: .authorizationDecisionRejected, message: "A Goblin authorization decision is required") }
            let decision = try JSONDecoder.serviceDecoder.decode(GoblinAuthorizationDecision.self, from: data)
            guard decision.schemaVersion == 1, decision.operation == operation, decision.projectID == projectID, decision.sessionID == sessionID else { throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Authorization decision target or operation does not match") }
            guard decision.requestDigest == CanonicalSigning.bodyDigest(request.body), decision.expiresAt >= observed, decision.issuedAt <= observed, decision.expiresAt.timeIntervalSince(decision.issuedAt) <= 30 else { throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Authorization decision is stale or request-mismatched") }
            let unsigned = decisionCanonicalString(decision)
            let decisionSignature = CanonicalSigning.hmacSHA256(message: unsigned, key: key.secret)
            guard decision.keyID == key.keyID, CanonicalSigning.secureEquals(decisionSignature, decision.signature) else { throw ServiceAPIError(code: .authorizationDecisionRejected, message: "Authorization decision signature is invalid") }
            return AuthenticatedInternalRequest(role: key.role, decision: decision)
        }
        return AuthenticatedInternalRequest(role: key.role, decision: nil)
    }

    public nonisolated func decisionCanonicalString(_ value: GoblinAuthorizationDecision) -> String {
        [String(value.schemaVersion), value.decisionID.uuidString, value.actor.goblinUserID, value.projectID?.uuidString ?? "", value.sessionID?.uuidString ?? "", value.operation, value.requestDigest, String(value.policyRevision), String(value.controllerRevision), String(value.membershipRevision), String(value.issuedAt.timeIntervalSince1970), String(value.expiresAt.timeIntervalSince1970), value.requestID.uuidString, value.correlationID.uuidString, value.keyID].joined(separator: "\n")
    }
}

extension HTTPField.Name {
    static let repoKeyID = Self("X-RepoPrompt-Key-Id")!
    static let repoTimestamp = Self("X-RepoPrompt-Timestamp")!
    static let repoNonce = Self("X-RepoPrompt-Nonce")!
    static let repoSignature = Self("X-RepoPrompt-Signature")!
    static let repoDecision = Self("X-RepoPrompt-Authorization-Decision")!
    static let idempotencyKey = Self("Idempotency-Key")!
}
