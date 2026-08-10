import Foundation
import RepoPromptAgentRuntimeCore
import RepoPromptServiceProtocol

public actor ProviderRegistry {
    private let configuredExecutables: [ProviderKind: String]
    public init(configuredExecutables: [ProviderKind: String]) {
        self.configuredExecutables = configuredExecutables
    }

    public func capabilities() -> [ProviderCapability] {
        ProviderKind.allCases.map { kind in
            guard let path = configuredExecutables[kind] else { return ProviderCapability(kind: kind, enabled: false, executable: nil, supportsResume: false, supportsSteering: false, reasonUnavailable: "not configured") }
            let executable = FileManager.default.isExecutableFile(atPath: path)
            return ProviderCapability(kind: kind, enabled: executable, executable: executable ? path : nil, supportsResume: kind == .codex || kind == .claudeCompatible, supportsSteering: kind != .mcp, reasonUnavailable: executable ? nil : "configured binary is not executable")
        }
    }
}

public enum ProcStatParser {
    public struct Stat: Equatable, Sendable { public let pid: Int32
        public let parentPID: Int32
        public let processGroupID: Int32
        public let sessionID: Int32
        public let startTimeTicks: UInt64
    }

    public static func parse(_ line: String) -> Stat? {
        guard let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")"), open < close else { return nil }
        let pidText = line[..<open].trimmingCharacters(in: .whitespaces)
        let suffix = line[line.index(after: close)...].split(separator: " ")
        guard let pid = Int32(pidText), suffix.count > 19, let parent = Int32(suffix[1]), let group = Int32(suffix[2]), let session = Int32(suffix[3]), let start = UInt64(suffix[19]) else { return nil }
        return Stat(pid: pid, parentPID: parent, processGroupID: group, sessionID: session, startTimeTicks: start)
    }
}

public actor ProviderProcessSupervisor {
    private let processPort: any ProcessSupervisionPort
    private let clock: any RuntimeClock
    private var families: [UUID: [ProcessIdentity]] = [:]
    public init(processPort: any ProcessSupervisionPort, clock: any RuntimeClock = SystemRuntimeClock()) {
        self.processPort = processPort
        self.clock = clock
    }

    public func register(runID: UUID, leader: ProcessIdentity) {
        families[runID] = [leader]
    }

    public func cancel(runID: UUID, termSignal: Int32 = 15, killSignal: Int32 = 9) async throws {
        guard let recorded = families[runID], let leader = recorded.first else { return }
        guard let current = try await processPort.inspect(pid: leader.pid), current == leader else { families[runID] = nil
            return
        }
        let descendants = try await processPort.descendants(of: leader.pid).filter { observed in recorded.contains(observed) || observed.bootID == leader.bootID }
        try await processPort.signal(termSignal, processGroupID: leader.processGroupID, verifiedMembers: [leader] + descendants)
        try await clock.sleep(for: .seconds(10))
        var survivors: [ProcessIdentity] = []
        for member in [leader] + descendants where try await processPort.inspect(pid: member.pid) == member {
            survivors.append(member)
        }
        if !survivors.isEmpty { try await processPort.signal(killSignal, processGroupID: leader.processGroupID, verifiedMembers: survivors) }
        for member in survivors {
            try await processPort.reap(pid: member.pid)
        }
        families[runID] = nil
    }
}
