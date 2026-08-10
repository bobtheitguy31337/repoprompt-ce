import Foundation
import RepoPromptServiceProtocol
import SQLiteNIO

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
    private var closed = false

    private init(connection: SQLiteConnection) {
        self.connection = connection
        encoder = JSONEncoder.serviceEncoder
        decoder = JSONDecoder.serviceDecoder
    }

    public static func open(storage: Storage) async throws -> SQLiteServiceStore {
        let location: SQLiteConnection.Storage = switch storage { case .memory: .memory
        case let .file(path): .file(path: path) }
        let connection = try await SQLiteConnection.open(storage: location)
        let store = SQLiteServiceStore(connection: connection)
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
        idempotencyResponse: Data? = nil
    ) async throws -> EventEnvelope {
        try await transaction {
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
            let event = try await appendEvent(projectID: snapshot.projectID, sessionID: snapshot.sessionID, rootSessionID: snapshot.rootSessionID, runID: nil, sessionSequence: Int64(snapshot.transcript.count), type: eventType, generation: snapshot.runGeneration, turnEpoch: snapshot.turnEpoch, actor: actor, correlationID: correlationID, payload: Data(snapshotJSON.utf8))
            if let idempotency {
                try await saveIdempotency(idempotency, status: 202, response: idempotencyResponse ?? encoder.encode(snapshot))
            }
            return event
        }
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

    public func consumeNonce(direction: String, keyID: String, nonce: String, observedAt: Date, expiresAt: Date) async throws {
        do {
            _ = try await connection.query("INSERT INTO request_nonces(direction,key_id,nonce,observed_at,expires_at) VALUES(?,?,?,?,?)", [.text(direction), .text(keyID), .text(nonce), .float(observedAt.timeIntervalSince1970), .float(expiresAt.timeIntervalSince1970)])
        } catch { throw ServiceAPIError(code: .internalAuthFailed, message: "Nonce has already been used") }
    }

    public func checkpoint() async throws {
        _ = try await connection.query("PRAGMA wal_checkpoint(TRUNCATE)")
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

    private func appendEvent(projectID: UUID, sessionID: UUID?, rootSessionID: UUID?, runID: UUID?, sessionSequence: Int64?, type: EventType, generation: Int64?, turnEpoch: Int64?, actor: ExternalActor?, correlationID: UUID, payload: Data) async throws -> EventEnvelope {
        let meta = try await metadata()
        let sequence = meta.nextGlobalSequence
        let digest = CanonicalSigning.bodyDigest(payload)
        let envelope = EventEnvelope(protocolVersion: 1, eventID: UUID(), storeID: meta.storeID, globalSequence: sequence, timestamp: Date(), projectID: projectID, sessionID: sessionID, agentID: nil, parentAgentID: nil, rootSessionID: rootSessionID, runID: runID, sessionSequence: sessionSequence, eventType: type, payloadVersion: 1, generation: generation, turnEpoch: turnEpoch, actor: actor, correlationID: correlationID, causationID: nil, payload: payload, digest: digest, keyID: "unsigned-local", signature: "")
        let actorJSON = try actor.map(encodeText)
        let bindings: [SQLiteData] = try [
            .integer(Int(sequence)), .text(envelope.eventID.uuidString), .text(projectID.uuidString), sessionID.map { .text($0.uuidString) } ?? .null,
            rootSessionID.map { .text($0.uuidString) } ?? .null, runID.map { .text($0.uuidString) } ?? .null,
            sessionSequence.map { .integer(Int($0)) } ?? .null, .text(type.rawValue), .integer(1), generation.map { .integer(Int($0)) } ?? .null,
            turnEpoch.map { .integer(Int($0)) } ?? .null, actorJSON.map(SQLiteData.text) ?? .null, .text(payload.base64EncodedString()),
            .text(digest), .float(envelope.timestamp.timeIntervalSince1970), .text(encodeText(envelope))
        ]
        _ = try await connection.query("INSERT INTO events(global_sequence,event_id,project_id,session_id,root_session_id,run_id,session_sequence,event_type,payload_version,generation,turn_epoch,actor_json,payload_json,digest,timestamp,envelope_json) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", bindings)
        _ = try await connection.query("UPDATE service_metadata SET next_global_sequence = next_global_sequence + 1, last_clean_shutdown = 0 WHERE fixed_id = 1")
        return envelope
    }

    private func migrate() async throws {
        _ = try await connection.query("PRAGMA foreign_keys=ON")
        _ = try await connection.query("PRAGMA journal_mode=WAL")
        _ = try await connection.query("PRAGMA synchronous=FULL")
        _ = try await connection.query("PRAGMA busy_timeout=5000")
        for statement in SchemaV1.statements {
            _ = try await connection.query(statement)
        }
        let count = try await connection.query("SELECT COUNT(*) AS count FROM service_metadata").first?.column("count")?.integer ?? 0
        if count == 0 {
            _ = try await connection.query("INSERT INTO service_metadata(fixed_id,store_id,schema_version,created_at,last_clean_shutdown,current_boot_epoch,next_global_sequence,replay_floor) VALUES(1,?,1,CURRENT_TIMESTAMP,0,1,1,0)", [.text(UUID().uuidString)])
            _ = try await connection.query("INSERT INTO schema_migrations(migration_id,version,description,digest,applied_at) VALUES('v1',1,'initial durable service schema','v1',CURRENT_TIMESTAMP)")
        }
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

    private func replacingCursor(_ value: ProjectSnapshot, cursor: ServiceCursor) -> ProjectSnapshot {
        ProjectSnapshot(projectID: value.projectID, name: value.name, creator: value.creator, state: value.state, roots: value.roots, revision: value.revision, cursor: cursor)
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
