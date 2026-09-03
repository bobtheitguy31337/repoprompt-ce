import Foundation
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import XCTest

final class ClientIntegrationStoreTests: XCTestCase {
    func testIssuedTokenIsUnbrandedAndAuthenticatesActor() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }

        let issue = try await store.createClientIntegration()
        XCTAssertTrue(issue.token.hasPrefix("rp_client_v1."))
        XCTAssertFalse(issue.token.contains("gabblin"))
        XCTAssertEqual(issue.integration.status, .active)

        try await store.authenticateClientCredential(
            token: issue.token,
            subject: "member_1",
            username: "ada",
            displayName: "Ada Lovelace"
        )
        let members = try await store.clientMembers()
        XCTAssertEqual(members.map(\.username), ["ada"])
        XCTAssertEqual(members.map(\.displayName), ["Ada Lovelace"])
    }

    func testLegacyTokenPrefixRemainsAccepted() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let issue = try await store.createClientIntegration()
        let legacy = issue.token.replacingOccurrences(of: "rp_client_v1.", with: "rp_gabblin_v1.")
        try await store.authenticateClientCredential(
            token: legacy,
            subject: "member_1",
            username: "ada",
            displayName: "Ada"
        )
        let members = try await store.clientMembers()
        XCTAssertEqual(members.map(\.username), ["ada"])
    }

    func testRotateAndRevokeRejectThePriorToken() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }

        let first = try await store.createClientIntegration()
        let rotated = try await store.rotateClientCredential()
        XCTAssertNotEqual(first.token, rotated.token)
        XCTAssertTrue(rotated.token.hasPrefix("rp_client_v1."))

        do {
            try await store.authenticateClientCredential(
                token: first.token,
                subject: "member_1",
                username: "ada",
                displayName: "Ada"
            )
            XCTFail("rotated token should reject the prior secret")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .internalAuthFailed)
            XCTAssertEqual(error.message, "API token is invalid")
        }

        try await store.authenticateClientCredential(
            token: rotated.token,
            subject: "member_1",
            username: "ada",
            displayName: "Ada"
        )
        let revoked = try await store.revokeClientIntegration()
        XCTAssertTrue(revoked)

        do {
            try await store.authenticateClientCredential(
                token: rotated.token,
                subject: "member_1",
                username: "ada",
                displayName: "Ada"
            )
            XCTFail("revoked integration should reject the current secret")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .internalAuthFailed)
        }
    }

    func testCreateRejectsAnAlreadyActiveIntegration() async throws {
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        _ = try await store.createClientIntegration()
        do {
            _ = try await store.createClientIntegration()
            XCTFail("second create should be rejected")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .invalidRequest)
            XCTAssertEqual(error.message, "Client integration already exists")
        }
    }
}
