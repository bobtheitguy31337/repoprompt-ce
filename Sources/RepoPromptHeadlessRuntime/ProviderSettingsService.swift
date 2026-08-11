import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore

public protocol ProviderAuthFlowCoordinating: Sendable {
    func start(providerID: ProviderSettingsID, kind: ProviderAuthFlowKind, ownerID: String) async throws -> ProviderAuthTransactionStatus
    func poll(flowID: UUID, ownerID: String) async throws -> ProviderAuthTransactionStatus
    func cancel(flowID: UUID, ownerID: String) async throws
}

public struct UnavailableProviderAuthFlowCoordinator: ProviderAuthFlowCoordinating {
    public init() {}

    public func start(providerID _: ProviderSettingsID, kind _: ProviderAuthFlowKind, ownerID _: String) async throws -> ProviderAuthTransactionStatus {
        throw ServiceAPIError(code: .capabilityMissing, message: "A server-side provider authentication adapter is not installed")
    }

    public func poll(flowID _: UUID, ownerID _: String) async throws -> ProviderAuthTransactionStatus {
        throw ServiceAPIError(code: .notFound, message: "Provider authentication transaction was not found")
    }

    public func cancel(flowID _: UUID, ownerID _: String) async throws {
        throw ServiceAPIError(code: .notFound, message: "Provider authentication transaction was not found")
    }
}

/// Provider/settings authority for the Linux portal. It owns only non-secret
/// preferences and browser-safe projections; native process/session authority
/// remains in `ProviderCLIAdapter`.
public actor ProviderSettingsService {
    private struct SanitizedAuthenticationDocument: Decodable {
        let authenticated: Bool
        let method: ProviderAuthenticationMethod?
        let expiresAt: Date?
    }

    private let store: SQLiteServiceStore
    private let adapter: ProviderCLIAdapter
    private let configurations: [ProviderKind: ProviderCLIConfiguration]
    private let initiallyEnabled: Set<ProviderKind>
    private let authenticationStatusFiles: [ProviderSettingsID: String]
    private let modelCatalogFiles: [ProviderSettingsID: String]
    private let authFlows: any ProviderAuthFlowCoordinating
    private let vault: ProviderCredentialVault?
    private let credentialTester: any ProviderCredentialTesting
    private let runner: any WorkspaceCommandRunning
    private var preferences: [ProviderSettingsID: ProviderSettingsPreference] = [:]
    private var cliHealth: [ProviderSettingsID: ProviderCLIHealth] = [:]
    private var runtimePreflight: [ProviderSettingsID: Bool] = [:]
    private var modelCatalogs: [ProviderSettingsID: [ProviderModelCatalogEntry]] = [:]
    private var connections: [ProviderSettingsID: SQLiteServiceStore.StoredProviderConnection] = [:]

    public init(
        store: SQLiteServiceStore,
        adapter: ProviderCLIAdapter,
        configurations: [ProviderCLIConfiguration],
        initiallyEnabled: Set<ProviderKind>,
        authenticationStatusFiles: [ProviderSettingsID: String] = [:],
        modelCatalogFiles: [ProviderSettingsID: String] = [:],
        authFlows: any ProviderAuthFlowCoordinating = UnavailableProviderAuthFlowCoordinator(),
        vault: ProviderCredentialVault? = nil,
        credentialTester: any ProviderCredentialTesting = UnavailableProviderCredentialTester(),
        runner: any WorkspaceCommandRunning = LocalWorkspaceCommandRunner()
    ) {
        self.store = store
        self.adapter = adapter
        self.configurations = Dictionary(uniqueKeysWithValues: configurations.map { ($0.kind, $0) })
        self.initiallyEnabled = initiallyEnabled
        self.authenticationStatusFiles = authenticationStatusFiles
        self.modelCatalogFiles = modelCatalogFiles
        self.authFlows = authFlows
        self.vault = vault
        self.credentialTester = credentialTester
        self.runner = runner
    }

    public func bootstrap() async throws {
        modelCatalogs = try loadModelCatalogs()
        let persisted = try await store.providerSettings()
        preferences = Dictionary(uniqueKeysWithValues: persisted.map { ($0.providerID, $0) })
        for preference in persisted {
            guard preference.revision > 0 else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider settings revision is invalid", retryable: false)
            }
            try validateSelection(
                .init(
                    expectedRevision: preference.revision,
                    enabled: preference.enabled,
                    defaultModel: preference.defaultModel,
                    reasoningEffort: preference.reasoningEffort,
                    speedMode: preference.speedMode,
                    serviceTier: preference.serviceTier
                ),
                providerID: preference.providerID,
                definition: Self.definition(preference.providerID)
            )
        }
        connections = try await Dictionary(uniqueKeysWithValues: store.providerConnections().map { ($0.record.providerID, $0) })
        let credentialReferences = Dictionary(uniqueKeysWithValues: connections.compactMap { providerID, stored in
            stored.credentialReference.map { (providerID, $0) }
        })
        if !credentialReferences.isEmpty, vault == nil {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Provider connections reference an unavailable credential vault", retryable: false)
        }
        if let vault {
            try await vault.rotateToActiveKeyIfNeeded()
            try await vault.reconcile(references: credentialReferences)
        }
        for providerID in ProviderSettingsID.allCases {
            if preferences[providerID] == nil {
                let initial = ProviderSettingsPreference(
                    providerID: providerID,
                    enabled: providerID.runtimeKind.map(initiallyEnabled.contains) ?? false,
                    defaultModel: defaultCatalog(for: providerID).first(where: \.isProviderDefault)?.id,
                    revision: 1
                )
                preferences[providerID] = try await store.upsertProviderSettings(initial, expectedRevision: 0)
            }
            try await applyRuntimePreference(providerID)
        }
        await refreshCLIHealth()
        await refreshRuntimePreflight()
    }

    public func catalog(refreshCLI: Bool = false, refreshRuntime: Bool = true) async throws -> ProviderSettingsCatalogResponse {
        if refreshCLI { await refreshCLIHealth() }
        if refreshRuntime { await refreshRuntimePreflight() }
        let snapshots = try ProviderSettingsID.allCases.map { try snapshot(for: $0) }
        return ProviderSettingsCatalogResponse(providers: snapshots)
    }

    public func update(
        providerID: ProviderSettingsID,
        request: UpdateProviderSettingsRequest,
        attribution: ProviderMutationAttribution? = nil,
        auditOperation: String = "updateSettings"
    ) async throws -> ProviderSettingsSnapshot {
        guard let current = preferences[providerID] else {
            throw ServiceAPIError(code: .notFound, message: "Provider settings are not initialized")
        }
        guard current.revision == request.expectedRevision else {
            throw ServiceAPIError(code: .staleRevision, message: "Provider settings revision is stale", currentRevision: current.revision)
        }
        let definition = Self.definition(providerID)
        if request.enabled, providerID.runtimeKind == nil {
            throw ServiceAPIError(code: .capabilityMissing, message: "This provider has no portable server runtime yet")
        }
        if request.enabled, let kind = providerID.runtimeKind, !initiallyEnabled.contains(kind) {
            throw ServiceAPIError(code: .capabilityMissing, message: "Deployment configuration does not allow this provider")
        }
        try validateSelection(request, providerID: providerID, definition: definition)
        let next = try ProviderSettingsPreference(
            providerID: providerID,
            enabled: request.enabled,
            defaultModel: normalized(request.defaultModel),
            reasoningEffort: normalized(request.reasoningEffort),
            speedMode: normalized(request.speedMode),
            serviceTier: normalized(request.serviceTier),
            revision: current.revision + 1
        )
        let audit = attribution.map {
            SQLiteServiceStore.ProviderConnectionAuditMutation(
                operation: auditOperation,
                attribution: $0,
                authenticationMethod: connections[providerID]?.record.authenticationMethod,
                result: auditOperation == "updateSettings" ? "updated" : (request.enabled ? "enabled" : "disabled")
            )
        }
        preferences[providerID] = try await store.upsertProviderSettings(next, expectedRevision: current.revision, audit: audit)
        try await applyRuntimePreference(providerID)
        await refreshRuntimePreflight()
        return try snapshot(for: providerID)
    }

    public func setEnabled(
        providerID: ProviderSettingsID,
        enabled: Bool,
        request: SetProviderEnabledRequest,
        attribution: ProviderMutationAttribution
    ) async throws -> ProviderSettingsSnapshot {
        guard let current = preferences[providerID] else {
            throw ServiceAPIError(code: .notFound, message: "Provider settings are not initialized")
        }
        return try await update(
            providerID: providerID,
            request: .init(
                expectedRevision: request.expectedRevision,
                enabled: enabled,
                defaultModel: current.defaultModel,
                reasoningEffort: current.reasoningEffort,
                speedMode: current.speedMode,
                serviceTier: current.serviceTier
            ),
            attribution: attribution,
            auditOperation: enabled ? "enable" : "disable"
        )
    }

    public func startAuthFlow(providerID: ProviderSettingsID, request: StartProviderAuthFlowRequest, ownerID: String) async throws -> ProviderAuthTransactionStatus {
        let descriptor = Self.definition(providerID).capabilities.authFlows.first { $0.kind == request.kind }
        guard descriptor?.startable == true else {
            throw ServiceAPIError(code: .capabilityMissing, message: descriptor?.detail ?? "Provider authentication flow is unavailable")
        }
        return try await authFlows.start(providerID: providerID, kind: request.kind, ownerID: ownerID)
    }

    public func pollAuthFlow(flowID: UUID, ownerID: String) async throws -> ProviderAuthTransactionStatus {
        try await authFlows.poll(flowID: flowID, ownerID: ownerID)
    }

    public func cancelAuthFlow(flowID: UUID, ownerID: String) async throws {
        try await authFlows.cancel(flowID: flowID, ownerID: ownerID)
    }

    public func connect(providerID: ProviderSettingsID, request: ConnectProviderRequest, attribution: ProviderMutationAttribution) async throws -> ProviderSettingsSnapshot {
        let definition = Self.definition(providerID)
        guard definition.capabilities.authenticationMethods.contains(request.authenticationMethod) else {
            throw ServiceAPIError(code: .capabilityMissing, message: "Authentication method is not supported by this provider")
        }
        guard ![ProviderAuthenticationMethod.browserOAuth, .deviceCodeBeta].contains(request.authenticationMethod) else {
            throw ServiceAPIError(code: .capabilityMissing, message: "This authentication method must use a provider authentication flow")
        }
        if let expiresAt = request.expiresAt {
            guard expiresAt.timeIntervalSince1970.isFinite, expiresAt > Date() else {
                throw ServiceAPIError(code: .invalidRequest, message: "Provider credential expiration must be in the future")
            }
        }
        let old = connections[providerID]
        let connectionID = old?.record.connectionID ?? UUID()
        let expectedRevision = old?.record.revision ?? 0
        let createdAt = old?.record.createdAt ?? Date()
        let secret = try credentialMaterial(request, providerID: providerID)
        let accountLabel = try safeLabel(request.accountLabel)
        let normalizedCredential = secret.flatMap { String(data: $0, encoding: .utf8) }
        if let label = accountLabel, let normalizedCredential, label.contains(normalizedCredential) {
            throw ServiceAPIError(code: .invalidRequest, message: "Provider account label must not contain credential material")
        }
        let needsVault = secret != nil
        if needsVault, vault == nil {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider credential vault is unavailable")
        }
        let external = !needsVault
        if external, !externallyProvisioned(providerID) {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Configured external provider credential source is unavailable")
        }
        let credentialReference = secret.map { _ in UUID() }
        if let secret, let credentialReference {
            try await vault?.store(secret: secret, providerID: providerID, connectionID: credentialReference)
        }
        let detail = external
            ? "External credential source is mounted; the provider verifies it at session launch"
            : "Credential stored; explicit validation is required"
        let initialTestState: ProviderCredentialTestState = external ? .valid : .notTested
        let initialState: ProviderConnectionState = external ? .connected : .attention
        let record = ProviderConnectionRecord(
            connectionID: connectionID,
            providerID: providerID,
            authenticationMethod: request.authenticationMethod,
            state: initialState,
            accountLabel: accountLabel,
            expiresAt: request.expiresAt,
            lastTestedAt: external ? Date() : nil,
            testState: initialTestState,
            detail: detail,
            keyHelperConfigured: false,
            workloadIdentityConfigured: false,
            createdAt: createdAt,
            updatedAt: Date(),
            revision: expectedRevision + 1
        )
        let stored = SQLiteServiceStore.StoredProviderConnection(record: record, credentialReference: credentialReference)
        let audit = SQLiteServiceStore.ProviderConnectionAuditMutation(
            operation: old == nil ? "connect" : "rotate",
            attribution: attribution,
            authenticationMethod: request.authenticationMethod,
            result: external ? "configured" : "stored"
        )
        do {
            connections[providerID] = try await store.upsertProviderConnection(stored, expectedRevision: expectedRevision, audit: audit)
        } catch {
            if let credentialReference {
                try? await vault?.delete(providerID: providerID, connectionID: credentialReference)
            }
            throw error
        }
        if let oldReference = old?.credentialReference, oldReference != credentialReference {
            // A crash or deletion failure leaves only an encrypted orphan;
            // bootstrap reconciliation removes it after SQLite is authoritative.
            try? await vault?.delete(providerID: providerID, connectionID: oldReference)
        }
        await refreshRuntimePreflight()
        return try snapshot(for: providerID)
    }

    public func testConnection(providerID: ProviderSettingsID, attribution: ProviderMutationAttribution) async throws -> ProviderSettingsSnapshot {
        guard let stored = connections[providerID] else {
            throw ServiceAPIError(code: .notFound, message: "Provider connection is not configured")
        }
        let secret: Data?
        if let reference = stored.credentialReference {
            guard let vault else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider credential vault is unavailable") }
            secret = try await vault.load(providerID: providerID, connectionID: reference)
        } else { secret = nil }
        let result = await credentialTester.test(providerID: providerID, method: stored.record.authenticationMethod, secret: secret)
        let knownSecrets = secret.flatMap { String(data: $0, encoding: .utf8) }.map { [$0] } ?? []
        let detail = try safeDetail(ProviderSecretRedaction.redact(result.detail, knownSecrets: knownSecrets))
        let returnedAccountLabel = try safeLabel(result.accountLabel)
        guard returnedAccountLabel.map({ label in knownSecrets.allSatisfy { !label.contains($0) } }) ?? true else {
            throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider validation returned unsafe metadata")
        }
        let accountLabel = returnedAccountLabel ?? stored.record.accountLabel
        let expiresAt = result.expiresAt ?? stored.record.expiresAt
        let expirationValid = expiresAt.map { $0.timeIntervalSince1970.isFinite && $0 > Date() } ?? true
        let testState: ProviderCredentialTestState = result.state == .valid && !expirationValid ? .invalid : result.state
        let state: ProviderConnectionState = testState == .valid ? .connected : .attention
        let updated = ProviderConnectionRecord(
            connectionID: stored.record.connectionID, providerID: providerID, authenticationMethod: stored.record.authenticationMethod,
            state: state, accountLabel: accountLabel, expiresAt: expiresAt,
            lastTestedAt: Date(), testState: testState, detail: expirationValid ? detail : "Provider credential has expired",
            keyHelperConfigured: stored.record.keyHelperConfigured, workloadIdentityConfigured: stored.record.workloadIdentityConfigured,
            createdAt: stored.record.createdAt, updatedAt: Date(), revision: stored.record.revision + 1
        )
        let next = SQLiteServiceStore.StoredProviderConnection(record: updated, credentialReference: stored.credentialReference)
        connections[providerID] = try await store.upsertProviderConnection(
            next,
            expectedRevision: stored.record.revision,
            audit: .init(operation: "test", attribution: attribution, authenticationMethod: stored.record.authenticationMethod, result: testState.rawValue)
        )
        await refreshRuntimePreflight()
        return try snapshot(for: providerID)
    }

    public func disconnect(providerID: ProviderSettingsID, attribution: ProviderMutationAttribution, revoke: Bool = false) async throws -> ProviderSettingsSnapshot {
        guard let stored = connections[providerID] else { return try snapshot(for: providerID) }
        try await store.deleteProviderConnection(
            providerID: providerID,
            expectedRevision: stored.record.revision,
            audit: .init(
                operation: revoke ? "revoke" : "disconnect",
                attribution: attribution,
                authenticationMethod: stored.record.authenticationMethod,
                result: "deleted"
            )
        )
        connections[providerID] = nil
        if let reference = stored.credentialReference {
            try? await vault?.delete(providerID: providerID, connectionID: reference)
        }
        await credentialTester.logout(providerID: providerID, method: stored.record.authenticationMethod)
        await refreshRuntimePreflight()
        return try snapshot(for: providerID)
    }

    private func credentialMaterial(_ request: ConnectProviderRequest, providerID: ProviderSettingsID) throws -> Data? {
        switch request.authenticationMethod {
        case .apiKey, .enterpriseAccessToken, .authToken:
            guard let value = request.credential?.trimmingCharacters(in: .whitespacesAndNewlines), value.utf8.count >= 8, value.utf8.count <= 65536, !value.contains("\0") else {
                throw ServiceAPIError(code: .invalidRequest, message: "A valid write-only credential is required")
            }
            return Data(value.utf8)
        case .keyHelper, .workloadIdentityFederation:
            throw ServiceAPIError(code: .capabilityMissing, message: "This authentication method is not runtime-wired")
        case .providerSpecific:
            guard providerID == .openCodeACP, request.credential == nil else {
                throw ServiceAPIError(code: .invalidRequest, message: "OpenCode raw credential endpoints are not proxied")
            }
            return nil
        case .browserLogin:
            guard providerID == .cursorACP, request.credential == nil else {
                throw ServiceAPIError(code: .invalidRequest, message: "Cursor browser credentials must be provisioned outside the portal")
            }
            return nil
        case .browserOAuth, .deviceCodeBeta:
            throw ServiceAPIError(code: .capabilityMissing, message: "Authentication method must use a transient provider flow")
        }
    }

    private func safeLabel(_ value: String?) throws -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        guard value.utf8.count <= 256,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !ProviderSecretRedaction.containsLikelySecret(value)
        else { throw ServiceAPIError(code: .invalidRequest, message: "Provider metadata is invalid or resembles credential material") }
        return value
    }

    private func safeDetail(_ value: String?) throws -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        guard value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !ProviderSecretRedaction.containsLikelySecret(value)
        else { throw ServiceAPIError(code: .dependencyUnavailable, message: "Provider validation returned unsafe metadata") }
        return value
    }

    private func externallyProvisioned(_ providerID: ProviderSettingsID) -> Bool {
        guard let kind = providerID.runtimeKind,
              let source = configurations[kind]?.credentialSourceDirectory
        else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func applyRuntimePreference(_ providerID: ProviderSettingsID) async throws {
        guard let kind = providerID.runtimeKind, let preference = preferences[providerID] else { return }
        guard configurations[kind] != nil else {
            if preference.enabled {
                throw ServiceAPIError(code: .providerUnavailable, message: "Provider executable is not configured")
            }
            return
        }
        let effectiveAdmission = preference.enabled && initiallyEnabled.contains(kind)
        try await adapter.applyRuntimeDefaults(
            kind: kind,
            defaults: ProviderRuntimeDefaults(
                enabled: effectiveAdmission,
                model: preference.defaultModel,
                reasoningEffort: preference.reasoningEffort,
                speedMode: preference.speedMode,
                serviceTier: preference.serviceTier
            )
        )
    }

    private func refreshCLIHealth() async {
        for (kind, configuration) in configurations {
            guard let providerID = Self.settingsID(kind) else { continue }
            guard FileManager.default.isExecutableFile(atPath: configuration.executable) else {
                cliHealth[providerID] = ProviderCLIHealth(installed: false, healthy: false, expectedVersion: configuration.expectedVersion, detail: "Configured CLI is not executable")
                continue
            }
            do {
                let output = try await runner.run(
                    executable: configuration.executable,
                    arguments: ["--version"],
                    workingDirectory: FileManager.default.currentDirectoryPath,
                    maximumBytes: 65536
                )
                let reported = Self.validCLIVersionOutput(output)
                let matches = configuration.expectedVersion.map { reported?.contains($0) == true } ?? (reported != nil)
                cliHealth[providerID] = ProviderCLIHealth(
                    installed: true,
                    healthy: matches,
                    version: matches ? configuration.expectedVersion : nil,
                    expectedVersion: configuration.expectedVersion,
                    detail: reported == nil ? "CLI returned invalid version output" : (matches ? nil : "Installed version does not match the pinned server contract")
                )
            } catch {
                cliHealth[providerID] = ProviderCLIHealth(installed: true, healthy: false, expectedVersion: configuration.expectedVersion, detail: "CLI version probe failed")
            }
        }
    }

    private func refreshRuntimePreflight() async {
        let capabilities = await adapter.preflight()
        for capability in capabilities {
            guard let providerID = Self.settingsID(capability.kind) else { continue }
            runtimePreflight[providerID] = capability.enabled && capability.reasonUnavailable == nil
        }
    }

    private func snapshot(for providerID: ProviderSettingsID) throws -> ProviderSettingsSnapshot {
        guard let preference = preferences[providerID] else {
            throw ServiceAPIError(code: .notFound, message: "Provider settings are not initialized")
        }
        let definition = Self.definition(providerID)
        let deploymentAllowed = providerID.runtimeKind.map(initiallyEnabled.contains) ?? false
        let preflightVerified = runtimePreflight[providerID] ?? false
        let models = modelCatalogs[providerID] ?? defaultCatalog(for: providerID)
        let connection = connections[providerID]?.record
        let preflight = preflightStatus(
            providerID: providerID,
            preference: preference,
            deploymentAllowed: deploymentAllowed,
            runtimeVerified: preflightVerified,
            connection: connection,
            cli: cliHealth[providerID]
        )
        return ProviderSettingsSnapshot(
            providerID: providerID,
            displayName: definition.displayName,
            category: definition.category,
            summary: definition.summary,
            deploymentAllowed: deploymentAllowed,
            runtimePreflightVerified: preflightVerified,
            effectiveEnabled: preference.enabled && preflight.ready,
            preference: preference,
            cli: providerID.runtimeKind == nil ? nil : cliHealth[providerID] ?? ProviderCLIHealth(installed: false, healthy: false, detail: "CLI health has not been checked"),
            authentication: authenticationStatus(providerID),
            connection: connection,
            preflight: preflight,
            capabilities: definition.capabilities,
            models: models
        )
    }

    private func authenticationStatus(_ providerID: ProviderSettingsID) -> ProviderAuthenticationStatus {
        if let connection = connections[providerID]?.record {
            let expired = connection.expiresAt.map { $0 <= Date() } ?? false
            return ProviderAuthenticationStatus(
                state: connection.state == .connected && !expired ? .authenticated : .attention,
                authenticated: connection.state == .connected && !expired,
                method: connection.authenticationMethod,
                accountLabel: connection.accountLabel,
                expiresAt: connection.expiresAt,
                detail: expired ? "Provider credential has expired" : connection.detail
            )
        }
        if let path = authenticationStatusFiles[providerID],
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let document = try? JSONDecoder.serviceDecoder.decode(SanitizedAuthenticationDocument.self, from: data)
        {
            return ProviderAuthenticationStatus(
                state: document.authenticated ? .authenticated : .attention,
                authenticated: document.authenticated,
                method: document.method,
                expiresAt: document.expiresAt,
                detail: document.authenticated ? "Authenticated" : "Authentication requires attention"
            )
        }
        if let kind = providerID.runtimeKind,
           let source = configurations[kind]?.credentialSourceDirectory,
           FileManager.default.fileExists(atPath: source)
        {
            return ProviderAuthenticationStatus(state: .unknown, authenticated: false, detail: "Credential home is mounted; sanitized account status is unavailable")
        }
        return ProviderAuthenticationStatus(state: .notConfigured, authenticated: false, detail: "Provision credentials on the server")
    }

    private func preflightStatus(providerID: ProviderSettingsID, preference: ProviderSettingsPreference, deploymentAllowed: Bool, runtimeVerified: Bool, connection: ProviderConnectionRecord?, cli: ProviderCLIHealth?) -> ProviderPreflightStatus {
        guard preference.enabled else { return .init(ready: false, reason: .disabled, detail: "Provider is administratively disabled") }
        guard deploymentAllowed else { return .init(ready: false, reason: .deploymentDisabled, detail: "Deployment configuration does not allow this provider runtime") }
        if providerID.runtimeKind != nil, cli?.installed != true {
            return .init(ready: false, reason: .missingExecutable, detail: "Provider executable is missing")
        }
        guard runtimeVerified else { return .init(ready: false, reason: .runtimeUnavailable, detail: cli?.detail ?? "Provider runtime preflight failed") }
        if let connection,
           [.browserLogin, .providerSpecific].contains(connection.authenticationMethod),
           !externallyProvisioned(providerID)
        {
            return .init(ready: false, reason: .missingCredential, detail: "External provider credential source is unavailable")
        }
        if connection == nil {
            guard externallyProvisioned(providerID) else { return .init(ready: false, reason: .missingCredential, detail: "Provider credential is not configured") }
        }
        if connection?.expiresAt.map({ $0 <= Date() }) == true { return .init(ready: false, reason: .invalidCredential, detail: "Provider credential has expired") }
        if connection?.testState == .invalid { return .init(ready: false, reason: .invalidCredential, detail: "Provider rejected the configured credential") }
        if let connection, connection.testState != .valid {
            return .init(ready: false, reason: .authenticationPending, detail: connection.detail ?? "Provider credential requires validation")
        }
        return .init(ready: true, reason: .ready, detail: "Provider is ready")
    }

    private func validateSelection(_ request: UpdateProviderSettingsRequest, providerID: ProviderSettingsID, definition: Definition) throws {
        let models = modelCatalogs[providerID] ?? defaultCatalog(for: providerID)
        let selectedModel: ProviderModelCatalogEntry?
        if let modelID = try normalized(request.defaultModel) {
            guard definition.capabilities.supportsModelSelection,
                  let model = models.first(where: { $0.id == modelID })
            else { throw ServiceAPIError(code: .invalidRequest, message: "Default model is not in the provider catalog") }
            selectedModel = model
        } else {
            selectedModel = nil
        }
        try validateOption(normalized(request.reasoningEffort), allowed: selectedModel?.reasoningEfforts ?? [], capability: definition.capabilities.supportsReasoningEffort, label: "reasoning effort")
        try validateOption(normalized(request.speedMode), allowed: selectedModel?.speedModes ?? [], capability: definition.capabilities.supportsSpeedMode, label: "speed mode")
        try validateOption(normalized(request.serviceTier), allowed: selectedModel?.serviceTiers ?? [], capability: definition.capabilities.supportsServiceTier, label: "service tier")
    }

    private func validateOption(_ value: String?, allowed: [String], capability: Bool, label: String) throws {
        guard let value else { return }
        guard capability, allowed.contains(value) else {
            throw ServiceAPIError(code: .invalidRequest, message: "Selected \(label) is not supported by this model")
        }
    }

    private func loadModelCatalogs() throws -> [ProviderSettingsID: [ProviderModelCatalogEntry]] {
        try modelCatalogFiles.reduce(into: [:]) { result, item in
            let data = try Data(contentsOf: URL(fileURLWithPath: item.value))
            let catalog = try JSONDecoder.serviceDecoder.decode([ProviderModelCatalogEntry].self, from: data)
            guard catalog.count <= 500,
                  Set(catalog.map(\.id)).count == catalog.count,
                  catalog.count(where: \.isProviderDefault) <= 1,
                  catalog.allSatisfy({ validCatalogEntry($0, providerID: item.key) })
            else { throw ServiceAPIError(code: .invalidRequest, message: "Provider model catalog is invalid") }
            result[item.key] = catalog
        }
    }

    private func validCatalogEntry(_ entry: ProviderModelCatalogEntry, providerID: ProviderSettingsID) -> Bool {
        let definition = Self.definition(providerID)
        let safeFields = [entry.id, entry.displayName, entry.description].compactMap(\.self)
        let optionGroups = [entry.reasoningEfforts, entry.speedModes, entry.serviceTiers]
        guard !entry.id.isEmpty,
              entry.id.utf8.count <= 256,
              !entry.displayName.isEmpty,
              entry.displayName.utf8.count <= 256,
              entry.description?.utf8.count ?? 0 <= 1024,
              safeFields.allSatisfy({ safeCatalogText($0) }),
              optionGroups.allSatisfy({ options in
                  options.count <= 64
                      && Set(options).count == options.count
                      && options.allSatisfy { !$0.isEmpty && $0.utf8.count <= 128 && safeCatalogText($0) }
              }),
              definition.capabilities.supportsReasoningEffort || entry.reasoningEfforts.isEmpty,
              definition.capabilities.supportsSpeedMode || entry.speedModes.isEmpty,
              definition.capabilities.supportsServiceTier || entry.serviceTiers.isEmpty
        else { return false }
        return true
    }

    private func safeCatalogText(_ value: String) -> Bool {
        !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !ProviderSecretRedaction.containsLikelySecret(value)
    }

    private func defaultCatalog(for providerID: ProviderSettingsID) -> [ProviderModelCatalogEntry] {
        switch providerID {
        case .codex:
            [
                .init(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", description: "Frontier coding model", isProviderDefault: true, reasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"], serviceTiers: ["fast"]),
                .init(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra", description: "Balanced agentic coding model", reasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"], serviceTiers: ["fast"]),
                .init(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna", description: "Efficient coding model", reasoningEfforts: ["low", "medium", "high", "xhigh", "max"], serviceTiers: ["fast"])
            ]
        case .claudeCompatible:
            [
                .init(id: "claude-fable-5", displayName: "Fable 5", isProviderDefault: true, reasoningEfforts: ["low", "medium", "high", "xhigh", "max"]),
                .init(id: "claude-opus-5", displayName: "Opus 5", reasoningEfforts: ["low", "medium", "high", "xhigh", "max"]),
                .init(id: "claude-sonnet-5", displayName: "Sonnet 5", reasoningEfforts: ["low", "medium", "high", "xhigh", "max"]),
                .init(id: "claude-haiku-4-5-20251001", displayName: "Haiku 4.5")
            ]
        case .cursorACP:
            [.init(id: "auto", displayName: "Auto", description: "Let Cursor choose the best advertised model", isProviderDefault: true)]
        case .openCodeACP, .xAI:
            // These catalogs are provider/account specific. A sanitized
            // server-side catalog file must opt in exact capabilities.
            []
        }
    }

    private struct Definition {
        let displayName: String
        let category: ProviderSettingsCategory
        let summary: String
        let capabilities: ProviderSettingsCapabilities
    }

    private nonisolated static func definition(_ providerID: ProviderSettingsID) -> Definition {
        let external = ProviderAuthFlowDescriptor(kind: .externalProvisioning, displayName: "Server credential provisioning", startable: false, detail: "Mount credentials or a provider key helper on the server; secret values never pass through the portal")
        switch providerID {
        case .codex:
            return Definition(displayName: "Codex", category: .cliProvider, summary: "OpenAI Codex app-server with isolated CODEX_HOME", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: true, supportsSpeedMode: false, supportsServiceTier: true, authenticationMethods: [.apiKey, .enterpriseAccessToken], authFlows: [
                .init(kind: .browserOAuth, displayName: "Browser OAuth", startable: false, detail: "Server-side OAuth adapter seam; not installed in this slice"),
                .init(kind: .deviceCodeBeta, displayName: "Device auth (beta)", startable: false, detail: "Transient owner-fenced driver seam is present; a Codex device driver is not installed"), external
            ]))
        case .claudeCompatible:
            return Definition(displayName: "Claude Code", category: .cliProvider, summary: "Claude-compatible stream JSON with isolated CLAUDE_CONFIG_DIR", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: true, supportsSpeedMode: false, supportsServiceTier: false, authenticationMethods: [.apiKey, .authToken], authFlows: [external]))
        case .openCodeACP:
            return Definition(displayName: "OpenCode", category: .cliProvider, summary: "Provider-specific ACP catalog and authentication", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: false, supportsSpeedMode: false, supportsServiceTier: false, authenticationMethods: [.providerSpecific], authFlows: [external]))
        case .cursorACP:
            return Definition(displayName: "Cursor", category: .cliProvider, summary: "Cursor ACP with browser login or server-side API key", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: false, supportsSpeedMode: false, supportsServiceTier: false, authenticationMethods: [.browserLogin, .apiKey], authFlows: [external]))
        case .xAI:
            return Definition(displayName: "xAI", category: .apiProvider, summary: "API-key-only provider; runtime extraction is pending", capabilities: .init(supportsModelSelection: true, supportsReasoningEffort: true, supportsSpeedMode: false, supportsServiceTier: true, authenticationMethods: [.apiKey], authFlows: [external]))
        }
    }

    private nonisolated static func settingsID(_ kind: ProviderKind) -> ProviderSettingsID? {
        switch kind {
        case .codex: .codex
        case .claudeCompatible: .claudeCompatible
        case .openCodeACP: .openCodeACP
        case .cursorACP: .cursorACP
        case .headlessAdapter, .mcp: nil
        }
    }

    private nonisolated static func validCLIVersionOutput(_ output: String) -> String? {
        guard let firstLine = output.split(whereSeparator: \.isNewline).first else { return nil }
        let value = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 128 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._+-/():"))
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value
    }

    private nonisolated func normalized(_ value: String?) throws -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        guard value.utf8.count <= 512,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !ProviderSecretRedaction.containsLikelySecret(value)
        else { throw ServiceAPIError(code: .invalidRequest, message: "Provider setting is invalid") }
        return value
    }
}
