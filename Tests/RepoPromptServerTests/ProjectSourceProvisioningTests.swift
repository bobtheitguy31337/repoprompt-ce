import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import RepoPromptHeadlessRuntime
@testable import RepoPromptServicePersistence
import RepoPromptServiceProtocol
import RepoPromptWorkspaceRuntimeCore
import XCTest

final class ProjectSourceProvisioningTests: XCTestCase {
    func testExactGoblinProjectCreationFixtureDecodes() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/goblin-project-creation-v1.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        XCTAssertEqual(fixture["schemaVersion"] as? Int, 1)
        let vectors = try XCTUnwrap(fixture["vectors"] as? [[String: Any]])
        XCTAssertEqual(vectors.count, 1)
        for vector in vectors {
            XCTAssertEqual(vector["internalPath"] as? String, "/internal/v1/projects")
            let body = try JSONSerialization.data(withJSONObject: XCTUnwrap(vector["internalBody"]))
            let input = try JSONDecoder.serviceDecoder.decode(CreateProjectWireInput.self, from: body)
            XCTAssertEqual(input.schemaVersion, 1)
            XCTAssertEqual(input.expectedRevision, 0)
            XCTAssertEqual(input.operationID.uuidString.lowercased(), (vector["operationId"] as? String)?.lowercased())
            XCTAssertEqual(
                try JSONSerialization.jsonObject(with: JSONEncoder.serviceEncoder.encode(input)) as? NSDictionary,
                vector["internalBody"] as? NSDictionary
            )
        }
        var unsupported = try XCTUnwrap(vectors.first?["internalBody"] as? [String: Any])
        unsupported["roots"] = []
        XCTAssertThrowsError(try JSONDecoder.serviceDecoder.decode(
            CreateProjectWireInput.self,
            from: JSONSerialization.data(withJSONObject: unsupported)
        ))
        unsupported.removeValue(forKey: "roots")
        unsupported["credentialPath"] = "/run/secret"
        XCTAssertThrowsError(try JSONDecoder.serviceDecoder.decode(
            CreateProjectWireInput.self,
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

    func testRefPolicyPatternsMatchTheEntireRef() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let git = FakeProjectSourceGitRunner()
        let service = try ProjectSourceProvisioningService(
            cloneRoot: fixture.cloneRoot.path,
            policy: try ProjectSourcePolicy.decode(fixture.policy(
                configuredPath: fixture.directory.path,
                allowedRefPatterns: ["main"],
                deniedRefPatterns: []
            )),
            credentials: ProjectSourceGitCredentials(),
            resources: store,
            git: git
        )
        do {
            _ = try await service.provision(
                input: .init(
                    operationID: UUID(), expectedRevision: 0, name: "Clone", logicalName: "root",
                    source: .gitClone(remote: "https://github.com/degentlemen/chat-server.git", ref: "main-old")
                ),
                projectID: UUID(),
                rootID: UUID()
            )
            XCTFail("Expected a partial ref regex match to be rejected")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .rootUnauthorized)
        }
        let invocations = await git.recorded()
        XCTAssertTrue(invocations.isEmpty)
    }

    func testSSHRemoteRulesRequireRuntimeIdentityAndKnownHosts() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let policy = try ProjectSourcePolicy.decode(fixture.policy(
            configuredPath: fixture.directory.path,
            remoteRules: [["scheme": "ssh", "host": "github.com", "pathPrefix": "/degentlemen/"]]
        ))
        XCTAssertThrowsError(try ProjectSourceProvisioningService(
            cloneRoot: fixture.cloneRoot.path,
            policy: policy,
            credentials: ProjectSourceGitCredentials(),
            resources: store,
            git: FakeProjectSourceGitRunner()
        )) { error in
            XCTAssertEqual((error as? ServiceAPIError)?.code, .invalidRequest)
        }
    }

    func testRealGitRunnerRejectsFastOutputOverrunAfterExit() async throws {
        let fixture = try RealRunnerFixture(script: "#!/bin/sh\ndd if=/dev/zero bs=65536 count=1 2>/dev/null\n")
        defer { fixture.cleanup() }
        do {
            _ = try await LocalProjectSourceGitRunner().run(fixture.invocation(maximumOutputBytes: 4_096, timeoutSeconds: 5))
            XCTFail("Expected output limit rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .dependencyUnavailable)
        }
    }

    func testRealGitRunnerTimeoutTerminatesAndReapsProcess() async throws {
        let fixture = try RealRunnerFixture(script: "#!/bin/sh\necho $$ > process.pid\nwhile :; do :; done\n")
        defer { fixture.cleanup() }
        do {
            _ = try await LocalProjectSourceGitRunner().run(fixture.invocation(timeoutSeconds: 1))
            XCTFail("Expected timeout")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .dependencyUnavailable)
        }
        let processID = try fixture.processID(named: "process.pid")
        let gone = await processIsGone(processID)
        XCTAssertTrue(gone)
    }

    func testRealGitRunnerCancellationTerminatesAndReapsProcess() async throws {
        let fixture = try RealRunnerFixture(script: "#!/bin/sh\necho $$ > process.pid\nwhile :; do :; done\n")
        defer { fixture.cleanup() }
        let task = Task { try await LocalProjectSourceGitRunner().run(fixture.invocation(timeoutSeconds: 30)) }
        try await fixture.waitForFile(named: "process.pid")
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let processID = try fixture.processID(named: "process.pid")
        let gone = await processIsGone(processID)
        XCTAssertTrue(gone)
    }

    #if os(Linux)
    func testLinuxSupervisorAnchorsFinalValidationThenSuccessReleasesWithoutLaterSignal() async throws {
        let fixture = try RealRunnerFixture(script: "#!/bin/sh\nexit 23\n")
        defer { fixture.cleanup() }
        let invocation = fixture.invocation(timeoutSeconds: 5)
        XCTAssertTrue(FileManager.default.createFile(atPath: invocation.outputPath, contents: nil))
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: invocation.outputPath))
        defer { try? output.close() }
        let lifecycle = ManagedProjectSourceProcess()
        try LocalProjectSourceGitRunner.spawnLinuxSupervisor(
            invocation,
            outputDescriptor: output.fileDescriptor,
            lifecycle: lifecycle
        )

        XCTAssertEqual(await waitForGitStatus(lifecycle), 23)
        let anchorPID = lifecycle.testSupervisorProcessID
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(kill(anchorPID, 0), 0, "The anchor must outlive Git through final validation")

        XCTAssertTrue(lifecycle.releaseSupervisor())
        let commandsAfterRelease = lifecycle.testControlCommandsSent
        XCTAssertTrue(await waitForSupervisorExit(lifecycle))
        lifecycle.signal(SIGTERM)
        XCTAssertEqual(lifecycle.testControlCommandsSent, commandsAfterRelease, "No signal command may be sent after release")
        XCTAssertNotEqual(kill(anchorPID, 0), 0, "The released supervisor must be reaped")
    }

    func testLinuxStoppedSupervisorConsumesKillEscalationBeforeReap() async throws {
        let fixture = try RealRunnerFixture(script: "#!/bin/sh\nexit 0\n")
        defer { fixture.cleanup() }
        let invocation = fixture.invocation(timeoutSeconds: 5)
        XCTAssertTrue(FileManager.default.createFile(atPath: invocation.outputPath, contents: nil))
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: invocation.outputPath))
        defer { try? output.close() }
        let lifecycle = ManagedProjectSourceProcess()
        try LocalProjectSourceGitRunner.spawnLinuxSupervisor(
            invocation,
            outputDescriptor: output.fileDescriptor,
            lifecycle: lifecycle
        )
        defer { lifecycle.signal(SIGKILL) }

        XCTAssertEqual(await waitForGitStatus(lifecycle), 0)
        let anchorPID = lifecycle.testSupervisorProcessID
        guard kill(anchorPID, SIGSTOP) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var stoppedStatus: Int32 = 0
        guard waitpid(anchorPID, &stoppedStatus, WUNTRACED) == anchorPID else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        XCTAssertTrue(WIFSTOPPED(stoppedStatus))
        XCTAssertTrue(lifecycle.releaseSupervisor())
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(kill(anchorPID, 0), 0, "A stopped anchor cannot consume release yet")

        lifecycle.signal(SIGKILL)
        XCTAssertTrue(await waitForSupervisorExit(lifecycle))
        XCTAssertNotEqual(kill(anchorPID, 0), 0)
    }

    func testLinuxStoppedSupervisorParentDeathWakesAndCleansDescendants() throws {
        let fixture = try RealRunnerFixture(
            script: "#!/bin/sh\nsh -c 'trap \"\" TERM; while :; do sleep 1; done' &\necho $! > child.pid\ntouch ready.marker\nwait\n"
        )
        defer { fixture.cleanup() }
        let invocation = fixture.invocation(timeoutSeconds: 30)
        XCTAssertTrue(FileManager.default.createFile(atPath: invocation.outputPath, contents: nil))
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: invocation.outputPath))
        defer { try? output.close() }
        var reportPipe = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(pipe(&reportPipe), 0)
        defer { if reportPipe[0] >= 0 { close(reportPipe[0]) } }

        let helperPID = fork()
        if helperPID == 0 {
            close(reportPipe[0])
            let lifecycle = ManagedProjectSourceProcess()
            do {
                try LocalProjectSourceGitRunner.spawnLinuxSupervisor(
                    invocation,
                    outputDescriptor: output.fileDescriptor,
                    lifecycle: lifecycle
                )
                let readyPath = fixture.directory.appendingPathComponent("ready.marker").path
                for _ in 0 ..< 500 {
                    if readyPath.withCString({ access($0, F_OK) }) == 0 { break }
                    usleep(10_000)
                }
                var supervisorPID = lifecycle.testSupervisorProcessID
                var stoppedStatus: Int32 = 0
                if readyPath.withCString({ access($0, F_OK) }) != 0
                    || kill(supervisorPID, SIGSTOP) != 0
                    || waitpid(supervisorPID, &stoppedStatus, WUNTRACED) != supervisorPID
                    || !WIFSTOPPED(stoppedStatus)
                {
                    supervisorPID = -1
                }
                _ = withUnsafeBytes(of: &supervisorPID) { bytes in
                    write(reportPipe[1], bytes.baseAddress, bytes.count)
                }
            } catch {
                var failure = pid_t(-1)
                _ = withUnsafeBytes(of: &failure) { bytes in
                    write(reportPipe[1], bytes.baseAddress, bytes.count)
                }
            }
            _exit(0)
        }
        guard helperPID > 0 else {
            let forkError = errno
            close(reportPipe[0])
            close(reportPipe[1])
            reportPipe = [-1, -1]
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(forkError))
        }

        var supervisorPID = pid_t(-1)
        var descendantPID = pid_t(-1)
        defer {
            if helperPID > 1 { _ = kill(helperPID, SIGKILL) }
            if supervisorPID > 1 {
                _ = kill(supervisorPID, SIGCONT)
                _ = kill(supervisorPID, SIGKILL)
            }
            if descendantPID > 1 { _ = kill(descendantPID, SIGKILL) }
        }

        close(reportPipe[1])
        reportPipe[1] = -1
        let reportCount = withUnsafeMutableBytes(of: &supervisorPID) { bytes in
            read(reportPipe[0], bytes.baseAddress, bytes.count)
        }
        close(reportPipe[0])
        reportPipe[0] = -1
        var helperStatus: Int32 = 0
        XCTAssertEqual(waitpid(helperPID, &helperStatus, 0), helperPID)
        guard reportCount == MemoryLayout<pid_t>.size, supervisorPID > 1 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ECHILD))
        }
        descendantPID = try fixture.processID(named: "child.pid")

        XCTAssertTrue(
            processIsGoneSynchronously(supervisorPID),
            "Parent death must wake and terminate a SIGSTOPed supervisor"
        )
        XCTAssertTrue(
            processIsGoneSynchronously(descendantPID),
            "Parent-death cleanup must not leave a SIGTERM-resistant descendant"
        )
    }

    func testLinuxCloseRangeFallbackClosesInheritedDescriptorAbove65535BeforeGitExec() async throws {
        var sentinelPipe = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(pipe(&sentinelPipe), 0)
        var inheritedDescriptor = fcntl(sentinelPipe[0], F_DUPFD, 70_000)
        close(sentinelPipe[0])
        close(sentinelPipe[1])
        guard inheritedDescriptor >= 70_000 else {
            throw XCTSkip("RLIMIT_NOFILE does not permit a descriptor above 65535")
        }
        defer { if inheritedDescriptor >= 0 { close(inheritedDescriptor) } }

        let noFileResource = __rlimit_resource_t(RLIMIT_NOFILE.rawValue)
        var originalLimit = rlimit()
        guard getrlimit(noFileResource, &originalLimit) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var loweredLimit = originalLimit
        loweredLimit.rlim_cur = min(originalLimit.rlim_cur, rlim_t(1_024))
        guard setrlimit(noFileResource, &loweredLimit) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var limitIsLowered = true
        defer {
            if limitIsLowered { _ = setrlimit(noFileResource, &originalLimit) }
        }

        let fixture = try RealRunnerFixture(
            script: "#!/bin/sh\nif [ -e /proc/self/fd/\(inheritedDescriptor) ]; then touch inherited-fd.marker; exit 91; fi\nexit 0\n"
        )
        defer { fixture.cleanup() }
        let invocation = fixture.invocation(
            timeoutSeconds: 5,
            environmentOverrides: ["REPOPROMPT_TEST_FORCE_CLOSE_RANGE_FALLBACK": "1"]
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: invocation.outputPath, contents: nil))
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: invocation.outputPath))
        defer { try? output.close() }
        let lifecycle = ManagedProjectSourceProcess()
        try LocalProjectSourceGitRunner.spawnLinuxSupervisor(
            invocation,
            outputDescriptor: output.fileDescriptor,
            lifecycle: lifecycle
        )
        defer { lifecycle.signal(SIGKILL) }
        guard setrlimit(noFileResource, &originalLimit) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        limitIsLowered = false
        close(inheritedDescriptor)
        inheritedDescriptor = -1

        XCTAssertEqual(await waitForGitStatus(lifecycle), 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("inherited-fd.marker").path
        ))
        XCTAssertTrue(lifecycle.releaseSupervisor())
        XCTAssertTrue(await waitForSupervisorExit(lifecycle))
    }

    func testLinuxCloseRangeFallbackFailsClosedWhenProcFDOpenFails() async throws {
        try await assertLinuxProcFDFaultFailsClosed("open")
    }

    func testLinuxCloseRangeFallbackFailsClosedWhenProcFDEnumerationFails() async throws {
        try await assertLinuxProcFDFaultFailsClosed("readdir")
    }

    private func assertLinuxProcFDFaultFailsClosed(_ fault: String) async throws {
        let fixture = try RealRunnerFixture(script: "#!/bin/sh\ntouch exec.marker\nexit 0\n")
        defer { fixture.cleanup() }
        let invocation = fixture.invocation(
            timeoutSeconds: 5,
            environmentOverrides: [
                "REPOPROMPT_TEST_FORCE_CLOSE_RANGE_FALLBACK": "1",
                "REPOPROMPT_TEST_PROC_FD_FAULT": fault,
            ]
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: invocation.outputPath, contents: nil))
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: invocation.outputPath))
        defer { try? output.close() }
        let lifecycle = ManagedProjectSourceProcess()
        try LocalProjectSourceGitRunner.spawnLinuxSupervisor(
            invocation,
            outputDescriptor: output.fileDescriptor,
            lifecycle: lifecycle
        )
        defer { lifecycle.signal(SIGKILL) }

        XCTAssertEqual(await waitForGitStatus(lifecycle), 127)
        XCTAssertTrue(await waitForSupervisorExit(lifecycle))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("exec.marker").path
        ))
    }

    func testLinuxSupervisorFailureSignalsFamilyWhileAnchorIsOwned() async throws {
        let fixture = try RealRunnerFixture(
            script: "#!/bin/sh\nsh -c 'trap \"echo terminated > term.marker; exit 0\" TERM; while :; do sleep 1; done' &\necho $! > child.pid\nexit 7\n"
        )
        defer { fixture.cleanup() }
        let invocation = fixture.invocation(timeoutSeconds: 5)
        XCTAssertTrue(FileManager.default.createFile(atPath: invocation.outputPath, contents: nil))
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: invocation.outputPath))
        defer { try? output.close() }
        let lifecycle = ManagedProjectSourceProcess()
        try LocalProjectSourceGitRunner.spawnLinuxSupervisor(
            invocation,
            outputDescriptor: output.fileDescriptor,
            lifecycle: lifecycle
        )

        XCTAssertEqual(await waitForGitStatus(lifecycle), 7)
        let anchorPID = lifecycle.testSupervisorProcessID
        XCTAssertEqual(kill(anchorPID, 0), 0)
        lifecycle.signal(SIGTERM)
        try await fixture.waitForFile(named: "term.marker")
        XCTAssertEqual(kill(anchorPID, 0), 0, "TERM must run while the anchor still owns the group")
        lifecycle.signal(SIGKILL)
        XCTAssertTrue(await waitForSupervisorExit(lifecycle))
        XCTAssertTrue(await processIsGone(try fixture.processID(named: "child.pid")))
    }

    func testRealGitRunnerPostExitOutputFailureTerminatesDescendantProcessGroup() async throws {
        let fixture = try RealRunnerFixture(
            script: "#!/bin/sh\nsleep 30 &\necho $! > child.pid\nexec dd if=/dev/zero bs=65536 count=1 2>/dev/null\n"
        )
        defer { fixture.cleanup() }
        do {
            _ = try await LocalProjectSourceGitRunner().run(
                fixture.invocation(maximumOutputBytes: 4_096, timeoutSeconds: 5)
            )
            XCTFail("Expected post-exit output limit rejection")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .dependencyUnavailable)
        }
        let childID = try fixture.processID(named: "child.pid")
        let gone = await processIsGone(childID)
        XCTAssertTrue(gone, "A descendant outliving the runner leader must be terminated")
    }

    func testRealGitRunnerTimeoutTerminatesDescendantProcessGroup() async throws {
        let fixture = try RealRunnerFixture(script: "#!/bin/sh\nsleep 30 &\necho $! > child.pid\nwait\n")
        defer { fixture.cleanup() }
        do {
            _ = try await LocalProjectSourceGitRunner().run(fixture.invocation(timeoutSeconds: 1))
            XCTFail("Expected timeout")
        } catch let error as ServiceAPIError {
            XCTAssertEqual(error.code, .dependencyUnavailable)
        }
        let childID = try fixture.processID(named: "child.pid")
        let gone = await processIsGone(childID)
        XCTAssertTrue(gone)
    }
    #endif

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

    func testConcurrentIdenticalConfiguredRootRequestsJoinOneOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let configured = fixture.directory.appendingPathComponent("configured", isDirectory: true)
        try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: true)
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = try ProjectSourceProvisioningService(
            cloneRoot: fixture.cloneRoot.path,
            policy: try ProjectSourcePolicy.decode(fixture.policy(configuredPath: configured.path)),
            credentials: ProjectSourceGitCredentials(),
            resources: store,
            git: FakeProjectSourceGitRunner()
        )
        let authority = RepoPromptHeadlessAuthority(store: store, projectSourceService: service)
        let actor = ExternalActor(goblinUserID: "concurrent-configured", username: "alice", displayName: "Alice")
        let input = ProjectSourceOperationInput(
            operationID: UUID(), expectedRevision: 0, name: "Configured", logicalName: "workspace",
            source: .configuredRoot(alias: "chat-server")
        )
        async let first = authority.createProjectFromSource(
            input: input, externalActor: actor, idempotencyKey: "same-key", requestDigest: "same-digest"
        )
        async let second = authority.createProjectFromSource(
            input: input, externalActor: actor, idempotencyKey: "same-key", requestDigest: "same-digest"
        )
        let results = try await (first, second)
        XCTAssertEqual(results.0, results.1)
        let projectCount = await authority.projectSnapshots().count
        XCTAssertEqual(projectCount, 1)
    }

    func testConcurrentIdenticalCloneRequestsShareOneStagingOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let git = FakeProjectSourceGitRunner(cloneDelay: .milliseconds(200))
        let service = try ProjectSourceProvisioningService(
            cloneRoot: fixture.cloneRoot.path,
            policy: try ProjectSourcePolicy.decode(fixture.policy(configuredPath: fixture.directory.path)),
            credentials: ProjectSourceGitCredentials(),
            resources: store,
            git: git
        )
        let authority = RepoPromptHeadlessAuthority(store: store, projectSourceService: service)
        let actor = ExternalActor(goblinUserID: "concurrent-clone", username: "alice", displayName: "Alice")
        let input = ProjectSourceOperationInput(
            operationID: UUID(), expectedRevision: 0, name: "Clone", logicalName: "workspace",
            source: .gitClone(remote: "https://github.com/degentlemen/chat-server.git", ref: "main")
        )
        async let first = authority.createProjectFromSource(
            input: input, externalActor: actor, idempotencyKey: "same-key", requestDigest: "same-digest"
        )
        async let second = authority.createProjectFromSource(
            input: input, externalActor: actor, idempotencyKey: "same-key", requestDigest: "same-digest"
        )
        let results = try await (first, second)
        XCTAssertEqual(results.0, results.1)
        let invocations = await git.recorded()
        XCTAssertEqual(invocations.filter { $0.arguments.contains("clone") }.count, 1)
        let projectCount = await authority.projectSnapshots().count
        XCTAssertEqual(projectCount, 1)
    }

    func testCanceledJoinedCloneWaiterReturnsPromptlyWithoutCancelingSharedOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let git = FakeProjectSourceGitRunner(cloneDelay: .milliseconds(300))
        let service = try ProjectSourceProvisioningService(
            cloneRoot: fixture.cloneRoot.path,
            policy: try ProjectSourcePolicy.decode(fixture.policy(configuredPath: fixture.directory.path)),
            credentials: ProjectSourceGitCredentials(),
            resources: store,
            git: git
        )
        let authority = RepoPromptHeadlessAuthority(store: store, projectSourceService: service)
        let actor = ExternalActor(goblinUserID: "canceled-waiter", username: "alice", displayName: "Alice")
        let input = ProjectSourceOperationInput(
            operationID: UUID(), expectedRevision: 0, name: "Clone", logicalName: "workspace",
            source: .gitClone(remote: "https://github.com/degentlemen/chat-server.git", ref: "main")
        )
        let primary = Task { try await authority.createProjectFromSource(
            input: input, externalActor: actor, idempotencyKey: "same-key", requestDigest: "same-digest"
        ) }
        var cloneStarted = false
        for _ in 0 ..< 100 {
            if await git.recorded().contains(where: { $0.arguments.contains("clone") }) {
                cloneStarted = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(cloneStarted)
        let waiter = Task { try await authority.createProjectFromSource(
            input: input, externalActor: actor, idempotencyKey: "same-key", requestDigest: "same-digest"
        ) }
        try await Task.sleep(for: .milliseconds(30))
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("Expected joined waiter cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        _ = try await primary.value
        let invocations = await git.recorded()
        XCTAssertEqual(invocations.filter { $0.arguments.contains("clone") }.count, 1)
    }

    func testConcurrentDifferentPayloadsWithSameKeyConflictAtomically() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let configured = fixture.directory.appendingPathComponent("configured", isDirectory: true)
        try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: true)
        let store = try await SQLiteServiceStore.open(storage: .memory)
        defer { Task { try? await store.close() } }
        let service = try ProjectSourceProvisioningService(
            cloneRoot: fixture.cloneRoot.path,
            policy: try ProjectSourcePolicy.decode(fixture.policy(configuredPath: configured.path)),
            credentials: ProjectSourceGitCredentials(),
            resources: store,
            git: FakeProjectSourceGitRunner(cloneDelay: .milliseconds(200))
        )
        let authority = RepoPromptHeadlessAuthority(store: store, projectSourceService: service)
        let actor = ExternalActor(goblinUserID: "concurrent-conflict", username: "alice", displayName: "Alice")
        let clone = ProjectSourceOperationInput(
            operationID: UUID(), expectedRevision: 0, name: "Clone", logicalName: "workspace",
            source: .gitClone(remote: "https://github.com/degentlemen/chat-server.git", ref: "main")
        )
        let configuredInput = ProjectSourceOperationInput(
            operationID: UUID(), expectedRevision: 0, name: "Configured", logicalName: "workspace",
            source: .configuredRoot(alias: "chat-server")
        )
        let first = Task { try await authority.createProjectFromSource(
            input: clone, externalActor: actor, idempotencyKey: "reused-key", requestDigest: "digest-a"
        ) }
        let second = Task { try await authority.createProjectFromSource(
            input: configuredInput, externalActor: actor, idempotencyKey: "reused-key", requestDigest: "digest-b"
        ) }
        let outcomes = [await first.result, await second.result]
        XCTAssertEqual(outcomes.filter { if case .success = $0 { true } else { false } }.count, 1)
        let errors = outcomes.compactMap { result -> Error? in
            if case let .failure(error) = result { return error }
            return nil
        }
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual((errors.first as? ServiceAPIError)?.code, .idempotencyConflict)
        let projectCount = await authority.projectSnapshots().count
        XCTAssertEqual(projectCount, 1)
    }
}

private struct RealRunnerFixture {
    let directory: URL
    let script: URL

    init(script contents: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        script = directory.appendingPathComponent("runner-script")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    }

    func invocation(
        maximumOutputBytes: Int = 16_384,
        timeoutSeconds: Int,
        environmentOverrides: [String: String] = [:]
    ) -> ProjectSourceGitInvocation {
        ProjectSourceGitInvocation(
            executable: script.path,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
                .merging(environmentOverrides) { _, override in override },
            workingDirectory: directory.path,
            outputPath: directory.appendingPathComponent("output").path,
            observedDirectory: directory.path,
            maximumOutputBytes: maximumOutputBytes,
            maximumDirectoryBytes: 10_485_760,
            timeoutSeconds: timeoutSeconds
        )
    }

    func waitForFile(named name: String) async throws {
        let path = directory.appendingPathComponent(name).path
        for _ in 0 ..< 100 {
            if FileManager.default.fileExists(atPath: path) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ServiceAPIError(code: .dependencyUnavailable, message: "Fixture process did not start")
    }

    func processID(named name: String) throws -> pid_t {
        let value = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(pid_t(value))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

#if os(Linux)
private func processIsGoneSynchronously(_ processID: pid_t) -> Bool {
    for _ in 0 ..< 250 {
        if kill(processID, 0) != 0 { return true }
        usleep(20_000)
    }
    return false
}

private func waitForGitStatus(_ lifecycle: ManagedProjectSourceProcess) async -> Int32? {
    for _ in 0 ..< 100 {
        if let status = lifecycle.terminationStatus() { return status }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return nil
}

private func waitForSupervisorExit(_ lifecycle: ManagedProjectSourceProcess) async -> Bool {
    for _ in 0 ..< 100 {
        if !lifecycle.terminationTargetExists() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}
#endif

private func processIsGone(_ processID: pid_t) async -> Bool {
    for _ in 0 ..< 100 {
        if kill(processID, 0) != 0 { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

private struct Fixture {
    let directory: URL
    let cloneRoot: URL

    init() throws {
        directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".test-project-source-\(UUID().uuidString)", isDirectory: true)
        cloneRoot = directory.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: cloneRoot, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }

    func policy(
        configuredPath: String,
        remoteRules: [[String: String]] = [["scheme": "https", "host": "github.com", "pathPrefix": "/degentlemen/"]],
        allowedRefPatterns: [String] = ["^(main|release/[A-Za-z0-9._-]+)$"],
        deniedRefPatterns: [String] = ["^private/.*$"]
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "configuredRoots": [["alias": "chat-server", "path": configuredPath, "writable": true]],
            "git": [
                "remoteRules": remoteRules,
                "allowedRefPatterns": allowedRefPatterns,
                "deniedRefPatterns": deniedRefPatterns,
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
    private let cloneDelay: Duration?
    private var origin = "https://github.com/degentlemen/chat-server.git"

    init(failClone: Bool = false, cloneDelay: Duration? = nil) {
        self.failClone = failClone
        self.cloneDelay = cloneDelay
    }

    func recorded() -> [ProjectSourceGitInvocation] {
        invocations
    }

    func run(_ invocation: ProjectSourceGitInvocation) async throws -> String {
        invocations.append(invocation)
        if invocation.arguments.contains("clone") {
            if let cloneDelay { try await Task.sleep(for: cloneDelay) }
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
