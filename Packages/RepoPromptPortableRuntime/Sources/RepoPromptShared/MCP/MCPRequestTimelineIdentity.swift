import Foundation

/// Correlation identity shared by the app, transport, bridge ledger, and CLI proxy.
///
/// Individual layers may initially know only part of the identity. Later layers preserve
/// the known fields and fill the remaining values without changing the JSON-RPC payload.
public struct MCPRequestTimelineIdentity: Equatable, Sendable {
    public let jsonRPCRequestID: JSONRPCBridgeID?
    public let connectionID: String?
    public let connectionGeneration: UInt64?
    public let appInvocationID: String?
    public let requestOrdinal: UInt64?

    public init(
        jsonRPCRequestID: JSONRPCBridgeID? = nil,
        connectionID: String? = nil,
        connectionGeneration: UInt64? = nil,
        appInvocationID: String? = nil,
        requestOrdinal: UInt64? = nil
    ) {
        self.jsonRPCRequestID = jsonRPCRequestID
        self.connectionID = connectionID
        self.connectionGeneration = connectionGeneration
        // Durable identity is minted by the application host. JSON-RPC ids are
        // client-controlled correlation values and must never become replay keys.
        self.appInvocationID = appInvocationID
        self.requestOrdinal = requestOrdinal
    }

    public func fillingMissingFields(from fallback: MCPRequestTimelineIdentity?) -> MCPRequestTimelineIdentity {
        MCPRequestTimelineIdentity(
            jsonRPCRequestID: jsonRPCRequestID ?? fallback?.jsonRPCRequestID,
            connectionID: connectionID ?? fallback?.connectionID,
            connectionGeneration: connectionGeneration ?? fallback?.connectionGeneration,
            appInvocationID: appInvocationID ?? fallback?.appInvocationID,
            requestOrdinal: requestOrdinal ?? fallback?.requestOrdinal
        )
    }
}

public enum MCPRequestTimelineContext {
    @TaskLocal public static var current: MCPRequestTimelineIdentity?
}
