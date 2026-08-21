import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptAuthorityAPI
import RepoPromptDomainRuntime
import RepoPromptHeadlessRuntime
import RepoPromptRuntimeModel
import RepoPromptServiceProtocol
import RepoPromptShared
import XCTest

@testable import RepoPromptServerHost
@testable import RepoPromptServicePersistence

private struct PR5InjectedFailure: Error {}

private actor PR5ArmedPersistenceFault {
    private var point: PersistenceFaultPoint?

    func arm(_ point: PersistenceFaultPoint) { self.point = point }

    func hit(_ observed: PersistenceFaultPoint) throws {
        guard observed == point else { return }
        point = nil
        throw PR5InjectedFailure()
    }
}

private enum PR5TestSupport {
    static let actor = ExternalActor(userID: "pr5-user", username: "pr5", displayName: "PR5")

    static func persistProject(
        in store: SQLiteServiceStore,
        name: String = "PR5"
    ) async throws -> EventEnvelope {
        let cursor = try await store.nextCursor()
        let project = ProjectSnapshot(
            projectID: UUID(),
            name: name,
            creator: actor,
            state: .active,
            roots: [],
            revision: 1,
            cursor: cursor
        )
        return try await store.persistProject(
            project,
            eventType: .projectCreated,
            actor: actor,
            correlationID: UUID(),
            idempotency: nil
        )
    }

    static func event(storeID: UUID, sequence: Int64, projectID: UUID = UUID()) -> EventEnvelope {
        EventEnvelope(
            eventID: UUID(),
            storeID: storeID,
            globalSequence: sequence,
            timestamp: Date(),
            projectID: projectID,
            sessionID: nil,
            agentID: nil,
            parentAgentID: nil,
            rootSessionID: nil,
            runID: nil,
            sessionSequence: nil,
            eventType: .sessionUpdated,
            generation: nil,
            turnEpoch: nil,
            actor: nil,
            correlationID: UUID(),
            causationID: nil,
            payload: .init(object: [:]),
            digest: "d\(sequence)",
            keyID: "test",
            signature: "s\(sequence)"
        )
    }

    static func makeAuthority(
        store: SQLiteServiceStore,
        dispatcher: any AgentProviderDispatcher
    ) async throws -> (RepoPromptHeadlessAuthority, SessionSnapshot, URL) {
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let authority = RepoPromptHeadlessAuthority(store: store, providerAdapter: dispatcher)
        let project = try await authority.createProject(
            input: .init(name: "PR5", roots: [.init(logicalName: "source", path: root.path, writable: true)]),
            externalActor: actor,
            idempotencyKey: "pr5-project-\(UUID().uuidString)",
            requestDigest: "pr5-project"
        )
        let session = try await authority.createSession(
            input: .init(projectID: project.projectID, provider: .codex, visibility: .privateSession),
            externalActor: actor,
            idempotencyKey: "pr5-session-\(UUID().uuidString)",
            requestDigest: "pr5-session"
        )
        return (authority, session, root)
    }
}

final class SchemaV8MigrationTests: XCTestCase {
    func testFreshStoreActivatesSchemaV8AndAllImmutableTables() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }

        let metadata = try await store.metadata()
        XCTAssertEqual(metadata.schemaVersion, 8)
        let names = try await store.database.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('authority_transitions','provider_event_receipts','event_outbox','idempotency_tombstones') ORDER BY name"
        ).compactMap { $0.column("name")?.string }
        XCTAssertEqual(names, [
            "authority_transitions",
            "event_outbox",
            "idempotency_tombstones",
            "provider_event_receipts",
        ])
        let ledger = try await store.database.query(
            "SELECT digest FROM schema_migrations WHERE version=8"
        ).first?.column("digest")?.string
        XCTAssertEqual(ledger, SchemaV8.canonicalDigest)
    }
}

final class AuthorityTransitionFaultInjectionTests: XCTestCase {
    func testCancelTransitionRollsBackEverySharedLifecycleTransactionBoundary() async throws {
        let points: [PersistenceFaultPoint] = [
            .afterAuthorityStateCAS,
            .afterAuthorityRunWrite,
            .afterAuthorityTransitionWrite,
            .afterAuthorityPresentationWrite,
            .afterAuthoritySessionWrite,
            .afterAuthorityAgentWrite,
            .afterEventInsertBeforeOutboxInsert,
            .afterOutboxInsertBeforeSequenceAdvance,
            .beforeTransactionCommit,
        ]
        for point in points {
            let armed = PR5ArmedPersistenceFault()
            let store = try await SQLiteServiceStore.open(storage: .memory, faultInjector: .init { observed in
                try await armed.hit(observed)
            })
            let provider = PR5ProviderDispatcher(mode: .held)
            let (authority, session, root) = try await PR5TestSupport.makeAuthority(store: store, dispatcher: provider)
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try await authority.execute(
                command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh),
                sessionID: session.sessionID,
                externalActor: PR5TestSupport.actor,
                idempotencyKey: "boundary-start-\(point.rawValue)",
                requestDigest: "boundary-start"
            )
            let latestRun = try await store.latestRun(sessionID: session.sessionID)
            let run = try XCTUnwrap(latestRun)
            await provider.waitUntilStarted(run.runID)
            let eventCount = try await store.database.query("SELECT COUNT(*) AS value FROM events").first?.column("value")?.integer
            let outboxCount = try await store.database.query("SELECT COUNT(*) AS value FROM event_outbox").first?.column("value")?.integer
            let transitionCount = try await store.database.query("SELECT COUNT(*) AS value FROM authority_transitions").first?.column("value")?.integer

            await armed.arm(point)
            do {
                _ = try await authority.execute(
                    command: .cancelSession(expectedRunID: run.runID, expectedGeneration: run.generation),
                    sessionID: session.sessionID,
                    externalActor: PR5TestSupport.actor,
                    idempotencyKey: "boundary-cancel-\(point.rawValue)",
                    requestDigest: "boundary-cancel"
                )
                XCTFail("Expected injected failure at \(point.rawValue)")
            } catch is PR5InjectedFailure {}

            let persistedRun = try await store.latestRun(sessionID: session.sessionID)
            let persistedSession = try await store.session(id: session.sessionID)
            let persistedEventCount = try await store.database.query("SELECT COUNT(*) AS value FROM events").first?.column("value")?.integer
            let persistedOutboxCount = try await store.database.query("SELECT COUNT(*) AS value FROM event_outbox").first?.column("value")?.integer
            let persistedTransitionCount = try await store.database.query("SELECT COUNT(*) AS value FROM authority_transitions").first?.column("value")?.integer
            let cancelCallCount = await provider.cancelCallCount()
            XCTAssertEqual(persistedRun?.state, "running")
            XCTAssertEqual(persistedSession?.state, .running)
            XCTAssertEqual(persistedEventCount, eventCount)
            XCTAssertEqual(persistedOutboxCount, outboxCount)
            XCTAssertEqual(persistedTransitionCount, transitionCount)
            XCTAssertEqual(cancelCallCount, 0, "Provider side effect ran despite rollback at \(point.rawValue)")
            await provider.abandon(run.runID)
            await authority.waitForProviderRunsToSettle()
            try await store.close()
        }
    }

    func testEventAndPendingOutboxRollbackTogetherAtEveryNewCrashBoundary() async throws {
        for point in [
            PersistenceFaultPoint.afterEventInsertBeforeOutboxInsert,
            .afterOutboxInsertBeforeSequenceAdvance,
        ] {
            let injector = PersistenceFaultInjector { observed in
                if observed == point { throw PR5InjectedFailure() }
            }
            let store = try await SQLiteServiceStore.open(storage: .memory, faultInjector: injector)
            do {
                _ = try await PR5TestSupport.persistProject(in: store)
                XCTFail("Expected injected failure at \(point.rawValue)")
            } catch is PR5InjectedFailure {}

            let metadata = try await store.metadata()
            let eventCount = try await store.database.query("SELECT COUNT(*) AS value FROM events")
                .first?.column("value")?.integer
            let outboxCount = try await store.database.query("SELECT COUNT(*) AS value FROM event_outbox")
                .first?.column("value")?.integer
            let projectCount = try await store.database.query("SELECT COUNT(*) AS value FROM projects")
                .first?.column("value")?.integer
            XCTAssertEqual(metadata.nextGlobalSequence, 1)
            XCTAssertEqual(eventCount, 0)
            XCTAssertEqual(outboxCount, 0)
            XCTAssertEqual(projectCount, 0)
            try await store.close()
        }
    }
}

final class ProviderEventAtomicityTests: XCTestCase {
    func testReceiptProjectionEventAndOutboxRollbackAsOneUnitAtEveryFrameBoundary() async throws {
        for point in [
            PersistenceFaultPoint.afterProviderEventReceiptInsert,
            .afterProviderSessionWrite,
            .afterEventInsertBeforeOutboxInsert,
            .afterOutboxInsertBeforeSequenceAdvance,
            .beforeTransactionCommit,
        ] {
            let armed = PR5ArmedPersistenceFault()
            let store = try await SQLiteServiceStore.open(storage: .memory, faultInjector: .init { observed in
                try await armed.hit(observed)
            })
            let provider = PR5ProviderDispatcher(mode: .held)
            let (authority, created, root) = try await PR5TestSupport.makeAuthority(store: store, dispatcher: provider)
            _ = try await authority.execute(command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh), sessionID: created.sessionID, externalActor: PR5TestSupport.actor, idempotencyKey: "atomic-\(point.rawValue)", requestDigest: "atomic")
            let latestRun = try await store.latestRun(sessionID: created.sessionID)
            let run = try XCTUnwrap(latestRun)
            await provider.waitUntilStarted(run.runID)
            let storedBefore = try await store.session(id: created.sessionID)
            let before = try XCTUnwrap(storedBefore)
            let entry = TranscriptEntry(entryID: UUID(), sessionSequence: (before.transcript.map(\.sessionSequence).max() ?? 0) + 1, kind: .assistant, content: "atomic", actor: nil, timestamp: Date())
            let proposed = before.replacing(revision: before.revision + 1, transcript: before.transcript + [entry])
            let identity = ProviderEventIdentity(runID: run.runID, providerEventID: "atomic-frame", payloadDigest: "digest", generation: run.generation, turnEpoch: run.turnEpoch, eventKind: "assistantFinal", connectionGeneration: 1, providerSequence: 2)
            let mutation = ProviderEventMutation(identity: identity, sessionEvent: .init(snapshot: proposed, eventType: .transcriptMessage, correlationID: UUID()))
            let eventCount = try await store.database.query("SELECT COUNT(*) AS value FROM events").first?.column("value")?.integer
            let outboxCount = try await store.database.query("SELECT COUNT(*) AS value FROM event_outbox").first?.column("value")?.integer
            await armed.arm(point)
            do {
                _ = try await store.applyProviderEvent(mutation)
                XCTFail("Expected injected provider-frame failure at \(point.rawValue)")
            } catch is PR5InjectedFailure {}
            let receiptCountAfterFailure = try await store.database.query("SELECT COUNT(*) AS value FROM provider_event_receipts WHERE provider_event_id='atomic-frame'").first?.column("value")?.integer
            let eventCountAfterFailure = try await store.database.query("SELECT COUNT(*) AS value FROM events").first?.column("value")?.integer
            let outboxCountAfterFailure = try await store.database.query("SELECT COUNT(*) AS value FROM event_outbox").first?.column("value")?.integer
            let sessionAfterFailure = try await store.session(id: created.sessionID)
            XCTAssertEqual(receiptCountAfterFailure, 0)
            XCTAssertEqual(eventCountAfterFailure, eventCount)
            XCTAssertEqual(outboxCountAfterFailure, outboxCount)
            XCTAssertEqual(sessionAfterFailure?.revision, before.revision)
            let retried = try await store.applyProviderEvent(mutation)
            XCTAssertTrue(retried.applied)
            await provider.abandon(run.runID)
            await authority.waitForProviderRunsToSettle()
            try await store.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testExactReplayIsNoOpWhileIdenticalPayloadAtNextSequenceIsDistinctAndGapsFail() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let provider = PR5ProviderDispatcher(mode: .held)
        let (authority, created, root) = try await PR5TestSupport.makeAuthority(store: store, dispatcher: provider)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await authority.execute(command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh), sessionID: created.sessionID, externalActor: PR5TestSupport.actor, idempotencyKey: "sequence", requestDigest: "sequence")
        let latestRun = try await store.latestRun(sessionID: created.sessionID)
        let run = try XCTUnwrap(latestRun)
        await provider.waitUntilStarted(run.runID)
        let storedBase = try await store.session(id: created.sessionID)
        let base = try XCTUnwrap(storedBase)
        func mutation(sequence: Int64, eventID: String, digest: String = "same") -> ProviderEventMutation {
            let entry = TranscriptEntry(entryID: UUID(), sessionSequence: sequence, kind: .assistant, content: "same", actor: nil, timestamp: Date())
            let snapshot = base.replacing(revision: base.revision + sequence - 1, transcript: base.transcript + [entry])
            return ProviderEventMutation(identity: .init(runID: run.runID, providerEventID: eventID, payloadDigest: digest, generation: run.generation, turnEpoch: run.turnEpoch, eventKind: "assistantFinal", connectionGeneration: 1, providerSequence: sequence), sessionEvent: .init(snapshot: snapshot, eventType: .transcriptMessage, correlationID: UUID()))
        }
        let second = mutation(sequence: 2, eventID: "two")
        let applied = try await store.applyProviderEvent(second)
        let duplicate = try await store.applyProviderEvent(second)
        XCTAssertTrue(applied.applied)
        XCTAssertFalse(duplicate.applied)
        do {
            _ = try await store.applyProviderEvent(mutation(sequence: 4, eventID: "four"))
            XCTFail("Expected sequence gap")
        } catch let error as ServiceAPIError { XCTAssertEqual(error.code, .dependencyUnavailable) }
        do {
            _ = try await store.applyProviderEvent(mutation(sequence: 2, eventID: "two", digest: "different"))
            XCTFail("Expected provider identity conflict")
        } catch let error as ServiceAPIError { XCTAssertEqual(error.code, .idempotencyConflict) }
        let third = try await store.applyProviderEvent(mutation(sequence: 3, eventID: "three"))
        let reconnected = ProviderEventMutation(identity: .init(
            runID: run.runID,
            providerEventID: "two",
            payloadDigest: "reconnected",
            generation: run.generation,
            turnEpoch: run.turnEpoch,
            eventKind: "progress",
            connectionGeneration: 2,
            providerSequence: 1
        ))
        let reconnectResult = try await store.applyProviderEvent(reconnected)
        let receiptCount = try await store.database.query("SELECT COUNT(*) AS value FROM provider_event_receipts WHERE run_id=?", [.text(run.runID.uuidString)]).first?.column("value")?.integer
        XCTAssertTrue(third.applied)
        XCTAssertTrue(reconnectResult.applied)
        XCTAssertEqual(receiptCount, 4)
        await provider.abandon(run.runID)
        await authority.waitForProviderRunsToSettle()
        try await store.close()
    }
}

private actor PR5FailOnceHook {
    private var pending = true

    func hit(_: EventEnvelope) throws {
        if pending {
            pending = false
            throw PR5InjectedFailure()
        }
    }
}

private actor PR5PublishedSequenceRecorder {
    private var sequences: [Int64] = []

    func record(_ event: EventEnvelope) {
        sequences.append(event.globalSequence)
    }

    func values() -> [Int64] {
        sequences
    }
}

final class OrderedEventOutboxTests: XCTestCase {
    func testPublishMarkCrashRedeliversNWithoutBypassingNPlusOneOrDuplicatingConsumer() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let first = try await PR5TestSupport.persistProject(in: store, name: "N")
        let second = try await PR5TestSupport.persistProject(in: store, name: "N+1")
        let hub = ServiceEventHub(subscriberBufferLimit: 8)
        let stream = await hub.subscribe()
        let failOnce = PR5FailOnceHook()
        let dispatcher = OrderedEventOutboxDispatcher(
            store: store,
            hub: hub,
            hooks: .init(afterPublishBeforeDispatchedMarker: { event in
                try await failOnce.hit(event)
            })
        )

        do {
            try await dispatcher.drainStartupWatermark(second.cursor)
            XCTFail("Expected simulated crash after publish and before marker")
        } catch is PR5InjectedFailure {}
        let statesAfterCrash = try await store.database.query(
            "SELECT global_sequence,state,dispatch_attempt_count FROM event_outbox ORDER BY global_sequence"
        )
        XCTAssertEqual(statesAfterCrash.map { $0.column("state")?.string }, ["pending", "pending"])
        XCTAssertEqual(statesAfterCrash.map { $0.column("dispatch_attempt_count")?.integer }, [1, 0])

        try await dispatcher.drainStartupWatermark(first.cursor)
        let statesAfterBoundedDrain = try await store.database.query(
            "SELECT global_sequence,state,dispatch_attempt_count FROM event_outbox ORDER BY global_sequence"
        )
        XCTAssertEqual(statesAfterBoundedDrain.map { $0.column("state")?.string }, ["dispatched", "pending"])
        XCTAssertEqual(statesAfterBoundedDrain.map { $0.column("dispatch_attempt_count")?.integer }, [2, 0])

        try await dispatcher.drainStartupWatermark(second.cursor)
        await hub.finish()
        var iterator = stream.makeAsyncIterator()
        let deliveredFirst = try await iterator.next()
        let deliveredSecond = try await iterator.next()
        let exhausted = try await iterator.next()
        XCTAssertEqual(deliveredFirst?.globalSequence, first.globalSequence)
        XCTAssertEqual(deliveredSecond?.globalSequence, second.globalSequence)
        XCTAssertNil(exhausted)
        let states = try await store.database.query(
            "SELECT state FROM event_outbox ORDER BY global_sequence"
        ).compactMap { $0.column("state")?.string }
        XCTAssertEqual(states, ["dispatched", "dispatched"])
        try await store.close()
    }

    func testStopCancelsWorkerBeforeSingleOwnerDrain() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        var expected: [Int64] = []
        for index in 0 ..< 32 {
            let event = try await PR5TestSupport.persistProject(in: store, name: "stop-\(index)")
            expected.append(event.globalSequence)
        }
        let recorder = PR5PublishedSequenceRecorder()
        let dispatcher = OrderedEventOutboxDispatcher(
            store: store,
            hub: ServiceEventHub(subscriberBufferLimit: 64),
            batchLimit: 4,
            hooks: .init(afterPublishBeforeDispatchedMarker: { event in
                await recorder.record(event)
            })
        )

        await dispatcher.start()
        await dispatcher.stop(drain: true)

        let recorded = await recorder.values()
        XCTAssertEqual(recorded, expected)
        let states = try await store.database.query(
            "SELECT state FROM event_outbox ORDER BY global_sequence"
        ).compactMap { $0.column("state")?.string }
        XCTAssertEqual(states, Array(repeating: "dispatched", count: expected.count))
        try await store.close()
    }

    func testPendingOutboxRowIsHardRetentionFloorAndDispatchedPrefixCanArchive() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let event = try await PR5TestSupport.persistProject(in: store)
        let pendingArchive = try await store.archiveEvents(through: event.globalSequence)
        let pendingEvents = try await store.events(after: nil, limit: 10).events
        XCTAssertNil(pendingArchive)
        XCTAssertEqual(pendingEvents.count, 1)

        try await store.markEventOutboxDispatched(event.cursor)
        let dispatchedArchive = try await store.archiveEvents(through: event.globalSequence)
        let remainingEvents = try await store.events(after: nil, limit: 10).events
        XCTAssertNotNil(dispatchedArchive)
        XCTAssertTrue(remainingEvents.isEmpty)
        let outboxCount = try await store.database.query("SELECT COUNT(*) AS value FROM event_outbox")
            .first?.column("value")?.integer
        XCTAssertEqual(outboxCount, 0)
        try await store.close()
    }
}

final class EventConsumerDedupeContractTests: XCTestCase {
    func testGateRejectsDuplicateAndStoreChangeUntilExplicitResnapshot() {
        let firstStore = UUID()
        let secondStore = UUID()
        var gate = EventDeliveryCursorGate()
        XCTAssertTrue(gate.shouldDeliver(.init(storeID: firstStore, globalSequence: 1)))
        XCTAssertFalse(gate.shouldDeliver(.init(storeID: firstStore, globalSequence: 1)))
        XCTAssertTrue(gate.shouldDeliver(.init(storeID: firstStore, globalSequence: 2)))
        XCTAssertFalse(gate.shouldDeliver(.init(storeID: secondStore, globalSequence: 1)))
        XCTAssertEqual(gate.greatestDelivered, .init(storeID: firstStore, globalSequence: 2))
        gate.resetForNewStore(.init(storeID: secondStore, globalSequence: 0))
        XCTAssertTrue(gate.shouldDeliver(.init(storeID: secondStore, globalSequence: 1)))
    }
}

final class EventReplayLiveRaceTests: XCTestCase {
    func testRegisterFirstLiveGateDropsReplayOverlapAndPreservesNextSequence() async throws {
        let storeID = UUID()
        let hub = ServiceEventHub(subscriberBufferLimit: 8)
        let stream = await hub.subscribe(after: .init(storeID: storeID, globalSequence: 10))
        let replayOverlap = PR5TestSupport.event(storeID: storeID, sequence: 10)
        let live = PR5TestSupport.event(
            storeID: storeID,
            sequence: 11,
            projectID: replayOverlap.projectID
        )
        await hub.publish(replayOverlap)
        await hub.publish(live)
        await hub.finish()
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        let exhausted = try await iterator.next()
        XCTAssertEqual(first?.globalSequence, 11)
        XCTAssertNil(exhausted)
    }

    func testSlowSubscriberTerminatesWithLastSafeCursor() async throws {
        let storeID = UUID()
        let hub = ServiceEventHub(subscriberBufferLimit: 1)
        let stream = await hub.subscribe()
        await hub.publish(PR5TestSupport.event(storeID: storeID, sequence: 1))
        await hub.publish(PR5TestSupport.event(storeID: storeID, sequence: 2))
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertEqual(first?.globalSequence, 1)
        do {
            _ = try await iterator.next()
            XCTFail("Expected slow-consumer termination")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rateLimited)
            XCTAssertEqual(error.cursor, .init(storeID: storeID, globalSequence: 1))
        }
    }

    func testStoreIdentityChangeTerminatesRegisteredConsumer() async throws {
        let firstStore = UUID()
        let hub = ServiceEventHub(subscriberBufferLimit: 2)
        let stream = await hub.subscribe(after: .init(storeID: firstStore, globalSequence: 4))
        await hub.publish(PR5TestSupport.event(storeID: UUID(), sequence: 1))
        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Expected resnapshot requirement")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .cursorExpired)
            XCTAssertEqual(error.cursor, .init(storeID: firstStore, globalSequence: 4))
        }
    }
}

final class MCPInvocationIdentityContractTests: XCTestCase {
    func testJSONRPCIdentityNeverSynthesizesDurableApplicationInvocation() {
        let identity = MCPRequestTimelineIdentity(
            jsonRPCRequestID: .number(1),
            connectionID: UUID().uuidString,
            connectionGeneration: 1,
            requestOrdinal: 1
        )
        XCTAssertNil(identity.appInvocationID)

        let appInvocationID = UUID().uuidString.lowercased()
        let explicit = MCPRequestTimelineIdentity(
            jsonRPCRequestID: .number(1),
            connectionID: UUID().uuidString,
            connectionGeneration: 1,
            appInvocationID: appInvocationID,
            requestOrdinal: 1
        )
        XCTAssertEqual(explicit.appInvocationID, appInvocationID)
        let binding = AuthorityMCPBinding(
            sessionID: UUID(),
            actor: PR5TestSupport.actor,
            appInvocationID: explicit.appInvocationID
        )
        XCTAssertEqual(binding.appInvocationID, appInvocationID)
    }
}

private actor PR5ProviderDispatcher: AgentProviderDispatcher {
    enum Mode {
        case immediate
        case held
        case cancelAmbiguous
    }

    private let mode: Mode
    private var active: Set<UUID> = []
    private var cancelRequests: Int = 0
    private var executionContinuations: [UUID: CheckedContinuation<ProviderExecutionResult, Error>] = [:]
    private var startWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    init(mode: Mode) {
        self.mode = mode
    }

    func capabilities() -> [ProviderCapability] {
        [.init(kind: .codex, enabled: true, executable: "/test/codex", supportsResume: true, supportsSteering: false)]
    }

    func preflight() -> [ProviderCapability] { capabilities() }
    func recoverProcessFamilies() async throws {}

    func execute(
        kind _: ProviderKind,
        model _: String?,
        prompt: String,
        workingDirectory _: String,
        maximumBytes _: Int,
        runID: UUID?,
        resumeProviderSessionID _: String?,
        onProviderSessionIdentity: @escaping @Sendable (String) async -> Void
    ) async throws -> ProviderExecutionResult {
        let runID = runID ?? UUID()
        await onProviderSessionIdentity("native-\(runID.uuidString)")
        return try await executeBody(runID: runID, output: "provider:\(prompt)")
    }

    func executeStreaming(
        _ request: ProviderExecutionRequest,
        onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void
    ) async throws -> ProviderExecutionResult {
        active.insert(request.runID)
        await onEvent(.providerIdentity("native-\(request.runID.uuidString)"))
        let result = try await executeBody(runID: request.runID, output: "provider:\(request.prompt)")
        await onEvent(.framed(providerEventID: "assistant-final", providerSequence: 2, event: .assistantFinal(result.output)))
        // Exact redelivery must be discarded by the durable provider receipt.
        await onEvent(.framed(providerEventID: "assistant-final", providerSequence: 2, event: .assistantFinal(result.output)))
        await onEvent(.completed(providerSessionID: result.providerSessionID))
        active.remove(request.runID)
        return result
    }

    func cancel(runID: UUID) throws {
        cancelRequests += 1
        if mode == .cancelAmbiguous { throw PR5InjectedFailure() }
        active.remove(runID)
        executionContinuations.removeValue(forKey: runID)?.resume(throwing: CancellationError())
    }

    func hasActiveRun(_ runID: UUID) -> Bool { active.contains(runID) }
    func cancelCallCount() -> Int { cancelRequests }

    func waitUntilStarted(_ runID: UUID) async {
        if executionContinuations[runID] != nil { return }
        await withCheckedContinuation { continuation in
            startWaiters[runID, default: []].append(continuation)
        }
    }

    func abandon(_ runID: UUID) {
        active.remove(runID)
        executionContinuations.removeValue(forKey: runID)?.resume(throwing: CancellationError())
    }

    private func executeBody(runID: UUID, output: String) async throws -> ProviderExecutionResult {
        switch mode {
        case .immediate:
            for waiter in startWaiters.removeValue(forKey: runID) ?? [] { waiter.resume() }
            active.remove(runID)
            return .init(output: output, providerSessionID: "native-\(runID.uuidString)")
        case .held, .cancelAmbiguous:
            return try await withCheckedThrowingContinuation { continuation in
                executionContinuations[runID] = continuation
                for waiter in startWaiters.removeValue(forKey: runID) ?? [] { waiter.resume() }
            }
        }
    }
}

final class IdempotencyRetryContractTests: XCTestCase {
    func testSameLifecycleIdentityReplaysReceiptAndConflictingDigestIsRejected() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let provider = PR5ProviderDispatcher(mode: .immediate)
        let (authority, session, root) = try await PR5TestSupport.makeAuthority(store: store, dispatcher: provider)
        defer { try? FileManager.default.removeItem(at: root) }
        let command = SessionCommand.resumeSession(expectedRunID: nil, providerResumeMode: .fresh)
        let first = try await authority.execute(
            command: command,
            sessionID: session.sessionID,
            externalActor: PR5TestSupport.actor,
            idempotencyKey: "app-invocation-1",
            requestDigest: "digest-a"
        )
        let replay = try await authority.execute(
            command: command,
            sessionID: session.sessionID,
            externalActor: PR5TestSupport.actor,
            idempotencyKey: "app-invocation-1",
            requestDigest: "digest-a"
        )
        XCTAssertEqual(replay.commandID, first.commandID)
        do {
            _ = try await authority.execute(
                command: command,
                sessionID: session.sessionID,
                externalActor: PR5TestSupport.actor,
                idempotencyKey: "app-invocation-1",
                requestDigest: "digest-b"
            )
            XCTFail("Expected idempotency conflict")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .idempotencyConflict)
        }
        await authority.waitForProviderRunsToSettle()
        let completed = try await authority.sessionSnapshot(sessionID: session.sessionID)
        XCTAssertEqual(completed.transcript.filter { $0.kind == .assistant }.count, 1)
        let transitionCount = try await store.database.query(
            "SELECT COUNT(*) AS value FROM authority_transitions WHERE kind='start'"
        ).first?.column("value")?.integer
        XCTAssertEqual(transitionCount, 1)
        let providerReceiptCount = try await store.database.query(
            "SELECT COUNT(*) AS value FROM provider_event_receipts"
        ).first?.column("value")?.integer
        XCTAssertEqual(providerReceiptCount, 2)
        _ = try await store.database.query(
            "DELETE FROM idempotency_records WHERE actor_id=? AND operation='resumeSession' AND idempotency_key='app-invocation-1'",
            [.text(PR5TestSupport.actor.userID)]
        )
        let transitionReplay = try await authority.execute(
            command: command,
            sessionID: session.sessionID,
            externalActor: PR5TestSupport.actor,
            idempotencyKey: "app-invocation-1",
            requestDigest: "digest-a"
        )
        XCTAssertEqual(transitionReplay.commandID, first.commandID)
        _ = try await store.database.query(
            "UPDATE authority_transitions SET response_body=NULL WHERE actor_id=? AND operation='resumeSession' AND idempotency_key='app-invocation-1'",
            [.text(PR5TestSupport.actor.userID)]
        )
        do {
            _ = try await authority.execute(command: command, sessionID: session.sessionID, externalActor: PR5TestSupport.actor, idempotencyKey: "app-invocation-1", requestDigest: "digest-a")
            XCTFail("Expected expired durable response to require resnapshot")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .operationReconciling)
        }
        try await store.close()
    }
}

final class ProviderLifecycleRecoveryTests: XCTestCase {
    func testUncleanRunningProviderIsInterruptedAtomicallyWhenNativeRunIsAbsent() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let provider = PR5ProviderDispatcher(mode: .held)
        let (authority, session, root) = try await PR5TestSupport.makeAuthority(store: store, dispatcher: provider)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await authority.execute(
            command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh),
            sessionID: session.sessionID,
            externalActor: PR5TestSupport.actor,
            idempotencyKey: "restart-start",
            requestDigest: "restart-start"
        )
        let latestRun = try await store.latestRun(sessionID: session.sessionID)
        let run = try XCTUnwrap(latestRun)
        await provider.waitUntilStarted(run.runID)
        await provider.abandon(run.runID)
        await authority.waitForProviderRunsToSettle()

        let recovered = RepoPromptHeadlessAuthority(store: store, providerAdapter: provider)
        try await recovered.recover()
        let snapshot = try await recovered.sessionSnapshot(sessionID: session.sessionID)
        XCTAssertEqual(snapshot.state, .interrupted)
        let recoveredRun = try await store.latestRun(sessionID: session.sessionID)
        let persistedRun = try XCTUnwrap(recoveredRun)
        XCTAssertEqual(persistedRun.state, "interrupted")
        let pending = try await store.nonfinalAuthorityTransitions()
        XCTAssertTrue(pending.isEmpty)
        try await store.close()
    }

    func testAmbiguousProviderCancellationRemainsDurablyReconciling() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let provider = PR5ProviderDispatcher(mode: .cancelAmbiguous)
        let (authority, session, root) = try await PR5TestSupport.makeAuthority(store: store, dispatcher: provider)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await authority.execute(
            command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh),
            sessionID: session.sessionID,
            externalActor: PR5TestSupport.actor,
            idempotencyKey: "ambiguous-start",
            requestDigest: "ambiguous-start"
        )
        let latestRun = try await store.latestRun(sessionID: session.sessionID)
        let run = try XCTUnwrap(latestRun)
        await provider.waitUntilStarted(run.runID)
        do {
            _ = try await authority.execute(
                command: .cancelSession(expectedRunID: run.runID, expectedGeneration: run.generation),
                sessionID: session.sessionID,
                externalActor: PR5TestSupport.actor,
                idempotencyKey: "ambiguous-cancel",
                requestDigest: "ambiguous-cancel"
            )
            XCTFail("Expected reconciliation-required result")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .operationReconciling)
        }
        let transitions = try await store.nonfinalAuthorityTransitions()
        XCTAssertEqual(transitions.last?.state, .reconciliationRequired)
        let cancelRequestedRun = try await store.latestRun(sessionID: session.sessionID)
        XCTAssertEqual(cancelRequestedRun?.state, "cancelRequested")
        await provider.abandon(run.runID)
        await authority.waitForProviderRunsToSettle()
        try await store.close()
    }
}

final class SustainedProviderConcurrencyTests: XCTestCase {
    func testConcurrentProjectsKeepGlobalEventsContiguousAndRunsIsolated() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        let provider = PR5ProviderDispatcher(mode: .immediate)
        var authorities: [(RepoPromptHeadlessAuthority, SessionSnapshot, URL)] = []
        for _ in 0 ..< 16 {
            authorities.append(try await PR5TestSupport.makeAuthority(store: store, dispatcher: provider))
        }
        defer { for item in authorities { try? FileManager.default.removeItem(at: item.2) } }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, item) in authorities.enumerated() {
                group.addTask {
                    _ = try await item.0.execute(
                        command: .resumeSession(expectedRunID: nil, providerResumeMode: .fresh),
                        sessionID: item.1.sessionID,
                        externalActor: PR5TestSupport.actor,
                        idempotencyKey: "concurrent-\(index)",
                        requestDigest: "concurrent-\(index)"
                    )
                    await item.0.waitForProviderRunsToSettle()
                }
            }
            try await group.waitForAll()
        }
        for item in authorities {
            let snapshot = try await item.0.sessionSnapshot(sessionID: item.1.sessionID)
            XCTAssertEqual(snapshot.state, .completed)
        }
        let events = try await store.events(after: nil, limit: 10_000).events
        XCTAssertEqual(events.map(\.globalSequence), Array(1 ... Int64(events.count)))
        let uncovered = try await store.database.query(
            "SELECT COUNT(*) AS value FROM events e LEFT JOIN event_outbox o ON o.global_sequence=e.global_sequence WHERE o.global_sequence IS NULL"
        ).first?.column("value")?.integer
        XCTAssertEqual(uncovered, 0)
        try await store.close()
    }
}
