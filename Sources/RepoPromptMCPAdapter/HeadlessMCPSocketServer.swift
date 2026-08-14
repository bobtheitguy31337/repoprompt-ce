#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Logging
import MCP
import RepoPromptDomainRuntime
import RepoPromptHeadlessRuntime
import RepoPromptServiceProtocol

/// In-process analogue of Desktop `BootstrapSocketServer`: Codex spawns
/// `RepoPromptServer mcp-stdio`, which connects here so `agent_run` hits the
/// same `RepoPromptHeadlessAuthority` as the parent Codex run.
public actor HeadlessMCPSocketServer {
    public struct Handshake: Codable, Sendable {
        public let sessionID: UUID
        public let runID: UUID?

        public init(sessionID: UUID, runID: UUID? = nil) {
            self.sessionID = sessionID
            self.runID = runID
        }
    }

    public enum ServerError: Error, Equatable {
        case pathTooLong
        case socket(errno: Int32)
        case bind(errno: Int32)
        case listen(errno: Int32)
        case handshakeTimeout
        case invalidHandshake
    }

    public let socketURL: URL
    private let adapter: RepoPromptMCPAdapter
    private let logger: Logger
    private var listenFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private var clientTasks: [UUID: Task<Void, Never>] = [:]

    public init(
        socketURL: URL,
        adapter: RepoPromptMCPAdapter,
        logger: Logger = Logger(label: "com.repoprompt.ce.mcp.headless-socket")
    ) {
        self.socketURL = socketURL
        self.adapter = adapter
        self.logger = logger
    }

    public func start() throws {
        guard listenFD < 0 else { return }
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        PortablePOSIX.unlinkPath(socketURL.path)
        let fd = PortablePOSIX.unixStreamSocket()
        guard fd >= 0 else { throw ServerError.socket(errno: errno) }
        PortablePOSIX.enableNoSIGPIPE(on: fd)
        var address = sockaddr_un()
        guard PortablePOSIX.fillUnixAddress(&address, path: socketURL.path) else {
            PortablePOSIX.closeDescriptor(fd)
            throw ServerError.pathTooLong
        }
        let bindResult = PortablePOSIX.bindUnix(fd, &address)
        guard bindResult == 0 else {
            let code = errno
            PortablePOSIX.closeDescriptor(fd)
            throw ServerError.bind(errno: code)
        }
        guard PortablePOSIX.chmodPath(socketURL.path, mode: 0o600) == 0 else {
            let code = errno
            PortablePOSIX.closeDescriptor(fd)
            PortablePOSIX.unlinkPath(socketURL.path)
            throw ServerError.bind(errno: code)
        }
        guard PortablePOSIX.listen(fd, backlog: 16) == 0 else {
            let code = errno
            PortablePOSIX.closeDescriptor(fd)
            PortablePOSIX.unlinkPath(socketURL.path)
            throw ServerError.listen(errno: code)
        }
        listenFD = fd
        acceptTask = Task.detached { [weak self] in
            guard let self else { return }
            await Self.acceptLoop(server: self, fd: fd)
        }
    }

    public func stop() async {
        let listener = listenFD
        listenFD = -1
        if listener >= 0 {
            PortablePOSIX.shutdownDescriptor(listener, how: SHUT_RDWR)
            PortablePOSIX.closeDescriptor(listener)
        }
        PortablePOSIX.unlinkPath(socketURL.path)
        acceptTask?.cancel()
        acceptTask = nil
        let clients = clientTasks
        clientTasks.removeAll()
        for task in clients.values {
            task.cancel()
        }
        for task in clients.values {
            await task.value
        }
    }

    private static func acceptLoop(server: HeadlessMCPSocketServer, fd: Int32) async {
        while !Task.isCancelled {
            let client = PortablePOSIX.accept(fd)
            if client < 0 {
                if errno == EINTR { continue }
                if Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(20))
                continue
            }
            PortablePOSIX.enableNoSIGPIPE(on: client)
            let connectionID = UUID()
            let task = Task {
                await server.serve(clientFD: client)
                await server.forget(connectionID: connectionID)
            }
            await server.remember(connectionID: connectionID, task: task)
        }
    }

    private func remember(connectionID: UUID, task: Task<Void, Never>) {
        clientTasks[connectionID] = task
    }

    private func forget(connectionID: UUID) {
        clientTasks[connectionID] = nil
    }

    private func serve(clientFD: Int32) async {
        defer { PortablePOSIX.closeDescriptor(clientFD) }
        let handshake: Handshake
        do {
            handshake = try readHandshake(from: clientFD)
        } catch {
            logger.warning("Rejected MCP handshake", metadata: ["error": "\(error)"])
            return
        }
        let snapshot: SessionSnapshot
        do {
            snapshot = try await adapter.sessionSnapshot(id: handshake.sessionID)
        } catch {
            logger.warning("MCP session not found", metadata: ["session": "\(handshake.sessionID)"])
            return
        }
        let binding = RepoPromptMCPBinding(sessionID: snapshot.sessionID, actor: snapshot.creator)
        let visibleNames = HeadlessCodexMCPToolPolicy.advertisedToolNames(
            isRootSession: snapshot.parentSessionID == nil
        )
        let classification = MCPClientToolPolicyCatalog.classification(for: .agentModeCodexEngineer)
        let server = Server(
            name: "RepoPrompt CE",
            version: "1",
            title: "RepoPrompt CE",
            instructions: "Canonical RepoPrompt MCP tools bound to the calling Agent Mode session.",
            capabilities: .init(tools: .init(listChanged: false)),
            configuration: .init(strict: true, responseSendTimeout: .seconds(5))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            let tools = MCPDomainCanonicalToolDefinitions.definitions.compactMap { definition -> MCP.Tool? in
                guard visibleNames.contains(definition.name) else { return nil }
                let projected = definition.annotations.projected(for: classification.annotationProfile)
                return MCP.Tool(
                    name: definition.name,
                    description: definition.description,
                    inputSchema: definition.inputSchema,
                    annotations: .init(
                        title: projected.title,
                        readOnlyHint: projected.readOnlyHint,
                        destructiveHint: projected.destructiveHint,
                        idempotentHint: projected.idempotentHint,
                        openWorldHint: projected.openWorldHint
                    )
                )
            }
            return ListTools.Result(tools: tools)
        }
        let adapter = adapter
        await server.withMethodHandler(CallTool.self) { params in
            guard visibleNames.contains(params.name) else {
                return Self.errorResult("Tool is unavailable for this client policy: \(params.name)")
            }
            do {
                let arguments = params.arguments ?? [:]
                let data = try await adapter.invoke(
                    toolName: params.name,
                    argumentsJSON: JSONEncoder().encode(arguments),
                    binding: binding
                )
                let value = try JSONDecoder().decode(Value.self, from: data)
                return Self.successResult(value)
            } catch {
                return Self.errorResult(String(describing: error))
            }
        }
        let transport = PortableMCPByteTransport(
            stdinFD: clientFD,
            stdoutFD: clientFD,
            logger: logger
        )
        do {
            try await server.start(transport: transport)
            _ = await transport.waitUntilTerminal()
            await server.stop()
            await server.waitUntilCompleted()
        } catch {
            logger.warning("MCP connection failed", metadata: ["error": "\(error)"])
            await server.stop()
        }
    }

    private func readHandshake(from fd: Int32) throws -> Handshake {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while ContinuousClock().now < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let polled = PortablePOSIX.poll(&descriptor, timeout: 100)
            if polled == 0 { continue }
            if polled < 0 {
                if errno == EINTR { continue }
                throw ServerError.invalidHandshake
            }
            let count = PortablePOSIX.read(fd, &buffer, buffer.count)
            if count == 0 { throw ServerError.invalidHandshake }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw ServerError.invalidHandshake
            }
            pending.append(buffer, count: count)
            if let newline = pending.firstIndex(of: 0x0A) {
                let payload = pending.prefix(upTo: newline)
                guard let handshake = try? JSONDecoder().decode(Handshake.self, from: Data(payload)) else {
                    throw ServerError.invalidHandshake
                }
                return handshake
            }
            if pending.count > 4096 { throw ServerError.invalidHandshake }
        }
        throw ServerError.handshakeTimeout
    }

    private static func successResult(_ value: Value) -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
            ?? String(describing: value)
        return CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            isError: false
        )
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }
}
