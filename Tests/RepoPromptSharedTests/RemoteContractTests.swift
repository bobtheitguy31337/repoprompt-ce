import XCTest
@testable import RepoPromptShared

final class RemoteContractTests: XCTestCase {
    func testAuthorizationUsesSessionScopedGrantAndExpiresLimitedGrant() {
        let sessionID = UUID()
        let now = Date(timeIntervalSince1970: 10)
        let state = RemoteAuthorizationState(
            defaultLevel: .respond,
            activeGrant: RemoteAuthorityGrant(
                level: .danger,
                scope: .session(sessionID),
                duration: .limited(until: Date(timeIntervalSince1970: 20)),
                grantedAt: now
            )
        )

        XCTAssertEqual(state.effectiveLevel(for: sessionID, at: now), .danger)
        XCTAssertEqual(state.effectiveLevel(for: UUID(), at: now), .respond)
        XCTAssertEqual(state.effectiveLevel(for: sessionID, at: Date(timeIntervalSince1970: 20)), .respond)
        XCTAssertTrue(state.allows(.respond, for: UUID(), at: now))
        XCTAssertFalse(state.allows(.control, for: UUID(), at: now))
    }

    func testReplayBufferSequencesEventsAndRequestsSnapshotWhenCursorIsTooOld() async {
        let buffer = RemoteEventReplayBuffer(capacity: 2)
        let desktopID = "desktop-1"

        let first = await buffer.append(RemoteEvent(desktopInstanceID: desktopID, type: .sessionCreated))
        let second = await buffer.append(RemoteEvent(desktopInstanceID: desktopID, type: .runStarted))
        let third = await buffer.append(RemoteEvent(desktopInstanceID: desktopID, type: .runProgressed))

        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(second.sequence, 2)
        XCTAssertEqual(third.sequence, 3)
        let latestCursor = await buffer.latestCursor()
        XCTAssertEqual(latestCursor, 3)

        let replay = await buffer.replay(after: 1, desktopInstanceID: desktopID)
        guard case let .events(events) = replay else {
            return XCTFail("Expected retained events")
        }
        XCTAssertEqual(events.map(\.sequence), [2, 3])

        let stale = await buffer.replay(after: 0, desktopInstanceID: desktopID)
        XCTAssertEqual(stale, .snapshotRequired)
    }

    func testDuplicateEventIDIsNotAppended() async {
        let buffer = RemoteEventReplayBuffer(capacity: 4)
        let eventID = UUID()
        let event = RemoteEvent(desktopInstanceID: "desktop-1", eventID: eventID, type: .catalogChanged)

        let first = await buffer.append(event)
        let duplicate = await buffer.append(event)

        XCTAssertEqual(first, duplicate)
        let latestCursor = await buffer.latestCursor()
        XCTAssertEqual(latestCursor, 1)
    }

    func testSnapshotRoundTripsWithoutSecretAnswerData() throws {
        let session = RemoteSessionSummary(
            sessionID: UUID(),
            workspaceID: "workspace-1",
            runState: .waitingForInput,
            pendingInteraction: RemoteInteractionSummary(
                id: "interaction-1",
                kind: .secretInput,
                prompt: "Enter provider token",
                requiresSecureEntry: true
            ),
            isLive: true
        )
        let snapshot = RemoteSnapshot(
            desktop: RemoteDesktopSummary(
                instanceID: "desktop-1",
                displayName: "Mac",
                appVersion: "1.0",
                isAvailable: true
            ),
            connection: RemoteConnectionSummary(state: .connected),
            authorization: RemoteAuthorizationState(),
            sessions: [session],
            eventCursor: 12
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(RemoteSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("token-value"))
        XCTAssertTrue(decoded.sessions[0].pendingInteraction?.requiresSecureEntry == true)
    }
}
