import Foundation
import RepoPromptServiceProtocol
import SQLiteNIO

extension SQLiteServiceStore {
    /// Publishes a tombstone and removes all mutable session-owned state in one
    /// transaction. The event ledger remains intact so thin clients can remove
    /// their projection and audit/replay cannot silently lose history.
    public func deleteSession(
        tombstone: SessionSnapshot,
        actor: ExternalActor?,
        correlationID: UUID
    ) async throws -> EventEnvelope {
        try await transaction {
            let event = try await persistSessionInTransaction(
                tombstone,
                eventType: .sessionRemoved,
                actor: actor,
                correlationID: correlationID,
                idempotency: nil,
                idempotencyResponse: nil,
                initialSelection: nil
            )
            let ID: SQLiteData = .text(tombstone.sessionID.uuidString)
            let runIDs = "SELECT run_id FROM runs WHERE session_id=?"
            _ = try await connection.query("DELETE FROM semantic_tools WHERE session_id=?", [ID])
            _ = try await connection.query("DELETE FROM semantic_activities WHERE session_id=?", [ID])
            _ = try await connection.query("DELETE FROM semantic_ingestion_watermarks WHERE session_id=?", [ID])
            _ = try await connection.query("DELETE FROM semantic_turns WHERE session_id=?", [ID])
            _ = try await connection.query("DELETE FROM accepted_attachment_manifests WHERE session_id=?", [ID])
            _ = try await connection.query("DELETE FROM composer_attachments WHERE session_id=?", [ID])
            _ = try await connection.query("DELETE FROM session_next_turn_defaults WHERE session_id=?", [ID])
            _ = try await connection.query("DELETE FROM effective_turn_configurations WHERE session_id=?", [ID])
            _ = try await connection.query("DELETE FROM agent_submissions WHERE session_id=?", [ID])
            _ = try await connection.query("DELETE FROM run_presentations WHERE session_id=?", [ID])
            _ = try await connection.query("DELETE FROM process_members WHERE run_id IN (\(runIDs))", [ID])
            _ = try await connection.query("DELETE FROM process_families WHERE run_id IN (\(runIDs))", [ID])
            _ = try await connection.query("DELETE FROM interactions WHERE session_id=?", [ID])
            _ = try await connection.query("DELETE FROM runs WHERE session_id=?", [ID])
            _ = try await connection.query("DELETE FROM transcript_entries WHERE session_id=?", [ID])
            _ = try await connection.query("DELETE FROM oracle_chats WHERE session_id=?", [ID])
            _ = try await connection.query("DELETE FROM session_contexts WHERE session_id=?", [ID])
            _ = try await connection.query("DELETE FROM collaboration_metadata WHERE session_id=?", [ID])
            _ = try await connection.query("DELETE FROM execution_permissions WHERE session_id=?", [ID])
            _ = try await connection.query("DELETE FROM session_selections WHERE session_id=?", [ID])
            _ = try await connection.query("DELETE FROM agents WHERE session_id=?", [ID])
            _ = try await connection.query(
                "UPDATE worktree_bindings SET session_id=NULL,ownership_state='released',revision=revision+1 WHERE session_id=?",
                [ID]
            )
            _ = try await connection.query("UPDATE artifacts SET session_id=NULL WHERE session_id=?", [ID])
            _ = try await connection.query(
                "UPDATE owned_resources SET session_id=NULL,lifecycle_state='released',retention_deadline=NULL WHERE session_id=?",
                [ID]
            )
            _ = try await connection.query("DELETE FROM session_event_counters WHERE session_id=?", [ID])
            _ = try await connection.query("DELETE FROM sessions WHERE session_id=?", [ID])
            return event
        }
    }
}
