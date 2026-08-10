import Foundation
import RepoPromptHeadlessRuntime
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

final class ProjectSourceProvisioningTests: XCTestCase {
    func testExactGoblinProjectSourceFixtureDecodes() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/goblin-project-source-operations-v1.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        XCTAssertEqual(fixture["schemaVersion"] as? Int, 1)
        let vectors = try XCTUnwrap(fixture["vectors"] as? [[String: Any]])
        XCTAssertEqual(vectors.count, 2)
        for vector in vectors {
            let body = try JSONSerialization.data(withJSONObject: XCTUnwrap(vector["internalBody"]))
            let input = try JSONDecoder.serviceDecoder.decode(ProjectSourceOperationInput.self, from: body)
            XCTAssertEqual(input.schemaVersion, 1)
            XCTAssertEqual(input.expectedRevision, 0)
            XCTAssertEqual(input.operationID.uuidString.lowercased(), (vector["operationId"] as? String)?.lowercased())
            XCTAssertEqual(
                try JSONSerialization.jsonObject(with: JSONEncoder.serviceEncoder.encode(input)) as? NSDictionary,
                vector["internalBody"] as? NSDictionary
            )
        }
        var unsupported = try XCTUnwrap(vectors.first?["internalBody"] as? [String: Any])
        unsupported["credentialPath"] = "/run/secret"
        XCTAssertThrowsError(try JSONDecoder.serviceDecoder.decode(
            ProjectSourceOperationInput.self,
            from: JSONSerialization.data(withJSONObject: unsupported)
        ))
        var unsupportedSource = try XCTUnwrap(unsupported["source"] as? [String: Any])
        unsupported.removeValue(forKey: "credentialPath")
        unsupportedSource["executable"] = "/usr/bin/git"
        unsupported["source"] = unsupportedSource
        XCTAssertThrowsError(try JSONDecoder.serviceDecoder.decode(
            ProjectSourceOperationInput.self,
            from: JSONSerialization.data(withJSONObject: unsupported)
        ))
    }

    func testConfiguredRootUsesOnlyServerAliasAndPreservesIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let configured = fixture.directory.appendingPathComponent("configured", isDirectory: true)
        try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: true)
        let policy = try ProjectSourcePolicy.decode(fixture.policy(configuredPath: configured.path))
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = try ProjectSourceProvisioningService(
            cloneRoot: fixture.cloneRoot.path,
            policy: policy,
            credentials: ProjectSourceGitCredentials(),
            resources: store,
            git: FakeProjectSourceGitRunner()
        )
        let root = try await service.provision(
            input: .init(
                operationID: UUID(),
                expectedRevision: 0,
                name: "Configured",
                logicalName: "workspace",
                source: .configuredRoot(alias: "chat-server")
            ),
            projectID: UUID(),
            rootID: UUID()
        )
        XCTAssertEqual(root.snapshot.canonicalPath, configured.path)
        XCTAssertEqual(root.snapshot.logicalName, "workspace")
        XCTAssertTrue(root.snapshot.writable)
        XCTAssertFalse(root.filesystemIdentity.isEmpty)

        try FileManager.default.removeItem(at: configured)
        try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: true)
        do {
            _ = try await service.provision(
                input: .init(
                    operationID: UUID(),
                    expectedRevision: 0,
                    name: "Changed",
                    logicalName: "workspace",
                    source: .configuredRoot(alias: "chat-server")
                ),
                projectID: UUID(),
                rootID: UUID()
            )
            XCTFail("Expected configured root identity rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rootUnauthorized)
        }
    }

    func testGitCloneUsesBoundedArrayInvocationAndAtomicPromotion() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let policy = try ProjectSourcePolicy.decode(fixture.policy(configuredPath: fixture.directory.path))
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let git = FakeProjectSourceGitRunner()
        let service = try ProjectSourceProvisioningService(
            cloneRoot: fixture.cloneRoot.path,
            policy: policy,
            credentials: ProjectSourceGitCredentials(),
            resources: store,
            git: git
        )
        let projectID = UUID()
        let operationID = UUID()
        let root = try await service.provision(
            input: .init(
                operationID: operationID,
                expectedRevision: 0,
                name: "Clone",
                logicalName: "workspace",
                source: .gitClone(remote: "https://GITHUB.com/degentlemen/chat-server.git", ref: "main")
            ),
            projectID: projectID,
            rootID: UUID()
        )
        XCTAssertEqual(root.snapshot.canonicalPath, fixture.cloneRoot.appendingPathComponent(projectID.uuidString).path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.snapshot.canonicalPath))
        let staging = fixture.cloneRoot.appendingPathComponent(".source-staging").appendingPathComponent(operationID.uuidString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))

        let invocations = await git.recorded()
        let clone = try XCTUnwrap(invocations.first)
        XCTAssertEqual(clone.executable, "/usr/bin/git")
        XCTAssertTrue(clone.arguments.contains("core.hooksPath=/dev/null"))
        XCTAssertTrue(clone.arguments.contains("protocol.file.allow=never"))
        XCTAssertTrue(clone.arguments.contains("--no-recurse-submodules"))
        XCTAssertEqual(clone.environment["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(clone.environment["GIT_CONFIG_GLOBAL"], "/dev/null")
        XCTAssertNil(clone.environment["GIT_SSH_COMMAND"])
        XCTAssertEqual(clone.maximumDirectoryBytes, 8_388_608)
        XCTAssertEqual(clone.timeoutSeconds, 5)

        let storedResource = try await store.ownedResource(externalID: projectID, kind: .cloneStaging)
        let resource = try XCTUnwrap(storedResource)
        XCTAssertEqual(resource.lifecycleState, .prepared)
        XCTAssertEqual(resource.internalPathIdentity, root.snapshot.canonicalPath)
        XCTAssertFalse(resource.metadata.values.contains(where: { $0.contains("github") }))
    }

    func testRejectsCredentialsTraversalRefsAndUnapprovedRemoteBeforeGit() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let policy = try ProjectSourcePolicy.decode(fixture.policy(configuredPath: fixture.directory.path))
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let git = FakeProjectSourceGitRunner()
        let service = try ProjectSourceProvisioningService(
            cloneRoot: fixture.cloneRoot.path,
            policy: policy,
            credentials: ProjectSourceGitCredentials(),
            resources: store,
            git: git
        )
        for source in [
            ProjectSourceOperationInput.Source.gitClone(remote: "https://token@github.com/degentlemen/chat-server.git", ref: "main"),
            .gitClone(remote: "https://github.com/degentlemen/../other.git", ref: "main"),
            .gitClone(remote: "https://evil.example/degentlemen/chat-server.git", ref: "main"),
            .gitClone(remote: "https://github.com/degentlemen/chat-server.git", ref: "../main"),
            .gitClone(remote: "https://github.com/degentlemen/chat-server.git", ref: "private/secret")
        ] {
            do {
                _ = try await service.provision(
                    input: .init(operationID: UUID(), expectedRevision: 0, name: "Clone", logicalName: "root", source: source),
                    projectID: UUID(),
                    rootID: UUID()
                )
                XCTFail("Expected source rejection")
            } catch let error as ServiceAPIError {
                XCTAssertTrue([.rootUnauthorized, .invalidRequest].contains(error.code))
            }
        }
        let invocations = await git.recorded()
        XCTAssertTrue(invocations.isEmpty)
    }

    func testCloneFailureCleansOnlyItsOwnedStagingDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let policy = try ProjectSourcePolicy.decode(fixture.policy(configuredPath: fixture.directory.path))
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let git = FakeProjectSourceGitRunner(failClone: true)
        let service = try ProjectSourceProvisioningService(
            cloneRoot: fixture.cloneRoot.path,
            policy: policy,
            credentials: ProjectSourceGitCredentials(),
            resources: store,
            git: git
        )
        let projectID = UUID()
        let operationID = UUID()
        do {
            _ = try await service.provision(
                input: .init(
                    operationID: operationID,
                    expectedRevision: 0,
                    name: "Clone",
                    logicalName: "root",
                    source: .gitClone(remote: "https://github.com/degentlemen/chat-server.git", ref: "main")
                ),
                projectID: projectID,
                rootID: UUID()
            )
            XCTFail("Expected clone failure")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .dependencyUnavailable)
        }
        let staging = fixture.cloneRoot.appendingPathComponent(".source-staging").appendingPathComponent(operationID.uuidString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        let resource = try await store.ownedResource(externalID: projectID, kind: .cloneStaging)
        XCTAssertEqual(resource?.lifecycleState, .failed)
    }

    func testAbandonAfterPromotionRemovesTheOwnedCheckout() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = try ProjectSourceProvisioningService(
            cloneRoot: fixture.cloneRoot.path,
            policy: try ProjectSourcePolicy.decode(fixture.policy(configuredPath: fixture.directory.path)),
            credentials: ProjectSourceGitCredentials(),
            resources: store,
            git: FakeProjectSourceGitRunner()
        )
        let projectID = UUID()
        let root = try await service.provision(
            input: .init(
                operationID: UUID(),
                expectedRevision: 0,
                name: "Clone",
                logicalName: "workspace",
                source: .gitClone(remote: "https://github.com/degentlemen/chat-server.git", ref: "main")
            ),
            projectID: projectID,
            rootID: UUID()
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.snapshot.canonicalPath))
        await service.abandonProvisionedClone(projectID: projectID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.snapshot.canonicalPath))
        let resource = try await store.ownedResource(externalID: projectID, kind: .cloneStaging)
        XCTAssertEqual(resource?.lifecycleState, .failed)
    }

    func testAuthorityActivatesCloneIdempotentlyAndPublishesOnlySafeEvents() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let policy = try ProjectSourcePolicy.decode(fixture.policy(configuredPath: fixture.directory.path))
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = try ProjectSourceProvisioningService(
            cloneRoot: fixture.cloneRoot.path,
            policy: policy,
            credentials: ProjectSourceGitCredentials(),
            resources: store,
            git: FakeProjectSourceGitRunner()
        )
        let authority = RepoPromptHeadlessAuthority(store: store, projectSourceService: service)
        let actor = ExternalActor(goblinUserID: "user-1", username: "alice", displayName: "Alice")
        let input = ProjectSourceOperationInput(
            operationID: UUID(),
            expectedRevision: 0,
            name: "Clone",
            logicalName: "workspace",
            source: .gitClone(remote: "https://github.com/degentlemen/chat-server.git", ref: "main")
        )

        let first = try await authority.createProjectFromSource(
            input: input,
            externalActor: actor,
            idempotencyKey: "source-1",
            requestDigest: "source-digest-1"
        )
        let replay = try await authority.createProjectFromSource(
            input: input,
            externalActor: actor,
            idempotencyKey: "source-1",
            requestDigest: "source-digest-1"
        )
        XCTAssertEqual(first, replay)
        XCTAssertEqual(first.state, .completed)
        let projectCount = await authority.projectSnapshots().count
        XCTAssertEqual(projectCount, 1)
        let resource = try await store.ownedResource(externalID: first.projectID, kind: .cloneStaging)
        XCTAssertEqual(resource?.lifecycleState, .active)

        let events = try await store.events(after: nil, limit: 100).events
        let published = String(decoding: try JSONEncoder.serviceEncoder.encode(events), as: UTF8.self)
        XCTAssertFalse(published.contains(fixture.cloneRoot.path))
        XCTAssertFalse(published.contains("github.com"))
        XCTAssertFalse(published.contains("canonicalPath"))
        XCTAssertTrue(published.contains("rootCount"))

        do {
            _ = try await authority.createProjectFromSource(
                input: .init(
                    operationID: UUID(),
                    expectedRevision: 1,
                    name: "stale",
                    logicalName: "workspace",
                    source: .configuredRoot(alias: "chat-server")
                ),
                externalActor: actor,
                idempotencyKey: "source-stale",
                requestDigest: "source-stale"
            )
            XCTFail("Expected stale project source revision")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .staleRevision)
            XCTAssertEqual(error.currentRevision, 0)
        }
    }
}

private struct Fixture {
    let directory: URL
    let cloneRoot: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        cloneRoot = directory.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: cloneRoot, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    func policy(configuredPath: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "configuredRoots": [["alias": "chat-server", "path": configuredPath, "writable": true]],
            "git": [
                "remoteRules": [["scheme": "https", "host": "github.com", "pathPrefix": "/degentlemen/"]],
                "allowedRefPatterns": ["^(main|release/[A-Za-z0-9._-]+)$"],
                "deniedRefPatterns": ["^private/"],
                "maximumCloneBytes": 8_388_608,
                "maximumCloneSeconds": 5,
                "maximumConcurrentClones": 1,
                "maximumOutputBytes": 16_384
            ]
        ])
    }
}

private actor FakeProjectSourceGitRunner: ProjectSourceGitRunning {
    private var invocations: [ProjectSourceGitInvocation] = []
    private let failClone: Bool
    private var origin = "https://github.com/degentlemen/chat-server.git"

    init(failClone: Bool = false) {
        self.failClone = failClone
    }

    func recorded() -> [ProjectSourceGitInvocation] {
        invocations
    }

    func run(_ invocation: ProjectSourceGitInvocation) async throws -> String {
        invocations.append(invocation)
        if invocation.arguments.contains("clone") {
            let destination = try XCTUnwrap(invocation.arguments.last)
            try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: destination).appendingPathComponent(".git").path, withIntermediateDirectories: true)
            if let separator = invocation.arguments.firstIndex(of: "--"), separator + 1 < invocation.arguments.count {
                origin = invocation.arguments[separator + 1]
            }
            if failClone { throw ServiceAPIError(code: .dependencyUnavailable, message: "fixture failure") }
            return ""
        }
        if invocation.arguments.contains("--show-toplevel") {
            guard let index = invocation.arguments.firstIndex(of: "-C"), index + 1 < invocation.arguments.count else { return "" }
            return invocation.arguments[index + 1]
        }
        if invocation.arguments.contains("get-url") { return origin }
        if invocation.arguments.contains("--verify") { return String(repeating: "a", count: 40) }
        return ""
    }
}
