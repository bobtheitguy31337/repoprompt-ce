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

public protocol AgentProviderDispatcher: Sendable {
    func capabilities() async -> [ProviderCapability]
    func start(session: SessionSnapshot, binding: RunBindingIdentity, workingDirectory: String) async throws
    func steer(runID: UUID, text: String, turnEpoch: Int64) async throws
    func cancel(runID: UUID, generation: Int64) async throws
}

public protocol InteractionDeliveryPort: Sendable {
    func deliverAnswer(session: SessionSnapshot, interaction: InteractionSnapshot, answer: Data) async throws
}
