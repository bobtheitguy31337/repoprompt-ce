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
}

public extension AgentProviderDispatcher {
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
}

public protocol InteractionDeliveryPort: Sendable {
    func deliverAnswer(session: SessionSnapshot, interaction: InteractionSnapshot, answer: Data) async throws
}
