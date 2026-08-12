import Foundation
import RepoPromptHeadlessRuntime
@testable import RepoPromptServiceHTTP
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

final class ServerSettingsFoundationTests: XCTestCase {
    func testTypedSettingsRoundTripThroughServiceCoders() throws {
        let target = AgentModelTarget(providerID: .codex, modelID: "gpt-5.6-sol", reasoningEffort: "high", pinned: true)
        try assertRoundTrip(AgentModelsProfile(oracle: target, engineer: target, restrictDiscoveryToRoleModels: true))
        try assertRoundTrip(SubagentPermissionSettings(policy: .custom, codex: .readOnly, claude: .autoApproveEdits, openCode: .fullAccess, cursor: .managedDefault))
        try assertRoundTrip(ContextBuilderSettingsProfile(
            budget: 100_000,
            enhancementMode: .augment,
            questionTimeoutSeconds: 120,
            portalClarifyingQuestions: false,
            mcpClarifyingQuestions: true,
            followUpAnalysis: .plan,
            followUpBudget: 80_000,
            prompts: [.init(promptID: UUID(), name: "Planning", instructions: "Produce a bounded plan.", order: 0)]
        ))
        try assertRoundTrip(MCPModelPreset(
            presetID: UUID(),
            name: "Review",
            target: target,
            availability: [.review],
            order: 0
        ))
        try assertRoundTrip(AdvancedServerSettings(historyIdleThresholdMinutes: 10))
        try assertRoundTrip(ProjectSelectionPreset(
            presetID: UUID(),
            projectID: UUID(),
            name: "Core",
            entries: [.init(rootID: UUID(), logicalPath: "Sources", mode: .full)],
            order: 0,
            rowRevision: 1
        ))
    }

    func testSettingsPersistAcrossRestartAndProjectInheritanceIsDeterministic() async throws {
        let database = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { removeSQLiteFiles(database) }
        let projectID = UUID()
        let rootID = UUID()
        let catalogs = StaticProviderCatalog(response: Self.providerCatalog())
        let projects = StaticProjectCatalog(roots: [projectID: [rootID]])
        let attribution = Self.attribution
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

        var store = try await SQLiteServiceStore.open(storage: .file(database.path))
        try await persistProject(projectID: projectID, rootID: rootID, store: store)
        var service = ServerSettingsService(store: store, providerCatalog: catalogs, projectCatalog: projects, now: { timestamp })

        let globalTarget = AgentModelTarget(providerID: .codex, modelID: "gpt-5.6-sol", reasoningEffort: "high", pinned: true)
        let global = try await service.replaceGlobalAgentModels(
            .init(expectedRevision: 0, profile: .init(oracle: globalTarget, restrictDiscoveryToRoleModels: true)),
            attribution: attribution
        )
        XCTAssertEqual(global.globalRevision, 1)
        let inherited = try await service.agentModels(projectID: projectID)
        XCTAssertEqual(inherited.projectMode, .inheritGlobal)
        XCTAssertEqual(inherited.effectiveProfile, global.globalProfile)

        let projectTarget = AgentModelTarget(providerID: .claudeCompatible, modelID: "claude-opus-5", pinned: false)
        let overridden = try await service.replaceProjectAgentModels(
            projectID: projectID,
            request: .init(expectedRevision: 0, mode: .projectOverride, profile: .init(oracle: projectTarget)),
            attribution: attribution
        )
        XCTAssertEqual(overridden.effectiveProfile.oracle, projectTarget)

        do {
            _ = try await service.copyGlobalAgentModelsToProject(
                projectID: projectID,
                request: .init(expectedGlobalRevision: 0, expectedProjectRevision: 1),
                attribution: attribution
            )
            XCTFail("expected stale source revision")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .staleRevision)
        }
        let copied = try await service.copyGlobalAgentModelsToProject(
            projectID: projectID,
            request: .init(expectedGlobalRevision: 1, expectedProjectRevision: 1),
            attribution: attribution
        )
        XCTAssertEqual(copied.projectRevision, 2)
        XCTAssertEqual(copied.effectiveProfile, global.globalProfile)
        do {
            _ = try await service.copyGlobalAgentModelsToProject(
                projectID: projectID,
                request: .init(expectedGlobalRevision: 1, expectedProjectRevision: 1),
                attribution: attribution
            )
            XCTFail("expected stale destination revision")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .staleRevision)
            XCTAssertEqual(error.currentRevision, 2)
        }

        _ = try await service.replaceGlobalContextBuilder(
            .init(expectedRevision: 0, profile: .init(budget: 100_000, prompts: [
                .init(promptID: UUID(), name: "Architecture", instructions: "Inspect the architecture.", order: 4)
            ])),
            attribution: attribution
        )
        let context = try await service.copyGlobalContextBuilderToProject(
            projectID: projectID,
            request: .init(expectedGlobalRevision: 1, expectedProjectRevision: 0),
            attribution: attribution
        )
        XCTAssertEqual(context.effectiveProfile.budget, 100_000)
        XCTAssertEqual(context.effectiveProfile.prompts.first?.order, 0)

        _ = try await service.replaceSubagentPermissions(
            .init(expectedRevision: 0, settings: .init(policy: .custom, codex: .readOnly)),
            attribution: attribution
        )
        _ = try await service.replaceModelPresets(
            .init(expectedRevision: 0, presets: [
                .init(
                    presetID: UUID(),
                    name: "Primary Review",
                    target: globalTarget,
                    availability: [.review, .plan],
                    order: 9
                )
            ]),
            attribution: attribution
        )
        _ = try await service.replaceAdvanced(
            .init(expectedRevision: 0, settings: .init(codeMapsEnabled: false, historyIdleThresholdMinutes: 12)),
            attribution: attribution
        )
        _ = try await service.replaceSelectionPresets(
            projectID: projectID,
            request: .init(expectedRevision: 0, presets: [
                .init(
                    presetID: UUID(),
                    projectID: projectID,
                    name: "Sources",
                    entries: [.init(rootID: rootID, logicalPath: "Sources", mode: .full)],
                    order: 7,
                    rowRevision: 1
                )
            ]),
            attribution: attribution
        )

        try await store.close()
        store = try await SQLiteServiceStore.open(storage: .file(database.path))
        service = ServerSettingsService(store: store, providerCatalog: catalogs, projectCatalog: projects, now: { timestamp })

        let recoveredAgentModels = try await service.agentModels(projectID: projectID)
        XCTAssertEqual(recoveredAgentModels.globalRevision, 1)
        XCTAssertEqual(recoveredAgentModels.projectRevision, 2)
        XCTAssertEqual(recoveredAgentModels.effectiveProfile, global.globalProfile)
        let recoveredContextBuilder = try await service.contextBuilder(projectID: projectID)
        let recoveredSubagents = await service.subagentPermissions()
        let recoveredModelPresets = try await service.modelPresets()
        let recoveredAdvanced = try await service.advanced()
        let recoveredSelectionPresets = try await service.selectionPresets(projectID: projectID)
        let recoveredMetadata = try await store.metadata()
        let operational = try await store.operationalSnapshot()
        XCTAssertEqual(recoveredContextBuilder.projectRevision, 1)
        XCTAssertEqual(recoveredSubagents.settings.policy, .custom)
        XCTAssertEqual(recoveredModelPresets.presets.first?.order, 0)
        XCTAssertFalse(recoveredAdvanced.settings.codeMapsEnabled)
        XCTAssertEqual(recoveredSelectionPresets.presets.first?.name, "Sources")
        XCTAssertEqual(recoveredMetadata.schemaVersion, 6)
        XCTAssertTrue(operational.migrationsValid)
        try await store.close()
    }

    func testStaleMutationHasNoWriteAndAuditContainsOnlyDigestAndAttribution() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: Self.providerCatalog()),
            projectCatalog: StaticProjectCatalog(roots: [:]),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        _ = try await service.replaceAdvanced(
            .init(expectedRevision: 0, settings: .init(codeMapsEnabled: false, historyIdleThresholdMinutes: 17)),
            attribution: Self.attribution
        )
        do {
            _ = try await service.replaceAdvanced(
                .init(expectedRevision: 0, settings: .init(codeMapsEnabled: true, historyIdleThresholdMinutes: 3)),
                attribution: Self.attribution
            )
            XCTFail("expected stale revision")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .staleRevision)
            XCTAssertEqual(error.currentRevision, 1)
        }

        let snapshot = try await service.advanced()
        XCTAssertEqual(snapshot.revision, 1)
        XCTAssertFalse(snapshot.settings.codeMapsEnabled)
        XCTAssertEqual(snapshot.settings.historyIdleThresholdMinutes, 17)
        let audits = try await store.settingsAuditRecords(domain: .advanced, scopeID: "global")
        XCTAssertEqual(audits.count, 1)
        XCTAssertEqual(audits[0].actorID, Self.attribution.actorID)
        XCTAssertEqual(audits[0].payloadDigest.count, 64)
        let auditJSON = String(decoding: try JSONEncoder.serviceEncoder.encode(audits), as: UTF8.self)
        XCTAssertFalse(auditJSON.contains("historyIdleThresholdMinutes"))
        XCTAssertFalse(auditJSON.contains("codeMapsEnabled"))
    }

    func testValidationRejectsSecretsBoundsUnknownModelsAndUnauthorizedRoots() async throws {
        let projectID = UUID()
        let rootID = UUID()
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        try await persistProject(projectID: projectID, rootID: rootID, store: store)
        let service = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: Self.providerCatalog()),
            projectCatalog: StaticProjectCatalog(roots: [projectID: [rootID]])
        )

        do {
            _ = try await service.replaceGlobalContextBuilder(
                .init(expectedRevision: 0, profile: .init(budget: 12_000)),
                attribution: Self.attribution
            )
            XCTFail("budget increment must be enforced")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
        do {
            _ = try await service.replaceGlobalContextBuilder(
                .init(expectedRevision: 0, profile: .init(prompts: [
                    .init(promptID: UUID(), name: "Unsafe", instructions: "Use sk-proj-abcdefghijklmnopqrstuvwxyz0123456789", order: 0)
                ])),
                attribution: Self.attribution
            )
            XCTFail("secret-shaped prompt text must be rejected")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
        do {
            _ = try await service.replaceModelPresets(
                .init(expectedRevision: 0, presets: [
                    .init(
                        presetID: UUID(),
                        name: "Unknown",
                        target: .init(providerID: .codex, modelID: "not-advertised"),
                        availability: [.chat],
                        order: 0
                    )
                ]),
                attribution: Self.attribution
            )
            XCTFail("unknown model must be rejected")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
        do {
            let target = AgentModelTarget(providerID: .codex, modelID: "gpt-5.6-sol", reasoningEffort: "low")
            _ = try await service.replaceModelPresets(
                .init(expectedRevision: 0, presets: [
                    .init(presetID: UUID(), name: "Duplicate", target: target, availability: [.chat], order: 0),
                    .init(presetID: UUID(), name: "duplicate", target: target, availability: [.plan], order: 1)
                ]),
                attribution: Self.attribution
            )
            XCTFail("case-folded duplicate names must be rejected")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
        }
        do {
            _ = try await service.replaceSelectionPresets(
                projectID: projectID,
                request: .init(expectedRevision: 0, presets: [
                    .init(
                        presetID: UUID(),
                        projectID: projectID,
                        name: "Escaped",
                        entries: [.init(rootID: UUID(), logicalPath: "Sources", mode: .full)],
                        order: 0,
                        rowRevision: 1
                    )
                ]),
                attribution: Self.attribution
            )
            XCTFail("foreign root must be rejected")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rootUnauthorized)
        }
    }

    func testLegacyTypedKeysRemainReadableButCannotBeMutated() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        var values = PortalDesktopSettingKey.defaultValues
        values[PortalDesktopSettingKey.contextBuilderBudget.rawValue] = "120000"
        _ = try await store.upsertPortalDesktopSettings(
            .init(revision: 1, values: values, updatedAt: Date()),
            expectedRevision: 0
        )
        let service = PortalDesktopSettingsService(store: store)
        let legacySnapshot = try await service.snapshot()
        XCTAssertEqual(legacySnapshot.values[PortalDesktopSettingKey.contextBuilderBudget.rawValue], "120000")
        XCTAssertEqual(PortalDesktopSettingKey.contextBuilderBudget.mutability, .supersededByTypedSettings)
        XCTAssertTrue(PortalDesktopSettingKey.codexPermissionLevel.isMutable)

        do {
            _ = try await service.update(.init(expectedRevision: 1, changes: [
                PortalDesktopSettingKey.contextBuilderBudget.rawValue: "125000"
            ]))
            XCTFail("legacy typed key must be read-only")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .capabilityMissing)
        }
        let unchanged = try await service.snapshot()
        XCTAssertEqual(unchanged.revision, 1)
    }

    func testRuntimeRouteResolutionContextDefaultsPresetsAndDiscovery() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let projectID = UUID()
        let rootID = UUID()
        try await persistProject(projectID: projectID, rootID: rootID, store: store)
        let service = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: Self.providerCatalog()),
            projectCatalog: StaticProjectCatalog(roots: [projectID: [rootID]])
        )
        let unassigned = try await service.resolveAgentTarget(projectID: projectID, target: .oracle)
        XCTAssertNil(unassigned)
        _ = try await service.applyGlobalAgentModelRecommendations(
            .init(expectedRevision: 0),
            attribution: Self.attribution
        )

        for target in AgentRoutingTarget.allCases {
            let resolved = try await service.resolveAgentTarget(projectID: projectID, target: target)
            let route = try XCTUnwrap(resolved)
            XCTAssertEqual(route.routingTarget, target)
            XCTAssertNotEqual(route.providerID, .openCodeACP)
            XCTAssertFalse(route.usedRecommendationFallback)
        }

        let savedPromptID = UUID()
        _ = try await service.replaceGlobalContextBuilder(
            .init(expectedRevision: 0, profile: .init(
                budget: 120_000,
                enhancementMode: .augment,
                questionTimeoutSeconds: 120,
                portalClarifyingQuestions: true,
                mcpClarifyingQuestions: false,
                followUpAnalysis: .review,
                followUpBudget: 60_000,
                prompts: [.init(promptID: savedPromptID, name: "Safety", instructions: "Preserve compatibility.", order: 0)]
            )),
            attribution: Self.attribution
        )
        let portal = try await service.resolveContextBuilder(projectID: projectID, origin: .portal)
        let mcp = try await service.resolveContextBuilder(
            projectID: projectID,
            origin: .mcp,
            overrides: .init(budget: 80_000, allowClarifyingQuestions: true, selectedPromptIDs: [savedPromptID])
        )
        XCTAssertTrue(portal.allowClarifyingQuestions)
        let defaultMCP = try await service.resolveContextBuilder(projectID: projectID, origin: .mcp)
        XCTAssertFalse(defaultMCP.allowClarifyingQuestions)
        XCTAssertEqual(mcp.budget, 80_000)
        XCTAssertEqual(mcp.questionTimeoutSeconds, 120)
        XCTAssertEqual(mcp.followUpAnalysis, .review)
        let rendered = try await service.renderContextBuilderInstructions("Caller", effective: mcp)
        XCTAssertTrue(rendered.contains("Preserve compatibility."))

        let presetID = UUID()
        _ = try await service.replaceModelPresets(
            .init(expectedRevision: 0, presets: [.init(
                presetID: presetID,
                name: "Oracle Review",
                target: .init(providerID: .codex, modelID: "gpt-5.6-sol", reasoningEffort: "high"),
                availability: [.review],
                order: 0
            )]),
            attribution: Self.attribution
        )
        let presetRoute = try await service.resolveModelPreset(presetID: presetID, availability: .review)
        XCTAssertEqual(presetRoute.providerID, .codex)
        XCTAssertEqual(presetRoute.reasoningEffort, "high")
        let discovery = try await service.modelDiscovery(projectID: projectID)
        XCTAssertEqual(discovery.presets.map(\.presetID), [presetID])
    }

    func testChildCreationEnforcesSafeInheritAndCustomWithExactProviderIdentity() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = StaticProviderCatalog(response: Self.providerCatalog())
        let service = ServerSettingsService(store: store, providerCatalog: catalog, projectCatalog: store)
        let inheritedDefaults = StaticDirectProviderDefaults(values: [
            .codex: .init(mode: "fullAccess", providerSettings: ["test.marker": "codex", "codex.approvalPolicy": "never"]),
            .claudeGLM: .init(mode: "workspaceWrite", providerSettings: ["test.marker": "claude", "claude.backendID": ProviderSettingsID.claudeGLM.rawValue, "claude.permissionMode": "acceptEdits"]),
            .openCodeACP: .init(mode: "fullAccess", providerSettings: ["test.marker": "opencode"]),
            .cursorACP: .init(mode: "fullAccess", providerSettings: ["test.marker": "cursor"])
        ])
        let authority = RepoPromptHeadlessAuthority(
            store: store,
            serverSettings: service,
            directProviderDefaults: inheritedDefaults
        )
        let actor = ExternalActor(goblinUserID: "runtime", username: "runtime", displayName: "Runtime")
        let project = try await authority.createProject(
            input: .init(name: "Runtime", roots: [.init(logicalName: "root", path: root.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "runtime-project",
            requestDigest: "runtime-project"
        )
        let parent = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "runtime-parent",
            requestDigest: "runtime-parent"
        )

        let safe = try await authority.spawnChildSession(
            parentSessionID: parent.sessionID,
            providerSettingsID: .claudeGLM,
            initialPrompt: "safe"
        )
        let safePermissions = try await authority.authoritySessionSnapshot(sessionID: safe.sessionID).permissions
        XCTAssertEqual(safe.providerSettingsID, .claudeGLM)
        XCTAssertEqual(safe.provider, .claudeCompatible)
        XCTAssertEqual(safePermissions.providerSettings["claude.backendID"], ProviderSettingsID.claudeGLM.rawValue)
        XCTAssertEqual(safePermissions.providerSettings["claude.permissionMode"], "default")
        for providerID in [ProviderSettingsID.codex, .openCodeACP, .cursorACP] {
            let child = try await authority.spawnChildSession(parentSessionID: parent.sessionID, providerSettingsID: providerID, initialPrompt: "safe-\(providerID.rawValue)")
            let permissions = try await authority.authoritySessionSnapshot(sessionID: child.sessionID).permissions
            XCTAssertNotEqual(permissions.mode, "fullAccess")
            XCTAssertEqual(permissions.providerSettings["test.marker"], providerID == .openCodeACP ? "opencode" : providerID.rawValue.replacingOccurrences(of: "ACP", with: "").lowercased())
        }

        _ = try await service.replaceSubagentPermissions(
            .init(expectedRevision: 0, settings: .init(policy: .inheritProviderSettings)),
            attribution: Self.attribution
        )
        let inherited = try await authority.spawnChildSession(parentSessionID: parent.sessionID, providerSettingsID: .claudeGLM, initialPrompt: "inherit")
        let inheritedPermissions = try await authority.authoritySessionSnapshot(sessionID: inherited.sessionID).permissions
        XCTAssertEqual(inheritedPermissions.providerSettings["claude.permissionMode"], "acceptEdits")
        for providerID in [ProviderSettingsID.codex, .openCodeACP, .cursorACP] {
            let child = try await authority.spawnChildSession(parentSessionID: parent.sessionID, providerSettingsID: providerID, initialPrompt: "inherit-\(providerID.rawValue)")
            let permissions = try await authority.authoritySessionSnapshot(sessionID: child.sessionID).permissions
            XCTAssertEqual(permissions.mode, "fullAccess")
        }

        _ = try await service.replaceSubagentPermissions(
            .init(expectedRevision: 1, settings: .init(policy: .custom, codex: .readOnly, claude: .fullAccess, openCode: .fullAccess, cursor: .fullAccess)),
            attribution: Self.attribution
        )
        let custom = try await authority.spawnChildSession(parentSessionID: parent.sessionID, providerSettingsID: .claudeGLM, initialPrompt: "custom")
        let customPermissions = try await authority.authoritySessionSnapshot(sessionID: custom.sessionID).permissions
        XCTAssertEqual(customPermissions.mode, "fullAccess")
        XCTAssertEqual(customPermissions.providerSettings["claude.permissionMode"], "bypassPermissions")
        XCTAssertEqual(customPermissions.providerSettings["provider.settingsID"], ProviderSettingsID.claudeGLM.rawValue)
        for (providerID, expectedMode) in [
            (ProviderSettingsID.codex, "readOnly"),
            (.openCodeACP, "fullAccess"),
            (.cursorACP, "fullAccess")
        ] {
            let child = try await authority.spawnChildSession(parentSessionID: parent.sessionID, providerSettingsID: providerID, initialPrompt: "custom-\(providerID.rawValue)")
            let permissions = try await authority.authoritySessionSnapshot(sessionID: child.sessionID).permissions
            XCTAssertEqual(permissions.mode, expectedMode)
        }
    }

    func testContextBuilderAndOracleConsumeFrozenRoutesDefaultsAndPreset() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/test-workspaces/context-runtime-\(UUID().uuidString)")
        let artifacts = FileManager.default.temporaryDirectory.appendingPathComponent("context-artifacts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: artifacts)
        }
        try "struct Runtime {}".write(to: root.appendingPathComponent("Runtime.swift"), atomically: true, encoding: .utf8)
        let catalog = StaticProviderCatalog(response: Self.providerCatalog())
        let service = ServerSettingsService(store: store, providerCatalog: catalog, projectCatalog: store)
        let contextRuntime = RecordingContextBuilderRuntime()
        let oracleRuntime = RecordingOracleRuntime()
        let runtimeDefaults = StaticDirectProviderDefaults(values: [
            .claudeGLM: .init(mode: "workspaceWrite", providerSettings: ["claude.backendID": ProviderSettingsID.claudeGLM.rawValue])
        ])
        let authority = try RepoPromptHeadlessAuthority(
            store: store,
            artifactService: ArtifactRuntimeService(baseDirectory: artifacts.path),
            contextBuilderRuntime: contextRuntime,
            oracleRuntime: oracleRuntime,
            serverSettings: service,
            directProviderDefaults: runtimeDefaults
        )
        let actor = ExternalActor(goblinUserID: "context", username: "context", displayName: "Context")
        let project = try await authority.createProject(
            input: .init(name: "Context", roots: [.init(logicalName: "root", path: root.resolvingSymlinksInPath().path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "context-project",
            requestDigest: "context-project"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .claudeCompatible, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "context-session",
            requestDigest: "context-session"
        )
        _ = try await service.applyGlobalAgentModelRecommendations(
            .init(expectedRevision: 0),
            attribution: Self.attribution
        )
        _ = try await service.replaceGlobalAgentModels(
            .init(expectedRevision: 1, profile: .init(
                contextBuilder: .init(providerID: .claudeGLM, modelID: "claude-sonnet-5")
            )),
            attribution: Self.attribution
        )
        let promptID = UUID()
        _ = try await service.replaceGlobalContextBuilder(
            .init(expectedRevision: 0, profile: .init(
                budget: 100_000,
                enhancementMode: .augment,
                questionTimeoutSeconds: 60,
                portalClarifyingQuestions: true,
                mcpClarifyingQuestions: false,
                followUpAnalysis: .plan,
                followUpBudget: 50_000,
                prompts: [.init(promptID: promptID, name: "Stored", instructions: "Stored instruction", order: 0)]
            )),
            attribution: Self.attribution
        )
        let presetID = UUID()
        _ = try await service.replaceModelPresets(
            .init(expectedRevision: 0, presets: [.init(
                presetID: presetID,
                name: "Review preset",
                target: .init(providerID: .codex, modelID: "gpt-5.6-sol", reasoningEffort: "high"),
                availability: [.review],
                order: 0
            )]),
            attribution: Self.attribution
        )

        let result = try await authority.runContextBuilder(
            sessionID: session.sessionID,
            input: .init(expectedSelectionRevision: 1, instructions: "Caller"),
            actor: actor,
            origin: .mcp
        )
        XCTAssertNotNil(result.followUpArtifactID)
        let recordedContextRequest = await contextRuntime.lastRequest()
        let contextRequest = try XCTUnwrap(recordedContextRequest)
        XCTAssertEqual(contextRequest.tokenBudget, 100_000)
        XCTAssertFalse(contextRequest.allowClarifyingQuestions)
        XCTAssertTrue(contextRequest.instructions.contains("Stored instruction"))
        XCTAssertEqual(contextRequest.providerSettingsID, .claudeGLM)
        XCTAssertEqual(contextRequest.providerSettings["claude.backendID"], ProviderSettingsID.claudeGLM.rawValue)
        let followUpRequests = await oracleRuntime.requests()
        let followUpRequest = try XCTUnwrap(followUpRequests.first)
        XCTAssertEqual(followUpRequest.tokenBudget, 50_000)
        XCTAssertEqual(followUpRequest.mode, "plan")

        let oracle = try await authority.askOracle(
            sessionID: session.sessionID,
            input: .init(chatID: nil, prompt: "Review", contextMode: "review", modelPresetID: presetID),
            actor: actor
        )
        let presetRequests = await oracleRuntime.requests()
        let presetRequest = try XCTUnwrap(presetRequests.last)
        XCTAssertEqual(presetRequest.providerSettingsID, .codex)
        XCTAssertEqual(presetRequest.model, "gpt-5.6-sol")
        XCTAssertEqual(presetRequest.reasoningEffort, "high")
        let chat = try await authority.oracleChatState(sessionID: session.sessionID, chatID: oracle.chatID)
        XCTAssertEqual(chat.providerSettingsID, .codex)
        XCTAssertNotNil(chat.providerSettings)
    }

    func testAdvancedSettingsChangeNextScanAndGateCodeMapsAndHistoryDefault() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("advanced-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "ignored.swift\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "needle".write(to: root.appendingPathComponent("ignored.swift"), atomically: true, encoding: .utf8)
        try "needle".write(to: root.appendingPathComponent("visible.swift"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)

        let service = ServerSettingsService(
            store: store,
            providerCatalog: StaticProviderCatalog(response: Self.providerCatalog()),
            projectCatalog: store
        )
        let authority = RepoPromptHeadlessAuthority(store: store, serverSettings: service)
        let actor = ExternalActor(goblinUserID: "advanced", username: "advanced", displayName: "Advanced")
        let project = try await authority.createProject(
            input: .init(name: "Advanced", roots: [.init(logicalName: "root", path: root.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "advanced-project",
            requestDigest: "advanced-project"
        )
        let rootID = try XCTUnwrap(project.roots.first?.rootID)
        let initialHits = try await authority.projectSearch(projectID: project.projectID, request: .init(rootID: rootID, query: "needle"))
        XCTAssertEqual(initialHits.map(\.logicalPath), ["visible.swift"])

        _ = try await service.replaceAdvanced(
            .init(expectedRevision: 0, settings: .init(
                respectRepoIgnore: false,
                showEmptyFolders: false,
                codeMapsEnabled: false,
                historyIdleThresholdMinutes: 14
            )),
            attribution: Self.attribution
        )
        let nextHits = try await authority.projectSearch(projectID: project.projectID, request: .init(rootID: rootID, query: "needle"))
        XCTAssertEqual(Set(nextHits.map(\.logicalPath)), Set(["ignored.swift", "visible.swift"]))
        let tree = try await authority.projectTree(projectID: project.projectID, request: .init(rootID: rootID))
        XCTAssertFalse(tree.contains(where: { $0.logicalPath == "empty" }))
        let storedThreshold = try await authority.historyIdleThresholdMinutes(explicit: nil)
        let explicitThreshold = try await authority.historyIdleThresholdMinutes(explicit: 2)
        XCTAssertEqual(storedThreshold, 14)
        XCTAssertEqual(explicitThreshold, 2)
        do {
            _ = try await authority.projectCodeMap(projectID: project.projectID, request: .init(rootID: rootID, logicalPath: "visible.swift"))
            XCTFail("code maps should be rejected while disabled")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .capabilityMissing)
        }
    }

    private func assertRoundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try JSONEncoder.serviceEncoder.encode(value)
        let decoded = try JSONDecoder.serviceDecoder.decode(T.self, from: data)
        XCTAssertEqual(decoded, value, file: file, line: line)
    }

    private func persistProject(projectID: UUID, rootID: UUID, store: SQLiteServiceStore) async throws {
        let actor = ExternalActor(goblinUserID: "settings-test", username: "settings-test", displayName: "Settings Test")
        let project = ProjectSnapshot(
            projectID: projectID,
            name: "Settings",
            creator: actor,
            state: .active,
            roots: [.init(rootID: rootID, logicalName: "root", canonicalPath: "/tmp/settings-root", writable: true)],
            revision: 1,
            cursor: try await store.nextCursor()
        )
        _ = try await store.persistProject(project, eventType: .projectCreated, actor: actor, correlationID: UUID(), idempotency: nil)
    }

    private func removeSQLiteFiles(_ database: URL) {
        try? FileManager.default.removeItem(at: database)
        try? FileManager.default.removeItem(atPath: database.path + "-wal")
        try? FileManager.default.removeItem(atPath: database.path + "-shm")
    }

    private static let attribution = SettingsMutationAttribution(
        actorID: "portal-test",
        actorLabel: "Portal Test",
        channel: "portal-test"
    )

    private static func providerCatalog() -> ProviderSettingsCatalogResponse {
        .init(providers: [
            provider(
                .codex,
                models: [.init(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", reasoningEfforts: ["low", "medium", "high"])]
            ),
            provider(
                .claudeCompatible,
                models: [
                    .init(id: "claude-opus-5", displayName: "Claude Opus 5"),
                    .init(id: "claude-sonnet-5", displayName: "Claude Sonnet 5", reasoningEfforts: ["high"]),
                    .init(id: "claude-haiku-5", displayName: "Claude Haiku 5")
                ]
            ),
            provider(
                .claudeGLM,
                models: [.init(id: "claude-sonnet-5", displayName: "Claude Sonnet 5")]
            ),
            provider(
                .cursorACP,
                models: [
                    .init(id: "auto", displayName: "Auto"),
                    .init(id: "composer-2", displayName: "Composer 2")
                ]
            )
        ])
    }

    private static func provider(_ id: ProviderSettingsID, models: [ProviderModelCatalogEntry]) -> ProviderSettingsSnapshot {
        .init(
            providerID: id,
            displayName: id.rawValue,
            category: .cliProvider,
            summary: "test",
            deploymentAllowed: true,
            runtimePreflightVerified: true,
            effectiveEnabled: true,
            preference: .init(providerID: id, enabled: true),
            cli: nil,
            authentication: .init(state: .authenticated, authenticated: true),
            capabilities: .init(
                supportsModelSelection: true,
                supportsReasoningEffort: true,
                supportsSpeedMode: false,
                supportsServiceTier: false,
                authenticationMethods: [],
                authFlows: []
            ),
            models: models
        )
    }
}

private struct StaticProviderCatalog: ServerSettingsProviderCatalogProviding {
    let response: ProviderSettingsCatalogResponse

    func serverSettingsProviderCatalog() async throws -> ProviderSettingsCatalogResponse { response }
}

private actor RecordingContextBuilderRuntime: ContextBuilderRuntimeService {
    private var request: ContextBuilderRuntimeRequest?

    func propose(_ request: ContextBuilderRuntimeRequest) async throws -> ContextBuilderRuntimeProposal {
        self.request = request
        return .init(
            selection: request.workspace.selection.entries,
            response: "context response",
            providerSessionID: "context-provider-session",
            rawProviderOutput: "context response"
        )
    }

    func lastRequest() -> ContextBuilderRuntimeRequest? { request }
}

private actor RecordingOracleRuntime: OracleRuntimeService {
    private var captured: [OracleRuntimeRequest] = []

    func ask(_ request: OracleRuntimeRequest) async throws -> OracleRuntimeResult {
        captured.append(request)
        return .init(
            response: "oracle response",
            providerSessionID: "oracle-provider-session",
            transcriptEntries: []
        )
    }

    func requests() -> [OracleRuntimeRequest] { captured }
}

private struct StaticDirectProviderDefaults: DirectProviderRuntimeDefaultsProviding {
    let values: [ProviderSettingsID: DirectProviderRuntimeDefaults]

    func directProviderRuntimeDefaults(for providerID: ProviderSettingsID) async throws -> DirectProviderRuntimeDefaults {
        values[providerID] ?? .init(mode: "workspaceWrite", providerSettings: [:])
    }
}

private struct StaticProjectCatalog: ServerSettingsProjectCatalogProviding {
    let roots: [UUID: Set<UUID>]

    func serverSettingsRootIDs(projectID: UUID) async throws -> Set<UUID> {
        guard let roots = roots[projectID] else {
            throw ServiceAPIError(code: .notFound, message: "Project not found")
        }
        return roots
    }
}
