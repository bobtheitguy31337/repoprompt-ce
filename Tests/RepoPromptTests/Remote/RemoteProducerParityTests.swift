import Foundation
@testable import RepoPromptApp
import RepoPromptRemoteProtocol
import XCTest

@MainActor
final class RemoteProducerParityTests: XCTestCase {
    func testWorkflowDescriptorsUseAuthoritativeVisualsAndFeaturedRanks() throws {
        let customID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000901"))
        let custom = AgentWorkflowDefinition(
            customID: customID,
            displayName: "Custom Audit",
            iconName: "checkmark.shield.fill",
            accentColorHex: "#123456",
            descriptionText: "Audits a custom boundary."
        )
        let orchestrate = AgentWorkflow.orchestrate.definition
        let review = AgentWorkflow.review.definition

        let descriptors = DesktopRemoteCatalogService.workflowDescriptors(
            workflows: [orchestrate, review, custom],
            featuredWorkflowIDs: [review.id, custom.id, orchestrate.id]
        )

        let orchestrateDescriptor = try XCTUnwrap(descriptors.first { $0.id == orchestrate.id })
        XCTAssertEqual(orchestrateDescriptor.displayName, "Orchestrate")
        XCTAssertEqual(orchestrateDescriptor.iconName, "arrow.triangle.branch")
        XCTAssertEqual(orchestrateDescriptor.accentColorHex, "#34C759")
        XCTAssertEqual(orchestrateDescriptor.descriptionText, orchestrate.descriptionText)
        XCTAssertEqual(orchestrateDescriptor.featuredRank, 2)
        XCTAssertTrue(orchestrateDescriptor.isBuiltIn)

        let customDescriptor = try XCTUnwrap(descriptors.first { $0.id == custom.id })
        XCTAssertEqual(customDescriptor.iconName, "checkmark.shield.fill")
        XCTAssertEqual(customDescriptor.accentColorHex, "#123456")
        XCTAssertEqual(customDescriptor.descriptionText, "Audits a custom boundary.")
        XCTAssertEqual(customDescriptor.featuredRank, 1)
        XCTAssertFalse(customDescriptor.isBuiltIn)
        XCTAssertFalse(descriptors.contains { $0.displayName == "Director" })
    }

    func testCatalogDefaultSelectionUsesPersistedPreferenceInsteadOfTransientWindowSelection() throws {
        let agents = [
            RemoteAgentDescriptor(
                id: "codexExec",
                displayName: "Codex",
                models: ["transient-model", "persisted-model"],
                isAvailable: true,
                modelDescriptors: [
                    RemoteModelDescriptor(id: "transient-model", displayName: "Transient"),
                    RemoteModelDescriptor(id: "persisted-model", displayName: "Persisted")
                ],
                defaultModelID: "transient-model"
            )
        ]
        let preferred = RemoteAgentSelection(
            agentID: "codexExec",
            modelID: "persisted-model",
            reasoningEffort: "high"
        )

        let resolved = try XCTUnwrap(DesktopRemoteCatalogService.resolvedDefaultSelection(
            preferred,
            agents: agents
        ))

        XCTAssertEqual(resolved, preferred)
    }

    func testAcceptedRunMetadataIsWriteOnceForOriginAndUpdatesLastStart() {
        let firstStart = Date(timeIntervalSinceReferenceDate: 10)
        let secondStart = Date(timeIntervalSinceReferenceDate: 20)
        let session = AgentModeViewModel.TabSession(tabID: UUID())

        XCTAssertTrue(session.recordAcceptedRunMetadata(
            workflow: AgentWorkflow.orchestrate.definition,
            startedAt: firstStart
        ))
        XCTAssertEqual(session.originWorkflowID, AgentWorkflow.orchestrate.definition.id)
        XCTAssertEqual(session.originWorkflowDisplayName, "Orchestrate")
        XCTAssertEqual(session.lastRunStartedAt, firstStart)

        XCTAssertTrue(session.recordAcceptedRunMetadata(
            workflow: AgentWorkflow.review.definition,
            startedAt: secondStart
        ))
        XCTAssertEqual(session.originWorkflowID, AgentWorkflow.orchestrate.definition.id)
        XCTAssertEqual(session.originWorkflowDisplayName, "Orchestrate")
        XCTAssertEqual(session.lastRunStartedAt, secondStart)

        let noWorkflowOrigin = AgentModeViewModel.TabSession(tabID: UUID())
        noWorkflowOrigin.recordAcceptedRunMetadata(workflow: nil, startedAt: firstStart)
        noWorkflowOrigin.recordAcceptedRunMetadata(workflow: AgentWorkflow.review.definition, startedAt: secondStart)
        XCTAssertNil(noWorkflowOrigin.originWorkflowID)
        XCTAssertNil(noWorkflowOrigin.originWorkflowDisplayName)
        XCTAssertEqual(noWorkflowOrigin.lastRunStartedAt, secondStart)

        let failedProvisionalStart = AgentModeViewModel.TabSession(tabID: UUID())
        failedProvisionalStart.selectedAgent = .codexExec
        XCTAssertFalse(failedProvisionalStart.recordRunMetadataIfAccepted(
            wasActiveBeforeStart: false,
            dispatchAccepted: false,
            workflow: AgentWorkflow.orchestrate.definition,
            startedAt: firstStart
        ))
        XCTAssertNil(failedProvisionalStart.originWorkflowID)
        XCTAssertNil(failedProvisionalStart.originWorkflowDisplayName)
        XCTAssertNil(failedProvisionalStart.lastRunStartedAt)
    }

    func testLegacySessionAndMetadataIndexDecodeWithoutLaunchMetadata() throws {
        let sessionPayload = """
        {
          "id": "00000000-0000-0000-0000-000000000902",
          "serializationVersion": 6,
          "name": "Legacy Session",
          "savedAt": 0,
          "items": [],
          "autoEditEnabled": true
        }
        """
        let session = try JSONDecoder().decode(AgentSession.self, from: Data(sessionPayload.utf8))
        XCTAssertNil(session.originWorkflowID)
        XCTAssertNil(session.originWorkflowDisplayName)
        XCTAssertNil(session.lastRunStartedAt)

        let indexPayload = """
        {
          "schemaVersion": 5,
          "generatedAt": 0,
          "entries": [
            {
              "id": "00000000-0000-0000-0000-000000000903",
              "filename": "AgentSession-00000000-0000-0000-0000-000000000903.json",
              "name": "Legacy Indexed Session",
              "savedAt": 0,
              "itemCount": 0,
              "hasUnknownConversationContent": false,
              "autoEditEnabled": true,
              "isMCPOriginated": false,
              "lastIndexedAt": 0
            }
          ],
          "quarantinedFiles": []
        }
        """
        let index = try JSONDecoder().decode(AgentSessionMetadataIndex.self, from: Data(indexPayload.utf8))
        let record = try XCTUnwrap(index.entries.first)
        XCTAssertNil(record.originWorkflowID)
        XCTAssertNil(record.originWorkflowDisplayName)
        XCTAssertNil(record.lastRunStartedAt)
    }

    func testDataServicePreservesLaunchMetadataAcrossFullStubIndexAndSidebar() async throws {
        let service = AgentSessionDataService.shared
        let workspace = makeTemporaryWorkspace()
        let storageURL = try XCTUnwrap(workspace.customStoragePath)
        defer { try? FileManager.default.removeItem(at: storageURL) }

        let sessionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000904"))
        let tabID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000905"))
        let startedAt = Date(timeIntervalSinceReferenceDate: 30)
        let session = AgentSession(
            id: sessionID,
            workspaceID: workspace.id,
            composeTabID: tabID,
            name: "Durable Remote Metadata",
            itemCount: 1,
            originWorkflowID: AgentWorkflow.deepPlan.definition.id,
            originWorkflowDisplayName: AgentWorkflow.deepPlan.displayName,
            lastRunStartedAt: startedAt,
            autoEditEnabled: true
        )

        let fileURL = try await service.saveAgentSession(
            session,
            for: workspace,
            preparation: .alreadyCanonicalTranscript,
            trustedCanonicalItemCount: 1
        )
        let loaded = try await service.loadAgentSession(from: fileURL)
        let stub = try await service.loadAgentSessionStub(from: fileURL)
        let records = try await service.indexedAgentSessionMetadataRecords(for: workspace)
        let sidebar = try await service.buildSidebarIndex(
            AgentSessionSidebarBuildRequest(
                workspace: workspace,
                tabNameByID: [tabID: "Durable Remote Metadata"],
                validTabIDs: [tabID],
                boundSessionIDByTabID: [tabID: sessionID]
            )
        )

        for value in [loaded, stub] {
            XCTAssertEqual(value.originWorkflowID, AgentWorkflow.deepPlan.definition.id)
            XCTAssertEqual(value.originWorkflowDisplayName, AgentWorkflow.deepPlan.displayName)
            XCTAssertEqual(value.lastRunStartedAt, startedAt)
        }
        let record = try XCTUnwrap(records.first { $0.id == sessionID })
        XCTAssertEqual(record.originWorkflowID, AgentWorkflow.deepPlan.definition.id)
        XCTAssertEqual(record.originWorkflowDisplayName, AgentWorkflow.deepPlan.displayName)
        XCTAssertEqual(record.lastRunStartedAt, startedAt)
        let entry = try XCTUnwrap(sidebar.entriesBySessionID[sessionID])
        XCTAssertEqual(entry.originWorkflowID, AgentWorkflow.deepPlan.definition.id)
        XCTAssertEqual(entry.originWorkflowDisplayName, AgentWorkflow.deepPlan.displayName)
        XCTAssertEqual(entry.lastRunStartedAt, startedAt)
    }

    func testLiveSessionProjectionMatchesSessionIdentityNotOnlyComposeTab() {
        let tabID = fixedUUID(906)
        let activeSessionID = fixedUUID(907)
        let inactiveSessionID = fixedUUID(908)
        let live = AgentModeViewModel.TabSession(tabID: tabID)
        live.testInstallPersistentSessionBinding(sessionID: activeSessionID)
        live.originWorkflowID = AgentWorkflow.orchestrate.definition.id

        let liveByTabID = [tabID: live]
        XCTAssertTrue(AgentModeRemoteSessionQueryService.matchingLiveSession(
            entryID: activeSessionID,
            tabID: tabID,
            liveByTabID: liveByTabID
        ) === live)
        XCTAssertNil(AgentModeRemoteSessionQueryService.matchingLiveSession(
            entryID: inactiveSessionID,
            tabID: tabID,
            liveByTabID: liveByTabID
        ))
    }

    func testTranscriptProjectionClassifiesNarrativeAndKeepsRawDetailsOptIn() throws {
        let timestamp = Date(timeIntervalSinceReferenceDate: 100)
        let request = AgentChatItem(
            id: fixedUUID(910),
            timestamp: timestamp,
            kind: .user,
            text: #"Use {"token":"request-secret"}"#,
            sequenceIndex: 0
        )
        let preamble = AgentTranscriptActivity(
            id: fixedUUID(911),
            timestamp: timestamp.addingTimeInterval(1),
            sequenceIndex: 1,
            role: .assistant,
            itemKind: .assistantInline,
            text: "Checking the relevant files",
            isSubstantiveAssistant: false
        )
        let answer = AgentTranscriptActivity(
            id: fixedUUID(912),
            timestamp: timestamp.addingTimeInterval(2),
            sequenceIndex: 2,
            role: .assistant,
            itemKind: .assistant,
            text: "The implementation is complete.",
            isSubstantiveAssistant: true,
            sealsAssistantBoundary: true
        )
        let substantiveAnswer = AgentTranscriptActivity(
            id: fixedUUID(916),
            timestamp: timestamp.addingTimeInterval(3),
            sequenceIndex: 3,
            role: .assistant,
            itemKind: .assistant,
            text: "A second answer without a conclusion marker.",
            isSubstantiveAssistant: true
        )
        let failedTool = AgentTranscriptActivity(
            id: fixedUUID(913),
            timestamp: timestamp.addingTimeInterval(4),
            sequenceIndex: 4,
            role: .toolExecution,
            itemKind: .toolResult,
            text: #"{"password":"raw-result"}"#,
            toolExecution: toolExecution(
                name: "exec_command",
                status: .failed,
                argsJSON: #"{"api_key":"raw-argument"}"#,
                resultJSON: #"{"password":"raw-result"}"#,
                isError: true,
                summaryText: "Command failed"
            ),
            reasoning: "Bearer raw-reasoning"
        )
        let question = AgentTranscriptActivity(
            id: fixedUUID(914),
            timestamp: timestamp.addingTimeInterval(5),
            sequenceIndex: 5,
            role: .toolExecution,
            itemKind: .toolCall,
            text: #"{"question":"Choose?"}"#,
            toolExecution: toolExecution(name: "ask_user", status: .running)
        )
        let permission = AgentTranscriptActivity(
            id: fixedUUID(917),
            timestamp: timestamp.addingTimeInterval(6),
            sequenceIndex: 6,
            role: .toolExecution,
            itemKind: .toolCall,
            text: "",
            toolExecution: toolExecution(name: "request_permissions", status: .running)
        )
        let approval = AgentTranscriptActivity(
            id: fixedUUID(918),
            timestamp: timestamp.addingTimeInterval(7),
            sequenceIndex: 7,
            role: .toolExecution,
            itemKind: .toolCall,
            text: "",
            toolExecution: toolExecution(name: "request_approval", status: .running)
        )
        let compact = AgentTranscriptActivity(
            id: fixedUUID(919),
            timestamp: timestamp.addingTimeInterval(8),
            sequenceIndex: 8,
            role: .progress,
            itemKind: .system,
            text: "Indexed three files"
        )
        let summaryID = fixedUUID(950)
        let turn = AgentTranscriptTurn(
            id: fixedUUID(915),
            request: AgentTranscriptRequestAnchor(from: request),
            responseSpans: [
                AgentTranscriptProviderResponseSpan(
                    startedAt: timestamp,
                    activities: [
                        preamble,
                        answer,
                        substantiveAnswer,
                        failedTool,
                        question,
                        permission,
                        approval,
                        compact
                    ]
                )
            ],
            conclusionActivityID: answer.id,
            retentionTier: .condensed,
            summary: AgentTranscriptTurnSummary(
                middleSummaryItemID: summaryID,
                requestText: nil,
                conclusionText: nil,
                compactConclusionText: "Compacted final answer",
                middleSummaryText: nil,
                toolCount: 3,
                notableToolNames: [],
                keyPaths: [],
                compactedActivityCount: 3,
                hadWarning: false,
                hadError: true
            ),
            startedAt: timestamp,
            lastActivityAt: timestamp.addingTimeInterval(9)
        )
        let transcript = AgentTranscript(turns: [turn], nextSequenceIndex: 10)

        let sanitized = WindowRemoteReadService.project(transcript: transcript, includeDetails: false)
        XCTAssertEqual(sanitized.first?.semanticKind, .userRequest)
        XCTAssertEqual(sanitized.first?.text, #"Use {"token":"[REDACTED]"}"#)
        XCTAssertEqual(sanitized.first { $0.id == preamble.id }?.semanticKind, .assistantPreamble)
        XCTAssertEqual(sanitized.first { $0.id == answer.id }?.semanticKind, .assistantAnswer)
        XCTAssertEqual(sanitized.first { $0.id == answer.id }?.kind, .conclusion)
        XCTAssertEqual(sanitized.first { $0.id == substantiveAnswer.id }?.semanticKind, .assistantAnswer)
        XCTAssertEqual(sanitized.first { $0.id == failedTool.id }?.semanticKind, .error)
        XCTAssertEqual(sanitized.first { $0.id == failedTool.id }?.text, "Command failed")
        XCTAssertNil(sanitized.first { $0.id == failedTool.id }?.detail)
        XCTAssertEqual(sanitized.first { $0.id == question.id }?.semanticKind, .question)
        XCTAssertNil(sanitized.first { $0.id == question.id }?.text)
        XCTAssertEqual(sanitized.first { $0.id == permission.id }?.semanticKind, .permission)
        XCTAssertEqual(sanitized.first { $0.id == approval.id }?.semanticKind, .approval)
        XCTAssertEqual(sanitized.first { $0.id == compact.id }?.semanticKind, .compactActivity)
        XCTAssertEqual(sanitized.first { $0.id == summaryID }?.semanticKind, .summary)
        XCTAssertEqual(sanitized.first { $0.id == summaryID }?.text, "Compacted final answer")

        let encodedDefault = try String(decoding: JSONEncoder().encode(sanitized), as: UTF8.self)
        XCTAssertFalse(encodedDefault.contains("raw-argument"))
        XCTAssertFalse(encodedDefault.contains("raw-result"))
        XCTAssertFalse(encodedDefault.contains("raw-reasoning"))
        XCTAssertFalse(encodedDefault.contains("request-secret"))

        let detailed = WindowRemoteReadService.project(transcript: transcript, includeDetails: true)
        let toolDetail = try XCTUnwrap(detailed.first { $0.id == failedTool.id }?.detail)
        XCTAssertEqual(toolDetail.argumentsJSON, #"{"api_key":"[REDACTED]"}"#)
        XCTAssertEqual(toolDetail.resultJSON, #"{"password":"[REDACTED]"}"#)
        XCTAssertEqual(toolDetail.reasoning, "Bearer [REDACTED]")
    }

    func testRecentBackwardPagingUsesStableCursorWithoutDuplicates() throws {
        let sessionID = fixedUUID(920)
        let timestamp = Date(timeIntervalSinceReferenceDate: 200)
        let items = (0 ..< 5).map { index in
            RemoteTranscriptItem(
                id: fixedUUID(921 + index),
                turnID: fixedUUID(930 + index),
                timestamp: timestamp.addingTimeInterval(TimeInterval(index)),
                sequenceIndex: index,
                kind: .activity,
                semanticKind: .compactActivity,
                role: "toolExecution",
                text: "Item \(index)"
            )
        }

        let latest = WindowRemoteReadService.page(
            sessionID: sessionID,
            allItems: items,
            paging: .recentBackward(before: nil),
            limit: 2,
            transcriptRevision: 7
        )
        XCTAssertEqual(latest.items.map(\.sequenceIndex), [3, 4])
        XCTAssertEqual(latest.pagingMode, .recentBackward)
        XCTAssertEqual(latest.hasOlder, true)
        XCTAssertEqual(latest.transcriptRevision, 7)

        let cursor = try XCTUnwrap(latest.olderCursor)
        XCTAssertEqual(try RemoteTranscriptCursorCodec.decode(RemoteTranscriptCursorCodec.encode(cursor)), cursor)
        let older = WindowRemoteReadService.page(
            sessionID: sessionID,
            allItems: items,
            paging: .recentBackward(before: cursor),
            limit: 2
        )
        XCTAssertEqual(older.items.map(\.sequenceIndex), [1, 2])
        XCTAssertTrue(Set(latest.items.map(\.id)).isDisjoint(with: Set(older.items.map(\.id))))

        let oldest = try WindowRemoteReadService.page(
            sessionID: sessionID,
            allItems: items,
            paging: .recentBackward(before: XCTUnwrap(older.olderCursor)),
            limit: 2
        )
        XCTAssertEqual(oldest.items.map(\.sequenceIndex), [0])
        XCTAssertEqual(oldest.hasOlder, false)
        XCTAssertNil(oldest.olderCursor)

        let empty = WindowRemoteReadService.page(
            sessionID: sessionID,
            allItems: [],
            paging: .recentBackward(before: nil),
            limit: 2
        )
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertEqual(empty.hasOlder, false)

        let oneItem = WindowRemoteReadService.page(
            sessionID: sessionID,
            allItems: [items[0]],
            paging: .recentBackward(before: nil),
            limit: 1
        )
        XCTAssertEqual(oneItem.items.map(\.id), [items[0].id])
        XCTAssertEqual(oneItem.hasOlder, false)

        let tiedItems = [
            RemoteTranscriptItem(
                id: fixedUUID(960),
                turnID: fixedUUID(962),
                timestamp: timestamp,
                sequenceIndex: 10,
                kind: .activity,
                role: "toolExecution"
            ),
            RemoteTranscriptItem(
                id: fixedUUID(961),
                turnID: fixedUUID(962),
                timestamp: timestamp,
                sequenceIndex: 10,
                kind: .activity,
                role: "toolExecution"
            )
        ]
        let tiedLatest = WindowRemoteReadService.page(
            sessionID: sessionID,
            allItems: tiedItems,
            paging: .recentBackward(before: nil),
            limit: 1
        )
        XCTAssertEqual(tiedLatest.items.map(\.id), [fixedUUID(961)])
        let tiedOlder = try WindowRemoteReadService.page(
            sessionID: sessionID,
            allItems: tiedItems,
            paging: .recentBackward(before: XCTUnwrap(tiedLatest.olderCursor)),
            limit: 1
        )
        XCTAssertEqual(tiedOlder.items.map(\.id), [fixedUUID(960)])

        let exact = WindowRemoteReadService.page(
            sessionID: sessionID,
            allItems: tiedItems,
            paging: .exactItem(fixedUUID(960)),
            limit: 1
        )
        XCTAssertEqual(exact.items.map(\.id), [fixedUUID(960)])

        let legacy = WindowRemoteReadService.page(
            sessionID: sessionID,
            allItems: items,
            paging: .legacyForward(afterSequenceIndex: 1),
            limit: 2
        )
        XCTAssertEqual(legacy.items.map(\.sequenceIndex), [2, 3])
        XCTAssertEqual(legacy.nextSequenceIndex, 3)
        XCTAssertThrowsError(try RemoteTranscriptCursorCodec.decode("not-a-cursor"))
    }

    func testRevisionTrackerIsMonotonicAndRevisionEventContainsOnlyNumericRevision() throws {
        let tracker = RemoteTranscriptRevisionTracker()
        let sessionID = fixedUUID(940)
        let baseTranscript = fingerprintTranscript(firstVisibleText: "first")
        let editedEarlierRow = fingerprintTranscript(firstVisibleText: "edited")
        let live = RemoteTranscriptRevisionFingerprint.live(transcript: baseTranscript)
        let equivalentPersisted = RemoteTranscriptRevisionFingerprint.persisted(transcript: baseTranscript)
        let changed = RemoteTranscriptRevisionFingerprint.live(transcript: editedEarlierRow)

        XCTAssertEqual(live, equivalentPersisted, "Live and persisted forms of the same visible transcript must normalize")
        XCTAssertEqual(tracker.observePersisted(
            sessionID: sessionID,
            savedAt: Date(timeIntervalSinceReferenceDate: 1),
            fingerprint: equivalentPersisted
        ), 1)
        XCTAssertEqual(tracker.observePersisted(
            sessionID: sessionID,
            savedAt: Date(timeIntervalSinceReferenceDate: 2),
            fingerprint: equivalentPersisted
        ), 1, "A metadata-only save must not increment the revision")
        XCTAssertEqual(tracker.cachedPersistedRevision(
            sessionID: sessionID,
            savedAt: Date(timeIntervalSinceReferenceDate: 2)
        ), 1)
        XCTAssertEqual(tracker.observe(sessionID: sessionID, fingerprint: changed), 2)
        XCTAssertEqual(tracker.revision(for: sessionID), 2)

        let commonDate = Date(timeIntervalSinceReferenceDate: 3)
        let old = RemoteSessionSummary(
            sessionID: sessionID,
            workspaceID: fixedUUID(941).uuidString,
            transcriptRevision: 1,
            runState: .working,
            lastUpdatedAt: commonDate,
            isLive: true
        )
        let current = RemoteSessionSummary(
            sessionID: sessionID,
            workspaceID: fixedUUID(941).uuidString,
            transcriptRevision: 2,
            runState: .working,
            lastUpdatedAt: commonDate,
            isLive: true
        )
        let event = try XCTUnwrap(RemoteGatewayController.transcriptRevisionEvent(
            old: old,
            current: current,
            desktopInstanceID: "desktop"
        ))
        XCTAssertEqual(event.type, .transcriptItemsAppended)
        XCTAssertEqual(event.sessionID, sessionID)
        XCTAssertEqual(event.payload, .text("2"))
        XCTAssertFalse(RemoteGatewayController.hasSessionChangeExcludingTranscriptRevision(
            old: old,
            current: current
        ))
        let encoded = try String(decoding: JSONEncoder().encode(event), as: UTF8.self)
        XCTAssertFalse(encoded.contains("transcript text"))
        XCTAssertFalse(encoded.contains("argumentsJSON"))
        XCTAssertFalse(encoded.contains("resultJSON"))
        XCTAssertFalse(encoded.contains("reasoning"))
    }

    func testConfigurationControlsChangeProducesSessionUpdate() {
        let commonDate = Date(timeIntervalSinceReferenceDate: 4)
        let base = RemoteSessionSummary(
            sessionID: fixedUUID(942),
            workspaceID: fixedUUID(943).uuidString,
            configurationControls: RemoteSessionConfigurationControls(
                agent: RemoteSelectionControl(isMutable: false),
                model: RemoteSelectionControl(isMutable: false),
                reasoningEffort: RemoteSelectionControl(isMutable: false)
            ),
            runState: .idle,
            lastUpdatedAt: commonDate,
            isLive: true
        )
        let changed = RemoteSessionSummary(
            sessionID: base.sessionID,
            workspaceID: base.workspaceID,
            configurationControls: RemoteSessionConfigurationControls(
                agent: RemoteSelectionControl(isMutable: true, allowedValueIDs: ["codexExec"]),
                model: RemoteSelectionControl(isMutable: true, allowedValueIDs: ["gpt-5"]),
                reasoningEffort: RemoteSelectionControl(isMutable: true, allowedValueIDs: ["high"])
            ),
            runState: .idle,
            lastUpdatedAt: commonDate,
            isLive: true
        )

        XCTAssertTrue(RemoteGatewayController.hasSessionChangeExcludingTranscriptRevision(
            old: base,
            current: changed
        ))
    }

    func testGatewayCursorAttachmentPreservesResolvedMetadata() {
        let selection = RemoteAgentSelection(agentID: "codexExec", modelID: "gpt-5", reasoningEffort: "high")
        let tools = RemoteToolCatalog(
            providerID: "codexExec",
            revision: 7,
            settings: [],
            isMutable: true
        )
        let response = RemoteCommandResponse(
            commandID: fixedUUID(944),
            accepted: true,
            resolvedSelection: selection,
            resolvedToolCatalog: tools
        )

        let attached = RemoteGatewayRequestRouter.attachingEventCursor(to: response, eventCursor: 42)

        XCTAssertEqual(attached.eventCursor, 42)
        XCTAssertEqual(attached.resolvedSelection, selection)
        XCTAssertEqual(attached.resolvedToolCatalog, tools)
    }

    func testTabSessionTranscriptMutationRevisionTracksTranscriptChanges() {
        let session = AgentModeViewModel.TabSession(tabID: fixedUUID(945))
        let initial = session.remoteTranscriptMutationRevision

        session.transcript = AgentTranscript(nextSequenceIndex: 1)
        let afterAssignment = session.remoteTranscriptMutationRevision
        session.transcript.nextSequenceIndex += 1

        XCTAssertGreaterThan(afterAssignment, initial)
        XCTAssertGreaterThan(session.remoteTranscriptMutationRevision, afterAssignment)
    }

    private func fingerprintTranscript(firstVisibleText: String) -> AgentTranscript {
        let timestamp = Date(timeIntervalSinceReferenceDate: 500)
        let request = AgentChatItem(
            id: fixedUUID(970),
            timestamp: timestamp,
            kind: .user,
            text: "request",
            sequenceIndex: 0
        )
        let first = AgentTranscriptActivity(
            id: fixedUUID(971),
            timestamp: timestamp.addingTimeInterval(1),
            sequenceIndex: 1,
            role: .assistant,
            itemKind: .assistantInline,
            text: firstVisibleText,
            isSubstantiveAssistant: false
        )
        let unchangedTail = AgentTranscriptActivity(
            id: fixedUUID(972),
            timestamp: timestamp.addingTimeInterval(2),
            sequenceIndex: 2,
            role: .assistant,
            itemKind: .assistant,
            text: "unchanged tail",
            isSubstantiveAssistant: true,
            sealsAssistantBoundary: true
        )
        return AgentTranscript(
            turns: [AgentTranscriptTurn(
                id: fixedUUID(973),
                request: AgentTranscriptRequestAnchor(from: request),
                responseSpans: [AgentTranscriptProviderResponseSpan(
                    startedAt: timestamp,
                    activities: [first, unchangedTail]
                )],
                conclusionActivityID: unchangedTail.id,
                startedAt: timestamp,
                lastActivityAt: unchangedTail.timestamp
            )],
            nextSequenceIndex: 3
        )
    }

    private func toolExecution(
        name: String,
        status: AgentTranscriptToolStatus,
        argsJSON: String? = nil,
        resultJSON: String? = nil,
        isError: Bool? = nil,
        summaryText: String? = nil
    ) -> AgentTranscriptToolExecution {
        AgentTranscriptToolExecution(
            stableExecutionID: UUID().uuidString,
            toolName: name,
            invocationID: UUID(),
            argsJSON: argsJSON,
            resultJSON: resultJSON,
            toolIsError: isError,
            status: status,
            summaryText: summaryText
        )
    }

    private func makeTemporaryWorkspace() -> WorkspaceModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteProducerParityTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return WorkspaceModel(
            name: "Remote Producer Parity",
            repoPaths: ["/tmp/repo"],
            customStoragePath: directory
        )
    }

    private func fixedUUID(_ suffix: Int) -> UUID {
        let value = String(format: "%012d", suffix)
        return UUID(uuidString: "00000000-0000-0000-0000-\(value)")!
    }
}
