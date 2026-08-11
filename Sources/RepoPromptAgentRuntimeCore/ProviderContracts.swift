import Foundation
import RepoPromptServiceProtocol

public struct ProviderCapability: Codable, Hashable, Sendable {
    public let kind: ProviderKind
    public let enabled: Bool
    public let executable: String?
    public let supportsResume: Bool
    public let supportsSteering: Bool
    public let version: String?
    public let protocolVersion: String?
    public let reasonUnavailable: String?

    public init(kind: ProviderKind, enabled: Bool, executable: String?, supportsResume: Bool, supportsSteering: Bool, version: String? = nil, protocolVersion: String? = nil, reasonUnavailable: String? = nil) {
        self.kind = kind
        self.enabled = enabled
        self.executable = executable
        self.supportsResume = supportsResume
        self.supportsSteering = supportsSteering
        self.version = version
        self.protocolVersion = protocolVersion
        self.reasonUnavailable = reasonUnavailable
    }
}

public struct ProviderExecutionResult: Sendable {
    public let output: String
    public let providerSessionID: String?

    public init(output: String, providerSessionID: String?) {
        self.output = output
        self.providerSessionID = providerSessionID
    }
}

public enum ProviderInteractionKind: String, Codable, Hashable, Sendable {
    case question
    case approval
}

public struct ProviderInteractionPayload: Codable, Hashable, Sendable {
    public let providerRequestID: String
    public let prompt: String
    public let choices: [String]

    public init(providerRequestID: String, prompt: String, choices: [String]) {
        self.providerRequestID = providerRequestID
        self.prompt = prompt
        self.choices = choices
    }
}

/// Normalized, provider-neutral stream emitted by native provider controllers.
/// Native frame identifiers are retained only as opaque delivery tokens; the
/// authority owns durable interaction IDs, transcript revisions, and events.
public enum ProviderRuntimeEvent: Sendable, Equatable {
    case providerIdentity(String)
    case assistantDelta(String)
    case assistantFinal(String)
    case reasoning(String)
    case progress(String)
    case toolStarted(providerToolID: String, name: String, arguments: Data?)
    case toolUpdated(providerToolID: String, output: String)
    case toolCompleted(providerToolID: String, name: String, output: String?, failed: Bool)
    case interactionRequested(providerRequestID: String, kind: ProviderInteractionKind, prompt: String, choices: [String])
    case interactionCancelled(providerRequestID: String)
    case completed(providerSessionID: String?)
}

public enum ProviderExecutionMode: String, Codable, Hashable, Sendable {
    case readOnly
    case workspaceWrite
    case fullAccess
}

public struct ProviderExecutionPolicy: Codable, Hashable, Sendable {
    public let mode: ProviderExecutionMode
    public let writableRoots: [String]
    public let providerSettings: [String: String]

    public init(mode: ProviderExecutionMode = .workspaceWrite, writableRoots: [String] = [], providerSettings: [String: String] = [:]) {
        self.mode = mode
        self.writableRoots = writableRoots
        self.providerSettings = providerSettings
    }
}

public struct ProviderExecutionRequest: Sendable {
    public let kind: ProviderKind
    public let model: String?
    public let prompt: String
    public let workingDirectory: String
    public let maximumBytes: Int
    public let runID: UUID
    public let resumeProviderSessionID: String?
    public let policy: ProviderExecutionPolicy
    private let launchValidation: @Sendable () throws -> Void

    public init(kind: ProviderKind, model: String?, prompt: String, workingDirectory: String, maximumBytes: Int = 8_388_608, runID: UUID, resumeProviderSessionID: String? = nil, policy: ProviderExecutionPolicy = .init(), launchValidation: @escaping @Sendable () throws -> Void = {}) {
        self.kind = kind
        self.model = model
        self.prompt = prompt
        self.workingDirectory = workingDirectory
        self.maximumBytes = maximumBytes
        self.runID = runID
        self.resumeProviderSessionID = resumeProviderSessionID
        self.policy = policy
        self.launchValidation = launchValidation
    }

    public func validateLaunch() throws {
        try launchValidation()
    }
}

/// Portable authority-to-provider seam. Implementations own native provider
/// transport, streaming controls, approval delivery, and process cleanup; the
/// caller remains the owner of session lifecycle and durable publication.
public protocol AgentProviderDispatcher: Sendable {
    func capabilities() async -> [ProviderCapability]
    func preflight() async -> [ProviderCapability]
    func recoverProcessFamilies() async throws
    func execute(
        kind: ProviderKind,
        model: String?,
        prompt: String,
        workingDirectory: String,
        maximumBytes: Int,
        runID: UUID?,
        resumeProviderSessionID: String?,
        onProviderSessionIdentity: @escaping @Sendable (String) async -> Void
    ) async throws -> ProviderExecutionResult
    func cancel(runID: UUID) async throws
    func executeStreaming(
        _ request: ProviderExecutionRequest,
        onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void
    ) async throws -> ProviderExecutionResult
    func steer(runID: UUID, text: String, targetTurnEpoch: Int64) async throws
    func deliverInteraction(runID: UUID, providerRequestID: String, answer: Data) async throws
    func prepareRun(kind: ProviderKind, runID: UUID) async
    func forgetRun(runID: UUID) async
}

public extension AgentProviderDispatcher {
    func prepareRun(kind _: ProviderKind, runID _: UUID) async {}
    func forgetRun(runID _: UUID) async {}
    func complete(kind: ProviderKind, model: String?, prompt: String, workingDirectory: String, maximumBytes: Int = 8_388_608, runID: UUID? = nil) async throws -> String {
        try await execute(kind: kind, model: model, prompt: prompt, workingDirectory: workingDirectory, maximumBytes: maximumBytes, runID: runID).output
    }

    func execute(
        kind: ProviderKind,
        model: String?,
        prompt: String,
        workingDirectory: String,
        maximumBytes: Int = 8_388_608,
        runID: UUID? = nil,
        resumeProviderSessionID: String? = nil
    ) async throws -> ProviderExecutionResult {
        try await execute(kind: kind, model: model, prompt: prompt, workingDirectory: workingDirectory, maximumBytes: maximumBytes, runID: runID, resumeProviderSessionID: resumeProviderSessionID) { _ in }
    }

    func executeStreaming(
        _ request: ProviderExecutionRequest,
        onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void
    ) async throws -> ProviderExecutionResult {
        try request.validateLaunch()
        let result = try await execute(
            kind: request.kind,
            model: request.model,
            prompt: request.prompt,
            workingDirectory: request.workingDirectory,
            maximumBytes: request.maximumBytes,
            runID: request.runID,
            resumeProviderSessionID: request.resumeProviderSessionID
        ) { identity in
            await onEvent(.providerIdentity(identity))
        }
        await onEvent(.assistantFinal(result.output))
        await onEvent(.completed(providerSessionID: result.providerSessionID))
        return result
    }

    func steer(runID _: UUID, text _: String, targetTurnEpoch _: Int64) async throws {
        throw ServiceAPIError(code: .capabilityMissing, message: "Provider-native steering is unavailable")
    }

    func deliverInteraction(runID _: UUID, providerRequestID _: String, answer _: Data) async throws {
        throw ServiceAPIError(code: .capabilityMissing, message: "Provider interaction delivery is unavailable")
    }
}

/// One native provider transport. A dispatcher selects a runtime; the runtime
/// owns protocol sessions and delivery while the authority owns durable state.
public protocol AgentProviderRuntime: Sendable {
    var kind: ProviderKind { get }
    func capability() async -> ProviderCapability
    func preflight() async -> ProviderCapability
    func recoverProcessFamilies() async throws
    func execute(
        _ request: ProviderExecutionRequest,
        onEvent: @escaping @Sendable (ProviderRuntimeEvent) async -> Void
    ) async throws -> ProviderExecutionResult
    func steer(runID: UUID, text: String, targetTurnEpoch: Int64) async throws
    func interrupt(runID: UUID) async throws
    func deliverInteraction(runID: UUID, providerRequestID: String, answer: Data) async throws
    func hasActiveRun(_ runID: UUID) async -> Bool
}

public extension AgentProviderRuntime {
    func recoverProcessFamilies() async throws {}
    func steer(runID _: UUID, text _: String, targetTurnEpoch _: Int64) async throws {
        throw ServiceAPIError(code: .capabilityMissing, message: "Provider-native steering is unavailable")
    }

    func deliverInteraction(runID _: UUID, providerRequestID _: String, answer _: Data) async throws {
        throw ServiceAPIError(code: .capabilityMissing, message: "Provider interaction delivery is unavailable")
    }

    func hasActiveRun(_: UUID) async -> Bool {
        false
    }
}

public protocol InteractionDeliveryPort: Sendable {
    func deliverAnswer(session: SessionSnapshot, interaction: InteractionSnapshot, answer: Data) async throws
}
