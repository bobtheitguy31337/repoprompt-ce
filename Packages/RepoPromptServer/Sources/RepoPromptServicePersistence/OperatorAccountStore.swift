import Foundation
import RepoPromptAuthorityAPI
import RepoPromptRuntimeModel

extension SQLiteServiceStore {
    public static let defaultOperatorUsername = "operator"
    public static let operatorSessionDuration: TimeInterval = 12 * 60 * 60

    public func hasOperatorAccount() async throws -> Bool {
        let count = try await database.query("SELECT COUNT(*) AS count FROM operator_accounts").first?.column("count")?.integer ?? 0
        return count > 0
    }

    public func issueOperatorSetupToken(
        correlationID: UUID = UUID(),
        channel: String = "offline"
    ) async throws -> String {
        let token = OperatorPasswordHasher.randomToken()
        let hash = OperatorPasswordHasher.sha256Hex(Data(token.utf8))
        try await transaction(.interactive(estimatedEncodedBytes: 0)) {
            _ = try await database.query("DELETE FROM operator_setup_tokens")
            _ = try await database.query(
                "INSERT INTO operator_setup_tokens(token_hash,created_at) VALUES(?,CURRENT_TIMESTAMP)",
                [.text(hash)]
            )
            try await appendOperatorSecurityAudit(
                operation: "setupTokenIssue", outcome: "success", actor: "operator-recovery",
                channel: channel, clientIdentityDigest: nil, correlationID: correlationID
            )
        }
        return token
    }

    public func createOperatorAccount(
        username: String = defaultOperatorUsername,
        password: String,
        setupToken: String?,
        allowMissingSetupToken: Bool = false,
        clientIdentityDigest: String? = nil,
        correlationID: UUID = UUID(),
        channel: String = "portal"
    ) async throws {
        guard try await hasOperatorAccount() == false else {
            throw ServiceAPIError(code: .invalidRequest, message: "Operator account already exists")
        }
        try OperatorPasswordHasher.validate(password)
        let salt = OperatorPasswordHasher.randomSalt()
        let hash = try OperatorPasswordHasher.hash(password: password, salt: salt)
        try await transaction(.interactive(estimatedEncodedBytes: 0)) {
            try await consumeSetupToken(setupToken, allowMissing: allowMissingSetupToken)
            _ = try await database.query(
                "INSERT INTO operator_accounts(username,password_salt,password_hash,iterations,created_at) VALUES(?,?,?,?,CURRENT_TIMESTAMP)",
                [.text(username), .text(salt.base64EncodedString()), .text(hash.base64EncodedString()), .integer(OperatorPasswordHasher.iterations)]
            )
            try await appendOperatorSecurityAudit(
                operation: "accountCreate", outcome: "success", actor: "operator:\(username)", channel: channel,
                clientIdentityDigest: clientIdentityDigest, correlationID: correlationID
            )
        }
    }

    public func verifyOperatorPassword(username: String = defaultOperatorUsername, password: String) async throws -> Bool {
        guard let row = try await database.query(
            "SELECT password_salt,password_hash,iterations FROM operator_accounts WHERE username=?",
            [.text(username)]
        ).first,
              let salt = Data(base64Encoded: row.column("password_salt")?.string ?? ""),
              let hash = Data(base64Encoded: row.column("password_hash")?.string ?? ""),
              let iterations = row.column("iterations")?.integer
        else { return false }
        return OperatorPasswordHasher.verify(password, salt: salt, hash: hash, iterations: iterations)
    }

    public func authenticateOperatorAndCreateSession(
        username: String = defaultOperatorUsername,
        password: String,
        clientIdentityDigest: String,
        usernameDigest: String,
        correlationID: UUID,
        now: Date = Date()
    ) async throws -> String? {
        guard let row = try await database.query(
            "SELECT password_salt,password_hash,iterations FROM operator_accounts WHERE username=?",
            [.text(username)]
        ).first,
              let saltText = row.column("password_salt")?.string,
              let hashText = row.column("password_hash")?.string,
              let salt = Data(base64Encoded: saltText),
              let hash = Data(base64Encoded: hashText),
              let iterations = row.column("iterations")?.integer,
              OperatorPasswordHasher.verify(password, salt: salt, hash: hash, iterations: iterations)
        else { return nil }

        let token = OperatorPasswordHasher.randomToken() + OperatorPasswordHasher.randomToken()
        let tokenHash = OperatorPasswordHasher.sha256Hex(Data(token.utf8))
        let expires = now.addingTimeInterval(Self.operatorSessionDuration)
        let sessionID = UUID()
        return try await transaction(.interactive(estimatedEncodedBytes: 0)) {
            let inserted = try await database.query(
                "INSERT INTO operator_sessions(session_id,username,token_hash,created_at,expires_at) SELECT ?,username,?,?,? FROM operator_accounts WHERE username=? AND password_salt=? AND password_hash=? AND iterations=? RETURNING session_id",
                [
                    .text(sessionID.uuidString.lowercased()), .text(tokenHash), .float(now.timeIntervalSince1970),
                    .float(expires.timeIntervalSince1970), .text(username), .text(saltText), .text(hashText),
                    .integer(iterations),
                ]
            )
            guard !inserted.isEmpty else { return nil }
            _ = try await database.query(
                "INSERT INTO operator_session_metadata(session_id,username,issued_at,last_seen_at,client_identity_digest,correlation_id) VALUES(?,?,?,?,?,?)",
                [
                    .text(sessionID.uuidString.lowercased()), .text(username), .float(now.timeIntervalSince1970),
                    .float(now.timeIntervalSince1970), .text(clientIdentityDigest),
                    .text(correlationID.uuidString.lowercased()),
                ]
            )
            try await clearOperatorAuthenticationThrottle(
                scope: .login,
                clientIdentityDigest: clientIdentityDigest,
                usernameDigest: usernameDigest
            )
            try await appendOperatorSecurityAudit(
                operation: "login", outcome: "success", actor: "operator:\(username)", channel: "portal",
                clientIdentityDigest: clientIdentityDigest, correlationID: correlationID, now: now
            )
            return token
        }
    }

    public func createOperatorSession(
        username: String = defaultOperatorUsername,
        clientIdentityDigest: String? = nil,
        correlationID: UUID = UUID(),
        now: Date = Date()
    ) async throws -> String {
        let token = OperatorPasswordHasher.randomToken() + OperatorPasswordHasher.randomToken()
        let hash = OperatorPasswordHasher.sha256Hex(Data(token.utf8))
        let expires = now.addingTimeInterval(Self.operatorSessionDuration)
        let sessionID = UUID()
        try await transaction(.interactive(estimatedEncodedBytes: 0)) {
            _ = try await database.query(
                "INSERT INTO operator_sessions(session_id,username,token_hash,created_at,expires_at) VALUES(?,?,?,?,?)",
                [.text(sessionID.uuidString.lowercased()), .text(username), .text(hash), .float(now.timeIntervalSince1970), .float(expires.timeIntervalSince1970)]
            )
            _ = try await database.query(
                "INSERT INTO operator_session_metadata(session_id,username,issued_at,last_seen_at,client_identity_digest,correlation_id) VALUES(?,?,?,?,?,?)",
                [
                    .text(sessionID.uuidString.lowercased()), .text(username), .float(now.timeIntervalSince1970),
                    .float(now.timeIntervalSince1970), clientIdentityDigest.map { .text($0) } ?? .null,
                    .text(correlationID.uuidString.lowercased()),
                ]
            )
        }
        return token
    }

    public func operatorSessionUsername(token: String, now: Date = Date()) async throws -> String? {
        let hash = OperatorPasswordHasher.sha256Hex(Data(token.utf8))
        guard let row = try await database.query(
            "SELECT session_id,username,expires_at FROM operator_sessions WHERE token_hash=?",
            [.text(hash)]
        ).first,
              let username = row.column("username")?.string,
              let expires = row.column("expires_at")?.double
        else { return nil }
        guard expires > now.timeIntervalSince1970 else {
            if let sessionID = row.column("session_id")?.string {
                _ = try await database.query(
                    "UPDATE operator_session_metadata SET revoked_at=?,revocation_reason='expired' WHERE session_id=?",
                    [.float(now.timeIntervalSince1970), .text(sessionID)]
                )
            }
            _ = try await database.query("DELETE FROM operator_sessions WHERE token_hash=?", [.text(hash)])
            return nil
        }
        if let sessionID = row.column("session_id")?.string {
            _ = try await database.query(
                "UPDATE operator_session_metadata SET last_seen_at=? WHERE session_id=?",
                [.float(now.timeIntervalSince1970), .text(sessionID)]
            )
        }
        return username
    }

    public func deleteOperatorSession(token: String, now: Date = Date()) async throws {
        let hash = OperatorPasswordHasher.sha256Hex(Data(token.utf8))
        if let sessionID = try await database.query(
            "SELECT session_id FROM operator_sessions WHERE token_hash=?", [.text(hash)]
        ).first?.column("session_id")?.string {
            _ = try await database.query(
                "UPDATE operator_session_metadata SET revoked_at=?,revocation_reason='logout' WHERE session_id=?",
                [.float(now.timeIntervalSince1970), .text(sessionID)]
            )
        }
        _ = try await database.query("DELETE FROM operator_sessions WHERE token_hash=?", [.text(hash)])
    }

    public func changeOperatorPassword(
        username: String = defaultOperatorUsername,
        currentPassword: String,
        newPassword: String,
        clientIdentityDigest: String?,
        correlationID: UUID,
        now: Date = Date()
    ) async throws -> String {
        guard let current = try await database.query(
            "SELECT password_salt,password_hash,iterations FROM operator_accounts WHERE username=?",
            [.text(username)]
        ).first,
              let currentSaltText = current.column("password_salt")?.string,
              let currentHashText = current.column("password_hash")?.string,
              let currentSalt = Data(base64Encoded: currentSaltText),
              let currentHash = Data(base64Encoded: currentHashText),
              let currentIterations = current.column("iterations")?.integer,
              OperatorPasswordHasher.verify(
                  currentPassword,
                  salt: currentSalt,
                  hash: currentHash,
                  iterations: currentIterations
              )
        else {
            throw ServiceAPIError(code: .internalAuthFailed, message: "Current password is incorrect")
        }
        try OperatorPasswordHasher.validate(newPassword)
        let salt = OperatorPasswordHasher.randomSalt()
        let passwordHash = try OperatorPasswordHasher.hash(password: newPassword, salt: salt)
        let replacement = OperatorPasswordHasher.randomToken() + OperatorPasswordHasher.randomToken()
        let replacementHash = OperatorPasswordHasher.sha256Hex(Data(replacement.utf8))
        let replacementSessionID = UUID()
        let replacementExpiry = now.addingTimeInterval(Self.operatorSessionDuration)
        try await transaction(.interactive(estimatedEncodedBytes: 0)) {
            let updated = try await database.query(
                "UPDATE operator_accounts SET password_salt=?,password_hash=?,iterations=? WHERE username=? AND password_salt=? AND password_hash=? AND iterations=? RETURNING username",
                [
                    .text(salt.base64EncodedString()), .text(passwordHash.base64EncodedString()),
                    .integer(OperatorPasswordHasher.iterations), .text(username), .text(currentSaltText),
                    .text(currentHashText), .integer(currentIterations),
                ]
            )
            guard !updated.isEmpty else {
                throw ServiceAPIError(code: .internalAuthFailed, message: "Current password changed before this request completed")
            }
            _ = try await database.query(
                "UPDATE operator_session_metadata SET revoked_at=?,revocation_reason='passwordChanged' WHERE username=? AND revoked_at IS NULL",
                [.float(now.timeIntervalSince1970), .text(username)]
            )
            _ = try await database.query("DELETE FROM operator_sessions WHERE username=?", [.text(username)])
            _ = try await database.query(
                "INSERT INTO operator_sessions(session_id,username,token_hash,created_at,expires_at) VALUES(?,?,?,?,?)",
                [
                    .text(replacementSessionID.uuidString.lowercased()), .text(username), .text(replacementHash),
                    .float(now.timeIntervalSince1970), .float(replacementExpiry.timeIntervalSince1970),
                ]
            )
            _ = try await database.query(
                "INSERT INTO operator_session_metadata(session_id,username,issued_at,last_seen_at,client_identity_digest,correlation_id) VALUES(?,?,?,?,?,?)",
                [
                    .text(replacementSessionID.uuidString.lowercased()), .text(username), .float(now.timeIntervalSince1970),
                    .float(now.timeIntervalSince1970), clientIdentityDigest.map { .text($0) } ?? .null,
                    .text(correlationID.uuidString.lowercased()),
                ]
            )
            try await appendOperatorSecurityAudit(
                operation: "passwordChange", outcome: "success", actor: "operator:\(username)", channel: "portal",
                clientIdentityDigest: clientIdentityDigest, correlationID: correlationID, now: now
            )
        }
        return replacement
    }

    public func resetOperatorPasswordOffline(
        username: String = defaultOperatorUsername,
        newPassword: String,
        correlationID: UUID = UUID(),
        now: Date = Date()
    ) async throws {
        try OperatorPasswordHasher.validate(newPassword)
        let salt = OperatorPasswordHasher.randomSalt()
        let passwordHash = try OperatorPasswordHasher.hash(password: newPassword, salt: salt)
        try await transaction(.interactive(estimatedEncodedBytes: 0)) {
            let updated = try await database.query(
                "UPDATE operator_accounts SET password_salt=?,password_hash=?,iterations=? WHERE username=? RETURNING username",
                [.text(salt.base64EncodedString()), .text(passwordHash.base64EncodedString()), .integer(OperatorPasswordHasher.iterations), .text(username)]
            )
            guard !updated.isEmpty else {
                throw ServiceAPIError(code: .notFound, message: "Operator account does not exist")
            }
            _ = try await database.query(
                "UPDATE operator_session_metadata SET revoked_at=?,revocation_reason='offlinePasswordReset' WHERE username=? AND revoked_at IS NULL",
                [.float(now.timeIntervalSince1970), .text(username)]
            )
            _ = try await database.query("DELETE FROM operator_sessions WHERE username=?", [.text(username)])
            try await appendOperatorSecurityAudit(
                operation: "passwordReset", outcome: "success", actor: "operator-recovery", channel: "offline",
                clientIdentityDigest: nil, correlationID: correlationID, now: now
            )
        }
    }

    private func consumeSetupToken(_ token: String?, allowMissing: Bool) async throws {
        guard let pending = try await database.query("SELECT token_hash FROM operator_setup_tokens WHERE consumed_at IS NULL").first,
              let expectedHash = pending.column("token_hash")?.string
        else {
            if allowMissing { return }
            throw ServiceAPIError(code: .invalidRequest, message: "First-run setup is not available")
        }
        if allowMissing {
            _ = try await database.query("UPDATE operator_setup_tokens SET consumed_at=CURRENT_TIMESTAMP WHERE token_hash=?", [.text(expectedHash)])
            return
        }
        let provided = OperatorPasswordHasher.sha256Hex(Data((token ?? "").utf8))
        guard OperatorPasswordHasher.constantTimeEquals(Data(provided.utf8), Data(expectedHash.utf8)) else {
            throw ServiceAPIError(code: .internalAuthFailed, message: "First-run setup token is invalid")
        }
        _ = try await database.query("UPDATE operator_setup_tokens SET consumed_at=CURRENT_TIMESTAMP WHERE token_hash=?", [.text(expectedHash)])
    }
}
