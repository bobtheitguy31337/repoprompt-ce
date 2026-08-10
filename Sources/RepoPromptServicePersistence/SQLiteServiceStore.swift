import Foundation
import RepoPromptServiceProtocol
import SQLiteNIO

public struct PersistedProcessIdentity: Codable, Hashable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let processGroupID: Int32
    public let sessionID: Int32
    public let startTimeTicks: UInt64
    public let bootID: String
    public let executablePath: String
    public let helperTokenDigest: String

    public init(pid: Int32, parentPID: Int32, processGroupID: Int32, sessionID: Int32, startTimeTicks: UInt64, bootID: String, executablePath: String, helperTokenDigest: String) {
        self.pid = pid
        self.parentPID = parentPID
        self.processGroupID = processGroupID
        self.sessionID = sessionID
        self.startTimeTicks = startTimeTicks
        self.bootID = bootID
        self.executablePath = executablePath
        self.helperTokenDigest = helperTokenDigest
    }
}

public struct PersistedProcessFamily: Codable, Hashable, Sendable {
    public let runID: UUID
    public let leader: PersistedProcessIdentity
    public let connectionGeneration: Int64
    public let containmentMode: String
    public let state: String
}

public actor SQLiteServiceStore {
    public struct Metadata: Sendable {
        public let storeID: UUID
        public let schemaVersion: Int
        public let nextGlobalSequence: Int64
        public let replayFloor: Int64
        public let lastCleanShutdown: Bool
    }

    public enum Storage: Sendable { case memory, file(String) }

    private let connection: SQLiteConnection
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let eventSigningKey: ServiceEventSigningKey?
    private var closed = false

    private init(connection: SQLiteConnection, eventSigningKey: ServiceEventSigningKey?) {
        self.connection = connection
        self.eventSigningKey = eventSigningKey
        encoder = JSONEncoder.serviceEncoder
        decoder = JSONDecoder.serviceDecoder
    }

    public static func open(storage: Storage, eventSigningKey: ServiceEventSigningKey? = nil) async throws -> SQLiteServiceStore {
        let location: SQLiteConnection.Storage = switch storage { case .memory: .memory
        case let .file(path): .file(path: path) }
        let connection = try await SQLiteConnection.open(storage: location)
        let store = SQLiteServiceStore(connection: connection, eventSigningKey: eventSigningKey)
        try await store.migrate()
        try await store.integrityCheck()
        return store
    }

    public func close(clean: Bool = true) async throws {
        guard !closed else { return }
        if clean {
            _ = try await connection.query("UPDATE service_metadata SET last_clean_shutdown = 1 WHERE fixed_id = 1")
            _ = try await connection.query("PRAGMA wal_checkpoint(TRUNCATE)")
        }
        try await connection.close()
        closed = true
    }

    public func metadata() async throws -> Metadata {
        let row = try await requireRow(connection.query("SELECT store_id, schema_version, next_global_sequence, replay_floor, last_clean_shutdown FROM service_metadata WHERE fixed_id = 1"))
        return try Metadata(
            storeID: requireUUID(row.column("store_id")?.string),
            schemaVersion: row.column("schema_version")?.integer ?? 1,
            nextGlobalSequence: Int64(row.column("next_global_sequence")?.integer ?? 1),
            replayFloor: Int64(row.column("replay_floor")?.integer ?? 0),
            lastCleanShutdown: row.column("last_clean_shutdown")?.bool ?? false
        )
    }

    public func nextCursor() async throws -> ServiceCursor {
        let value = try await metadata()
        return ServiceCursor(storeID: value.storeID, globalSequence: value.nextGlobalSequence)
    }

    public func persistProject(_ snapshot: ProjectSnapshot, eventType: EventType, actor: ExternalActor, correlationID: UUID, idempotency: IdempotencyInput?) async throws -> EventEnvelope {
        try await transaction {
            try await validateExpectedCursor(snapshot.cursor)
            if let idempotency, let existing = try await existingIdempotency(idempotency) { throw ExistingIdempotency(existing) }
            let snapshotJSON = try encodeText(snapshot)
            _ = try await connection.query(
                "INSERT INTO projects(project_id, schema_version, name, creator_json, lifecycle_state, revision, snapshot_json, created_at, updated_at) VALUES(?,1,?,?,?,?,?,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP) ON CONFLICT(project_id) DO UPDATE SET name=excluded.name,lifecycle_state=excluded.lifecycle_state,revision=excluded.revision,snapshot_json=excluded.snapshot_json,updated_at=CURRENT_TIMESTAMP",
                [.text(snapshot.projectID.uuidString), .text(snapshot.name), .text(encodeText(actor)), .text(snapshot.state.rawValue), .integer(Int(snapshot.revision)), .text(snapshotJSON)]
            )
            for root in snapshot.roots {
                _ = try await connection.query("INSERT INTO project_roots(root_id,project_id,schema_version,logical_name,canonical_path,filesystem_identity,writable,revision) VALUES(?,?,1,?,?,?,?,?) ON CONFLICT(root_id) DO UPDATE SET logical_name=excluded.logical_name,canonical_path=excluded.canonical_path,writable=excluded.writable,revision=excluded.revision", [.text(root.rootID.uuidString), .text(snapshot.projectID.uuidString), .text(root.logicalName), .text(root.canonicalPath), .text("pending"), .integer(root.writable ? 1 : 0), .integer(Int(root.revision))])
            }
            let event = try await appendEvent(projectID: snapshot.projectID, sessionID: nil, rootSessionID: nil, runID: nil, sessionSequence: nil, type: eventType, generation: nil, turnEpoch: nil, actor: actor, correlationID: correlationID, payload: Data(snapshotJSON.utf8))
            if let idempotency { try await saveIdempotency(idempotency, status: 201, response: encoder.encode(snapshot)) }
            return event
        }
    }

    public func persistSession(
        _ snapshot: SessionSnapshot,
        eventType: EventType,
        actor: ExternalActor?,
        correlationID: UUID,
        idempotency: IdempotencyInput?,
        idempotencyResponse: Data? = nil,
        initialSelection: SelectionSnapshot? = nil
    ) async throws -> EventEnvelope {
        try await transaction {
            try await persistSessionInTransaction(snapshot, eventType: eventType, actor: actor, correlationID: correlationID, idempotency: idempotency, idempotencyResponse: idempotencyResponse, initialSelection: initialSelection)
        }
    }

    public func persistNewSession(
        _ snapshot: SessionSnapshot,
        agent: AgentSnapshot,
        actor: ExternalActor,
        correlationID: UUID,
        agentCorrelationID: UUID,
        idempotency: IdempotencyInput,
        initialSelection: SelectionSnapshot
    ) async throws -> (session: EventEnvelope, agent: EventEnvelope) {
        try await transaction {
            let sessionEvent = try await persistSessionInTransaction(snapshot, eventType: .sessionCreated, actor: actor, correlationID: correlationID, idempotency: idempotency, idempotencyResponse: nil, initialSelection: initialSelection)
            let agentEvent = try await persistAgentInTransaction(agent, projectID: snapshot.projectID, actor: snapshot.parentSessionID == nil ? actor : nil, correlationID: agentCorrelationID, eventType: .agentStarted)
            return (sessionEvent, agentEvent)
        }
    }

    public func persistImportedProject(_ snapshot: ProjectSnapshot, sourceDigest: String, actor: ExternalActor) async throws -> Bool {
        try await transaction {
            if try await importAuditExists(kind: "legacy.project", digest: sourceDigest) { return false }
            if try await project(id: snapshot.projectID) != nil {
                throw ServiceAPIError(code: .idempotencyConflict, message: "Legacy import project ID already exists with different provenance")
            }
            try await validateExpectedCursor(snapshot.cursor)
            let snapshotJSON = try encodeText(snapshot)
            _ = try await connection.query(
                "INSERT INTO projects(project_id,schema_version,name,creator_json,lifecycle_state,revision,snapshot_json,created_at,updated_at) VALUES(?,1,?,?,?,?,?,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)",
                [.text(snapshot.projectID.uuidString), .text(snapshot.name), .text(encodeText(actor)), .text(snapshot.state.rawValue), .integer(Int(snapshot.revision)), .text(snapshotJSON)]
            )
            for root in snapshot.roots {
                _ = try await connection.query("INSERT INTO project_roots(root_id,project_id,schema_version,logical_name,canonical_path,filesystem_identity,writable,revision) VALUES(?,?,1,?,?,?,?,?)", [.text(root.rootID.uuidString), .text(snapshot.projectID.uuidString), .text(root.logicalName), .text(root.canonicalPath), .text("legacy-import"), .integer(root.writable ? 1 : 0), .integer(Int(root.revision))])
            }
            _ = try await appendEvent(projectID: snapshot.projectID, sessionID: nil, rootSessionID: nil, runID: nil, sessionSequence: nil, type: .projectCreated, generation: nil, turnEpoch: nil, actor: actor, correlationID: UUID(), payload: Data(snapshotJSON.utf8))
            try await recordImportAudit(kind: "legacy.project", digest: sourceDigest)
            return true
        }
    }

    public func persistImportedSession(_ snapshot: SessionSnapshot, sourceDigest: String, actor: ExternalActor) async throws -> Bool {
        try await transaction {
            if try await importAuditExists(kind: "legacy.session", digest: sourceDigest) { return false }
            if try await session(id: snapshot.sessionID) != nil {
                throw ServiceAPIError(code: .idempotencyConflict, message: "Legacy import session ID already exists with different provenance")
            }
            try await validateExpectedCursor(snapshot.cursor)
            let snapshotJSON = try encodeText(snapshot)
            let bindings: [SQLiteData] = [
                .text(snapshot.sessionID.uuidString), .text(snapshot.projectID.uuidString), snapshot.parentSessionID.map { .text($0.uuidString) } ?? .null,
                .text(snapshot.rootSessionID.uuidString), .text(snapshot.creator.goblinUserID), .text(snapshot.state.rawValue), .text(snapshot.provider.rawValue),
                snapshot.model.map(SQLiteData.text) ?? .null, .text(snapshot.visibility.rawValue), .integer(Int(snapshot.runGeneration)), .integer(Int(snapshot.turnEpoch)),
                .integer(Int(snapshot.revision)), .text(snapshotJSON)
            ]
            _ = try await connection.query("INSERT INTO sessions(session_id,project_id,parent_session_id,root_session_id,schema_version,creator_external_id,lifecycle_state,provider_kind,model,visibility,run_generation,turn_epoch,revision,snapshot_json,created_at,updated_at) VALUES(?,?,?,?,1,?,?,?,?,?,?,?,?,?,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)", bindings)
            for entry in snapshot.transcript {
                _ = try await connection.query("INSERT INTO transcript_entries(session_id,entry_id,schema_version,session_sequence,entry_json,content_digest) VALUES(?,?,1,?,?,?)", [.text(snapshot.sessionID.uuidString), .text(entry.entryID.uuidString), .integer(Int(entry.sessionSequence)), .text(encodeText(entry)), .text(CanonicalSigning.bodyDigest(encoder.encode(entry)))])
            }
            let event = try await appendEvent(projectID: snapshot.projectID, sessionID: snapshot.sessionID, rootSessionID: snapshot.rootSessionID, runID: nil, sessionSequence: Int64(snapshot.transcript.count), type: .sessionCreated, generation: snapshot.runGeneration, turnEpoch: snapshot.turnEpoch, actor: actor, correlationID: UUID(), payload: Data(snapshotJSON.utf8))
            if [.completed, .failed, .canceled, .interrupted, .archived].contains(snapshot.state) {
                try await saveCheckpoint(scope: "session:\(snapshot.sessionID.uuidString)", sequence: event.globalSequence, snapshot: Data(snapshotJSON.utf8))
            }
            try await recordImportAudit(kind: "legacy.session", digest: sourceDigest)
            return true
        }
    }

    public func beginLegacyImport(sourceDigest: String) async throws {
        let meta = try await metadata()
        let started = try await importAuditExists(kind: "legacy.import.started", digest: sourceDigest)
        let completed = try await importAuditExists(kind: "legacy.import.completed", digest: sourceDigest)
        let resumable = started && !completed
        guard meta.lastCleanShutdown || meta.nextGlobalSequence == 1 || resumable else {
            throw ServiceAPIError(code: .quiescing, message: "JSON import requires a new, cleanly stopped, or resumable import store")
        }
        if !resumable, !completed {
            try await transaction { try await recordImportAudit(kind: "legacy.import.started", digest: sourceDigest) }
        }
    }

    public func completeLegacyImport(sourceDigest: String) async throws {
        guard try await !importAuditExists(kind: "legacy.import.completed", digest: sourceDigest) else { return }
        try await transaction { try await recordImportAudit(kind: "legacy.import.completed", digest: sourceDigest) }
    }

    public func project(id: UUID) async throws -> ProjectSnapshot? {
        guard let row = try await connection.query("SELECT snapshot_json FROM projects WHERE project_id = ?", [.text(id.uuidString)]).first, let text = row.column("snapshot_json")?.string else { return nil }
        return try decoder.decode(ProjectSnapshot.self, from: Data(text.utf8))
    }

    public func session(id: UUID) async throws -> SessionSnapshot? {
        guard let row = try await connection.query("SELECT snapshot_json FROM sessions WHERE session_id = ?", [.text(id.uuidString)]).first, let text = row.column("snapshot_json")?.string else { return nil }
        return try decoder.decode(SessionSnapshot.self, from: Data(text.utf8))
    }

    public func allProjects() async throws -> [ProjectSnapshot] {
        try await decodeRows("SELECT snapshot_json FROM projects WHERE lifecycle_state != 'archived' ORDER BY created_at", as: ProjectSnapshot.self)
    }

    public func allSessions() async throws -> [SessionSnapshot] {
        try await decodeRows("SELECT snapshot_json FROM sessions ORDER BY created_at", as: SessionSnapshot.self)
    }

    public func persistAgent(_ snapshot: AgentSnapshot, projectID: UUID, actor: ExternalActor?, correlationID: UUID, eventType: EventType) async throws -> EventEnvelope {
        try await transaction {
            try await persistAgentInTransaction(snapshot, projectID: projectID, actor: actor, correlationID: correlationID, eventType: eventType)
        }
    }

    public func agents(rootSessionID: UUID? = nil) async throws -> [AgentSnapshot] {
        let rows = if let rootSessionID {
            try await connection.query("SELECT * FROM agents WHERE root_session_id=? ORDER BY created_at", [.text(rootSessionID.uuidString)])
        } else {
            try await connection.query("SELECT * FROM agents ORDER BY created_at")
        }
        return try rows.map { row in
            guard let agentID = UUID(uuidString: row.column("agent_id")?.string ?? ""),
                  let sessionID = UUID(uuidString: row.column("session_id")?.string ?? ""),
                  let rootID = UUID(uuidString: row.column("root_session_id")?.string ?? ""),
                  let state = SessionLifecycleState(rawValue: row.column("lifecycle_state")?.string ?? "")
            else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Persisted agent is invalid") }
            return AgentSnapshot(agentID: agentID, sessionID: sessionID, rootSessionID: rootID, parentAgentID: row.column("parent_agent_id")?.string.flatMap(UUID.init(uuidString:)), providerNativeIdentity: row.column("provider_native_identity")?.string, role: row.column("role")?.string ?? "agent", label: row.column("label")?.string, state: state, revision: Int64(row.column("revision")?.integer ?? 1))
        }
    }

    public func persistRun(_ snapshot: ProviderRunSnapshot) async throws {
        _ = try await connection.query(
            "INSERT INTO runs(run_id,session_id,schema_version,provider_kind,provider_session_id,state,generation,turn_epoch,start_reason,end_reason,started_at,ended_at) VALUES(?,?,1,?,?,?,?,?,?,?,?,?) ON CONFLICT(run_id) DO UPDATE SET provider_session_id=excluded.provider_session_id,state=excluded.state,turn_epoch=excluded.turn_epoch,end_reason=excluded.end_reason,ended_at=excluded.ended_at",
            [.text(snapshot.runID.uuidString), .text(snapshot.sessionID.uuidString), .text(snapshot.provider.rawValue), snapshot.providerSessionID.map(SQLiteData.text) ?? .null, .text(snapshot.state), .integer(Int(snapshot.generation)), .integer(Int(snapshot.turnEpoch)), .text(snapshot.startReason), snapshot.endReason.map(SQLiteData.text) ?? .null, .float(snapshot.startedAt.timeIntervalSince1970), snapshot.endedAt.map { .float($0.timeIntervalSince1970) } ?? .null]
        )
    }

    public func latestRun(sessionID: UUID) async throws -> ProviderRunSnapshot? {
        guard let row = try await connection.query("SELECT * FROM runs WHERE session_id=? ORDER BY generation DESC LIMIT 1", [.text(sessionID.uuidString)]).first,
              let runID = UUID(uuidString: row.column("run_id")?.string ?? ""),
              let provider = ProviderKind(rawValue: row.column("provider_kind")?.string ?? ""),
              let state = row.column("state")?.string,
              let startReason = row.column("start_reason")?.string
        else { return nil }
        return ProviderRunSnapshot(runID: runID, sessionID: sessionID, provider: provider, providerSessionID: row.column("provider_session_id")?.string, state: state, generation: Int64(row.column("generation")?.integer ?? 0), turnEpoch: Int64(row.column("turn_epoch")?.integer ?? 0), startReason: startReason, endReason: row.column("end_reason")?.string, startedAt: Date(timeIntervalSince1970: row.column("started_at")?.double ?? 0), endedAt: row.column("ended_at")?.double.map(Date.init(timeIntervalSince1970:)))
    }

    public func events(after cursor: ServiceCursor?, limit: Int) async throws -> EventPage {
        let meta = try await metadata()
        if let cursor {
            guard cursor.storeID == meta.storeID else { throw ServiceAPIError(code: .cursorExpired, message: "Store namespace changed", cursor: ServiceCursor(storeID: meta.storeID, globalSequence: meta.replayFloor)) }
            guard cursor.globalSequence >= meta.replayFloor else { throw ServiceAPIError(code: .cursorExpired, message: "Cursor is below replay floor", cursor: ServiceCursor(storeID: meta.storeID, globalSequence: meta.replayFloor)) }
        }
        let after = cursor?.globalSequence ?? meta.replayFloor
        let bounded = max(1, min(limit, 1000))
        let rows = try await connection.query("SELECT envelope_json FROM events WHERE global_sequence > ? ORDER BY global_sequence LIMIT ?", [.integer(Int(after)), .integer(bounded)])
        let events: [EventEnvelope] = try rows.compactMap { row in guard let text = row.column("envelope_json")?.string else { return nil }
            return try decoder.decode(EventEnvelope.self, from: Data(text.utf8))
        }
        return EventPage(storeID: meta.storeID, events: events, nextCursor: events.last?.cursor ?? ServiceCursor(storeID: meta.storeID, globalSequence: after), replayFloor: meta.replayFloor)
    }

    public func idempotencyResult(_ input: IdempotencyInput) async throws -> (response: Data, status: Int)? {
        guard let value = try await existingIdempotency(input) else { return nil }
        return (response: value.0, status: value.1)
    }

    public func persistSelection(_ snapshot: SelectionSnapshot, projectID: UUID, rootSessionID: UUID, actor: ExternalActor, correlationID: UUID, idempotency: IdempotencyInput? = nil) async throws -> EventEnvelope {
        try await transaction {
            if let idempotency, let existing = try await existingIdempotency(idempotency) { throw ExistingIdempotency(existing) }
            _ = try await connection.query(
                "INSERT INTO session_selections(session_id,schema_version,allowed_roots_json,selection_json,selection_revision,binding_revision,transactional_commit_id) VALUES(?,1,?,?,?,?,?) ON CONFLICT(session_id) DO UPDATE SET selection_json=excluded.selection_json,selection_revision=excluded.selection_revision,binding_revision=excluded.binding_revision,transactional_commit_id=excluded.transactional_commit_id",
                [.text(snapshot.sessionID.uuidString), .text(encodeText(Array(Set(snapshot.entries.map(\.rootID))))), .text(encodeText(snapshot)), .integer(Int(snapshot.revision)), .integer(Int(snapshot.bindingRevision)), .text(UUID().uuidString)]
            )
            let event = try await appendEvent(projectID: projectID, sessionID: snapshot.sessionID, rootSessionID: rootSessionID, runID: nil, sessionSequence: nil, type: .selectionUpdated, generation: nil, turnEpoch: nil, actor: actor, correlationID: correlationID, payload: encoder.encode(snapshot))
            if let idempotency { try await saveIdempotency(idempotency, status: 200, response: encoder.encode(snapshot)) }
            return event
        }
    }

    public func selection(sessionID: UUID) async throws -> SelectionSnapshot? {
        guard let text = try await connection.query("SELECT selection_json FROM session_selections WHERE session_id=?", [.text(sessionID.uuidString)]).first?.column("selection_json")?.string else { return nil }
        return try decoder.decode(SelectionSnapshot.self, from: Data(text.utf8))
    }

    public func selectionTemplate(projectID: UUID) async throws -> ProjectSelectionTemplateSnapshot? {
        guard let text = try await connection.query("SELECT selection_json FROM project_selection_templates WHERE project_id=?", [.text(projectID.uuidString)]).first?.column("selection_json")?.string else { return nil }
        return try decoder.decode(ProjectSelectionTemplateSnapshot.self, from: Data(text.utf8))
    }

    public func persistSelectionTemplate(_ snapshot: ProjectSelectionTemplateSnapshot, actor: ExternalActor, correlationID: UUID, idempotency: IdempotencyInput) async throws -> EventEnvelope {
        try await transaction {
            if let existing = try await existingIdempotency(idempotency) { throw ExistingIdempotency(existing) }
            _ = try await connection.query(
                "INSERT INTO project_selection_templates(template_id,project_id,schema_version,selection_json,revision,transactional_commit_id) VALUES(?,?,1,?,?,?) ON CONFLICT(template_id) DO UPDATE SET selection_json=excluded.selection_json,revision=excluded.revision,transactional_commit_id=excluded.transactional_commit_id",
                [.text(snapshot.projectID.uuidString), .text(snapshot.projectID.uuidString), .text(encodeText(snapshot)), .integer(Int(snapshot.revision)), .text(UUID().uuidString)]
            )
            let event = try await appendEvent(projectID: snapshot.projectID, sessionID: nil, rootSessionID: nil, runID: nil, sessionSequence: nil, type: .selectionUpdated, generation: nil, turnEpoch: nil, actor: actor, correlationID: correlationID, payload: encoder.encode(snapshot))
            try await saveIdempotency(idempotency, status: 200, response: encoder.encode(snapshot))
            return event
        }
    }

    public func persistPermissions(_ snapshot: ExecutionPermissionSnapshot, projectID: UUID, rootSessionID: UUID, correlationID: UUID, idempotency: IdempotencyInput? = nil) async throws -> EventEnvelope {
        try await transaction {
            if let idempotency, let existing = try await existingIdempotency(idempotency) { throw ExistingIdempotency(existing) }
            _ = try await connection.query(
                "INSERT INTO execution_permissions(session_id,schema_version,mode,provider_settings_json,revision,updated_actor_json,updated_at) VALUES(?,1,?,?,?,?,CURRENT_TIMESTAMP) ON CONFLICT(session_id) DO UPDATE SET mode=excluded.mode,provider_settings_json=excluded.provider_settings_json,revision=excluded.revision,updated_actor_json=excluded.updated_actor_json,updated_at=CURRENT_TIMESTAMP",
                [.text(snapshot.sessionID.uuidString), .text(snapshot.mode), .text(encodeText(snapshot.providerSettings)), .integer(Int(snapshot.revision)), .text(encodeText(snapshot.updatedActor))]
            )
            let event = try await appendEvent(projectID: projectID, sessionID: snapshot.sessionID, rootSessionID: rootSessionID, runID: nil, sessionSequence: nil, type: .permissionUpdated, generation: nil, turnEpoch: nil, actor: snapshot.updatedActor, correlationID: correlationID, payload: encoder.encode(snapshot))
            if let idempotency { try await saveIdempotency(idempotency, status: 200, response: encoder.encode(snapshot)) }
            return event
        }
    }

    public func permissions(sessionID: UUID) async throws -> ExecutionPermissionSnapshot? {
        guard let row = try await connection.query("SELECT mode,provider_settings_json,revision,updated_actor_json FROM execution_permissions WHERE session_id=?", [.text(sessionID.uuidString)]).first,
              let mode = row.column("mode")?.string,
              let settings = row.column("provider_settings_json")?.string,
              let actor = row.column("updated_actor_json")?.string
        else { return nil }
        return try ExecutionPermissionSnapshot(sessionID: sessionID, mode: mode, providerSettings: decoder.decode([String: String].self, from: Data(settings.utf8)), revision: Int64(row.column("revision")?.integer ?? 1), updatedActor: decoder.decode(ExternalActor.self, from: Data(actor.utf8)))
    }

    public func persistInteraction(_ snapshot: InteractionSnapshot, session: SessionSnapshot, actor: ExternalActor?, correlationID: UUID, idempotency: IdempotencyInput? = nil) async throws -> EventEnvelope {
        try await transaction {
            if let idempotency, let existing = try await existingIdempotency(idempotency) { throw ExistingIdempotency(existing) }
            let actorJSON = try actor.map(encodeText)
            _ = try await connection.query(
                "INSERT INTO interactions(interaction_id,session_id,run_id,agent_id,schema_version,kind,state,payload_json,created_at,expires_at,settled_at,settled_actor_json,revision) VALUES(?,?,?,?,1,?,?,?,CURRENT_TIMESTAMP,?,?,?,?) ON CONFLICT(interaction_id) DO UPDATE SET state=excluded.state,payload_json=excluded.payload_json,settled_at=excluded.settled_at,settled_actor_json=excluded.settled_actor_json,revision=excluded.revision",
                [.text(snapshot.interactionID.uuidString), .text(session.sessionID.uuidString), snapshot.runID.map { .text($0.uuidString) } ?? .null, snapshot.agentID.map { .text($0.uuidString) } ?? .null, .text(snapshot.kind.rawValue), .text(snapshot.state.rawValue), .text(snapshot.payload.base64EncodedString()), snapshot.expiresAt.map { .float($0.timeIntervalSince1970) } ?? .null, snapshot.state == .resolved ? .float(Date().timeIntervalSince1970) : .null, actorJSON.map(SQLiteData.text) ?? .null, .integer(Int(snapshot.revision))]
            )
            let eventType: EventType = snapshot.state == .resolved ? .interactionResolved : .interactionRequested
            let event = try await appendEvent(projectID: session.projectID, sessionID: session.sessionID, rootSessionID: session.rootSessionID, runID: nil, sessionSequence: nil, type: eventType, generation: session.runGeneration, turnEpoch: session.turnEpoch, actor: actor, correlationID: correlationID, payload: encoder.encode(snapshot))
            if let idempotency { try await saveIdempotency(idempotency, status: 200, response: encoder.encode(snapshot)) }
            return event
        }
    }

    public func persistInteractionDeliveryState(_ snapshot: InteractionSnapshot, sessionID: UUID, actor: ExternalActor?) async throws {
        try await transaction {
            let actorJSON = try actor.map(encodeText)
            _ = try await connection.query(
                "UPDATE interactions SET state=?,payload_json=?,settled_at=?,settled_actor_json=?,revision=? WHERE interaction_id=? AND session_id=?",
                [.text(snapshot.state.rawValue), .text(snapshot.payload.base64EncodedString()), snapshot.state == .resolved ? .float(Date().timeIntervalSince1970) : .null, actorJSON.map(SQLiteData.text) ?? .null, .integer(Int(snapshot.revision)), .text(snapshot.interactionID.uuidString), .text(sessionID.uuidString)]
            )
        }
    }

    public func interactions(sessionID: UUID) async throws -> [InteractionSnapshot] {
        try await connection.query("SELECT interaction_id,run_id,agent_id,kind,state,payload_json,revision,expires_at FROM interactions WHERE session_id=? ORDER BY created_at", [.text(sessionID.uuidString)]).map { row in
            guard let id = UUID(uuidString: row.column("interaction_id")?.string ?? ""),
                  let kind = InteractionSnapshot.Kind(rawValue: row.column("kind")?.string ?? ""),
                  let state = InteractionSnapshot.State(rawValue: row.column("state")?.string ?? "")
            else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Persisted interaction is invalid") }
            let expiresAt = row.column("expires_at")?.double.map { Date(timeIntervalSince1970: $0) }
            return InteractionSnapshot(interactionID: id, runID: row.column("run_id")?.string.flatMap(UUID.init(uuidString:)), agentID: row.column("agent_id")?.string.flatMap(UUID.init(uuidString:)), kind: kind, state: state, payload: Data(base64Encoded: row.column("payload_json")?.string ?? "") ?? Data(), revision: Int64(row.column("revision")?.integer ?? 1), expiresAt: expiresAt)
        }
    }

    public func oracleChat(chatID: UUID) async throws -> OracleChatState? {
        guard let text = try await connection.query("SELECT chat_json FROM oracle_chats WHERE chat_id=?", [.text(chatID.uuidString)]).first?.column("chat_json")?.string else { return nil }
        return try decoder.decode(OracleChatState.self, from: Data(text.utf8))
    }

    public func persistOracleChat(_ chat: OracleChatState) async throws {
        try await transaction {
            _ = try await connection.query(
                "INSERT INTO oracle_chats(chat_id,session_id,schema_version,chat_json,revision,created_at,updated_at) VALUES(?,?,1,?,?,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP) ON CONFLICT(chat_id) DO UPDATE SET chat_json=excluded.chat_json,revision=excluded.revision,updated_at=CURRENT_TIMESTAMP",
                [.text(chat.chatID.uuidString), .text(chat.sessionID.uuidString), .text(encodeText(chat)), .integer(Int(chat.revision))]
            )
        }
    }

    public func persistWorktree(_ snapshot: WorktreeBindingSnapshot, actor: ExternalActor, correlationID: UUID, idempotency: IdempotencyInput? = nil) async throws -> EventEnvelope {
        try await transaction {
            if let idempotency, let existing = try await existingIdempotency(idempotency) { throw ExistingIdempotency(existing) }
            _ = try await connection.query(
                "INSERT INTO worktree_bindings(binding_id,project_id,root_id,session_id,schema_version,base_ref,branch,physical_path,ownership_state,merge_state,revision) VALUES(?,?,?,?,1,?,?,?,?,?,?) ON CONFLICT(binding_id) DO UPDATE SET session_id=excluded.session_id,ownership_state=excluded.ownership_state,merge_state=excluded.merge_state,revision=excluded.revision",
                [.text(snapshot.bindingID.uuidString), .text(snapshot.projectID.uuidString), .text(snapshot.rootID.uuidString), snapshot.sessionID.map { .text($0.uuidString) } ?? .null, .text(snapshot.baseRef), .text(snapshot.branch), .text(snapshot.physicalPath), .text(snapshot.ownershipState.rawValue), .text(snapshot.mergeState.rawValue), .integer(Int(snapshot.revision))]
            )
            let event = try await appendEvent(projectID: snapshot.projectID, sessionID: snapshot.sessionID, rootSessionID: snapshot.sessionID, runID: nil, sessionSequence: nil, type: snapshot.revision == 1 ? .worktreeCreated : .worktreeUpdated, generation: nil, turnEpoch: nil, actor: actor, correlationID: correlationID, payload: encoder.encode(snapshot))
            if let idempotency { try await saveIdempotency(idempotency, status: snapshot.revision == 1 ? 201 : 200, response: encoder.encode(snapshot)) }
            return event
        }
    }

    public func persistWorktreeBinding(_ worktree: WorktreeBindingSnapshot, selection: SelectionSnapshot, session: SessionSnapshot, actor: ExternalActor, correlationID: UUID, idempotency: IdempotencyInput) async throws -> (worktree: EventEnvelope, selection: EventEnvelope) {
        try await transaction {
            if let existing = try await existingIdempotency(idempotency) { throw ExistingIdempotency(existing) }
            _ = try await connection.query(
                "INSERT INTO worktree_bindings(binding_id,project_id,root_id,session_id,schema_version,base_ref,branch,physical_path,ownership_state,merge_state,revision) VALUES(?,?,?,?,1,?,?,?,?,?,?) ON CONFLICT(binding_id) DO UPDATE SET session_id=excluded.session_id,ownership_state=excluded.ownership_state,merge_state=excluded.merge_state,revision=excluded.revision",
                [.text(worktree.bindingID.uuidString), .text(worktree.projectID.uuidString), .text(worktree.rootID.uuidString), worktree.sessionID.map { .text($0.uuidString) } ?? .null, .text(worktree.baseRef), .text(worktree.branch), .text(worktree.physicalPath), .text(worktree.ownershipState.rawValue), .text(worktree.mergeState.rawValue), .integer(Int(worktree.revision))]
            )
            _ = try await connection.query(
                "INSERT INTO session_selections(session_id,schema_version,allowed_roots_json,selection_json,selection_revision,binding_revision,transactional_commit_id) VALUES(?,1,?,?,?,?,?) ON CONFLICT(session_id) DO UPDATE SET selection_json=excluded.selection_json,selection_revision=excluded.selection_revision,binding_revision=excluded.binding_revision,transactional_commit_id=excluded.transactional_commit_id",
                [.text(selection.sessionID.uuidString), .text(encodeText(Array(Set(selection.entries.map(\.rootID))))), .text(encodeText(selection)), .integer(Int(selection.revision)), .integer(Int(selection.bindingRevision)), .text(UUID().uuidString)]
            )
            let worktreeEvent = try await appendEvent(projectID: session.projectID, sessionID: session.sessionID, rootSessionID: session.rootSessionID, runID: nil, sessionSequence: nil, type: .worktreeUpdated, generation: session.runGeneration, turnEpoch: session.turnEpoch, actor: actor, correlationID: correlationID, payload: encoder.encode(worktree))
            let selectionEvent = try await appendEvent(projectID: session.projectID, sessionID: session.sessionID, rootSessionID: session.rootSessionID, runID: nil, sessionSequence: nil, type: .selectionUpdated, generation: session.runGeneration, turnEpoch: session.turnEpoch, actor: actor, correlationID: correlationID, payload: encoder.encode(selection))
            try await saveIdempotency(idempotency, status: 200, response: encoder.encode(worktree))
            return (worktreeEvent, selectionEvent)
        }
    }

    public func worktrees(projectID: UUID) async throws -> [WorktreeBindingSnapshot] {
        try await connection.query("SELECT * FROM worktree_bindings WHERE project_id=? ORDER BY binding_id", [.text(projectID.uuidString)]).map(decodeWorktree)
    }

    public func worktree(bindingID: UUID) async throws -> WorktreeBindingSnapshot? {
        try await connection.query("SELECT * FROM worktree_bindings WHERE binding_id=?", [.text(bindingID.uuidString)]).first.map(decodeWorktree)
    }

    public func persistArtifact(_ snapshot: ArtifactSnapshot, storageReference: String, actor: ExternalActor?, correlationID: UUID) async throws -> EventEnvelope {
        try await transaction {
            _ = try await connection.query(
                "INSERT INTO artifacts(artifact_id,project_id,session_id,schema_version,kind,logical_name,content_digest,storage_reference,size,created_sequence,created_at,retention_state) VALUES(?,?,?,1,?,?,?,?,?,?,CURRENT_TIMESTAMP,?)",
                [.text(snapshot.artifactID.uuidString), .text(snapshot.projectID.uuidString), snapshot.sessionID.map { .text($0.uuidString) } ?? .null, .text(snapshot.kind), .text(snapshot.logicalName), .text(snapshot.contentDigest), .text(storageReference), .integer(Int(snapshot.size)), .integer(Int(snapshot.createdCursor.globalSequence)), .text(snapshot.retentionState)]
            )
            return try await appendEvent(projectID: snapshot.projectID, sessionID: snapshot.sessionID, rootSessionID: snapshot.sessionID, runID: nil, sessionSequence: nil, type: .artifactCreated, generation: nil, turnEpoch: nil, actor: actor, correlationID: correlationID, payload: encoder.encode(snapshot))
        }
    }

    public func artifacts(sessionID: UUID) async throws -> [(snapshot: ArtifactSnapshot, storageReference: String)] {
        let meta = try await metadata()
        return try await connection.query("SELECT * FROM artifacts WHERE session_id=? AND retention_state!='deleted' ORDER BY created_sequence", [.text(sessionID.uuidString)]).map { try decodeArtifact($0, storeID: meta.storeID) }
    }

    public func artifact(id: UUID) async throws -> (snapshot: ArtifactSnapshot, storageReference: String)? {
        let meta = try await metadata()
        return try await connection.query("SELECT * FROM artifacts WHERE artifact_id=? AND retention_state!='deleted'", [.text(id.uuidString)]).first.map { try decodeArtifact($0, storeID: meta.storeID) }
    }

    public func installWorkflows(_ workflows: [WorkflowSnapshot]) async throws {
        try await transaction {
            for workflow in workflows {
                _ = try await connection.query("INSERT INTO workflows(workflow_id,schema_version,source,name,definition_json,content_digest,enabled) VALUES(?,1,?,?,?,?,?) ON CONFLICT(workflow_id) DO UPDATE SET source=excluded.source,name=excluded.name,definition_json=excluded.definition_json,content_digest=excluded.content_digest,enabled=excluded.enabled", [.text(workflow.workflowID), .text(workflow.source), .text(workflow.name), .text(workflow.definition), .text(workflow.contentDigest), .integer(workflow.enabled ? 1 : 0)])
            }
            return ()
        }
    }

    public func workflows() async throws -> [WorkflowSnapshot] {
        try await connection.query("SELECT * FROM workflows WHERE enabled=1 ORDER BY name").map { row in
            WorkflowSnapshot(workflowID: row.column("workflow_id")?.string ?? "", source: row.column("source")?.string ?? "", name: row.column("name")?.string ?? "", definition: row.column("definition_json")?.string ?? "", contentDigest: row.column("content_digest")?.string ?? "", enabled: row.column("enabled")?.bool ?? false)
        }
    }

    public func persistProcessFamily(runID: UUID, leader: PersistedProcessIdentity, connectionGeneration: Int64 = 1, containmentMode: String = "process-group", state: String = "running") async throws {
        try await transaction {
            let executableDigest = CanonicalSigning.bodyDigest(Data(leader.executablePath.utf8))
            _ = try await connection.query(
                "INSERT INTO process_families(run_id,schema_version,leader_pid,pgid,process_start_time,boot_id,executable_digest,executable_path,helper_token_digest,connection_generation,containment_mode,state) VALUES(?,1,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(run_id) DO UPDATE SET leader_pid=excluded.leader_pid,pgid=excluded.pgid,process_start_time=excluded.process_start_time,boot_id=excluded.boot_id,executable_digest=excluded.executable_digest,executable_path=excluded.executable_path,helper_token_digest=excluded.helper_token_digest,connection_generation=excluded.connection_generation,containment_mode=excluded.containment_mode,state=excluded.state",
                [.text(runID.uuidString), .integer(Int(leader.pid)), .integer(Int(leader.processGroupID)), .integer(Int(leader.startTimeTicks)), .text(leader.bootID), .text(executableDigest), .text(leader.executablePath), .text(leader.helperTokenDigest), .integer(Int(connectionGeneration)), .text(containmentMode), .text(state)]
            )
            try await persistProcessMembersWithoutTransaction(runID: runID, members: [leader], terminalState: nil)
        }
    }

    public func persistProcessMembers(runID: UUID, members: [PersistedProcessIdentity], terminalState: String? = nil) async throws {
        try await transaction {
            try await persistProcessMembersWithoutTransaction(runID: runID, members: members, terminalState: terminalState)
        }
    }

    public func activeProcessFamilies() async throws -> [PersistedProcessFamily] {
        try await connection.query("SELECT f.*,m.parent_pid AS leader_parent_pid,m.session_id AS leader_session_id FROM process_families f LEFT JOIN process_members m ON m.run_id=f.run_id AND m.pid=f.leader_pid AND m.start_time=f.process_start_time WHERE f.state IN ('running','terminating') ORDER BY f.run_id").map { row in
            guard let runID = UUID(uuidString: row.column("run_id")?.string ?? "") else {
                throw ServiceAPIError(code: .persistenceUnavailable, message: "Persisted process family run ID is invalid")
            }
            let leader = PersistedProcessIdentity(
                pid: Int32(row.column("leader_pid")?.integer ?? 0),
                parentPID: Int32(row.column("leader_parent_pid")?.integer ?? 0),
                processGroupID: Int32(row.column("pgid")?.integer ?? 0),
                sessionID: Int32(row.column("leader_session_id")?.integer ?? 0),
                startTimeTicks: UInt64(row.column("process_start_time")?.integer ?? 0),
                bootID: row.column("boot_id")?.string ?? "",
                executablePath: row.column("executable_path")?.string ?? "",
                helperTokenDigest: row.column("helper_token_digest")?.string ?? ""
            )
            return PersistedProcessFamily(runID: runID, leader: leader, connectionGeneration: Int64(row.column("connection_generation")?.integer ?? 1), containmentMode: row.column("containment_mode")?.string ?? "process-group", state: row.column("state")?.string ?? "running")
        }
    }

    public func updateProcessFamilyState(runID: UUID, state: String, members: [PersistedProcessIdentity] = []) async throws {
        try await transaction {
            _ = try await connection.query("UPDATE process_families SET state=? WHERE run_id=?", [.text(state), .text(runID.uuidString)])
            if !members.isEmpty {
                try await persistProcessMembersWithoutTransaction(runID: runID, members: members, terminalState: state)
            }
        }
    }

    public func processFamilyState(runID: UUID) async throws -> String? {
        try await connection.query("SELECT state FROM process_families WHERE run_id=?", [.text(runID.uuidString)]).first?.column("state")?.string
    }

    public func consumeNonce(direction: String, keyID: String, nonce: String, observedAt: Date, expiresAt: Date) async throws {
        do {
            _ = try await connection.query("INSERT INTO request_nonces(direction,key_id,nonce,observed_at,expires_at) VALUES(?,?,?,?,?)", [.text(direction), .text(keyID), .text(nonce), .float(observedAt.timeIntervalSince1970), .float(expiresAt.timeIntervalSince1970)])
        } catch { throw ServiceAPIError(code: .internalAuthFailed, message: "Nonce has already been used") }
    }

    public func checkpoint() async throws {
        _ = try await connection.query("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    public func archiveEvents(through sequence: Int64) async throws -> UUID? {
        try await transaction {
            let meta = try await metadata()
            let bounded = min(sequence, meta.nextGlobalSequence - 1)
            guard bounded >= meta.replayFloor else { return nil }
            let rows = try await connection.query("SELECT envelope_json FROM events WHERE global_sequence<=? ORDER BY global_sequence", [.integer(Int(bounded))])
            let events = try rows.compactMap { row -> EventEnvelope? in
                guard let text = row.column("envelope_json")?.string else { return nil }
                return try decoder.decode(EventEnvelope.self, from: Data(text.utf8))
            }
            guard let first = events.first, let last = events.last else { return nil }
            let archiveID = UUID()
            let bytes = try encoder.encode(events)
            let digest = CanonicalSigning.bodyDigest(bytes)
            _ = try await connection.query("INSERT INTO event_archives(archive_id,first_sequence,last_sequence,event_count,canonical_events_json,digest,created_at) VALUES(?,?,?,?,?,?,CURRENT_TIMESTAMP)", [.text(archiveID.uuidString), .integer(Int(first.globalSequence)), .integer(Int(last.globalSequence)), .integer(events.count), .text(String(decoding: bytes, as: UTF8.self)), .text(digest)])
            _ = try await connection.query("DELETE FROM events WHERE global_sequence<=?", [.integer(Int(last.globalSequence))])
            _ = try await connection.query("UPDATE service_metadata SET replay_floor=? WHERE fixed_id=1", [.integer(Int(last.globalSequence))])
            return archiveID
        }
    }

    public func archivedEvents(archiveID: UUID) async throws -> [EventEnvelope] {
        guard let text = try await connection.query("SELECT canonical_events_json FROM event_archives WHERE archive_id=?", [.text(archiveID.uuidString)]).first?.column("canonical_events_json")?.string else { throw ServiceAPIError(code: .notFound, message: "Event archive not found") }
        return try decoder.decode([EventEnvelope].self, from: Data(text.utf8))
    }

    public func snapshotCheckpoints(scope: String) async throws -> [(sequence: Int64, digest: String)] {
        try await connection.query("SELECT sequence,digest FROM snapshot_checkpoints WHERE scope=? ORDER BY sequence", [.text(scope)]).map { (Int64($0.column("sequence")?.integer ?? 0), $0.column("digest")?.string ?? "") }
    }

    public func markRestored(from priorStoreID: UUID, backupSequence: Int64, digest: String) async throws -> UUID {
        let current = try await metadata()
        guard current.storeID == priorStoreID else {
            throw ServiceAPIError(code: .invalidRequest, message: "Restore provenance does not match the current store namespace")
        }
        let fresh = UUID()
        let restoredFloor = max(backupSequence, current.nextGlobalSequence - 1)
        let restoredCursor = ServiceCursor(storeID: fresh, globalSequence: restoredFloor)
        let projects = try await allProjects().map { replacingCursor($0, cursor: restoredCursor) }
        let sessions = try await allSessions().map { replacingCursor($0, cursor: restoredCursor) }
        try await transaction {
            _ = try await connection.query("UPDATE service_metadata SET restored_from_store_id=store_id,store_id=?,restore_backup_sequence=?,restore_digest=?,replay_floor=?,next_global_sequence=?,last_clean_shutdown=0 WHERE fixed_id=1", [.text(fresh.uuidString), .integer(Int(backupSequence)), .text(digest), .integer(Int(restoredFloor)), .integer(Int(restoredFloor + 1))])
            for project in projects {
                _ = try await connection.query("UPDATE projects SET snapshot_json=?,updated_at=CURRENT_TIMESTAMP WHERE project_id=?", [.text(encodeText(project)), .text(project.projectID.uuidString)])
            }
            for session in sessions {
                _ = try await connection.query("UPDATE sessions SET snapshot_json=?,updated_at=CURRENT_TIMESTAMP WHERE session_id=?", [.text(encodeText(session)), .text(session.sessionID.uuidString)])
            }
            let provenance = try encodeText(["priorStoreId": priorStoreID.uuidString])
            _ = try await connection.query("INSERT INTO audit_events(event_id,schema_version,event_type,payload_json,created_at) VALUES(?,1,'store.restored',?,CURRENT_TIMESTAMP)", [.text(UUID().uuidString), .text(provenance)])
            return ()
        }
        return fresh
    }

    private func appendEvent(projectID: UUID, sessionID: UUID?, agentID: UUID? = nil, parentAgentID: UUID? = nil, rootSessionID: UUID?, runID: UUID?, sessionSequence: Int64?, type: EventType, generation: Int64?, turnEpoch: Int64?, actor: ExternalActor?, correlationID: UUID, payload: Data) async throws -> EventEnvelope {
        let meta = try await metadata()
        let sequence = meta.nextGlobalSequence
        let digest = CanonicalSigning.bodyDigest(payload)
        let keyID = eventSigningKey?.keyID ?? "unsigned-local"
        let signature = eventSigningKey.map { CanonicalSigning.hmacSHA256(message: "\(meta.storeID.uuidString)\n\(sequence)\n\(digest)", key: $0.secret) } ?? ""
        let envelope = EventEnvelope(protocolVersion: 1, eventID: UUID(), storeID: meta.storeID, globalSequence: sequence, timestamp: Date(), projectID: projectID, sessionID: sessionID, agentID: agentID, parentAgentID: parentAgentID, rootSessionID: rootSessionID, runID: runID, sessionSequence: sessionSequence, eventType: type, payloadVersion: 1, generation: generation, turnEpoch: turnEpoch, actor: actor, correlationID: correlationID, causationID: nil, payload: payload, digest: digest, keyID: keyID, signature: signature)
        let actorJSON = try actor.map(encodeText)
        let bindings: [SQLiteData] = try [
            .integer(Int(sequence)), .text(envelope.eventID.uuidString), .text(projectID.uuidString), sessionID.map { .text($0.uuidString) } ?? .null,
            agentID.map { .text($0.uuidString) } ?? .null, parentAgentID.map { .text($0.uuidString) } ?? .null, rootSessionID.map { .text($0.uuidString) } ?? .null, runID.map { .text($0.uuidString) } ?? .null,
            sessionSequence.map { .integer(Int($0)) } ?? .null, .text(type.rawValue), .integer(1), generation.map { .integer(Int($0)) } ?? .null,
            turnEpoch.map { .integer(Int($0)) } ?? .null, actorJSON.map(SQLiteData.text) ?? .null, .text(payload.base64EncodedString()),
            .text(digest), .float(envelope.timestamp.timeIntervalSince1970), .text(encodeText(envelope))
        ]
        _ = try await connection.query("INSERT INTO events(global_sequence,event_id,project_id,session_id,agent_id,parent_agent_id,root_session_id,run_id,session_sequence,event_type,payload_version,generation,turn_epoch,actor_json,payload_json,digest,timestamp,envelope_json) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", bindings)
        _ = try await connection.query("UPDATE service_metadata SET next_global_sequence = next_global_sequence + 1, last_clean_shutdown = 0 WHERE fixed_id = 1")
        return envelope
    }

    private func persistProcessMembersWithoutTransaction(runID: UUID, members: [PersistedProcessIdentity], terminalState: String?) async throws {
        for member in members {
            let executableIdentity = CanonicalSigning.bodyDigest(Data(member.executablePath.utf8))
            _ = try await connection.query(
                "INSERT INTO process_members(run_id,pid,schema_version,parent_pid,pgid,session_id,start_time,executable_identity,first_observed_at,last_observed_at,terminal_state) VALUES(?,?,1,?,?,?,?,?,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP,?) ON CONFLICT(run_id,pid,start_time) DO UPDATE SET parent_pid=excluded.parent_pid,pgid=excluded.pgid,session_id=excluded.session_id,executable_identity=excluded.executable_identity,last_observed_at=CURRENT_TIMESTAMP,terminal_state=excluded.terminal_state",
                [.text(runID.uuidString), .integer(Int(member.pid)), .integer(Int(member.parentPID)), .integer(Int(member.processGroupID)), .integer(Int(member.sessionID)), .integer(Int(member.startTimeTicks)), .text(executableIdentity), terminalState.map(SQLiteData.text) ?? .null]
            )
        }
    }

    private func importAuditExists(kind: String, digest: String) async throws -> Bool {
        try await connection.query("SELECT 1 FROM audit_events WHERE event_type=? AND payload_json=? LIMIT 1", [.text(kind), .text(digest)]).first != nil
    }

    private func recordImportAudit(kind: String, digest: String) async throws {
        _ = try await connection.query("INSERT INTO audit_events(event_id,schema_version,event_type,payload_json,created_at) VALUES(?,1,?,?,CURRENT_TIMESTAMP)", [.text(UUID().uuidString), .text(kind), .text(digest)])
    }

    private func persistSessionInTransaction(
        _ snapshot: SessionSnapshot,
        eventType: EventType,
        actor: ExternalActor?,
        correlationID: UUID,
        idempotency: IdempotencyInput?,
        idempotencyResponse: Data?,
        initialSelection: SelectionSnapshot?
    ) async throws -> EventEnvelope {
        try await validateExpectedCursor(snapshot.cursor)
        if let idempotency, let existing = try await existingIdempotency(idempotency) { throw ExistingIdempotency(existing) }
        let snapshotJSON = try encodeText(snapshot)
        let sessionBindings: [SQLiteData] = [
            .text(snapshot.sessionID.uuidString), .text(snapshot.projectID.uuidString), snapshot.parentSessionID.map { .text($0.uuidString) } ?? .null,
            .text(snapshot.rootSessionID.uuidString), .text(snapshot.creator.goblinUserID), .text(snapshot.state.rawValue), .text(snapshot.provider.rawValue),
            snapshot.model.map(SQLiteData.text) ?? .null, .text(snapshot.visibility.rawValue), .integer(Int(snapshot.runGeneration)), .integer(Int(snapshot.turnEpoch)),
            .integer(Int(snapshot.revision)), .text(snapshotJSON)
        ]
        _ = try await connection.query("INSERT INTO sessions(session_id,project_id,parent_session_id,root_session_id,schema_version,creator_external_id,lifecycle_state,provider_kind,model,visibility,run_generation,turn_epoch,revision,snapshot_json,created_at,updated_at) VALUES(?,?,?,?,1,?,?,?,?,?,?,?,?,?,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP) ON CONFLICT(session_id) DO UPDATE SET lifecycle_state=excluded.lifecycle_state,run_generation=excluded.run_generation,turn_epoch=excluded.turn_epoch,revision=excluded.revision,snapshot_json=excluded.snapshot_json,updated_at=CURRENT_TIMESTAMP", sessionBindings)
        for entry in snapshot.transcript {
            _ = try await connection.query("INSERT OR IGNORE INTO transcript_entries(session_id,entry_id,schema_version,session_sequence,entry_json,content_digest) VALUES(?,?,1,?,?,?)", [.text(snapshot.sessionID.uuidString), .text(entry.entryID.uuidString), .integer(Int(entry.sessionSequence)), .text(encodeText(entry)), .text(CanonicalSigning.bodyDigest(encoder.encode(entry)))])
        }
        if let initialSelection {
            _ = try await connection.query(
                "INSERT INTO session_selections(session_id,schema_version,allowed_roots_json,selection_json,selection_revision,binding_revision,transactional_commit_id) VALUES(?,1,?,?,?,?,?) ON CONFLICT(session_id) DO NOTHING",
                [.text(initialSelection.sessionID.uuidString), .text(encodeText(Array(Set(initialSelection.entries.map(\.rootID))))), .text(encodeText(initialSelection)), .integer(Int(initialSelection.revision)), .integer(Int(initialSelection.bindingRevision)), .text(UUID().uuidString)]
            )
        }
        let event = try await appendEvent(projectID: snapshot.projectID, sessionID: snapshot.sessionID, rootSessionID: snapshot.rootSessionID, runID: nil, sessionSequence: Int64(snapshot.transcript.count), type: eventType, generation: snapshot.runGeneration, turnEpoch: snapshot.turnEpoch, actor: actor, correlationID: correlationID, payload: Data(snapshotJSON.utf8))
        if [.completed, .failed, .canceled, .interrupted, .archived].contains(snapshot.state) || (!snapshot.transcript.isEmpty && snapshot.transcript.count.isMultiple(of: 1000)) {
            try await saveCheckpoint(scope: "session:\(snapshot.sessionID.uuidString)", sequence: event.globalSequence, snapshot: Data(snapshotJSON.utf8))
        }
        if let idempotency {
            try await saveIdempotency(idempotency, status: 202, response: idempotencyResponse ?? encoder.encode(snapshot))
        }
        return event
    }

    private func persistAgentInTransaction(_ snapshot: AgentSnapshot, projectID: UUID, actor: ExternalActor?, correlationID: UUID, eventType: EventType) async throws -> EventEnvelope {
        _ = try await connection.query(
            "INSERT INTO agents(agent_id,session_id,root_session_id,parent_agent_id,schema_version,provider_native_identity,role,label,lifecycle_state,revision,created_at,updated_at) VALUES(?,?,?,?,1,?,?,?,?,?,CURRENT_TIMESTAMP,CURRENT_TIMESTAMP) ON CONFLICT(agent_id) DO UPDATE SET provider_native_identity=excluded.provider_native_identity,role=excluded.role,label=excluded.label,lifecycle_state=excluded.lifecycle_state,revision=excluded.revision,updated_at=CURRENT_TIMESTAMP",
            [.text(snapshot.agentID.uuidString), .text(snapshot.sessionID.uuidString), .text(snapshot.rootSessionID.uuidString), snapshot.parentAgentID.map { .text($0.uuidString) } ?? .null, snapshot.providerNativeIdentity.map(SQLiteData.text) ?? .null, .text(snapshot.role), snapshot.label.map(SQLiteData.text) ?? .null, .text(snapshot.state.rawValue), .integer(Int(snapshot.revision))]
        )
        return try await appendEvent(projectID: projectID, sessionID: snapshot.sessionID, agentID: snapshot.agentID, parentAgentID: snapshot.parentAgentID, rootSessionID: snapshot.rootSessionID, runID: nil, sessionSequence: nil, type: eventType, generation: nil, turnEpoch: nil, actor: actor, correlationID: correlationID, payload: encoder.encode(snapshot))
    }

    private func migrate() async throws {
        _ = try await connection.query("PRAGMA foreign_keys=ON")
        _ = try await connection.query("PRAGMA journal_mode=WAL")
        _ = try await connection.query("PRAGMA synchronous=FULL")
        _ = try await connection.query("PRAGMA busy_timeout=5000")
        for statement in SchemaV1.statements {
            _ = try await connection.query(statement)
        }
        try await addColumnIfMissing(table: "events", column: "agent_id", definition: "TEXT")
        try await addColumnIfMissing(table: "events", column: "parent_agent_id", definition: "TEXT")
        let count = try await connection.query("SELECT COUNT(*) AS count FROM service_metadata").first?.column("count")?.integer ?? 0
        if count == 0 {
            _ = try await connection.query("INSERT INTO service_metadata(fixed_id,store_id,schema_version,created_at,last_clean_shutdown,current_boot_epoch,next_global_sequence,replay_floor) VALUES(1,?,1,CURRENT_TIMESTAMP,0,1,1,0)", [.text(UUID().uuidString)])
            _ = try await connection.query("INSERT INTO schema_migrations(migration_id,version,description,digest,applied_at) VALUES('v1',1,'initial durable service schema','v1',CURRENT_TIMESTAMP)")
        }
    }

    private func addColumnIfMissing(table: String, column: String, definition: String) async throws {
        let columns = try await connection.query("PRAGMA table_info(\(table))")
        guard !columns.contains(where: { $0.column("name")?.string == column }) else { return }
        _ = try await connection.query("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
    }

    private func integrityCheck() async throws {
        let result = try await connection.query("PRAGMA quick_check").first?.columns.first?.data.string
        guard result == "ok" else { throw ServiceAPIError(code: .persistenceUnavailable, message: "SQLite integrity check failed", retryable: false) }
    }

    private func transaction<T>(_ body: () async throws -> T) async throws -> T {
        _ = try await connection.query("BEGIN IMMEDIATE")
        do { let result = try await body()
            _ = try await connection.query("COMMIT")
            return result
        } catch let existing as ExistingIdempotency { _ = try await connection.query("ROLLBACK")
            throw existing
        } catch { _ = try? await connection.query("ROLLBACK")
            throw error
        }
    }

    private func validateExpectedCursor(_ cursor: ServiceCursor) async throws {
        let meta = try await metadata()
        guard cursor.storeID == meta.storeID, cursor.globalSequence == meta.nextGlobalSequence else { throw ServiceAPIError(code: .staleRevision, message: "Publication cursor is stale", cursor: ServiceCursor(storeID: meta.storeID, globalSequence: meta.nextGlobalSequence)) }
    }

    private func decodeRows<T: Decodable>(_ sql: String, as: T.Type) async throws -> [T] {
        try await connection.query(sql).compactMap { row in guard let text = row.column("snapshot_json")?.string else { return nil }
            return try decoder.decode(T.self, from: Data(text.utf8))
        }
    }

    private func encodeText(_ value: some Encodable) throws -> String {
        try String(decoding: encoder.encode(value), as: UTF8.self)
    }

    private func requireRow(_ rows: [SQLiteRow]) throws -> SQLiteRow {
        guard let row = rows.first else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Service metadata is missing") }
        return row
    }

    private func requireUUID(_ value: String?) throws -> UUID {
        guard let value, let id = UUID(uuidString: value) else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Persisted UUID is invalid") }
        return id
    }

    private func decodeWorktree(_ row: SQLiteRow) throws -> WorktreeBindingSnapshot {
        guard let ownership = WorktreeBindingSnapshot.OwnershipState(rawValue: row.column("ownership_state")?.string ?? ""),
              let merge = WorktreeBindingSnapshot.MergeState(rawValue: row.column("merge_state")?.string ?? "")
        else { throw ServiceAPIError(code: .persistenceUnavailable, message: "Persisted worktree state is invalid") }
        return try WorktreeBindingSnapshot(
            bindingID: requireUUID(row.column("binding_id")?.string),
            projectID: requireUUID(row.column("project_id")?.string),
            rootID: requireUUID(row.column("root_id")?.string),
            sessionID: row.column("session_id")?.string.flatMap(UUID.init(uuidString:)),
            baseRef: row.column("base_ref")?.string ?? "",
            branch: row.column("branch")?.string ?? "",
            physicalPath: row.column("physical_path")?.string ?? "",
            ownershipState: ownership,
            mergeState: merge,
            revision: Int64(row.column("revision")?.integer ?? 1)
        )
    }

    private func decodeArtifact(_ row: SQLiteRow, storeID: UUID) throws -> (snapshot: ArtifactSnapshot, storageReference: String) {
        let snapshot = try ArtifactSnapshot(
            artifactID: requireUUID(row.column("artifact_id")?.string),
            projectID: requireUUID(row.column("project_id")?.string),
            sessionID: row.column("session_id")?.string.flatMap(UUID.init(uuidString:)),
            kind: row.column("kind")?.string ?? "",
            logicalName: row.column("logical_name")?.string ?? "",
            contentDigest: row.column("content_digest")?.string ?? "",
            size: Int64(row.column("size")?.integer ?? 0),
            createdCursor: ServiceCursor(storeID: storeID, globalSequence: Int64(row.column("created_sequence")?.integer ?? 0)),
            retentionState: row.column("retention_state")?.string ?? "active"
        )
        guard let reference = row.column("storage_reference")?.string else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "Persisted artifact reference is missing")
        }
        return (snapshot, reference)
    }

    private func replacingCursor(_ value: ProjectSnapshot, cursor: ServiceCursor) -> ProjectSnapshot {
        ProjectSnapshot(projectID: value.projectID, name: value.name, creator: value.creator, state: value.state, roots: value.roots, revision: value.revision, cursor: cursor)
    }

    private func saveCheckpoint(scope: String, sequence: Int64, snapshot: Data) async throws {
        let digest = CanonicalSigning.bodyDigest(snapshot)
        _ = try await connection.query("INSERT OR IGNORE INTO snapshot_checkpoints(scope,sequence,schema_version,snapshot,digest,created_at) VALUES(?,?,1,?,?,CURRENT_TIMESTAMP)", [.text(scope), .integer(Int(sequence)), .text(snapshot.base64EncodedString()), .text(digest)])
        _ = try await connection.query("DELETE FROM snapshot_checkpoints WHERE scope=? AND sequence NOT IN (SELECT sequence FROM snapshot_checkpoints WHERE scope=? ORDER BY sequence DESC LIMIT 3)", [.text(scope), .text(scope)])
    }

    private func replacingCursor(_ value: SessionSnapshot, cursor: ServiceCursor) -> SessionSnapshot {
        SessionSnapshot(sessionID: value.sessionID, projectID: value.projectID, parentSessionID: value.parentSessionID, rootSessionID: value.rootSessionID, creator: value.creator, provider: value.provider, model: value.model, visibility: value.visibility, state: value.state, runGeneration: value.runGeneration, turnEpoch: value.turnEpoch, revision: value.revision, transcript: value.transcript, interactions: value.interactions, cursor: cursor)
    }
}

public struct IdempotencyInput: Sendable {
    public let actorID: String
    public let operation: String
    public let key: String
    public let requestDigest: String
    public init(actorID: String, operation: String, key: String, requestDigest: String) {
        self.actorID = actorID
        self.operation = operation
        self.key = key
        self.requestDigest = requestDigest
    }
}

public struct ExistingIdempotency: Error, Sendable { public let response: Data
    public let status: Int
    init(_ value: (Data, Int)) {
        response = value.0
        status = value.1
    }
}

private extension SQLiteServiceStore {
    func existingIdempotency(_ input: IdempotencyInput) async throws -> (Data, Int)? {
        guard let row = try await connection.query("SELECT request_digest,response_body,status FROM idempotency_records WHERE actor_id=? AND operation=? AND idempotency_key=?", [.text(input.actorID), .text(input.operation), .text(input.key)]).first else { return nil }
        guard row.column("request_digest")?.string == input.requestDigest else { throw ServiceAPIError(code: .idempotencyConflict, message: "Idempotency key was used with a different request") }
        let response = Data(base64Encoded: row.column("response_body")?.string ?? "") ?? Data()
        return (response, row.column("status")?.integer ?? 200)
    }

    func saveIdempotency(_ input: IdempotencyInput, status: Int, response: Data) async throws {
        _ = try await connection.query("INSERT INTO idempotency_records(actor_id,operation,idempotency_key,request_digest,response_body,status,created_at,expires_at) VALUES(?,?,?,?,?,?,CURRENT_TIMESTAMP,datetime('now','+30 days'))", [.text(input.actorID), .text(input.operation), .text(input.key), .text(input.requestDigest), .text(response.base64EncodedString()), .integer(status)])
    }
}

public extension JSONEncoder {
    static var serviceEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

public extension JSONDecoder {
    static var serviceDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
