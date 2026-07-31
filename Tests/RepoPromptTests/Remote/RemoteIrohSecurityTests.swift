import Foundation
@testable import RepoPromptApp
import RepoPromptRemoteProtocol
import XCTest

@MainActor
final class RemoteIrohSecurityTests: XCTestCase {
    private final class TestClock {
        var date: Date

        init(_ date: Date) {
            self.date = date
        }
    }

    private enum PersistenceFailure: Error {
        case failed
    }

    func testIssuedLegacyAndIrohAdvertisementsShareExpiringSecret() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1000))
        let manager = makeManager(clock: clock)
        let issued = try manager.issuePairingAdvertisements(
            port: 8443,
            serviceName: "RepoPrompt-test",
            host: "192.0.2.1",
            server: RemoteIrohEndpointAddress(endpointID: endpointID("a"))
        )

        XCTAssertEqual(issued.legacy.oneTimeSecret, issued.iroh.oneTimeSecret)
        XCTAssertEqual(issued.legacy.expiresAt, clock.date.addingTimeInterval(300))
        XCTAssertEqual(issued.iroh.expiresAt, clock.date.addingTimeInterval(300))
        XCTAssertEqual(issued.iroh.legacyFallback, issued.legacy)
        XCTAssertEqual(Data(base64URL: issued.legacy.oneTimeSecret)?.count, 32)
    }

    func testPairingSecretExpiresAndIsSingleUse() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 2000))
        var persisted: [RemoteStoredDeviceCredential?] = []
        let manager = makeManager(clock: clock) { persisted.append($0) }
        let advertisement = try manager.issueAdvertisement(
            port: 8443,
            serviceName: "RepoPrompt-test",
            host: nil
        )
        clock.date = try XCTUnwrap(advertisement.expiresAt?.addingTimeInterval(1))

        XCTAssertThrowsError(try manager.pair(
            request: pairingRequest(secret: advertisement.oneTimeSecret),
            desktop: desktopSummary()
        )) { error in
            guard case RemoteGatewaySecurityError.pairingSecretExpired = error else {
                return XCTFail("Expected pairingSecretExpired, got \(error)")
            }
        }
        XCTAssertTrue(persisted.isEmpty)

        XCTAssertThrowsError(try manager.pair(
            request: pairingRequest(secret: advertisement.oneTimeSecret),
            desktop: desktopSummary()
        )) { error in
            guard case RemoteGatewaySecurityError.pairingSecretInvalid = error else {
                return XCTFail("Expected pairingSecretInvalid, got \(error)")
            }
        }
    }

    func testPairingReplayFailsEvenWhenCredentialPersistenceFails() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 3000))
        let manager = makeManager(clock: clock) { _ in throw PersistenceFailure.failed }
        let advertisement = try manager.issueAdvertisement(
            port: 8443,
            serviceName: "RepoPrompt-test",
            host: nil
        )
        let request = pairingRequest(secret: advertisement.oneTimeSecret)

        XCTAssertThrowsError(try manager.pair(request: request, desktop: desktopSummary())) { error in
            XCTAssertTrue(error is PersistenceFailure)
        }
        XCTAssertThrowsError(try manager.pair(request: request, desktop: desktopSummary())) { error in
            guard case RemoteGatewaySecurityError.pairingSecretInvalid = error else {
                return XCTFail("Expected consumed secret rejection, got \(error)")
            }
        }
    }

    func testFreshValidIrohPairingReplacesStaleOneDeviceRecord() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 3500))
        let stale = RemoteStoredDeviceCredential(
            deviceID: "stale-device",
            credential: "stale-credential",
            expiresAt: clock.date.addingTimeInterval(3600),
            deviceName: "Old phone",
            irohPeerEndpointID: endpointID("b")
        )
        var persisted: RemoteStoredDeviceCredential? = nil
        let manager = makeManager(clock: clock, storedDevice: stale) { persisted = $0 }
        let serverID = endpointID("a")
        let replacementClientID = endpointID("c")
        let issued = try manager.issuePairingAdvertisements(
            port: 8443,
            serviceName: "RepoPrompt-test",
            host: nil,
            server: RemoteIrohEndpointAddress(endpointID: serverID)
        )

        let response = try manager.pairIroh(
            request: RemoteIrohPairingRequest(
                desktopInstanceID: "desktop",
                expectedServerEndpointID: serverID,
                clientEndpointID: replacementClientID,
                oneTimeSecret: issued.iroh.oneTimeSecret,
                deviceName: "Replacement phone"
            ),
            authenticatedPeerEndpointID: replacementClientID,
            serverEndpointID: serverID,
            desktop: desktopSummary()
        )

        XCTAssertNotEqual(response.pairingResponse.deviceID, stale.deviceID)
        XCTAssertEqual(persisted?.deviceID, response.pairingResponse.deviceID)
        XCTAssertEqual(persisted?.irohPeerEndpointID, replacementClientID)
        XCTAssertFalse(manager.isAuthorized("Bearer \(stale.credential)"))
        XCTAssertTrue(manager.isAuthorizedIroh(
            authorizationHeader: "Bearer \(response.pairingResponse.credential)",
            deviceID: response.pairingResponse.deviceID,
            authenticatedPeerEndpointID: replacementClientID
        ))
    }

    func testIrohPairingAuthenticatesBothEndpointBindingsBeforeConsumingSecret() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 4000))
        var persisted: RemoteStoredDeviceCredential? = nil
        let manager = makeManager(clock: clock) { persisted = $0 }
        let serverID = endpointID("a")
        let clientID = endpointID("b")
        let issued = try manager.issuePairingAdvertisements(
            port: 8443,
            serviceName: "RepoPrompt-test",
            host: nil,
            server: RemoteIrohEndpointAddress(endpointID: serverID)
        )
        let request = RemoteIrohPairingRequest(
            desktopInstanceID: "desktop",
            expectedServerEndpointID: serverID,
            clientEndpointID: clientID,
            oneTimeSecret: issued.iroh.oneTimeSecret,
            deviceName: "Phone"
        )

        XCTAssertThrowsError(try manager.pairIroh(
            request: request,
            authenticatedPeerEndpointID: endpointID("c"),
            serverEndpointID: serverID,
            desktop: desktopSummary()
        )) { error in
            guard case RemoteGatewaySecurityError.endpointBindingInvalid = error else {
                return XCTFail("Expected endpointBindingInvalid, got \(error)")
            }
        }

        let response = try manager.pairIroh(
            request: request,
            authenticatedPeerEndpointID: clientID,
            serverEndpointID: serverID,
            desktop: desktopSummary()
        )
        XCTAssertEqual(response.serverEndpointID, serverID)
        XCTAssertEqual(response.clientEndpointID, clientID)
        XCTAssertEqual(persisted?.irohPeerEndpointID, clientID)
        XCTAssertTrue(manager.isAuthorizedIroh(
            authorizationHeader: "Bearer \(response.pairingResponse.credential)",
            deviceID: response.pairingResponse.deviceID,
            authenticatedPeerEndpointID: clientID
        ))

        XCTAssertThrowsError(try manager.pairIroh(
            request: request,
            authenticatedPeerEndpointID: clientID,
            serverEndpointID: serverID,
            desktop: desktopSummary()
        ))
    }

    func testAuthenticatedHTTPSBindingUpdatesExistingCredentialWithoutReplacement() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 5000))
        let original = RemoteStoredDeviceCredential(
            deviceID: "device",
            credential: "bearer",
            expiresAt: clock.date.addingTimeInterval(60),
            deviceName: "Phone"
        )
        var persisted: RemoteStoredDeviceCredential? = nil
        let manager = makeManager(clock: clock, storedDevice: original) { persisted = $0 }
        let serverID = endpointID("a")
        let firstClientID = endpointID("b")
        let request = RemoteIrohBindingRequest(
            desktopInstanceID: "desktop",
            deviceID: original.deviceID,
            expectedServerEndpointID: serverID,
            clientEndpointID: firstClientID
        )

        let response = try manager.bindIrohEndpoint(
            request: request,
            authorizationHeader: "Bearer bearer",
            serverEndpointID: serverID
        )
        XCTAssertEqual(response.deviceID, original.deviceID)
        XCTAssertEqual(persisted?.credential, original.credential)
        XCTAssertEqual(persisted?.irohPeerEndpointID, firstClientID)
        XCTAssertTrue(manager.isAuthorizedIroh(
            authorizationHeader: "Bearer bearer",
            deviceID: "device",
            authenticatedPeerEndpointID: firstClientID
        ))
        XCTAssertFalse(manager.isAuthorizedIroh(
            authorizationHeader: "Bearer bearer",
            deviceID: "device",
            authenticatedPeerEndpointID: endpointID("c")
        ))

        let replacementClientID = endpointID("d")
        _ = try manager.bindIrohEndpoint(
            request: RemoteIrohBindingRequest(
                desktopInstanceID: "desktop",
                deviceID: original.deviceID,
                expectedServerEndpointID: serverID,
                clientEndpointID: replacementClientID
            ),
            authorizationHeader: "Bearer bearer",
            serverEndpointID: serverID
        )
        XCTAssertEqual(persisted?.irohPeerEndpointID, replacementClientID)
        XCTAssertFalse(manager.isAuthorizedIroh(
            authorizationHeader: "Bearer bearer",
            deviceID: "device",
            authenticatedPeerEndpointID: firstClientID
        ))
    }

    func testBindingRejectsWrongBearerDeviceAndServer() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 6000))
        let original = RemoteStoredDeviceCredential(
            deviceID: "device",
            credential: "bearer",
            expiresAt: clock.date.addingTimeInterval(60),
            deviceName: "Phone"
        )
        let manager = makeManager(clock: clock, storedDevice: original)
        let serverID = endpointID("a")

        for (request, bearer, actualServer) in [
            (RemoteIrohBindingRequest(
                desktopInstanceID: "desktop",
                deviceID: "device",
                expectedServerEndpointID: serverID,
                clientEndpointID: endpointID("b")
            ), "Bearer wrong", serverID),
            (RemoteIrohBindingRequest(
                desktopInstanceID: "desktop",
                deviceID: "other",
                expectedServerEndpointID: serverID,
                clientEndpointID: endpointID("b")
            ), "Bearer bearer", serverID),
            (RemoteIrohBindingRequest(
                desktopInstanceID: "desktop",
                deviceID: "device",
                expectedServerEndpointID: endpointID("c"),
                clientEndpointID: endpointID("b")
            ), "Bearer bearer", serverID)
        ] {
            XCTAssertThrowsError(try manager.bindIrohEndpoint(
                request: request,
                authorizationHeader: bearer,
                serverEndpointID: actualServer
            ))
        }
    }

    func testPersistedPairingFieldsAreBoundedAndEndpointIDsAreCanonical() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 6500))
        var persisted: RemoteStoredDeviceCredential?
        let manager = makeManager(clock: clock) { persisted = $0 }
        let advertisement = try manager.issueAdvertisement(
            port: 8443,
            serviceName: "RepoPrompt-test",
            host: nil
        )
        let request = RemotePairingRequest(
            desktopInstanceID: "desktop",
            oneTimeSecret: advertisement.oneTimeSecret,
            deviceName: String(repeating: "📱", count: 512)
        )
        _ = try manager.pair(request: request, desktop: desktopSummary())
        XCTAssertEqual(persisted?.deviceName.count, RemotePairingManager.maximumDeviceNameCharacters)

        let boundManager = makeManager(clock: clock, storedDevice: persisted)
        XCTAssertThrowsError(try boundManager.bindIrohEndpoint(
            request: RemoteIrohBindingRequest(
                desktopInstanceID: "desktop",
                deviceID: persisted?.deviceID ?? "",
                expectedServerEndpointID: endpointID("a"),
                clientEndpointID: "not-an-endpoint"
            ),
            authorizationHeader: "Bearer \(persisted?.credential ?? "")",
            serverEndpointID: endpointID("a")
        )) { error in
            guard case RemoteGatewaySecurityError.endpointBindingInvalid = error else {
                return XCTFail("Expected endpointBindingInvalid, got \(error)")
            }
        }
    }

    func testStoredCredentialDecodesLegacyShapeAndOldDecoderIgnoresBinding() throws {
        let oldJSON = """
        {
          "deviceID": "device",
          "credential": "bearer",
          "expiresAt": 1000,
          "deviceName": "Phone"
        }
        """
        let decoded = try JSONDecoder().decode(
            RemoteStoredDeviceCredential.self,
            from: Data(oldJSON.utf8)
        )
        XCTAssertNil(decoded.irohPeerEndpointID)

        let updated = RemoteStoredDeviceCredential(
            deviceID: decoded.deviceID,
            credential: decoded.credential,
            expiresAt: decoded.expiresAt,
            deviceName: decoded.deviceName,
            irohPeerEndpointID: endpointID("a")
        )
        struct LegacyCredential: Decodable {
            let deviceID: String
            let credential: String
            let expiresAt: Date
            let deviceName: String
        }
        let legacy = try JSONDecoder().decode(
            LegacyCredential.self,
            from: JSONEncoder().encode(updated)
        )
        XCTAssertEqual(legacy.deviceID, updated.deviceID)
        XCTAssertEqual(legacy.credential, updated.credential)
        XCTAssertEqual(legacy.expiresAt, updated.expiresAt)
        XCTAssertEqual(legacy.deviceName, updated.deviceName)
    }

    func testFailedDurableRevocationRetainsPairedAuthorizationState() {
        let clock = TestClock(Date(timeIntervalSince1970: 7000))
        let stored = RemoteStoredDeviceCredential(
            deviceID: "device",
            credential: "bearer",
            expiresAt: clock.date.addingTimeInterval(60),
            deviceName: "Phone",
            irohPeerEndpointID: endpointID("a")
        )
        let manager = makeManager(clock: clock, storedDevice: stored) { _ in
            throw PersistenceFailure.failed
        }

        XCTAssertThrowsError(try manager.revokeDevice()) { error in
            XCTAssertTrue(error is PersistenceFailure)
        }
        XCTAssertTrue(manager.isPaired)
        XCTAssertTrue(manager.isAuthorized("Bearer bearer"))
        XCTAssertTrue(manager.isAuthorizedIroh(
            authorizationHeader: "Bearer bearer",
            deviceID: "device",
            authenticatedPeerEndpointID: endpointID("a")
        ))
    }

    func testConstantTimeComparisonHandlesEqualDifferentAndDifferentLengthValues() {
        XCTAssertTrue(RemoteConstantTimeComparison.equals(Data([1, 2, 3]), Data([1, 2, 3])))
        XCTAssertFalse(RemoteConstantTimeComparison.equals(Data([9, 2, 3]), Data([1, 2, 3])))
        XCTAssertFalse(RemoteConstantTimeComparison.equals(Data([1, 2, 9]), Data([1, 2, 3])))
        XCTAssertFalse(RemoteConstantTimeComparison.equals(Data([1, 2]), Data([1, 2, 0])))
    }

    func testDesktopIdentityStoreLoadsCreatesAndReplacesCorruptValues() throws {
        let stable = Data(repeating: 1, count: 32)
        var writes: [Data] = []
        let loaded = try RemoteIrohIdentityStore(
            read: { stable },
            write: { writes.append($0) },
            generate: { XCTFail("Should not generate")
                return Data()
            }
        ).loadOrCreate()
        XCTAssertEqual(loaded, RemoteIrohIdentity(secret: stable, origin: .loaded))
        XCTAssertTrue(writes.isEmpty)

        let createdSecret = Data(repeating: 2, count: 32)
        let created = try RemoteIrohIdentityStore(
            read: { nil },
            write: { writes.append($0) },
            generate: { createdSecret }
        ).loadOrCreate()
        XCTAssertEqual(created, RemoteIrohIdentity(secret: createdSecret, origin: .created))
        XCTAssertEqual(writes.last, createdSecret)

        let replacement = Data(repeating: 3, count: 32)
        let replaced = try RemoteIrohIdentityStore(
            read: { Data(repeating: 9, count: 31) },
            write: { writes.append($0) },
            generate: { replacement }
        ).loadOrCreate()
        XCTAssertEqual(replaced, RemoteIrohIdentity(secret: replacement, origin: .replacedCorruptValue))
        XCTAssertEqual(writes.last, replacement)
    }

    private func makeManager(
        clock: TestClock,
        storedDevice: RemoteStoredDeviceCredential? = nil,
        persist: @escaping (RemoteStoredDeviceCredential?) throws -> Void = { _ in }
    ) -> RemotePairingManager {
        RemotePairingManager(
            desktopInstanceID: "desktop",
            certificateSHA256: String(repeating: "f", count: 64),
            storedDevice: storedDevice,
            now: { clock.date },
            randomBytes: { count in Data(repeating: UInt8(count), count: count) },
            persistStoredDevice: persist
        )
    }

    private func pairingRequest(secret: String) -> RemotePairingRequest {
        RemotePairingRequest(
            desktopInstanceID: "desktop",
            oneTimeSecret: secret,
            deviceName: "Phone"
        )
    }

    private func desktopSummary() -> RemoteDesktopSummary {
        RemoteDesktopSummary(
            instanceID: "desktop",
            displayName: "Mac",
            appVersion: "test",
            isAvailable: true
        )
    }

    private func endpointID(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }
}

private extension Data {
    init?(base64URL: String) {
        var normalized = base64URL
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        self.init(base64Encoded: normalized)
    }
}
