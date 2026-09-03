import Crypto
import Foundation
import RepoPromptServiceProtocol
import SQLiteNIO

public struct ClientIntegrationRecord: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case active, revoked }

    public let integrationID: UUID
    public let workspaceID: String
    public let status: Status
    public let createdAt: Date
    public let updatedAt: Date
    public let revokedAt: Date?
}

public struct ClientMemberRecord: Codable, Sendable, Equatable {
    public let memberID: UUID
    public let username: String
    public let displayName: String
    public let firstSeenAt: Date
    public let lastSeenAt: Date
    public let profileObservedAt: Date
}

public struct ClientCredentialIssue: Sendable {
    public let integration: ClientIntegrationRecord
    public let token: String
}

/// Client-token crypto. New tokens are unbranded. The legacy prefix and digest
/// domain remain accepted so already-issued tokens keep working.
private enum ClientCredentialCrypto {
    static let issuedTokenPrefix = "rp_client_v1"
    static let legacyTokenPrefix = "rp_gabblin_v1"
    static let digestDomain = "repoprompt.external.gabblin.v1"

    static func digest(credentialID: UUID, secret: Data) -> String {
        var material = Data(digestDomain.utf8)
        material.append(0)
        let bytes = credentialID.uuid
        material.append(contentsOf: [
            bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7,
            bytes.8, bytes.9, bytes.10, bytes.11, bytes.12, bytes.13, bytes.14, bytes.15,
        ])
        material.append(0)
        material.append(secret)
        return SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
    }

    static func prepare() -> (id: UUID, token: String, digest: String) {
        let credentialID = UUID()
        var generator = SystemRandomNumberGenerator()
        let secret = Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let encoded = secret.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "\(issuedTokenPrefix).\(credentialID.uuidString.lowercased()).\(encoded)"
        return (credentialID, token, digest(credentialID: credentialID, secret: secret))
    }

    static func parse(_ token: String) -> (id: UUID, digest: String)? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == issuedTokenPrefix || parts[0] == legacyTokenPrefix,
              let credentialID = UUID(uuidString: String(parts[1])),
              let secret = CanonicalSigning.base64URLDecode(String(parts[2])),
              secret.count == 32
        else { return nil }
        return (credentialID, digest(credentialID: credentialID, secret: secret))
    }
}

public extension SQLiteServiceStore {
    func authenticateClientCredential(
        token: String,
        subject: String,
        username: String,
        displayName: String,
        now: Date = Date()
    ) async throws {
        guard let credential = ClientCredentialCrypto.parse(token) else {
            throw ServiceAPIError(code: .internalAuthFailed, message: "API token is invalid")
        }
        try await transaction {
            guard let row = try await connection.query(
                "SELECT c.secret_digest,i.integration_id FROM external_gabblin_credentials c JOIN external_gabblin_integration i ON i.integration_id=c.integration_id WHERE c.credential_id=? AND c.revoked_at IS NULL AND i.status='active'",
                [.text(credential.id.uuidString.lowercased())]
            ).first,
                let storedDigest = row.column("secret_digest")?.string,
                let integrationID = row.column("integration_id")?.string,
                CanonicalSigning.secureEquals(storedDigest, credential.digest)
            else {
                throw ServiceAPIError(code: .internalAuthFailed, message: "API token is invalid")
            }
            let staleBefore = now.addingTimeInterval(-60).timeIntervalSince1970
            _ = try await connection.query(
                "UPDATE external_gabblin_credentials SET last_used_at=? WHERE credential_id=? AND last_used_at<?",
                [.float(now.timeIntervalSince1970), .text(credential.id.uuidString.lowercased()), .float(staleBefore)]
            )
            _ = try await connection.query(
                "INSERT INTO external_gabblin_members(member_id,integration_id,immutable_subject,display_name,username,first_seen_at,last_seen_at,profile_observed_at) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(integration_id,immutable_subject) DO UPDATE SET display_name=excluded.display_name,username=excluded.username,last_seen_at=excluded.last_seen_at,profile_observed_at=excluded.profile_observed_at WHERE external_gabblin_members.last_seen_at<? OR external_gabblin_members.display_name<>excluded.display_name OR external_gabblin_members.username<>excluded.username",
                [.text(UUID().uuidString.lowercased()), .text(integrationID), .text(subject), .text(displayName), .text(username), .float(now.timeIntervalSince1970), .float(now.timeIntervalSince1970), .float(now.timeIntervalSince1970), .float(staleBefore)]
            )
        }
    }

    func clientIntegration() async throws -> ClientIntegrationRecord? {
        guard let row = try await connection.query(
            "SELECT integration_id,workspace_id,status,created_at,updated_at,revoked_at FROM external_gabblin_integration WHERE fixed_id=1"
        ).first else { return nil }
        return try decodeClientIntegration(row)
    }

    func clientMembers() async throws -> [ClientMemberRecord] {
        try await connection.query(
            "SELECT member_id,username,display_name,first_seen_at,last_seen_at,profile_observed_at FROM external_gabblin_members ORDER BY first_seen_at,member_id"
        ).map { row in
            guard let memberID = row.column("member_id")?.string.flatMap(UUID.init(uuidString:)) else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Client member record is invalid")
            }
            return ClientMemberRecord(
                memberID: memberID,
                username: row.column("username")?.string ?? "",
                displayName: row.column("display_name")?.string ?? "",
                firstSeenAt: Date(timeIntervalSince1970: row.column("first_seen_at")?.double ?? 0),
                lastSeenAt: Date(timeIntervalSince1970: row.column("last_seen_at")?.double ?? 0),
                profileObservedAt: Date(timeIntervalSince1970: row.column("profile_observed_at")?.double ?? 0)
            )
        }
    }

    func createClientIntegration(now: Date = Date()) async throws -> ClientCredentialIssue {
        let correlationID = UUID()
        let prepared = ClientCredentialCrypto.prepare()
        return try await transaction {
            let existingRow = try await connection.query(
                "SELECT integration_id,workspace_id,status,created_at,updated_at,revoked_at FROM external_gabblin_integration WHERE fixed_id=1"
            ).first
            let integrationID: UUID
            let workspaceID: String
            let createdAt: Date
            if let existingRow {
                let existing = try decodeClientIntegration(existingRow)
                guard existing.status == .revoked else {
                    throw ServiceAPIError(code: .invalidRequest, message: "Client integration already exists")
                }
                integrationID = existing.integrationID
                workspaceID = existing.workspaceID
                createdAt = existing.createdAt
                _ = try await connection.query(
                    "UPDATE external_gabblin_integration SET status='active',updated_at=?,revoked_at=NULL,correlation_id=? WHERE fixed_id=1",
                    [.float(now.timeIntervalSince1970), .text(correlationID.uuidString.lowercased())]
                )
            } else {
                integrationID = UUID()
                workspaceID = integrationID.uuidString.lowercased()
                createdAt = now
                _ = try await connection.query(
                    "INSERT INTO external_gabblin_integration(fixed_id,integration_id,workspace_id,status,created_at,updated_at,correlation_id) VALUES(1,?,?,'active',?,?,?)",
                    [.text(integrationID.uuidString.lowercased()), .text(workspaceID), .float(now.timeIntervalSince1970), .float(now.timeIntervalSince1970), .text(correlationID.uuidString.lowercased())]
                )
            }
            _ = try await connection.query(
                "INSERT INTO external_gabblin_credentials(credential_id,integration_id,secret_digest,issued_at,last_used_at) VALUES(?,?,?,?,?)",
                [.text(prepared.id.uuidString.lowercased()), .text(integrationID.uuidString.lowercased()), .text(prepared.digest), .float(now.timeIntervalSince1970), .float(now.timeIntervalSince1970)]
            )
            return ClientCredentialIssue(
                integration: ClientIntegrationRecord(integrationID: integrationID, workspaceID: workspaceID, status: .active, createdAt: createdAt, updatedAt: now, revokedAt: nil),
                token: prepared.token
            )
        }
    }

    func rotateClientCredential(now: Date = Date()) async throws -> ClientCredentialIssue {
        let prepared = ClientCredentialCrypto.prepare()
        let correlationID = UUID()
        return try await transaction {
            guard let row = try await connection.query(
                "SELECT integration_id,workspace_id,status,created_at,updated_at,revoked_at FROM external_gabblin_integration WHERE fixed_id=1 AND status='active'"
            ).first else {
                throw ServiceAPIError(code: .notFound, message: "Active client integration does not exist")
            }
            let integration = try decodeClientIntegration(row)
            _ = try await connection.query(
                "UPDATE external_gabblin_credentials SET secret_digest=NULL,revoked_at=?,revocation_reason='rotated' WHERE integration_id=? AND revoked_at IS NULL",
                [.float(now.timeIntervalSince1970), .text(integration.integrationID.uuidString.lowercased())]
            )
            _ = try await connection.query(
                "INSERT INTO external_gabblin_credentials(credential_id,integration_id,secret_digest,issued_at,last_used_at) VALUES(?,?,?,?,?)",
                [.text(prepared.id.uuidString.lowercased()), .text(integration.integrationID.uuidString.lowercased()), .text(prepared.digest), .float(now.timeIntervalSince1970), .float(now.timeIntervalSince1970)]
            )
            _ = try await connection.query(
                "UPDATE external_gabblin_integration SET updated_at=?,correlation_id=? WHERE fixed_id=1",
                [.float(now.timeIntervalSince1970), .text(correlationID.uuidString.lowercased())]
            )
            return ClientCredentialIssue(
                integration: ClientIntegrationRecord(integrationID: integration.integrationID, workspaceID: integration.workspaceID, status: .active, createdAt: integration.createdAt, updatedAt: now, revokedAt: nil),
                token: prepared.token
            )
        }
    }

    @discardableResult
    func revokeClientIntegration(now: Date = Date()) async throws -> Bool {
        let correlationID = UUID()
        return try await transaction {
            let rows = try await connection.query(
                "UPDATE external_gabblin_integration SET status='revoked',updated_at=?,revoked_at=?,correlation_id=? WHERE fixed_id=1 AND status='active' RETURNING integration_id",
                [.float(now.timeIntervalSince1970), .float(now.timeIntervalSince1970), .text(correlationID.uuidString.lowercased())]
            )
            guard let integrationID = rows.first?.column("integration_id")?.string else { return false }
            _ = try await connection.query(
                "UPDATE external_gabblin_credentials SET secret_digest=NULL,revoked_at=?,revocation_reason='operatorRevoked' WHERE integration_id=? AND revoked_at IS NULL",
                [.float(now.timeIntervalSince1970), .text(integrationID)]
            )
            return true
        }
    }

    private func decodeClientIntegration(_ row: SQLiteRow) throws -> ClientIntegrationRecord {
        guard let integrationID = row.column("integration_id")?.string.flatMap(UUID.init(uuidString:)),
              let workspaceID = row.column("workspace_id")?.string,
              let status = row.column("status")?.string.flatMap(ClientIntegrationRecord.Status.init(rawValue:)),
              let createdAt = row.column("created_at")?.double,
              let updatedAt = row.column("updated_at")?.double
        else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Client integration record is invalid") }
        return ClientIntegrationRecord(
            integrationID: integrationID,
            workspaceID: workspaceID,
            status: status,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            revokedAt: row.column("revoked_at")?.double.map(Date.init(timeIntervalSince1970:))
        )
    }
}
