import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import RepoPromptAgentRuntimeCore
@testable import RepoPromptHeadlessRuntime
@testable import RepoPromptServiceHTTP
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

private func testIdentity() -> CanonicalTurnIdentity {
    .init(requestAnchorID: UUID(), runID: UUID(), generation: 1, turnEpoch: 1, turnID: UUID(), responseSpanID: UUID())
}

private func testConfiguration(at date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> EffectiveTurnConfigurationRecord {
    .init(
        catalogRevision: "catalog-v1",
        providerID: .codex,
        modelID: "gpt-5.6-sol",
        providerRawModelValue: "gpt-5.6-sol-high",
        effortID: "high",
        permissionID: "codex.workspaceWrite",
        toolValues: ["codex.bash": .boolean(true), "codex.mcpServers": .choices(["repoprompt"])],
        capabilityDigest: "capability-v1",
        actorID: "actor-1",
        acceptedAt: date
    )
}

private func tinyPNG() -> Data {
    Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl9sAAAAASUVORK5CYII=")!
}

final class AgentComposerCatalogTests: XCTestCase {
    func testProviderMatrixAndNormalizationFixtureAreExact() throws {
        XCTAssertEqual(AgentComposerProviderMatrix.entries.map(\.providerID), [.codex, .claudeCompatible, .claudeGLM, .claudeKimi, .claudeCustom, .openCodeACP, .cursorACP, .xAI])
        XCTAssertEqual(AgentComposerProviderMatrix.liveFreshnessSeconds, 900)
        XCTAssertEqual(AgentComposerProviderMatrix.persistedFallbackMaximumAgeSeconds, 86_400)
        XCTAssertNil(AgentModelIdentityNormalizer.normalize(providerID: .codex, rawModelID: "Default"))
        let normalized = try XCTUnwrap(AgentModelIdentityNormalizer.normalize(providerID: .codex, rawModelID: "gpt-5.6-sol-high"))
        XCTAssertEqual(normalized.modelID, "gpt-5.6-sol")
        XCTAssertEqual(normalized.effortID, "high")
        XCTAssertEqual(normalized.displayName, "5.6 Sol")

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Fixtures/AgentParity/v1/provider-matrix.json"))) as? [String: Any]
        XCTAssertEqual((object?["providers"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, AgentComposerProviderMatrix.entries.map { $0.providerID.rawValue })
    }

    func testCodexAdapterRejectsUnknownControlsAndKeepsRequiredRepoPromptMCP() throws {
        let model = ProviderModelDescriptor(providerID: .codex, modelID: "gpt-5.6-sol", providerRawValue: "gpt-5.6-sol-high", displayName: "GPT-5.6 Sol", supportedEffortIDs: ["high"], defaultEffortID: "high", capabilities: .init(nativeImages: true, steering: true))
        let adapter = CodexTurnConfigurationAdapter()
        let compiled = try adapter.compile(.init(providerID: .codex, model: model, effortID: "high", permissionID: "codex.workspaceWrite", toolValues: ["codex.mcpServers": .choices([])]))
        XCTAssertEqual(compiled.providerRawModelValue, "gpt-5.6-sol-high")
        XCTAssertEqual(compiled.normalizedToolValues["codex.mcpServers"], .choices(["repoprompt"]))
        XCTAssertThrowsError(try adapter.compile(.init(providerID: .codex, model: model, toolValues: ["codex.unknown": .boolean(true)])))
    }
}

final class AgentComposerWireContractTests: XCTestCase {
    func testClosedUnionsRoundTripAndRejectUnknownDiscriminator() throws {
        let value = ComposerControlWire.multiChoice(common: .init(id: "codex.mcpServers", displayName: "MCP servers", required: true), selectedIDs: ["repoprompt"], choices: [.init(id: "repoprompt", displayName: "RepoPrompt")])
        XCTAssertEqual(try JSONDecoder.serviceDecoder.decode(ComposerControlWire.self, from: JSONEncoder.serviceEncoder.encode(value)), value)
        XCTAssertThrowsError(try JSONDecoder.serviceDecoder.decode(ComposerControlValueWire.self, from: Data(#"{"type":"text","value":true}"#.utf8)))
    }

    func testLegacyModelCatalogPayloadStillDecodes() throws {
        let legacy = Data(#"{"id":"gpt-5.6-sol","provider":"codex","displayName":"Sol","enabled":true}"#.utf8)
        let decoded = try JSONDecoder.serviceDecoder.decode(ModelCatalogItem.self, from: legacy)
        XCTAssertEqual(decoded.id, "gpt-5.6-sol")
        XCTAssertNil(decoded.providerID)
        XCTAssertNil(decoded.supportedEffortIDs)
    }

    func testSessionSnapshotAgentStateFieldsAreAdditiveAndVersioned() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionID = UUID(), projectID = UUID(), runID = UUID()
        let actor = ExternalActor(goblinUserID: "actor-1", username: "actor", displayName: "Actor")
        let configuration = EffectiveTurnConfigurationWireSnapshot(testConfiguration(at: now))
        let defaults = SessionNextTurnDefaultsWireSnapshot(sessionID: sessionID, revision: 3, configuration: configuration, updatedAt: now)
        let presentation = RunPresentationWireSnapshot(sessionID: sessionID, runID: runID, generation: 2, turnEpoch: 2, phase: .waiting, phaseRevision: 4, runningStatusCode: "awaiting_input", runStartedAt: now, priorActivePhase: .working)
        let enriched = SessionSnapshot(sessionID: sessionID, projectID: projectID, parentSessionID: nil, rootSessionID: sessionID, creator: actor, provider: .codex, model: "gpt-5.6-sol-high", visibility: .privateSession, state: .running, runGeneration: 2, turnEpoch: 2, revision: 7, transcript: [], interactions: [], cursor: .init(storeID: UUID(), globalSequence: 9), effectiveTurnConfiguration: configuration, nextTurnDefaults: defaults, runPresentation: presentation)
        let decoded = try JSONDecoder.serviceDecoder.decode(SessionSnapshot.self, from: JSONEncoder.serviceEncoder.encode(enriched))
        XCTAssertEqual(decoded.effectiveTurnConfiguration?.schemaVersion, 1)
        XCTAssertEqual(decoded.nextTurnDefaults?.revision, 3)
        XCTAssertEqual(decoded.runPresentation?.phaseRevision, 4)
        XCTAssertEqual(decoded.runPresentation?.phase, .waiting)

        let legacy = SessionSnapshot(sessionID: sessionID, projectID: projectID, parentSessionID: nil, rootSessionID: sessionID, creator: actor, provider: .codex, model: nil, visibility: .privateSession, state: .idle, runGeneration: 0, turnEpoch: 0, revision: 1, transcript: [], interactions: [], cursor: .init(storeID: UUID(), globalSequence: 1))
        let legacyDecoded = try JSONDecoder.serviceDecoder.decode(SessionSnapshot.self, from: JSONEncoder.serviceEncoder.encode(legacy))
        XCTAssertNil(legacyDecoded.effectiveTurnConfiguration)
        XCTAssertNil(legacyDecoded.nextTurnDefaults)
        XCTAssertNil(legacyDecoded.runPresentation)
    }
}

final class AgentComposerAttachmentStoreTests: XCTestCase {
    func testRasterOwnershipExpiryPreviewAndPreparationLease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let attachments = try AgentComposerAttachmentStore(store: store, configuration: .init(stagingRoot: root.appendingPathComponent("staged").path, acceptedRoot: root.appendingPathComponent("accepted").path, maximumStagedBytesPerActor: 512, maximumGlobalStagedBytes: 1_024, minimumFreeBytes: 0))
        let projectID = UUID()
        let staged = try await attachments.stage(data: tinyPNG(), displayName: "../bad\u{0}name.png", declaredMediaType: "image/png", actorID: "owner", projectID: projectID)
        XCTAssertEqual(staged.pixelWidth, 1)
        XCTAssertFalse(staged.displayName.contains("/"))
        let foreignResolution = try await attachments.resolve(attachmentIDs: [staged.attachmentID], actorID: "other", projectID: projectID)
        XCTAssertEqual(foreignResolution.first?.errorCode, "resource_owner_mismatch")
        let wrongProjectResolution = try await attachments.resolve(attachmentIDs: [staged.attachmentID], actorID: "owner", projectID: UUID())
        XCTAssertEqual(wrongProjectResolution.first?.errorCode, "resource_context_mismatch")
        let opaqueResolution = try await attachments.resolve(attachmentIDs: [staged.attachmentID], actorID: "other", projectID: UUID())
        XCTAssertEqual(opaqueResolution.first?.errorCode, "forbidden")
        let expiring = try await attachments.stage(data: tinyPNG(), displayName: "expired.png", declaredMediaType: "image/png", actorID: "owner", projectID: projectID, now: Date(timeIntervalSince1970: 100))
        let expiredResolution = try await attachments.resolve(attachmentIDs: [expiring.attachmentID], actorID: "owner", projectID: projectID, now: Date(timeIntervalSince1970: 100 + 86_401))
        XCTAssertEqual(expiredResolution.first?.errorCode, "expired_resource")
        do {
            _ = try await attachments.preview(attachmentID: staged.attachmentID, actorID: "other", projectID: projectID)
            XCTFail("Cross-owner preview must remain opaque")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .notFound)
        }
        let preview = try await attachments.preview(attachmentID: staged.attachmentID, actorID: "owner", projectID: projectID)
        XCTAssertEqual(preview.1, tinyPNG())

        do {
            _ = try await attachments.prepareAcceptance(attachmentIDs: [staged.attachmentID], submissionID: UUID(), actorID: "other", projectID: projectID, sessionID: UUID(), turnID: UUID(), supportsNativeImages: true)
            XCTFail("Cross-owner claim must fail with a stable code")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .resourceOwnerMismatch)
        }
        do {
            _ = try await attachments.prepareAcceptance(attachmentIDs: [staged.attachmentID], submissionID: UUID(), actorID: "owner", projectID: UUID(), sessionID: UUID(), turnID: UUID(), supportsNativeImages: true)
            XCTFail("Cross-project claim must fail with a stable code")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .resourceContextMismatch)
        }
        do {
            _ = try await attachments.prepareAcceptance(attachmentIDs: [expiring.attachmentID], submissionID: UUID(), actorID: "owner", projectID: projectID, sessionID: UUID(), turnID: UUID(), supportsNativeImages: true)
            XCTFail("Expired claim must fail with a stable code")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .expiredResource)
        }

        let submissionID = UUID(), sessionID = UUID(), turnID = UUID()
        let manifest = try await attachments.prepareAcceptance(attachmentIDs: [staged.attachmentID], submissionID: submissionID, actorID: "owner", projectID: projectID, sessionID: sessionID, turnID: turnID, supportsNativeImages: true)
        XCTAssertEqual(manifest.attachments.map(\.attachmentID), [staged.attachmentID])
        XCTAssertEqual(manifest.nativeImages.count, 1)
        try await attachments.releasePreparation(submissionID: submissionID)
        let released = try await store.composerAttachment(attachmentID: staged.attachmentID)
        XCTAssertNil(released?.leaseSubmissionID)
        try await store.close()
    }

    func testRejectsMediaMismatchAndActorQuota() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let attachments = try AgentComposerAttachmentStore(store: store, configuration: .init(stagingRoot: root.appendingPathComponent("staged").path, acceptedRoot: root.appendingPathComponent("accepted").path, maximumStagedBytesPerActor: tinyPNG().count, maximumGlobalStagedBytes: 1_000, minimumFreeBytes: 0))
        await XCTAssertThrowsErrorAsync { try await attachments.stage(data: tinyPNG(), displayName: "x.jpg", declaredMediaType: "image/jpeg", actorID: "a", projectID: UUID()) }
        _ = try await attachments.stage(data: tinyPNG(), displayName: "x.png", declaredMediaType: nil, actorID: "a", projectID: UUID())
        await XCTAssertThrowsErrorAsync { try await attachments.stage(data: tinyPNG(), displayName: "y.png", declaredMediaType: nil, actorID: "a", projectID: UUID()) }
        try await store.close()
    }
}

private struct TestTaggedResolver: AgentTurnTaggedFileResolving {
    func resolve(_ reference: ComposerTaggedFileReferenceWire, projectID: UUID, sessionID: UUID?) async throws -> ResolvedTaggedFile {
        .init(reference: reference, logicalLabel: reference.logicalPath, content: "let fixture = true")
    }
}

private struct TestSuggestionResolver: AgentTurnSuggestionResolving {
    func resolve(_ token: ComposerResolvedSuggestionTokenWire, providerID: ProviderSettingsID, catalogRevision: String) async throws -> ResolvedComposerSuggestion {
        token.kind == .skill ? .init(token: token, expansion: "skill instructions") : .init(token: token, nativeInvocation: "native invocation")
    }
}

final class AgentTurnIntentCompilerTests: XCTestCase {
    func testDeterministicSectionOrderAndSeparateNativeImages() async throws {
        let identity = testIdentity(), config = testConfiguration(), attachmentID = UUID()
        let file = ComposerTaggedFileReferenceWire(rootID: UUID(), logicalPath: "Sources/A.swift", displayName: "A.swift")
        let skill = ComposerResolvedSuggestionTokenWire(kind: .skill, id: "review", insertionText: "/review")
        let command = ComposerResolvedSuggestionTokenWire(kind: .nativeCommand, id: "compact", insertionText: "/compact")
        let wireAttachment = ComposerAttachmentWire(attachmentID: attachmentID, displayName: "x.png", mediaType: "image/png", byteSize: tinyPNG().count, digest: "digest", pixelWidth: 1, pixelHeight: 1, lifecycle: .staged)
        let native = ProviderNativeImageDescriptor(attachmentID: attachmentID, mediaType: "image/png", byteSize: tinyPNG().count, digest: "digest", filePath: "/private/accepted/x.png")
        let provider = CompiledProviderTurnConfiguration(runtimeKind: .codex, providerRawModelValue: "gpt-5.6-sol-high", executionPolicy: .init(), supportsNativeImages: true, normalizedToolValues: [:])
        let compiler = AgentTurnIntentCompiler(taggedFiles: TestTaggedResolver(), suggestions: TestSuggestionResolver())
        let result = try await compiler.compile(.init(projectID: UUID(), sessionID: UUID(), identity: identity, content: .init(text: "literal text", attachmentIDs: [attachmentID], taggedFiles: [file], resolvedSuggestionTokens: [skill, command]), effectiveConfiguration: config, providerConfiguration: provider, attachmentManifest: .init(attachments: [wireAttachment], nativeImages: [native]), continuationContext: "handoff", providerPromptWrapper: "wrapper", workflowGuidance: "workflow", goalGuidance: "goal"))
        let prompt = result.providerInput.prompt
        let markers = ["continuation-context", "provider-instructions", "workflow-guidance", "goal-guidance", "skill review", "native command compact", "tagged-file", "user-request"]
        let positions = markers.compactMap { prompt.range(of: $0)?.lowerBound }.map { prompt.distance(from: prompt.startIndex, to: $0) }
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertEqual(result.providerInput.nativeImages, [native])
        XCTAssertFalse(result.canonicalUserTurn.text.contains("skill instructions"))
    }

    func testStructuredFirstTurnFreezesSelectedMessageContextForCanonicalAndProviderInput() async throws {
        let context = SelectedMessageContext(source: "goblin-explicit-selection", messages: [
            .init(roomID: "room-1", messageID: "message-1", text: "Exact selected chat text", senderID: "sender-1", timestamp: "2026-08-12T12:00:00Z", revision: "7", threadID: "thread-1")
        ])
        let provider = CompiledProviderTurnConfiguration(runtimeKind: .codex, providerRawModelValue: "gpt-5.6-sol-high", executionPolicy: .init(), supportsNativeImages: true, normalizedToolValues: [:])
        let compiler = AgentTurnIntentCompiler()
        let result = try await compiler.compile(.init(projectID: UUID(), sessionID: nil, identity: testIdentity(), content: .init(text: "Investigate the regression"), selectedMessageContext: context, effectiveConfiguration: testConfiguration(), providerConfiguration: provider))
        let frozen = context.frozenPrompt(userPrompt: "Investigate the regression")
        XCTAssertEqual(result.canonicalUserTurn.text, frozen)
        XCTAssertEqual(result.providerInput.prompt, frozen)
        XCTAssertTrue(result.canonicalUserTurn.taggedFiles.isEmpty)
    }

    func testTextOnlyAdapterRejectsAttachmentBeforeAcceptance() async throws {
        let attachmentID = UUID()
        let wire = ComposerAttachmentWire(attachmentID: attachmentID, displayName: "x.png", mediaType: "image/png", byteSize: 24, digest: "d", pixelWidth: 1, pixelHeight: 1, lifecycle: .staged)
        let native = ProviderNativeImageDescriptor(attachmentID: attachmentID, mediaType: "image/png", byteSize: 24, digest: "d", filePath: "/x")
        let compiler = AgentTurnIntentCompiler()
        let provider = CompiledProviderTurnConfiguration(runtimeKind: .openCodeACP, providerRawModelValue: "model", executionPolicy: .init(), supportsNativeImages: false, normalizedToolValues: [:])
        await XCTAssertThrowsErrorAsync { try await compiler.compile(.init(projectID: UUID(), sessionID: nil, identity: testIdentity(), content: .init(text: "", attachmentIDs: [attachmentID]), effectiveConfiguration: testConfiguration(), providerConfiguration: provider, attachmentManifest: .init(attachments: [wire], nativeImages: [native]))) }
    }
}

final class AgentSubmissionCoordinatorTests: XCTestCase {
    func testAtomicAcceptanceStoresExactReceiptAndReplaysPreparedWinner() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let now = Date(timeIntervalSince1970: 1_700_000_000), identity = testIdentity(), sessionID = UUID(), submissionID = UUID()
        let config = testConfiguration(at: now)
        let canonical = CanonicalUserTurn(identity: identity, text: "hello", suggestionTokens: [], taggedFiles: [], attachments: [], effectiveConfiguration: config)
        let record = AgentSubmissionRecord(submissionID: submissionID, actorID: "actor-1", targetKey: sessionID.uuidString, operation: "submitTurn", publicKey: submissionID.uuidString.lowercased(), requestDigest: "request-digest", state: .preparing, sessionID: sessionID, identity: identity, preparedJSON: Data("prepared".utf8), compiledInputJSON: Data("compiled".utf8), createdAt: now, updatedAt: now)
        _ = try await store.prepareAgentSubmission(record)
        let receipt = SubmissionReceipt(submissionID: submissionID, acceptedAt: now, operation: "submitTurn", sessionID: sessionID, sessionRevision: 2, requestAnchorID: identity.requestAnchorID, runID: identity.runID, generation: identity.generation, turnEpoch: identity.turnEpoch, runPhase: "preparing", runStartedAt: now, selectedConfiguration: .init(catalogRevision: config.catalogRevision, providerID: config.providerID, modelID: config.modelID, effortID: config.effortID, permissionID: config.permissionID))
        _ = try await store.commitAgentSubmission(record: record, turn: .init(sessionID: sessionID, identity: identity, firstSequence: 1, lastSequence: 1, canonicalUserTurnJSON: JSONEncoder.serviceEncoder.encode(canonical), effectiveConfiguration: config, createdAt: now, acceptedAt: now), nextDefaults: .init(sessionID: sessionID, revision: 1, configuration: config, updatedAt: now), runPresentation: .init(sessionID: sessionID, runID: identity.runID, generation: 1, turnEpoch: 1, phase: .preparing, phaseRevision: 1, runStartedAt: now), receipt: receipt)
        let fetchedAccepted = try await store.agentSubmission(submissionID: submissionID)
        let accepted = try XCTUnwrap(fetchedAccepted)
        XCTAssertEqual(accepted.state, .accepted)
        XCTAssertEqual(accepted.receiptJSON, try JSONEncoder.serviceEncoder.encode(receipt))
        let replayed = try await store.prepareAgentSubmission(record)
        XCTAssertEqual(replayed.submissionID, submissionID)
        let turns = try await store.semanticTurns(sessionID: sessionID)
        XCTAssertEqual(turns.count, 1)
        let persistedConfiguration = try await store.effectiveTurnConfiguration(turnID: identity.turnID)
        XCTAssertNotNil(persistedConfiguration)
        try await store.close()
    }
}

final class AgentSemanticActivityLedgerTests: XCTestCase {
    func testActivityAndToolUpdatesAreMonotonic() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let now = Date(), identity = testIdentity(), sessionID = UUID(), activityID = UUID()
        let newer = SemanticActivityRecord(activityID: activityID, sessionID: sessionID, identity: identity, canonicalSequence: 3, revision: 2, kind: .assistant, content: "complete", createdAt: now, updatedAt: now)
        let older = SemanticActivityRecord(activityID: activityID, sessionID: sessionID, identity: identity, canonicalSequence: 2, revision: 1, kind: .assistant, content: "partial", createdAt: now, updatedAt: now)
        try await store.upsertSemanticActivity(newer)
        try await store.upsertSemanticActivity(older)
        let persistedActivity = try await store.semanticActivity(activityID: activityID)
        XCTAssertEqual(persistedActivity?.content, "complete")
        let finished = SemanticToolRecord(executionID: "tool-1", activityID: activityID, turnID: identity.turnID, sessionID: sessionID, canonicalSequence: 4, revision: 2, normalizedName: "read_file", status: .success, displayResult: "ok", createdAt: now, updatedAt: now)
        let started = SemanticToolRecord(executionID: "tool-1", activityID: activityID, turnID: identity.turnID, sessionID: sessionID, canonicalSequence: 3, revision: 1, normalizedName: "read_file", status: .running, createdAt: now, updatedAt: now)
        try await store.upsertSemanticTool(finished)
        try await store.upsertSemanticTool(started)
        let tools = try await store.semanticTools(turnID: identity.turnID)
        XCTAssertEqual(tools.first?.status, .success)
        try await store.close()
    }
}

final class SQLiteServiceStoreV6CompatibilityTests: XCTestCase {
    private static let rollbackProjectID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func testMigrationIsAdditiveAndDetectsLegacyLedgerGap() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let metadata = try await store.metadata()
        XCTAssertEqual(metadata.schemaVersion, 6)
        let tables = try await store.connection.query("SELECT name FROM sqlite_master WHERE type='table'").compactMap { $0.column("name")?.string }
        XCTAssertTrue(Set(["projects", "sessions", "transcript_entries", "semantic_turns", "semantic_activities", "semantic_tools", "agent_submissions"]).isSubset(of: Set(tables)))
        let sessionID = UUID()
        try await store.advanceSemanticWatermark(sessionID: sessionID, semanticSequence: 2, legacySequence: 5, gapDetected: true, at: Date())
        let fetchedWatermark = try await store.semanticWatermark(sessionID: sessionID)
        let watermark = try XCTUnwrap(fetchedWatermark)
        XCTAssertTrue(watermark.gapDetected)
        XCTAssertEqual(watermark.lastLegacySequence, 5)
        try await store.close()
    }

    func testCreatesV6DatabaseForExactPreviousV5SourceProbe() async throws {
        guard let path = ProcessInfo.processInfo.environment["REPOPROMPT_SCHEMA_COMPAT_DB"] else {
            throw XCTSkip("External rollback compatibility probe only")
        }
        try? FileManager.default.removeItem(atPath: path)
        let store = try await SQLiteServiceStore.open(storage: .file(path))
        let metadata = try await store.metadata()
        XCTAssertEqual(metadata.schemaVersion, 6)
        try await store.close()
    }

    func testVerifiesExactPreviousV5SourceReadWriteResult() async throws {
        guard let path = ProcessInfo.processInfo.environment["REPOPROMPT_SCHEMA_COMPAT_DB"] else {
            throw XCTSkip("External rollback compatibility probe only")
        }
        let store = try await SQLiteServiceStore.open(storage: .file(path))
        let metadata = try await store.metadata()
        let project = try await store.project(id: Self.rollbackProjectID)
        let semantic = try await store.semanticTurns(sessionID: UUID())
        XCTAssertEqual(metadata.schemaVersion, 6)
        XCTAssertEqual(project?.name, "v5 rollback write")
        XCTAssertTrue(semantic.isEmpty)
        try await store.close()
    }
}

final class AgentTranscriptPresentationTests: XCTestCase {
    func testSuppressesExactTurnStartedAndClustersMeaningfulActivity() {
        let turnStarted = TranscriptEntry(entryID: UUID(), sessionSequence: 1, kind: .progress, content: "Turn started.", actor: nil, timestamp: Date())
        XCTAssertNil(AgentTranscriptPresentationCore.projectLegacy(turnStarted))
        let tool = AgentPresentationToolWire(executionID: "e1", name: "read_file", status: .success, summary: "Read", keyPaths: ["Sources/A.swift"])
        let projected = AgentTranscriptPresentationCore.project(.init(turnID: "turn", responseSpanID: "span", requestAnchorID: UUID(), requestText: "request", terminalState: "completed", activities: [
            .init(id: "lifecycle", sequence: 1, revision: 1, kind: "progress", content: "turn started"),
            .init(id: "reason", sequence: 2, revision: 1, kind: "reasoning", content: "Considering"),
            .init(id: "tool", sequence: 3, revision: 1, kind: "tool", tool: tool),
            .init(id: "answer", sequence: 4, revision: 2, kind: "assistant", content: "Done")
        ]))
        XCTAssertEqual(projected.blocks.count, 3)
        guard case let .activityCluster(_, rows, summary) = projected.blocks[1] else { return XCTFail("expected activity cluster") }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(summary.toolGroups, ["read_file"])
    }

    func testLegacyRollbackGapIsDetectedWithoutInventingSemanticTurns() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let service = AgentTranscriptPresentationService(store: store)
        let sessionID = UUID()
        let legacy = [TranscriptEntry(entryID: UUID(), sessionSequence: 7, kind: .assistant, content: "legacy answer", actor: nil, timestamp: Date())]
        let page = try await service.page(sessionID: sessionID, actorID: "actor", legacyTranscript: legacy)
        let watermark = try await store.semanticWatermark(sessionID: sessionID)
        XCTAssertEqual(page.turns.count, 1)
        XCTAssertTrue(page.turns[0].legacyStandalone)
        XCTAssertTrue(watermark?.gapDetected == true)
        let semantic = try await store.semanticTurns(sessionID: sessionID)
        XCTAssertTrue(semantic.isEmpty)
        try await store.close()
    }
}

final class NativeProviderRuntimeLifecycleTests: XCTestCase {
    func testCodexTurnStartedIsLifecycleOnlyAndPhaseRevisionAdvances() throws {
        let frame = Data(#"{"method":"turn/started","params":{}}"#.utf8)
        let normalized = try CodexAppServerProviderRuntime.normalize(frame)
        XCTAssertEqual(normalized.events.count, 1)
        guard case let .runStatusChanged(phase, code, _) = normalized.events[0] else { return XCTFail("turn started must be lifecycle") }
        XCTAssertEqual(phase, .thinking)
        XCTAssertEqual(code, "turn_started")
        let now = Date(), sessionID = UUID(), runID = UUID()
        let preparing = RunPresentationSnapshot(sessionID: sessionID, runID: runID, generation: 1, turnEpoch: 1, phase: .preparing, phaseRevision: 1, runStartedAt: now)
        let thinking = try preparing.transitioning(to: .thinking, statusCode: code)
        XCTAssertEqual(thinking.phaseRevision, 2)
        XCTAssertEqual(thinking.phase, .thinking)
    }

    func testReconnectReadsEveryDurablePhaseAndTerminalSettlement() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("run-presentation-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let now = Date(timeIntervalSince1970: 1_786_400_000), sessionID = UUID(), runID = UUID()
        var expected = RunPresentationSnapshot(sessionID: sessionID, runID: runID, generation: 4, turnEpoch: 9, phase: .preparing, phaseRevision: 1, runStartedAt: now)
        for phase in [RunPresentationPhase.preparing, .thinking, .working, .waiting, .cancelling] {
            if expected.phase != phase { expected = try expected.transitioning(to: phase, statusCode: "phase_\(phase.rawValue)") }
            let writer = try await SQLiteServiceStore.open(storage: .file(path))
            try await writer.upsertRunPresentation(expected)
            try await writer.close()
            let reader = try await SQLiteServiceStore.open(storage: .file(path))
            let restored = try await reader.runPresentation(sessionID: sessionID)
            XCTAssertEqual(restored, expected)
            try await reader.close()
        }
        let terminal = expected.settling(code: "cancelled", at: now.addingTimeInterval(5))
        let writer = try await SQLiteServiceStore.open(storage: .file(path))
        try await writer.upsertRunPresentation(terminal)
        try await writer.close()
        let reader = try await SQLiteServiceStore.open(storage: .file(path))
        let restored = try await reader.runPresentation(sessionID: sessionID)
        XCTAssertEqual(restored?.phase, nil)
        XCTAssertEqual(restored?.terminalSettlementCode, "cancelled")
        XCTAssertEqual(restored?.phaseRevision, terminal.phaseRevision)
        try await reader.close()
    }
}

final class RepoPromptHTTPComposerContractTests: XCTestCase {
    func testActorScopedResponsesArePrivateAndVaryOnCredentials() throws {
        let json = try HTTPResponses.privateJSON(["ok": true])
        XCTAssertEqual(json.headers[.cacheControl], "private, no-store")
        XCTAssertEqual(json.headers[.vary], "Cookie, Authorization")
        let empty = HTTPResponses.privateEmpty()
        XCTAssertEqual(empty.headers[.cacheControl], "private, no-store")
        XCTAssertEqual(empty.headers[.vary], "Cookie, Authorization")
    }

    func testAttachmentErrorsExposeStableSanitizedHTTPStatusCodes() throws {
        XCTAssertEqual(HTTPResponses.error(ServiceAPIError(code: .resourceOwnerMismatch, message: "sanitized")).status, .forbidden)
        XCTAssertEqual(HTTPResponses.error(ServiceAPIError(code: .resourceContextMismatch, message: "sanitized")).status, .forbidden)
        XCTAssertEqual(HTTPResponses.error(ServiceAPIError(code: .expiredResource, message: "sanitized")).status, .gone)
        XCTAssertEqual(HTTPResponses.error(ServiceAPIError(code: .notFound, message: "Attachment is unavailable")).status, .notFound)
    }
}

final class RepoPromptHTTPStructuredStartAtomicityTests: XCTestCase {
    func testPreCommitConfigurationFailurePublishesNoSessionEventOrSemanticTurn() async throws {
        let fixture = try await StructuredStartFixture.make()
        defer { Task { try? await fixture.store.close(); try? FileManager.default.removeItem(at: fixture.root) } }
        let invalid = AgentTurnSubmissionWire(
            content: .init(text: "must not publish"),
            configuration: .init(catalogRevision: "stale-catalog", providerID: .claudeCompatible, modelID: fixture.modelID)
        )

        let body = try JSONEncoder.serviceEncoder.encode(AgentStartSessionWire(projectID: fixture.sessionInput.projectID, visibility: fixture.sessionInput.visibility, turn: invalid))
        let instant = Date(timeIntervalSince1970: 1_786_400_000)
        let key = InternalSigningKey(keyID: "atomic-http", role: .goblinApp, direction: "test", secret: Data("atomic-http-secret".utf8))
        let service = RepoPromptHTTPService(authority: fixture.authority, store: fixture.store, authenticator: InternalRequestAuthenticator(keys: [key], store: fixture.store, now: { instant }), eventSigningKey: key, submissionCoordinator: fixture.coordinator)
        let app = Application(router: service.internalRouter())
        try await app.test(.router) { client in
            let headers = try structuredStartHeaders(body: body, actor: fixture.actor, projectID: fixture.sessionInput.projectID, idempotencyKey: UUID().uuidString.lowercased(), nonce: "atomicfailure001", instant: instant, key: key)
            try await client.execute(uri: "/internal/v1/sessions", method: .post, headers: headers, body: ByteBuffer(bytes: body)) { response in
                XCTAssertEqual(response.status, .conflict)
            }
        }

        let publishedSessions = try await fixture.authority.sessionSnapshots()
        XCTAssertTrue(publishedSessions.isEmpty)
        let rows = try await fixture.store.connection.query("SELECT COUNT(*) AS count FROM sessions")
        XCTAssertEqual(rows.first?.column("count")?.integer, 0)
        let eventRows = try await fixture.store.connection.query("SELECT COUNT(*) AS count FROM events WHERE session_id IS NOT NULL")
        XCTAssertEqual(eventRows.first?.column("count")?.integer, 0)
        let turnRows = try await fixture.store.connection.query("SELECT COUNT(*) AS count FROM semantic_turns")
        XCTAssertEqual(turnRows.first?.column("count")?.integer, 0)
        let receiptRows = try await fixture.store.connection.query("SELECT COUNT(*) AS count FROM agent_submissions WHERE state='accepted' OR receipt_json IS NOT NULL")
        XCTAssertEqual(receiptRows.first?.column("count")?.integer, 0)
    }

    func testStructuredStartCarriesSelectedMessageContextWithoutSelectionMutation() async throws {
        let fixture = try await StructuredStartFixture.make()
        defer { Task { try? await fixture.store.close(); try? FileManager.default.removeItem(at: fixture.root) } }
        let submissionKey = UUID().uuidString.lowercased()
        let selectedContext = SelectedMessageContext(source: "goblin-explicit-selection", messages: [
            .init(roomID: "room-1", messageID: "message-1", text: "Exact selected chat text", senderID: "sender-1", timestamp: "2026-08-12T12:00:00Z", revision: "3", threadID: "thread-1")
        ])
        let submission = AgentTurnSubmissionWire(
            content: .init(text: "Investigate the regression"),
            configuration: .init(catalogRevision: fixture.catalogRevision, providerID: .claudeCompatible, modelID: fixture.modelID, effortID: fixture.effortID, permissionID: "claude.requireApproval", toolValues: ["claude.repoPromptOnlyMCP": .boolean(true)])
        )
        let body = try JSONEncoder.serviceEncoder.encode(AgentStartSessionWire(projectID: fixture.sessionInput.projectID, visibility: fixture.sessionInput.visibility, turn: submission, selectedMessageContext: selectedContext))
        let instant = Date(timeIntervalSince1970: 1_786_400_000)
        let signingKey = InternalSigningKey(keyID: "atomic-http", role: .goblinApp, direction: "test", secret: Data("atomic-http-secret".utf8))
        let service = RepoPromptHTTPService(authority: fixture.authority, store: fixture.store, authenticator: InternalRequestAuthenticator(keys: [signingKey], store: fixture.store, now: { instant }), eventSigningKey: signingKey, submissionCoordinator: fixture.coordinator)
        let app = Application(router: service.internalRouter())
        let receipt = try await app.test(.router) { client in
            let headers = try structuredStartHeaders(body: body, actor: fixture.actor, projectID: fixture.sessionInput.projectID, idempotencyKey: submissionKey, nonce: "atomiccontext001", instant: instant, key: signingKey)
            return try await client.execute(uri: "/internal/v1/sessions", method: .post, headers: headers, body: ByteBuffer(bytes: body)) { response in
                XCTAssertEqual(response.status, .accepted)
                return try JSONDecoder.serviceDecoder.decode(SubmissionReceipt.self, from: Data(response.body.readableBytesView))
            }
        }
        let frozen = selectedContext.frozenPrompt(userPrompt: submission.content.text)
        XCTAssertEqual(receipt.session?.transcript.map(\.content), [frozen])
        let turns = try await fixture.store.semanticTurns(sessionID: receipt.sessionID)
        let turn = try XCTUnwrap(turns.first)
        let canonical = try JSONDecoder.serviceDecoder.decode(CanonicalUserTurn.self, from: turn.canonicalUserTurnJSON)
        XCTAssertEqual(canonical.text, frozen)
        let storedRecord = try await fixture.store.agentSubmission(actorID: fixture.actor.goblinUserID, targetKey: "project:\(fixture.sessionInput.projectID.uuidString.lowercased())", operation: "startSession", publicKey: submissionKey)
        let stored = try XCTUnwrap(storedRecord)
        let compiled = try JSONDecoder.serviceDecoder.decode(CompiledProviderTurnInput.self, from: try XCTUnwrap(stored.compiledInputJSON))
        XCTAssertTrue(compiled.prompt.contains(frozen))
        let selection = try await fixture.authority.selectionSnapshot(sessionID: receipt.sessionID)
        XCTAssertTrue(selection.entries.isEmpty)
    }

    func testLostResponseReplayReturnsOneSessionTurnAndStoredReceipt() async throws {
        let fixture = try await StructuredStartFixture.make()
        defer { Task { try? await fixture.store.close(); try? FileManager.default.removeItem(at: fixture.root) } }
        let key = UUID().uuidString.lowercased()
        let submission = AgentTurnSubmissionWire(
            content: .init(text: "accepted exactly once"),
            configuration: .init(catalogRevision: fixture.catalogRevision, providerID: .claudeCompatible, modelID: fixture.modelID, effortID: fixture.effortID, permissionID: "claude.requireApproval", toolValues: ["claude.repoPromptOnlyMCP": .boolean(true)])
        )

        let body = try JSONEncoder.serviceEncoder.encode(AgentStartSessionWire(projectID: fixture.sessionInput.projectID, visibility: fixture.sessionInput.visibility, turn: submission))
        let instant = Date(timeIntervalSince1970: 1_786_400_000)
        let signingKey = InternalSigningKey(keyID: "atomic-http", role: .goblinApp, direction: "test", secret: Data("atomic-http-secret".utf8))
        let service = RepoPromptHTTPService(authority: fixture.authority, store: fixture.store, authenticator: InternalRequestAuthenticator(keys: [signingKey], store: fixture.store, now: { instant }), eventSigningKey: signingKey, submissionCoordinator: fixture.coordinator)
        let app = Application(router: service.internalRouter())
        let receipts = try await app.test(.router) { client in
            let firstHeaders = try structuredStartHeaders(body: body, actor: fixture.actor, projectID: fixture.sessionInput.projectID, idempotencyKey: key, nonce: "atomicreplay0001", instant: instant, key: signingKey)
            let first = try await client.execute(uri: "/internal/v1/sessions", method: .post, headers: firstHeaders, body: ByteBuffer(bytes: body)) { response in
                XCTAssertEqual(response.status, .accepted)
                return try JSONDecoder.serviceDecoder.decode(SubmissionReceipt.self, from: Data(response.body.readableBytesView))
            }
            let replayHeaders = try structuredStartHeaders(body: body, actor: fixture.actor, projectID: fixture.sessionInput.projectID, idempotencyKey: key, nonce: "atomicreplay0002", instant: instant, key: signingKey)
            let replay = try await client.execute(uri: "/internal/v1/sessions", method: .post, headers: replayHeaders, body: ByteBuffer(bytes: body)) { response in
                XCTAssertEqual(response.status, .accepted)
                return try JSONDecoder.serviceDecoder.decode(SubmissionReceipt.self, from: Data(response.body.readableBytesView))
            }
            let detailPath = "/internal/v1/sessions/\(first.sessionID.uuidString)/snapshot"
            let detailHeaders = try sessionSnapshotHeaders(actor: fixture.actor, sessionID: first.sessionID, path: detailPath, nonce: "atomicdetail0001", instant: instant, key: signingKey)
            let detail = try await client.execute(uri: detailPath, method: .get, headers: detailHeaders) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers[.cacheControl], "private, no-store")
                return try JSONDecoder.serviceDecoder.decode(SessionSnapshot.self, from: Data(response.body.readableBytesView))
            }
            return (first, replay, detail)
        }
        let accepted = receipts.0
        XCTAssertEqual(accepted, receipts.1)
        XCTAssertEqual(receipts.2.effectiveTurnConfiguration?.configuration.modelID, fixture.modelID)
        XCTAssertEqual(receipts.2.nextTurnDefaults?.revision, 1)
        XCTAssertEqual(receipts.2.runPresentation?.runID, accepted.runID)
        XCTAssertGreaterThanOrEqual(receipts.2.runPresentation?.phaseRevision ?? 0, 1)
        let sessions = try await fixture.authority.sessionSnapshots()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.sessionID, accepted.sessionID)
        XCTAssertEqual(sessions.first?.transcript.map(\.content), ["accepted exactly once"])
        let turns = try await fixture.store.semanticTurns(sessionID: accepted.sessionID)
        XCTAssertEqual(turns.count, 1)
        let sessionEvents = try await fixture.store.connection.query("SELECT event_type,COUNT(*) AS count FROM events WHERE session_id=? GROUP BY event_type", [.text(accepted.sessionID.uuidString)])
        XCTAssertEqual(sessionEvents.first { $0.column("event_type")?.string == EventType.sessionCreated.rawValue }?.column("count")?.integer, 1)
        XCTAssertEqual(sessionEvents.first { $0.column("event_type")?.string == EventType.agentStarted.rawValue }?.column("count")?.integer, 1)
        let storedReceipts = try await fixture.store.connection.query("SELECT COUNT(*) AS count FROM agent_submissions WHERE state='accepted' AND receipt_json IS NOT NULL")
        XCTAssertEqual(storedReceipts.first?.column("count")?.integer, 1)
    }
}

private func structuredStartHeaders(body: Data, actor: ExternalActor, projectID: UUID, idempotencyKey: String, nonce: String, instant: Date, key: InternalSigningKey) throws -> HTTPFields {
    let bodyDigest = CanonicalSigning.bodyDigest(body)
    let unsigned = GoblinAuthorizationDecision(
        decisionID: UUID(),
        actor: actor,
        projectID: projectID,
        operation: "startSession",
        requestDigest: bodyDigest,
        policyRevision: 1,
        controllerRevision: 1,
        membershipRevision: 1,
        issuedAt: instant,
        expiresAt: instant.addingTimeInterval(30),
        requestID: UUID(),
        correlationID: UUID(),
        keyID: key.keyID,
        signature: ""
    )
    let unsignedData = try JSONEncoder.serviceEncoder.encode(unsigned)
    let decisionSignature = CanonicalSigning.hmacSHA256(message: try CanonicalSigning.canonicalJSONObject(unsignedData, removingTopLevelKeys: ["signature"]), key: key.secret)
    let decision = GoblinAuthorizationDecision(decisionID: unsigned.decisionID, actor: actor, projectID: projectID, operation: unsigned.operation, requestDigest: bodyDigest, policyRevision: 1, controllerRevision: 1, membershipRevision: 1, issuedAt: instant, expiresAt: unsigned.expiresAt, requestID: unsigned.requestID, correlationID: unsigned.correlationID, keyID: key.keyID, signature: decisionSignature)
    let decisionData = try JSONEncoder.serviceEncoder.encode(decision)
    let decisionDigest = CanonicalSigning.bodyDigest(decisionData)
    let timestamp = CanonicalSigning.iso8601String(instant)
    let canonical = CanonicalSigning.requestString(method: "POST", pathAndQuery: "/internal/v1/sessions", timestamp: timestamp, nonce: nonce, bodyDigest: bodyDigest, authorizationDecisionDigest: decisionDigest, keyID: key.keyID)
    var headers = HTTPFields()
    headers[.init("content-type")!] = "application/json"
    headers[.init("x-internal-key-id")!] = key.keyID
    headers[.init("x-internal-timestamp")!] = timestamp
    headers[.init("x-internal-nonce")!] = nonce
    headers[.init("x-internal-body-digest")!] = bodyDigest
    headers[.init("x-internal-authorization-digest")!] = decisionDigest
    headers[.init("x-internal-signature")!] = CanonicalSigning.hmacSHA256(message: canonical, key: key.secret)
    headers[.init("x-goblin-authorization-decision")!] = CanonicalSigning.base64URLEncode(decisionData)
    headers[.init("idempotency-key")!] = idempotencyKey
    return headers
}

private func sessionSnapshotHeaders(actor: ExternalActor, sessionID: UUID, path: String, nonce: String, instant: Date, key: InternalSigningKey) throws -> HTTPFields {
    let body = Data()
    let bodyDigest = CanonicalSigning.bodyDigest(body)
    let unsigned = GoblinAuthorizationDecision(
        decisionID: UUID(),
        actor: actor,
        sessionID: sessionID,
        operation: "getSession",
        requestDigest: bodyDigest,
        policyRevision: 1,
        controllerRevision: 1,
        membershipRevision: 1,
        issuedAt: instant,
        expiresAt: instant.addingTimeInterval(30),
        requestID: UUID(),
        correlationID: UUID(),
        keyID: key.keyID,
        signature: ""
    )
    let unsignedData = try JSONEncoder.serviceEncoder.encode(unsigned)
    let decisionSignature = CanonicalSigning.hmacSHA256(message: try CanonicalSigning.canonicalJSONObject(unsignedData, removingTopLevelKeys: ["signature"]), key: key.secret)
    let decision = GoblinAuthorizationDecision(decisionID: unsigned.decisionID, actor: actor, sessionID: sessionID, operation: unsigned.operation, requestDigest: bodyDigest, policyRevision: 1, controllerRevision: 1, membershipRevision: 1, issuedAt: instant, expiresAt: unsigned.expiresAt, requestID: unsigned.requestID, correlationID: unsigned.correlationID, keyID: key.keyID, signature: decisionSignature)
    let decisionData = try JSONEncoder.serviceEncoder.encode(decision)
    let decisionDigest = CanonicalSigning.bodyDigest(decisionData)
    let timestamp = CanonicalSigning.iso8601String(instant)
    let canonical = CanonicalSigning.requestString(method: "GET", pathAndQuery: path, timestamp: timestamp, nonce: nonce, bodyDigest: bodyDigest, authorizationDecisionDigest: decisionDigest, keyID: key.keyID)
    var headers = HTTPFields()
    headers[.init("x-internal-key-id")!] = key.keyID
    headers[.init("x-internal-timestamp")!] = timestamp
    headers[.init("x-internal-nonce")!] = nonce
    headers[.init("x-internal-body-digest")!] = bodyDigest
    headers[.init("x-internal-authorization-digest")!] = decisionDigest
    headers[.init("x-internal-signature")!] = CanonicalSigning.hmacSHA256(message: canonical, key: key.secret)
    headers[.init("x-goblin-authorization-decision")!] = CanonicalSigning.base64URLEncode(decisionData)
    return headers
}

private struct StructuredStartFixture {
    let root: URL
    let store: SQLiteServiceStore
    let authority: RepoPromptHeadlessAuthority
    let coordinator: AgentSubmissionCoordinator
    let actor: ExternalActor
    let sessionInput: CreateSessionInput
    let catalogRevision: String
    let modelID: String
    let effortID: String?

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let actor = ExternalActor(goblinUserID: "atomic-start-owner", username: "owner", displayName: "Owner")
        let authority = RepoPromptHeadlessAuthority(store: store)
        let project = try await authority.createProject(input: .init(name: "Atomic start", roots: []), externalActor: actor, idempotencyKey: "project", requestDigest: "project")
        let configuration = ProviderCLIConfiguration(kind: .claudeCompatible, executable: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift", protocolVersion: "stream-json-v1", credentialSourceDirectory: root.path)
        let now = Date()
        let connection = ProviderConnectionRecord(connectionID: UUID(), providerID: .claudeCompatible, authenticationMethod: .providerSpecific, state: .connected, accountLabel: "test", lastTestedAt: now, testState: .valid, detail: "Connected", keyHelperConfigured: false, workloadIdentityConfigured: false, createdAt: now, updatedAt: now, revision: 1)
        _ = try await store.upsertProviderConnection(.init(record: connection, credentialReference: nil), expectedRevision: 0)
        let runner = StructuredStartProviderRunner()
        let providerAdapter = ProviderCLIAdapter(configurations: [configuration], enabledProviders: [.claudeCompatible], runner: runner)
        let settings = ProviderSettingsService(store: store, adapter: providerAdapter, configurations: [configuration], initiallyEnabled: [.claudeCompatible], runner: runner)
        try await settings.bootstrap()
        let initialSettings = try await settings.catalog()
        let claude = try XCTUnwrap(initialSettings.providers.first { $0.providerID == .claudeCompatible })
        _ = try await settings.update(providerID: .claudeCompatible, request: .init(expectedRevision: claude.preference.revision, enabled: true, defaultModel: "claude-fable-5", reasoningEffort: nil, speedMode: nil, serviceTier: nil))
        await settings.startConnectedProviderRecovery()
        var refreshed = try await settings.catalog()
        for _ in 0 ..< 100 where refreshed.providers.first(where: { $0.providerID == .claudeCompatible })?.runtimePreflightVerified != true {
            try await Task.sleep(for: .milliseconds(10))
            refreshed = try await settings.catalog()
        }
        let catalog = AgentComposerCatalogService(providerSettings: settings, store: store)
        let snapshot = try await catalog.snapshot(context: .init(kind: .project, projectID: project.projectID, actorID: actor.goblinUserID))
        let model = try XCTUnwrap(snapshot.providerGroups.first { $0.providerID == .claudeCompatible }?.models.first)
        let attachments = try AgentComposerAttachmentStore(store: store, configuration: .init(stagingRoot: root.appendingPathComponent("staged").path, acceptedRoot: root.appendingPathComponent("accepted").path, minimumFreeBytes: 0))
        let coordinator = AgentSubmissionCoordinator(store: store, catalog: catalog, compiler: AgentTurnIntentCompiler(), attachments: attachments)
        return .init(root: root, store: store, authority: authority, coordinator: coordinator, actor: actor, sessionInput: .init(projectID: project.projectID, provider: .claudeCompatible, model: model.id, visibility: .privateSession, startImmediately: false), catalogRevision: snapshot.revision, modelID: model.id, effortID: model.defaultEffortID)
    }
}

private actor StructuredStartProviderRunner: WorkspaceCommandRunning {
    func run(executable _: String, arguments: [String], workingDirectory _: String, maximumBytes _: Int) async throws -> String {
        response(arguments)
    }

    func run(executable _: String, arguments: [String], workingDirectory _: String, maximumBytes _: Int, environment _: [String: String]) async throws -> String {
        response(arguments)
    }

    private nonisolated func response(_ arguments: [String]) -> String {
        if arguments == ["auth", "status", "--json"] { return #"{"loggedIn":true}"# }
        return "Swift version 6.2"
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
