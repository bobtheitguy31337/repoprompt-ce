import Foundation
import MCP
import RepoPromptAgentRuntimeCore
import RepoPromptDomainRuntime
import RepoPromptHeadlessRuntime
import RepoPromptServiceProtocol

public struct RepoPromptMCPBinding: Sendable {
    public let sessionID: UUID
    public let actor: ExternalActor

    public init(sessionID: UUID, actor: ExternalActor) {
        self.sessionID = sessionID
        self.actor = actor
    }
}

/// Canonical MCP compatibility transport over the durable headless authority.
///
/// The adapter deliberately owns no project, selection, conversation, run, interaction, or
/// worktree state. Every tool invocation resolves through `RepoPromptHeadlessAuthority`; the
/// canonical domain catalog supplies the exact 27 tool names shared with the macOS product.
public actor RepoPromptMCPAdapter {
    private let authority: RepoPromptHeadlessAuthority

    public init(authority: RepoPromptHeadlessAuthority) {
        self.authority = authority
    }

    public nonisolated static var canonicalToolNames: [String] {
        MCPDomainToolCatalog.orderedToolNames
    }

    public func projectSnapshot(id: UUID) async throws -> ProjectSnapshot {
        try await authority.projectSnapshot(projectID: id)
    }

    public func sessionSnapshot(id: UUID) async throws -> SessionSnapshot {
        try await authority.sessionSnapshot(sessionID: id)
    }

    public func events(after cursor: ServiceCursor?, limit: Int) async throws -> EventPage {
        try await authority.events(after: cursor, limit: limit)
    }

    public func invoke(
        toolName: String,
        argumentsJSON: Data,
        binding: RepoPromptMCPBinding
    ) async throws -> Data {
        guard Self.canonicalToolNames.contains(toolName) else {
            throw ServiceAPIError(code: .capabilityMissing, message: "Unknown canonical MCP tool")
        }
        let arguments = try JSONDecoder().decode([String: Value].self, from: argumentsJSON)
        let invocation = try await authority.beginToolInvocation(sessionID: binding.sessionID, toolName: toolName, argumentDigest: CanonicalSigning.bodyDigest(argumentsJSON), actor: binding.actor)
        do {
            let backend = AuthorityToolBackend(authority: authority, binding: binding)
            let value = try await backend.invoke(toolName: toolName, arguments: arguments)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(value)
            try await authority.finishToolInvocation(sessionID: binding.sessionID, invocation: invocation, resultDigest: CanonicalSigning.bodyDigest(data), errorCode: nil, actor: binding.actor)
            return data
        } catch {
            let code = (error as? ServiceAPIError)?.code ?? .dependencyUnavailable
            try? await authority.finishToolInvocation(sessionID: binding.sessionID, invocation: invocation, resultDigest: nil, errorCode: code, actor: binding.actor)
            throw error
        }
    }

    package func install(
        runtime: MCPDomainRuntime,
        scopeID: DomainStandaloneScopeID,
        binding: RepoPromptMCPBinding
    ) async throws -> MCPDomainStandaloneToolInstallation {
        let backend = AuthorityDomainBackend(adapter: self, binding: binding)
        return try await MCPDomainStandaloneToolInstaller.install(
            runtime: runtime,
            scopeID: scopeID,
            backends: MCPDomainStandaloneCapabilityBackends(
                global: backend,
                workspace: backend,
                filesystem: backend,
                conversation: backend,
                versionControl: backend,
                agent: backend,
                history: backend
            )
        )
    }
}

private struct AuthorityDomainBackend: DomainGlobalControlBackend, DomainWorkspaceCapabilityBackend, DomainFilesystemMutationBackend, DomainConversationCapabilityBackend, DomainVersionControlCapabilityBackend, DomainAgentCapabilityBackend, DomainHistoryCapabilityBackend {
    let adapter: RepoPromptMCPAdapter
    let binding: RepoPromptMCPBinding

    private func call(_ toolName: String, _ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await DomainPhysicalToolResult(json: adapter.invoke(toolName: toolName, argumentsJSON: request.argumentsJSON, binding: binding))
    }

    private func call(_ toolName: String, _ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await call(toolName, request.request)
    }

    func accessSettings(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPGlobalToolName.appSettings, request)
    }

    func routeContext(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPGlobalToolName.bindContext, request)
    }

    func manageWorkspaceLifecycle(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPGlobalToolName.manageWorkspaces, request)
    }

    func mutateSelection(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.manageSelection, request)
    }

    func inspectCodeStructure(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.getCodeStructure, request)
    }

    func renderFileTree(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.getFileTree, request)
    }

    func readFile(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.readFile, request)
    }

    func searchFiles(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.search, request)
    }

    func renderWorkspaceContext(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.workspaceContext, request)
    }

    func accessPrompt(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.prompt, request)
    }

    func manageFiles(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.fileActions, request)
    }

    func applyFileEdits(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.applyEdits, request)
    }

    func accessOracleUtilities(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.oracleUtils, request)
    }

    func startOracleConversation(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.askOracle, request)
    }

    func continueOracleConversation(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.oracleSend, request)
    }

    func readOracleLog(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.oracleChatLog, request)
    }

    func buildContext(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.contextBuilder, request)
    }

    func requestUserInput(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.askUser, request)
    }

    func inspectGit(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.git, request)
    }

    func manageWorktree(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.manageWorktree, request)
    }

    func explore(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.agentExplore, request)
    }

    func run(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.agentRun, request)
    }

    func manage(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.agentManage, request)
    }

    func shareThoughts(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.shareThoughts, request)
    }

    func publishStatus(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.setStatus, request)
    }

    func waitForInstruction(_ request: DomainPhysicalToolRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.waitForNextInstruction, request)
    }

    func inspectHistory(_ request: DomainPhysicalReadRequest) async throws -> DomainPhysicalToolResult {
        try await call(MCPWindowToolName.history, request)
    }
}

private actor AuthorityToolBackend {
    private struct BoundPath {
        let root: ProjectRootSnapshot
        let physicalRoot: URL
        let logicalPath: String
        let physicalPath: URL
    }

    private let authority: RepoPromptHeadlessAuthority
    private let binding: RepoPromptMCPBinding

    init(authority: RepoPromptHeadlessAuthority, binding: RepoPromptMCPBinding) {
        self.authority = authority
        self.binding = binding
    }

    func invoke(toolName: String, arguments: [String: Value]) async throws -> Value {
        switch toolName {
        case MCPGlobalToolName.appSettings:
            try await appSettings(arguments)
        case MCPGlobalToolName.bindContext:
            try await bindContext()
        case MCPGlobalToolName.manageWorkspaces:
            try await manageWorkspaces(arguments)
        case MCPWindowToolName.manageSelection:
            try await manageSelection(arguments)
        case MCPWindowToolName.fileActions:
            try await manageFiles(arguments)
        case MCPWindowToolName.getCodeStructure:
            try await codeStructure(arguments)
        case MCPWindowToolName.getFileTree:
            try await fileTree(arguments)
        case MCPWindowToolName.readFile:
            try await readFile(arguments)
        case MCPWindowToolName.search:
            try await search(arguments)
        case MCPWindowToolName.workspaceContext:
            try await workspaceContext(arguments)
        case MCPWindowToolName.prompt:
            try await prompt(arguments)
        case MCPWindowToolName.applyEdits:
            try await applyEdits(arguments)
        case MCPWindowToolName.oracleUtils:
            try await oracleUtilities(arguments)
        case MCPWindowToolName.askOracle:
            try await askOracle(arguments, continuing: false)
        case MCPWindowToolName.oracleSend:
            try await askOracle(arguments, continuing: true)
        case MCPWindowToolName.oracleChatLog:
            try await oracleChatLog(arguments)
        case MCPWindowToolName.git:
            try await git(arguments)
        case MCPWindowToolName.manageWorktree:
            try await manageWorktree(arguments)
        case MCPWindowToolName.contextBuilder:
            try await contextBuilder(arguments)
        case MCPWindowToolName.askUser:
            try await askUser(arguments)
        case MCPWindowToolName.agentExplore:
            try await agentLifecycle(arguments, defaultRole: "explore")
        case MCPWindowToolName.agentRun:
            try await agentLifecycle(arguments, defaultRole: "pair")
        case MCPWindowToolName.agentManage:
            try await agentManage(arguments)
        case MCPWindowToolName.history:
            try await history(arguments)
        case MCPWindowToolName.shareThoughts:
            try await shareThoughts(arguments)
        case MCPWindowToolName.setStatus:
            try await setStatus(arguments)
        case MCPWindowToolName.waitForNextInstruction:
            try await waitForInstruction(arguments)
        default:
            throw ServiceAPIError(code: .capabilityMissing, message: "Unknown canonical MCP tool")
        }
    }

    private func appSettings(_ arguments: [String: Value]) async throws -> Value {
        let capabilities = try await authority.capabilities()
        let providers = await authority.providerCapabilities(preflight: arguments["op"]?.stringValue == "list")
        return try value(SettingsResult(
            operation: arguments["op"]?.stringValue ?? "list",
            capabilities: capabilities,
            providers: providers
        ))
    }

    private func bindContext() async throws -> Value {
        let session = try await session()
        return .object([
            "session_id": .string(session.sessionID.uuidString),
            "project_id": .string(session.projectID.uuidString),
            "root_session_id": .string(session.rootSessionID.uuidString),
            "authority": .string("RepoPromptHeadlessAuthority")
        ])
    }

    private func manageWorkspaces(_ arguments: [String: Value]) async throws -> Value {
        let operation = arguments["op"]?.stringValue ?? "list"
        let projects = await authority.projectSnapshots()
        let sessions = try await authority.sessionSnapshots()
        return try value(WorkspaceResult(operation: operation, projects: projects, sessions: sessions))
    }

    private func manageSelection(_ arguments: [String: Value]) async throws -> Value {
        let current = try await authority.selectionSnapshot(sessionID: binding.sessionID)
        let operation = arguments["op"]?.stringValue ?? "get"
        guard !["get", "preview"].contains(operation) else { return try value(current) }

        let requested = arguments["paths"]?.arrayValue?.compactMap(\.stringValue) ?? []
        var entries = current.entries
        switch operation {
        case "clear":
            entries = []
        case "set":
            entries = try await selectionEntries(paths: requested, mode: .full)
        case "add":
            let additions = try await selectionEntries(paths: requested, mode: .full)
            for entry in additions where !entries.contains(entry) {
                entries.append(entry)
            }
        case "remove":
            let removals = try await Set(selectionEntries(paths: requested, mode: .full).map {
                "\($0.rootID.uuidString):\($0.logicalPath)"
            })
            entries.removeAll { removals.contains("\($0.rootID.uuidString):\($0.logicalPath)") }
        case "promote":
            let promoted = try await Set(selectionEntries(paths: requested, mode: .full).map {
                "\($0.rootID.uuidString):\($0.logicalPath)"
            })
            entries = entries.map {
                promoted.contains("\($0.rootID.uuidString):\($0.logicalPath)")
                    ? LogicalSelectionEntry(rootID: $0.rootID, logicalPath: $0.logicalPath, mode: .full)
                    : $0
            }
        case "demote":
            let demoted = try await Set(selectionEntries(paths: requested, mode: .codeMap).map {
                "\($0.rootID.uuidString):\($0.logicalPath)"
            })
            entries = entries.map {
                demoted.contains("\($0.rootID.uuidString):\($0.logicalPath)")
                    ? LogicalSelectionEntry(rootID: $0.rootID, logicalPath: $0.logicalPath, mode: .codeMap)
                    : $0
            }
        default:
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported selection operation")
        }
        return try await value(authority.replaceSelection(
            sessionID: binding.sessionID,
            entries: entries,
            expectedRevision: current.revision,
            actor: binding.actor
        ))
    }

    private func fileTree(_ arguments: [String: Value]) async throws -> Value {
        let project = try await project()
        if arguments["type"]?.stringValue == "roots" { return try value(project.roots) }
        let maximumDepth = min(max(arguments["max_depth"]?.intValue ?? 6, 0), 32)
        let maximumEntries = min(max(arguments["maximum_entries"]?.intValue ?? 5000, 1), 10000)
        if let rawPath = arguments["path"]?.stringValue {
            let path = try await resolve(rawPath, allowMissingLeaf: false)
            return try await value(authority.projectTree(
                projectID: project.projectID,
                request: ProjectTreeRequest(
                    rootID: path.root.rootID,
                    logicalPath: path.logicalPath,
                    maximumDepth: maximumDepth,
                    maximumEntries: maximumEntries
                )
            ))
        }
        var entries: [ProjectTreeEntry] = []
        for root in project.roots {
            entries += try await authority.projectTree(
                projectID: project.projectID,
                request: ProjectTreeRequest(
                    rootID: root.rootID,
                    maximumDepth: maximumDepth,
                    maximumEntries: max(1, maximumEntries - entries.count)
                )
            )
            if entries.count >= maximumEntries { break }
        }
        return try value(Array(entries.prefix(maximumEntries)))
    }

    private func readFile(_ arguments: [String: Value]) async throws -> Value {
        guard let rawPath = arguments["path"]?.stringValue else {
            throw ServiceAPIError(code: .invalidRequest, message: "read_file requires path")
        }
        let path = try await resolve(rawPath, allowMissingLeaf: false)
        let snapshot = try await authority.projectFile(
            projectID: session().projectID,
            request: ProjectFileRequest(
                rootID: path.root.rootID,
                logicalPath: path.logicalPath,
                startLine: arguments["start_line"]?.intValue,
                lineCount: arguments["limit"]?.intValue
            )
        )
        return try value(snapshot)
    }

    private func search(_ arguments: [String: Value]) async throws -> Value {
        guard let query = arguments["pattern"]?.stringValue ?? arguments["query"]?.stringValue,
              !query.isEmpty
        else { throw ServiceAPIError(code: .invalidRequest, message: "file_search requires pattern") }
        let project = try await project()
        let requestedPath = arguments["path"]?.stringValue
        let roots: [(ProjectRootSnapshot, String)]
        if let requestedPath {
            let path = try await resolve(requestedPath, allowMissingLeaf: false)
            roots = [(path.root, path.logicalPath)]
        } else {
            roots = project.roots.map { ($0, "") }
        }
        var hits: [ProjectSearchHit] = []
        let limit = min(max(arguments["max_results"]?.intValue ?? 200, 1), 1000)
        for (root, logicalPath) in roots {
            hits += try await authority.projectSearch(
                projectID: project.projectID,
                request: ProjectSearchRequest(
                    rootID: root.rootID,
                    query: query,
                    logicalPath: logicalPath,
                    useRegex: arguments["regex"]?.boolValue ?? false,
                    maximumResults: max(1, limit - hits.count)
                )
            )
            if hits.count >= limit { break }
        }
        return try value(Array(hits.prefix(limit)))
    }

    private func codeStructure(_ arguments: [String: Value]) async throws -> Value {
        let selection = try await authority.selectionSnapshot(sessionID: binding.sessionID)
        let requested = arguments["paths"]?.arrayValue?.compactMap(\.stringValue) ?? []
        var paths = requested
        if paths.isEmpty {
            for entry in selection.entries {
                try await paths.append(physicalPath(for: entry))
            }
        }
        var maps: [ProjectCodeMapSnapshot] = []
        let projectID = try await session().projectID
        for rawPath in paths.prefix(256) {
            let path = try await resolve(rawPath, allowMissingLeaf: false)
            try await maps.append(authority.projectCodeMap(
                projectID: projectID,
                request: ProjectCodeMapRequest(rootID: path.root.rootID, logicalPath: path.logicalPath)
            ))
        }
        return try value(CodeStructureResult(files: maps, updatesPending: false))
    }

    private func workspaceContext(_ arguments: [String: Value]) async throws -> Value {
        let selection = try await authority.selectionSnapshot(sessionID: binding.sessionID)
        let include = arguments["include"]?.arrayValue?.compactMap(\.stringValue)
            ?? ["prompt", "selection", "files", "code"]
        let artifact = try await authority.buildContext(
            sessionID: binding.sessionID,
            expectedSelectionRevision: selection.revision,
            include: include,
            actor: binding.actor
        )
        let content = try await authority.artifactContent(artifactID: artifact.artifactID, maximumBytes: 8_388_608)
        return try .object([
            "artifact": value(artifact),
            "content": .string(String(decoding: content, as: UTF8.self))
        ])
    }

    private func prompt(_ arguments: [String: Value]) async throws -> Value {
        let operation = arguments["op"]?.stringValue ?? "get"
        var context = try await authority.sessionContext(sessionID: binding.sessionID)
        switch operation {
        case "get": break
        case "set":
            context = try await authority.updateSessionPrompt(
                sessionID: binding.sessionID,
                prompt: arguments["text"]?.stringValue ?? "",
                expectedContextRevision: context.contextRevision,
                actor: binding.actor
            )
        case "append":
            context = try await authority.updateSessionPrompt(
                sessionID: binding.sessionID,
                prompt: context.prompt + (arguments["text"]?.stringValue ?? ""),
                expectedContextRevision: context.contextRevision,
                actor: binding.actor
            )
        case "clear":
            context = try await authority.updateSessionPrompt(
                sessionID: binding.sessionID,
                prompt: "",
                expectedContextRevision: context.contextRevision,
                actor: binding.actor
            )
        default:
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported prompt operation")
        }
        return try value(context)
    }

    private func manageFiles(_ arguments: [String: Value]) async throws -> Value {
        guard let operation = arguments["action"]?.stringValue else {
            throw ServiceAPIError(code: .invalidRequest, message: "file_actions requires action")
        }
        guard let rawPath = arguments["path"]?.stringValue else {
            throw ServiceAPIError(code: .invalidRequest, message: "file_actions requires path")
        }
        let source = try await resolve(rawPath, allowMissingLeaf: operation == "create")
        guard source.root.writable else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Project root is read-only")
        }
        switch operation {
        case "create":
            let overwrite = arguments["if_exists"]?.stringValue == "overwrite"
            if FileManager.default.fileExists(atPath: source.physicalPath.path), !overwrite {
                throw ServiceAPIError(code: .staleRevision, message: "Destination already exists")
            }
            try FileManager.default.createDirectory(
                at: source.physicalPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data((arguments["content"]?.stringValue ?? "").utf8).write(
                to: source.physicalPath,
                options: .atomic
            )
        case "delete":
            try FileManager.default.removeItem(at: source.physicalPath)
        case "move":
            guard let destinationRaw = arguments["new_path"]?.stringValue else {
                throw ServiceAPIError(code: .invalidRequest, message: "move requires new_path")
            }
            let destination = try await resolve(destinationRaw, allowMissingLeaf: true)
            guard destination.root.rootID == source.root.rootID else {
                throw ServiceAPIError(code: .rootUnauthorized, message: "Cross-root moves are unavailable")
            }
            try FileManager.default.moveItem(at: source.physicalPath, to: destination.physicalPath)
        default:
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported file action")
        }
        return .object(["action": .string(operation), "path": .string(source.logicalPath), "ok": .bool(true)])
    }

    private func applyEdits(_ arguments: [String: Value]) async throws -> Value {
        guard let rawPath = arguments["path"]?.stringValue else {
            throw ServiceAPIError(code: .invalidRequest, message: "apply_edits requires path")
        }
        let path = try await resolve(rawPath, allowMissingLeaf: arguments["rewrite"] != nil)
        guard path.root.writable else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Project root is read-only")
        }
        let existing = (try? String(contentsOf: path.physicalPath, encoding: .utf8)) ?? ""
        let updated: String
        if let rewrite = arguments["rewrite"]?.stringValue {
            updated = rewrite
        } else if let edits = arguments["edits"]?.arrayValue {
            updated = try edits.reduce(existing) { partial, raw in
                guard let object = raw.objectValue,
                      let search = object["search"]?.stringValue,
                      let replacement = object["replace"]?.stringValue
                else { throw ServiceAPIError(code: .invalidRequest, message: "Invalid edit entry") }
                return try replace(
                    in: partial,
                    search: search,
                    replacement: replacement,
                    all: object["all"]?.boolValue ?? false
                )
            }
        } else if let search = arguments["search"]?.stringValue,
                  let replacement = arguments["replace"]?.stringValue
        {
            updated = try replace(
                in: existing,
                search: search,
                replacement: replacement,
                all: arguments["all"]?.boolValue ?? false
            )
        } else {
            throw ServiceAPIError(code: .invalidRequest, message: "apply_edits requires one edit mode")
        }
        try FileManager.default.createDirectory(
            at: path.physicalPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(updated.utf8).write(to: path.physicalPath, options: .atomic)
        return .object([
            "path": .string(path.logicalPath),
            "changed": .bool(existing != updated),
            "bytes": .int(updated.utf8.count)
        ])
    }

    private func oracleUtilities(_ arguments: [String: Value]) async throws -> Value {
        let providers = await authority.providerCapabilities(preflight: true)
        let discovery = try await authority.modelDiscovery(sessionID: binding.sessionID)
        return try value(ProviderCatalogResult(
            operation: arguments["op"]?.stringValue ?? "models",
            providers: providers,
            rawModels: discovery.providers,
            presets: discovery.presets,
            roleModelRestrictionApplied: discovery.roleModelRestrictionApplied,
            settingsRevision: discovery.settingsRevision
        ))
    }

    private func askOracle(_ arguments: [String: Value], continuing: Bool) async throws -> Value {
        guard let message = arguments["message"]?.stringValue, !message.isEmpty else {
            throw ServiceAPIError(code: .invalidRequest, message: "Oracle requires message")
        }
        let chatID = arguments["chat_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        if continuing, chatID == nil {
            throw ServiceAPIError(code: .invalidRequest, message: "oracle_send requires chat_id")
        }
        return try await value(authority.askOracle(
            sessionID: binding.sessionID,
            input: OracleInput(
                chatID: chatID,
                prompt: message,
                contextMode: arguments["mode"]?.stringValue ?? "chat",
                modelPresetID: arguments["model_preset_id"]?.stringValue.flatMap(UUID.init(uuidString:))
            ),
            actor: binding.actor
        ))
    }

    private func oracleChatLog(_ arguments: [String: Value]) async throws -> Value {
        guard let chatID = arguments["chat_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
            throw ServiceAPIError(code: .invalidRequest, message: "oracle_chat_log requires chat_id")
        }
        let state = try await authority.oracleChatState(sessionID: binding.sessionID, chatID: chatID)
        let limit = min(max(arguments["limit"]?.intValue ?? 8, 1), 50)
        return try value(OracleLogResult(
            chatID: state.chatID,
            providerSessionID: state.providerSessionID,
            turns: Array(state.turns.suffix(limit)),
            revision: state.revision
        ))
    }

    private func contextBuilder(_ arguments: [String: Value]) async throws -> Value {
        guard let instructions = arguments["instructions"]?.stringValue, !instructions.isEmpty else {
            throw ServiceAPIError(code: .invalidRequest, message: "context_builder requires instructions")
        }
        let selection = try await authority.selectionSnapshot(sessionID: binding.sessionID)
        return try await value(authority.runContextBuilder(
            sessionID: binding.sessionID,
            input: ContextBuilderInput(
                expectedSelectionRevision: selection.revision,
                instructions: instructions,
                budget: arguments["budget"]?.intValue,
                responseType: arguments["response_type"]?.stringValue,
                allowClarifyingQuestions: arguments["allow_clarifying_questions"]?.boolValue,
                enhancementMode: arguments["enhancement_mode"]?.stringValue.flatMap(ContextBuilderEnhancementMode.init(rawValue:)),
                questionTimeoutSeconds: arguments["question_timeout_seconds"]?.intValue,
                followUpAnalysis: arguments["follow_up_analysis"]?.stringValue.flatMap(ContextBuilderFollowUpAnalysis.init(rawValue:)),
                followUpBudget: arguments["follow_up_budget"]?.intValue
            ),
            actor: binding.actor,
            origin: .mcp
        ))
    }

    private func askUser(_ arguments: [String: Value]) async throws -> Value {
        let payload = try JSONEncoder().encode(arguments)
        let timeout = arguments["timeout_seconds"]?.intValue ?? arguments["timeout"]?.intValue
        let answer = try await authority.askUserAndWait(
            sessionID: binding.sessionID,
            arguments: payload,
            timeoutSeconds: timeout
        )
        return try JSONDecoder().decode(Value.self, from: answer)
    }

    private func git(_ arguments: [String: Value]) async throws -> Value {
        let operation = arguments["op"]?.stringValue ?? "status"
        let project = try await project()
        let root = try await root(arguments["root_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let command: [String]
        switch operation {
        case "status": command = ["status", "--short", "--branch"]
        case "log": command = ["log", "--oneline", "-n", String(min(max(arguments["count"]?.intValue ?? 20, 1), 200))]
        case "show": command = ["show", "--stat", arguments["ref"]?.stringValue ?? "HEAD"]
        case "diff":
            let diff = try await authority.projectDiff(
                projectID: project.projectID,
                request: ProjectDiffRequest(
                    rootID: root.rootID,
                    comparison: arguments["compare"]?.stringValue ?? "HEAD",
                    logicalPaths: arguments["paths"]?.arrayValue?.compactMap(\.stringValue) ?? []
                )
            )
            return try value(diff)
        default:
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported Git operation")
        }
        return try await .object([
            "op": .string(operation),
            "output": .string(authority.projectGit(
                projectID: project.projectID,
                rootID: root.rootID,
                arguments: command
            ))
        ])
    }

    private func manageWorktree(_ arguments: [String: Value]) async throws -> Value {
        let operation = arguments["op"]?.stringValue ?? "list"
        let session = try await session()
        switch operation {
        case "list", "status":
            return try await value(authority.worktreeSnapshots(projectID: session.projectID))
        case "create":
            let root = try await root(arguments["root_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
            return try await value(authority.createWorktree(
                sessionID: binding.sessionID,
                rootID: root.rootID,
                baseRef: arguments["base_ref"]?.stringValue ?? "HEAD",
                branch: arguments["branch"]?.stringValue ?? "repoprompt/session-\(binding.sessionID.uuidString.lowercased().prefix(12))",
                actor: binding.actor
            ))
        case "bind":
            guard let bindingID = arguments["binding_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
                throw ServiceAPIError(code: .invalidRequest, message: "bind requires binding_id")
            }
            let worktree = try await authority.worktreeSnapshot(projectID: session.projectID, bindingID: bindingID)
            let selection = try await authority.selectionSnapshot(sessionID: binding.sessionID)
            return try await value(authority.bindWorktree(
                sessionID: binding.sessionID,
                bindingID: bindingID,
                expectedRevision: arguments["expected_revision"]?.intValue.map(Int64.init) ?? worktree.revision,
                expectedSelectionBindingRevision: selection.bindingRevision,
                actor: binding.actor
            ))
        case "merge":
            guard let bindingID = arguments["binding_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
                throw ServiceAPIError(code: .invalidRequest, message: "merge requires binding_id")
            }
            let worktree = try await authority.worktreeSnapshot(projectID: session.projectID, bindingID: bindingID)
            return try await value(authority.mergeWorktree(
                sessionID: binding.sessionID,
                bindingID: bindingID,
                strategy: arguments["strategy"]?.stringValue ?? "merge",
                expectedRevision: arguments["expected_revision"]?.intValue.map(Int64.init) ?? worktree.revision,
                actor: binding.actor
            ))
        case "abort":
            guard let bindingID = arguments["binding_id"]?.stringValue.flatMap(UUID.init(uuidString:)),
                  let leaseID = arguments["lease_id"]?.stringValue.flatMap(UUID.init(uuidString:))
            else {
                throw ServiceAPIError(code: .invalidRequest, message: "abort requires binding_id and lease_id")
            }
            let worktree = try await authority.worktreeSnapshot(projectID: session.projectID, bindingID: bindingID)
            return try await value(authority.abortConflictedMerge(
                sessionID: binding.sessionID,
                bindingID: bindingID,
                leaseID: leaseID,
                expectedRevision: arguments["expected_revision"]?.intValue.map(Int64.init) ?? worktree.revision,
                actor: binding.actor
            ))
        default:
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported worktree operation")
        }
    }

    private func agentLifecycle(_ arguments: [String: Value], defaultRole: String) async throws -> Value {
        let operation = arguments["op"]?.stringValue ?? "start"
        switch operation {
        case "start":
            guard let message = arguments["message"]?.stringValue, !message.isEmpty else {
                throw ServiceAPIError(code: .invalidRequest, message: "Agent start requires message")
            }
            let provider = arguments["provider"]?.stringValue.flatMap(ProviderKind.init(rawValue:))
            let providerSettingsID = arguments["provider_settings_id"]?.stringValue.flatMap(ProviderSettingsID.init(rawValue:))
            let child = try await authority.spawnChildSession(
                parentSessionID: binding.sessionID,
                provider: provider,
                providerSettingsID: providerSettingsID,
                model: arguments["model"]?.stringValue,
                initialPrompt: message,
                role: arguments["model_id"]?.stringValue ?? defaultRole,
                label: arguments["session_name"]?.stringValue
            )
            _ = try await authority.startChildAgentRun(sessionID: child.sessionID)
            return try await value(authority.sessionSnapshot(sessionID: child.sessionID))
        case "poll":
            return try await value(authority.sessionSnapshot(sessionID: agentSessionID(arguments)))
        case "wait":
            return try await value(waitForTerminal(
                sessionID: agentSessionID(arguments),
                timeout: arguments["timeout"]?.doubleValue ?? 120
            ))
        case "cancel":
            let sessionID = try agentSessionID(arguments)
            _ = try await authority.cancelChildAgentRun(sessionID: sessionID)
            return try await value(authority.sessionSnapshot(sessionID: sessionID))
        default:
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported agent operation")
        }
    }

    private func agentManage(_ arguments: [String: Value]) async throws -> Value {
        let operation = arguments["op"]?.stringValue ?? "list_agents"
        switch operation {
        case "list_agents", "list", "list_sessions":
            let root = try await session().rootSessionID
            return try await value(authority.agentSnapshots(rootSessionID: root))
        case "cancel":
            let sessionID = try agentSessionID(arguments)
            _ = try await authority.cancelChildAgentRun(sessionID: sessionID)
            return try await value(authority.sessionSnapshot(sessionID: sessionID))
        default:
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported agent_manage operation")
        }
    }

    private func history(_ arguments: [String: Value]) async throws -> Value {
        let operation = arguments["op"]?.stringValue ?? "list_sessions"
        let all = try await authority.sessionSnapshots()
        let limit = min(max(arguments["limit"]?.intValue ?? 30, 1), 100)
        switch operation {
        case "list_sessions": return try value(Array(all.suffix(limit)))
        case "get_session": return try await value(authority.sessionSnapshot(sessionID: agentSessionID(arguments)))
        case "search":
            let query = arguments["query"]?.stringValue?.lowercased() ?? ""
            return try value(Array(all.filter {
                $0.sessionID.uuidString.lowercased().contains(query)
                    || $0.transcript.contains { $0.content.lowercased().contains(query) }
            }.prefix(limit)))
        case "time":
            let threshold = try await authority.historyIdleThresholdMinutes(explicit: arguments["idle_threshold_minutes"]?.intValue)
            let maximumGap = TimeInterval(threshold * 60)
            let activeSeconds = all.reduce(0.0) { total, session in
                let timestamps = session.transcript.map(\.timestamp).sorted()
                let duration = zip(timestamps, timestamps.dropFirst()).reduce(0.0) { subtotal, pair in
                    subtotal + min(maximumGap, max(0, pair.1.timeIntervalSince(pair.0)))
                }
                return total + duration
            }
            return .object([
                "session_count": .int(all.count),
                "group_by": arguments["group_by"] ?? .string("session"),
                "idle_threshold_minutes": .int(threshold),
                "active_seconds": .double(activeSeconds)
            ])
        default:
            throw ServiceAPIError(code: .invalidRequest, message: "Unsupported history operation")
        }
    }

    private func shareThoughts(_ arguments: [String: Value]) async throws -> Value {
        guard let text = arguments["text"]?.stringValue ?? arguments["thoughts"]?.stringValue else {
            throw ServiceAPIError(code: .invalidRequest, message: "share_thoughts requires text")
        }
        let target = arguments["session_id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? binding.sessionID
        let current = try await authority.sessionSnapshot(sessionID: target)
        let snapshot = try await authority.publishProgress(sessionID: target, text: text, actor: binding.actor, expectedRevision: current.revision)
        return .object([
            "session_id": .string(snapshot.sessionID.uuidString),
            "accepted": .bool(true),
            "content_digest": .string(CanonicalSigning.bodyDigest(Data(text.utf8)))
        ])
    }

    private func setStatus(_ arguments: [String: Value]) async throws -> Value {
        let snapshot = try await authority.sessionSnapshot(sessionID: binding.sessionID)
        guard let current = try await authority.agentSnapshots(rootSessionID: snapshot.rootSessionID).first(where: { $0.sessionID == binding.sessionID }) else {
            throw ServiceAPIError(code: .notFound, message: "Agent not found")
        }
        let updated = try await authority.updateAgentLabel(sessionID: binding.sessionID, label: arguments["session_name"]?.stringValue, actor: binding.actor, expectedRevision: current.revision)
        return .object([
            "session_id": .string(snapshot.sessionID.uuidString),
            "session_name": updated.label.map(Value.string) ?? .null,
            "state": .string(snapshot.state.rawValue)
        ])
    }

    private func waitForInstruction(_ arguments: [String: Value]) async throws -> Value {
        let timeoutValue = arguments["timeout_seconds"] ?? arguments["timeout"]
        let timeout = min(max(timeoutValue?.doubleValue ?? timeoutValue?.intValue.map(Double.init) ?? 120, 0), 3600)
        let current = try await authority.sessionSnapshot(sessionID: binding.sessionID)
        let baseline = arguments["after_sequence"]?.intValue.map(Int64.init) ?? current.transcript.last?.sessionSequence ?? 0
        let deadline = ContinuousClock().now.advanced(by: .seconds(timeout))
        while ContinuousClock().now < deadline {
            let snapshot = try await authority.sessionSnapshot(sessionID: binding.sessionID)
            if let instruction = snapshot.transcript.first(where: { $0.kind == .human && $0.sessionSequence > baseline }) {
                return try value(instruction)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return .object(["timed_out": .bool(true)])
    }

    private func session() async throws -> SessionSnapshot {
        try await authority.sessionSnapshot(sessionID: binding.sessionID)
    }

    private func project() async throws -> ProjectSnapshot {
        let session = try await session()
        return try await authority.projectSnapshot(projectID: session.projectID)
    }

    private func root(_ requested: UUID?) async throws -> ProjectRootSnapshot {
        let project = try await project()
        if let requested, let root = project.roots.first(where: { $0.rootID == requested }) { return root }
        guard project.roots.count == 1, let root = project.roots.first else {
            throw ServiceAPIError(code: .invalidRequest, message: "root_id is required for a multi-root project")
        }
        return root
    }

    private func resolve(_ rawPath: String, allowMissingLeaf: Bool) async throws -> BoundPath {
        let project = try await project()
        let worktrees = try await authority.worktreeSnapshots(projectID: project.projectID)
        let bindings = Dictionary(uniqueKeysWithValues: worktrees.filter { $0.sessionID == binding.sessionID }.map {
            ($0.rootID, URL(fileURLWithPath: $0.physicalPath).standardizedFileURL.resolvingSymlinksInPath())
        })
        var candidates: [BoundPath] = []
        for root in project.roots {
            let physicalRoot = bindings[root.rootID]
                ?? URL(fileURLWithPath: root.canonicalPath).standardizedFileURL.resolvingSymlinksInPath()
            let candidate: URL
            let logicalPath: String
            if rawPath.hasPrefix("/") {
                let absolute = URL(fileURLWithPath: rawPath).standardizedFileURL
                guard absolute.path == physicalRoot.path || absolute.path.hasPrefix(physicalRoot.path + "/") else { continue }
                candidate = absolute
                logicalPath = String(absolute.path.dropFirst(physicalRoot.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            } else {
                candidate = physicalRoot.appendingPathComponent(rawPath).standardizedFileURL
                logicalPath = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            let checked = allowMissingLeaf
                ? candidate.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(candidate.lastPathComponent)
                : candidate.resolvingSymlinksInPath()
            guard checked.path == physicalRoot.path || checked.path.hasPrefix(physicalRoot.path + "/") else { continue }
            if rawPath.hasPrefix("/") || FileManager.default.fileExists(atPath: checked.path) || allowMissingLeaf {
                candidates.append(BoundPath(root: root, physicalRoot: physicalRoot, logicalPath: logicalPath, physicalPath: checked))
            }
        }
        guard candidates.count == 1, let result = candidates.first else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Path is missing, ambiguous, or outside the bound roots")
        }
        return result
    }

    private func selectionEntries(paths: [String], mode: LogicalSelectionEntry.Mode) async throws -> [LogicalSelectionEntry] {
        var entries: [LogicalSelectionEntry] = []
        for rawPath in paths {
            let path = try await resolve(rawPath, allowMissingLeaf: false)
            entries.append(LogicalSelectionEntry(
                rootID: path.root.rootID,
                logicalPath: path.logicalPath,
                mode: mode
            ))
        }
        return entries
    }

    private func physicalPath(for entry: LogicalSelectionEntry) async throws -> String {
        let project = try await project()
        guard let root = project.roots.first(where: { $0.rootID == entry.rootID }) else {
            throw ServiceAPIError(code: .rootUnauthorized, message: "Selected root is unavailable")
        }
        return URL(fileURLWithPath: root.canonicalPath).appendingPathComponent(entry.logicalPath).path
    }

    private func agentSessionID(_ arguments: [String: Value]) throws -> UUID {
        guard let raw = arguments["session_id"]?.stringValue,
              let sessionID = UUID(uuidString: raw)
        else { throw ServiceAPIError(code: .invalidRequest, message: "session_id must be a UUID") }
        return sessionID
    }

    private func waitForTerminal(sessionID: UUID, timeout: Double) async throws -> SessionSnapshot {
        let deadline = ContinuousClock().now.advanced(by: .seconds(min(max(timeout, 0), 3600)))
        while true {
            let snapshot = try await authority.sessionSnapshot(sessionID: sessionID)
            if [.completed, .failed, .canceled, .interrupted, .archived].contains(snapshot.state) { return snapshot }
            if ContinuousClock().now >= deadline { return snapshot }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func replace(in text: String, search: String, replacement: String, all: Bool) throws -> String {
        guard !search.isEmpty else { throw ServiceAPIError(code: .invalidRequest, message: "Edit search must not be empty") }
        guard let range = text.range(of: search) else {
            throw ServiceAPIError(code: .staleRevision, message: "Edit search text was not found")
        }
        if all { return text.replacingOccurrences(of: search, with: replacement) }
        return text.replacingCharacters(in: range, with: replacement)
    }

    private func value(_ encodable: some Encodable) throws -> Value {
        let data = try JSONEncoder.serviceEncoder.encode(encodable)
        return try JSONDecoder().decode(Value.self, from: data)
    }
}

private struct SettingsResult: Encodable {
    let operation: String
    let capabilities: ServiceCapabilities
    let providers: [ProviderCapability]
}

private struct WorkspaceResult: Encodable {
    let operation: String
    let projects: [ProjectSnapshot]
    let sessions: [SessionSnapshot]
}

private struct CodeStructureResult: Encodable {
    let files: [ProjectCodeMapSnapshot]
    let updatesPending: Bool

    enum CodingKeys: String, CodingKey {
        case files
        case updatesPending = "updates_pending"
    }
}

private struct ProviderCatalogResult: Encodable {
    let operation: String
    let providers: [ProviderCapability]
    let rawModels: [ProviderSettingsSnapshot]
    let presets: [MCPModelPreset]
    let roleModelRestrictionApplied: Bool
    let settingsRevision: Int64

    enum CodingKeys: String, CodingKey {
        case operation, providers, presets
        case rawModels = "raw_models"
        case roleModelRestrictionApplied = "role_model_restriction_applied"
        case settingsRevision = "settings_revision"
    }
}

private struct OracleLogResult: Encodable {
    let chatID: UUID
    let providerSessionID: String?
    let turns: [OracleChatTurn]
    let revision: Int64
}
