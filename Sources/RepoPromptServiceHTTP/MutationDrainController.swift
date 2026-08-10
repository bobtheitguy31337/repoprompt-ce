import Foundation
import RepoPromptServiceProtocol

public struct MutationDrainSnapshot: Codable, Hashable, Sendable {
    public let acceptingMutations: Bool
    public let inFlightMutations: Int
    public let drainStartedAt: Date?
    public let drainTimedOut: Bool

    public init(
        acceptingMutations: Bool,
        inFlightMutations: Int,
        drainStartedAt: Date?,
        drainTimedOut: Bool
    ) {
        self.acceptingMutations = acceptingMutations
        self.inFlightMutations = inFlightMutations
        self.drainStartedAt = drainStartedAt
        self.drainTimedOut = drainTimedOut
    }
}

public actor MutationDrainController {
    private var acceptingMutations = true
    private var inFlightMutations = 0
    private var drainStartedAt: Date?
    private var drainTimedOut = false

    public init() {}

    public func snapshot() -> MutationDrainSnapshot {
        MutationDrainSnapshot(
            acceptingMutations: acceptingMutations,
            inFlightMutations: inFlightMutations,
            drainStartedAt: drainStartedAt,
            drainTimedOut: drainTimedOut
        )
    }

    public func startDrain(now: Date = Date()) {
        guard acceptingMutations else { return }
        acceptingMutations = false
        drainStartedAt = now
    }

    public func beginMutation() -> Bool {
        guard acceptingMutations else { return false }
        inFlightMutations += 1
        return true
    }

    public func finishMutation() {
        precondition(inFlightMutations > 0, "Mutation admission accounting underflow")
        inFlightMutations -= 1
    }

    @discardableResult
    public func drain(timeout: TimeInterval = 15) async -> MutationDrainSnapshot {
        startDrain()
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while inFlightMutations > 0, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        drainTimedOut = inFlightMutations > 0
        return snapshot()
    }
}
