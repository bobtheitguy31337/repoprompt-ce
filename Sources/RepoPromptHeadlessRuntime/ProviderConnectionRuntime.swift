import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptServicePersistence
import RepoPromptServiceProtocol

public protocol ProviderCredentialTesting: Sendable {
    func test(providerID: ProviderSettingsID, method: ProviderAuthenticationMethod, secret: Data?) async -> ProviderCredentialTestResult
    func logout(providerID: ProviderSettingsID, method: ProviderAuthenticationMethod) async
}

public struct UnavailableProviderCredentialTester: ProviderCredentialTesting {
    public init() {}
    public func test(providerID _: ProviderSettingsID, method _: ProviderAuthenticationMethod, secret _: Data?) async -> ProviderCredentialTestResult {
        .init(state: .unavailable, detail: "Credential validation adapter is unavailable")
    }

    public func logout(providerID _: ProviderSettingsID, method _: ProviderAuthenticationMethod) async {}
}

/// Vault-backed, per-launch environment projection. Secrets exist only in the
/// child environment and are never rendered into arguments or result DTOs.
public actor VaultProviderProcessEnvironment: ProviderProcessEnvironmentProviding {
    private let store: SQLiteServiceStore
    private let vault: ProviderCredentialVault?
    private let externallyProvisionedKinds: Set<ProviderKind>

    public init(store: SQLiteServiceStore, vault: ProviderCredentialVault?, externallyProvisionedKinds: Set<ProviderKind> = []) {
        self.store = store
        self.vault = vault
        self.externallyProvisionedKinds = externallyProvisionedKinds
    }

    public func environment(for kind: ProviderKind) async throws -> [String: String] {
        guard let providerID = Self.providerID(kind) else { return [:] }
        guard let stored = try await store.providerConnection(providerID: providerID) else {
            guard externallyProvisionedKinds.contains(kind) else {
                throw ServiceAPIError(code: .providerUnavailable, message: "Provider credential is not configured")
            }
            return [:]
        }
        guard stored.record.state == .connected,
              stored.record.testState == .valid,
              stored.record.expiresAt.map({ $0 > Date() }) ?? true
        else {
            throw ServiceAPIError(code: .providerUnavailable, message: "Provider credential is not validated")
        }
        guard let reference = stored.credentialReference else {
            guard externallyProvisionedKinds.contains(kind) else {
                throw ServiceAPIError(code: .providerUnavailable, message: "Provider credential source is unavailable")
            }
            return [:]
        }
        guard let vault else {
            throw ServiceAPIError(code: .providerUnavailable, message: "Provider credential vault is unavailable")
        }
        let secret = try await vault.load(providerID: providerID, connectionID: reference)
        guard let value = String(data: secret, encoding: .utf8), !value.isEmpty else {
            throw ServiceAPIError(code: .providerUnavailable, message: "Provider credential could not be injected")
        }
        switch (providerID, stored.record.authenticationMethod) {
        case (.codex, .apiKey), (.codex, .enterpriseAccessToken): return ["OPENAI_API_KEY": value]
        case (.claudeCompatible, .apiKey): return ["ANTHROPIC_API_KEY": value]
        case (.claudeCompatible, .authToken): return ["ANTHROPIC_AUTH_TOKEN": value]
        case (.cursorACP, .apiKey): return ["CURSOR_API_KEY": value]
        default:
            throw ServiceAPIError(code: .providerUnavailable, message: "Provider credential method is not runtime-wired")
        }
    }

    private nonisolated static func providerID(_ kind: ProviderKind) -> ProviderSettingsID? {
        switch kind {
        case .codex: .codex
        case .claudeCompatible: .claudeCompatible
        case .openCodeACP: .openCodeACP
        case .cursorACP: .cursorACP
        case .headlessAdapter, .mcp: nil
        }
    }
}

/// Provider-specific status/logout adapter. Raw command and HTTP output is
/// discarded; callers receive only closed, redacted states.
public actor ProviderAuthenticationAdapter: ProviderCredentialTesting {
    public init(configurations _: [ProviderCLIConfiguration]) {}

    /// Credential verification is deliberately fail-closed until an
    /// administrator opts the deployment into a provider-specific validator.
    /// The server neither sends write-only credentials over an implicit
    /// network path nor starts an unbounded login-status subprocess.
    public func test(providerID _: ProviderSettingsID, method _: ProviderAuthenticationMethod, secret: Data?) async -> ProviderCredentialTestResult {
        guard secret?.isEmpty == false else {
            return .init(state: .invalid, detail: "Provider credential is missing")
        }
        return .init(state: .unavailable, detail: "Provider credential validation is not configured for this deployment")
    }

    public func logout(providerID _: ProviderSettingsID, method _: ProviderAuthenticationMethod) async {}
}

public protocol ProviderAuthFlowDriving: Sendable {
    func start(providerID: ProviderSettingsID, kind: ProviderAuthFlowKind) async throws -> ProviderAuthTransactionStatus
    func poll(flowID: UUID) async throws -> ProviderAuthTransactionStatus
    func cancel(flowID: UUID) async
}

/// In-memory owner fence for device/browser authentication. No transaction,
/// code, URL, or process output is written to SQLite or the vault.
public actor TransientProviderAuthFlowCoordinator: ProviderAuthFlowCoordinating {
    private struct Transaction {
        let ownerID: String
        var status: ProviderAuthTransactionStatus
    }

    private let driver: any ProviderAuthFlowDriving
    private let now: @Sendable () -> Date
    private let maximumTransactions: Int
    private var transactions: [UUID: Transaction] = [:]

    public init(driver: any ProviderAuthFlowDriving, now: @escaping @Sendable () -> Date = Date.init, maximumTransactions: Int = 128) {
        self.driver = driver
        self.now = now
        self.maximumTransactions = max(1, maximumTransactions)
    }

    public func start(providerID: ProviderSettingsID, kind: ProviderAuthFlowKind, ownerID: String) async throws -> ProviderAuthTransactionStatus {
        let ownerID = try validatedOwnerID(ownerID)
        await pruneExpired()
        guard transactions.count < maximumTransactions else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Too many provider authentication transactions are active")
        }
        let returned = try await driver.start(providerID: providerID, kind: kind)
        guard returned.providerID == providerID,
              returned.kind == kind,
              returned.expiresAt > now(),
              transactions[returned.flowID] == nil
        else {
            await driver.cancel(flowID: returned.flowID)
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider authentication driver returned an invalid transaction")
        }
        let status = try sanitized(returned, fixedExpiration: returned.expiresAt)
        transactions[status.flowID] = Transaction(ownerID: ownerID, status: status)
        return status
    }

    public func poll(flowID: UUID, ownerID: String) async throws -> ProviderAuthTransactionStatus {
        let ownerID = try validatedOwnerID(ownerID)
        guard var transaction = transactions[flowID], transaction.ownerID == ownerID else {
            throw ServiceAPIError(code: .notFound, message: "Provider authentication transaction was not found")
        }
        if transaction.status.expiresAt <= now() {
            transaction.status = .init(flowID: flowID, providerID: transaction.status.providerID, kind: transaction.status.kind, state: .expired, expiresAt: transaction.status.expiresAt, detail: "Authentication transaction expired")
            transactions[flowID] = nil
            await driver.cancel(flowID: flowID)
            return transaction.status
        }
        let returned = try await driver.poll(flowID: flowID)
        guard returned.flowID == flowID,
              returned.providerID == transaction.status.providerID,
              returned.kind == transaction.status.kind,
              returned.expiresAt <= transaction.status.expiresAt
        else {
            transactions[flowID] = nil
            await driver.cancel(flowID: flowID)
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider authentication driver returned an invalid transaction")
        }
        transaction.status = try sanitized(returned, fixedExpiration: transaction.status.expiresAt)
        transactions[flowID] = transaction.status.state == .pending ? transaction : nil
        return transaction.status
    }

    public func cancel(flowID: UUID, ownerID: String) async throws {
        let ownerID = try validatedOwnerID(ownerID)
        guard let transaction = transactions[flowID], transaction.ownerID == ownerID else {
            throw ServiceAPIError(code: .notFound, message: "Provider authentication transaction was not found")
        }
        transactions[flowID] = nil
        await driver.cancel(flowID: flowID)
    }

    private func sanitized(_ status: ProviderAuthTransactionStatus, fixedExpiration: Date) throws -> ProviderAuthTransactionStatus {
        let terminal = status.state != .pending
        let userCode = try terminal ? nil : sanitizedUserCode(status.userCode)
        let verificationURL = try terminal ? nil : sanitizedVerificationURL(status.verificationURL)
        return .init(
            flowID: status.flowID,
            providerID: status.providerID,
            kind: status.kind,
            state: status.state,
            userCode: userCode,
            verificationURL: verificationURL,
            expiresAt: fixedExpiration,
            detail: sanitizedDetail(status.detail)
        )
    }

    private func validatedOwnerID(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == value,
              trimmed.utf8.count <= 256,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw ServiceAPIError(code: .invalidRequest, message: "Provider authentication owner is invalid")
        }
        return trimmed
    }

    private func sanitizedUserCode(_ value: String?) throws -> String? {
        guard let value else { return nil }
        guard value.utf8.count <= 64,
              value.range(of: "^[A-Za-z0-9 -]+$", options: .regularExpression) != nil
        else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider authentication driver returned an invalid user code")
        }
        return value
    }

    private func sanitizedVerificationURL(_ value: URL?) throws -> URL? {
        guard let value else { return nil }
        guard value.scheme?.lowercased() == "https",
              value.host?.isEmpty == false,
              value.user == nil,
              value.password == nil,
              value.absoluteString.utf8.count <= 2048
        else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider authentication driver returned an invalid verification URL")
        }
        return value
    }

    private func sanitizedDetail(_ value: String?) -> String? {
        guard let value else { return nil }
        let redacted = ProviderSecretRedaction.redact(value)
        let allowedScalars = redacted.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let sanitized = String(String.UnicodeScalarView(allowedScalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? nil : String(sanitized.prefix(256))
    }

    private func pruneExpired() async {
        let expired = transactions.compactMap { key, value in value.status.expiresAt <= now() ? key : nil }
        for flowID in expired {
            transactions[flowID] = nil
            await driver.cancel(flowID: flowID)
        }
    }
}
