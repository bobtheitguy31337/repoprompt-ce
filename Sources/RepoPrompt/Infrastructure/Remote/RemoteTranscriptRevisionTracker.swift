import Foundation

/// Non-sensitive digest of every default-visible transcript row. Live and
/// persisted transcripts use the same projection so representation changes do
/// not create revisions, while edits to any visible row do.
struct RemoteTranscriptRevisionFingerprint: Equatable {
    private let visibleContentDigest: UInt64

    @MainActor
    static func live(transcript: AgentTranscript) -> Self {
        canonical(transcript: transcript)
    }

    @MainActor
    static func persisted(transcript: AgentTranscript) -> Self {
        canonical(transcript: transcript)
    }

    @MainActor
    private static func canonical(transcript: AgentTranscript) -> Self {
        let items = WindowRemoteReadService.project(transcript: transcript, includeDetails: false)
        var digest = FNV1a64()
        digest.add(items.count)
        for item in items {
            digest.add(item.id.uuidString)
            digest.add(item.turnID.uuidString)
            digest.add(item.timestamp.timeIntervalSinceReferenceDate.bitPattern)
            digest.add(item.sequenceIndex)
            digest.add(item.kind.rawValue)
            digest.add(item.semanticKind?.rawValue)
            digest.add(item.role)
            digest.add(item.text)
            digest.add(item.toolName)
            digest.add(item.toolStatus)
            digest.add(item.summaryOnly)
            digest.add(item.detailAvailable)
        }
        return Self(visibleContentDigest: digest.value)
    }

    private struct FNV1a64 {
        private(set) var value: UInt64 = 14_695_981_039_346_656_037

        mutating func add(_ value: String?) {
            guard let value else {
                addMarker(0)
                return
            }
            addMarker(1)
            add(value.utf8.count)
            for byte in value.utf8 {
                mix(byte)
            }
        }

        mutating func add(_ value: Int) {
            addMarker(4)
            addBytes(UInt64(bitPattern: Int64(value)))
        }

        mutating func add(_ value: UInt64) {
            addMarker(5)
            addBytes(value)
        }

        private mutating func addBytes(_ value: UInt64) {
            var value = value
            for _ in 0 ..< MemoryLayout<UInt64>.size {
                mix(UInt8(truncatingIfNeeded: value))
                value >>= 8
            }
        }

        mutating func add(_ value: Bool) {
            addMarker(value ? 2 : 3)
        }

        private mutating func addMarker(_ marker: UInt8) {
            mix(marker)
        }

        private mutating func mix(_ byte: UInt8) {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
    }
}

/// Process-lifetime monotonic transcript revisions. Gateway stop/start keeps
/// this instance alive; a full application restart begins a new revision epoch.
@MainActor
final class RemoteTranscriptRevisionTracker {
    private struct State {
        var fingerprint: RemoteTranscriptRevisionFingerprint
        var revision: UInt64
        /// Cache token only. It is deliberately excluded from the fingerprint.
        var persistedSavedAt: Date?
    }

    private var stateBySessionID: [UUID: State] = [:]

    @discardableResult
    func observe(
        sessionID: UUID,
        fingerprint: RemoteTranscriptRevisionFingerprint
    ) -> UInt64 {
        observe(sessionID: sessionID, fingerprint: fingerprint, persistedSavedAt: nil)
    }

    func cachedPersistedRevision(sessionID: UUID, savedAt: Date) -> UInt64? {
        guard let state = stateBySessionID[sessionID], state.persistedSavedAt == savedAt else {
            return nil
        }
        return state.revision
    }

    @discardableResult
    func observePersisted(
        sessionID: UUID,
        savedAt: Date,
        fingerprint: RemoteTranscriptRevisionFingerprint
    ) -> UInt64 {
        observe(sessionID: sessionID, fingerprint: fingerprint, persistedSavedAt: savedAt)
    }

    func revision(for sessionID: UUID) -> UInt64? {
        stateBySessionID[sessionID]?.revision
    }

    func remove(sessionID: UUID) {
        stateBySessionID.removeValue(forKey: sessionID)
    }

    private func observe(
        sessionID: UUID,
        fingerprint: RemoteTranscriptRevisionFingerprint,
        persistedSavedAt: Date?
    ) -> UInt64 {
        guard var state = stateBySessionID[sessionID] else {
            stateBySessionID[sessionID] = State(
                fingerprint: fingerprint,
                revision: 1,
                persistedSavedAt: persistedSavedAt
            )
            return 1
        }
        if state.fingerprint != fingerprint {
            state.fingerprint = fingerprint
            if state.revision < UInt64.max {
                state.revision += 1
            }
        }
        state.persistedSavedAt = persistedSavedAt
        stateBySessionID[sessionID] = state
        return state.revision
    }
}
