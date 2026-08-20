import Foundation
import RepoPromptRuntimeModel
import SQLiteNIO

public enum SQLiteOperationClass: String, CaseIterable, Sendable {
    case control
    case interactive
    case bulk
}

public struct SQLiteDatabaseExecutorMetrics: Sendable, Equatable {
    public let capacity: Int
    public let reservedControlCapacity: Int
    public let queuedByClass: [SQLiteOperationClass: Int]
    public let saturationCount: Int
    public let completedByClass: [SQLiteOperationClass: Int]
    public let totalWaitNanosecondsByClass: [SQLiteOperationClass: UInt64]
    public let totalExecuteNanosecondsByClass: [SQLiteOperationClass: UInt64]
}

enum SQLiteExecutionContext {
    @TaskLocal static var transactionID: UUID?
}

/// The sole owner of a SQLite connection.
///
/// All statements are admitted to one bounded scheduler and executed by one
/// worker. Transaction-affine statements are the only work eligible between
/// BEGIN and COMMIT/ROLLBACK, so actor reentrancy cannot expose a partially
/// applied transaction to unrelated reads.
public actor SQLiteDatabaseExecutor {
    public static let defaultCapacity = 256
    public static let defaultReservedControlCapacity = 32
    public static let maximumBulkRows = 256
    public static let maximumBulkEncodedBytes = 1_048_576

    private enum Work: Sendable {
        case query(String, [SQLiteData])
        case begin
        case commit
        case rollback
    }

    private struct Job {
        let id: UUID
        let sequence: UInt64
        let operationClass: SQLiteOperationClass
        let transactionID: UUID?
        let work: Work
        let enqueuedAtNanoseconds: UInt64
        let continuation: CheckedContinuation<[SQLiteRow], Error>
    }

    private struct AdmissionWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let connection: SQLiteConnection
    private let capacity: Int
    private let reservedControlCapacity: Int
    private var queues: [SQLiteOperationClass: [Job]] = [
        .control: [],
        .interactive: [],
        .bulk: [],
    ]
    private var admissionWaiters: [AdmissionWaiter] = []
    private var activeTransactionID: UUID?
    private var nextSequence: UInt64 = 1
    private var workerRunning = false
    private var closed = false
    private var saturationCount = 0
    private var completedByClass: [SQLiteOperationClass: Int] = [
        .control: 0,
        .interactive: 0,
        .bulk: 0,
    ]
    private var totalWaitNanosecondsByClass: [SQLiteOperationClass: UInt64] = [
        .control: 0,
        .interactive: 0,
        .bulk: 0,
    ]
    private var totalExecuteNanosecondsByClass: [SQLiteOperationClass: UInt64] = [
        .control: 0,
        .interactive: 0,
        .bulk: 0,
    ]
    private var bypasses: [SQLiteOperationClass: Int] = [
        .control: 0,
        .interactive: 0,
        .bulk: 0,
    ]
    private let weightedCycle: [SQLiteOperationClass] = [
        .control, .control, .control, .control,
        .interactive, .interactive,
        .bulk,
    ]
    private var cycleIndex = 0
    private var testCompletionObserver: (@Sendable (SQLiteOperationClass) -> Void)?

    private init(
        connection: SQLiteConnection,
        capacity: Int,
        reservedControlCapacity: Int
    ) {
        self.connection = connection
        self.capacity = capacity
        self.reservedControlCapacity = reservedControlCapacity
    }

    public static func open(
        storage: SQLiteConnection.Storage,
        capacity: Int = defaultCapacity,
        reservedControlCapacity: Int = defaultReservedControlCapacity
    ) async throws -> SQLiteDatabaseExecutor {
        guard capacity > 0,
              reservedControlCapacity >= 16,
              reservedControlCapacity < capacity
        else {
            throw ServiceAPIError(
                code: .invalidRequest,
                message: "Invalid SQLite executor capacity configuration"
            )
        }
        let connection = try await SQLiteConnection.open(storage: storage)
        return SQLiteDatabaseExecutor(
            connection: connection,
            capacity: capacity,
            reservedControlCapacity: reservedControlCapacity
        )
    }

    public func query(
        _ sql: String,
        _ bindings: [SQLiteData] = [],
        operationClass: SQLiteOperationClass = .interactive
    ) async throws -> [SQLiteRow] {
        try await submit(
            .query(sql, bindings),
            operationClass: operationClass,
            transactionID: SQLiteExecutionContext.transactionID
        )
    }

    func beginTransaction(_ transactionID: UUID) async throws {
        _ = try await submit(.begin, operationClass: .control, transactionID: transactionID)
    }

    func commitTransaction(_ transactionID: UUID) async throws {
        _ = try await submit(.commit, operationClass: .control, transactionID: transactionID)
    }

    func rollbackTransaction(_ transactionID: UUID) async {
        _ = try? await submitUncancelled(
            .rollback,
            operationClass: .control,
            transactionID: transactionID
        )
    }

    public func metrics() -> SQLiteDatabaseExecutorMetrics {
        SQLiteDatabaseExecutorMetrics(
            capacity: capacity,
            reservedControlCapacity: reservedControlCapacity,
            queuedByClass: Dictionary(uniqueKeysWithValues: SQLiteOperationClass.allCases.map {
                ($0, queues[$0, default: []].count)
            }),
            saturationCount: saturationCount,
            completedByClass: completedByClass,
            totalWaitNanosecondsByClass: totalWaitNanosecondsByClass,
            totalExecuteNanosecondsByClass: totalExecuteNanosecondsByClass
        )
    }

    func installTestCompletionObserver(
        _ observer: @escaping @Sendable (SQLiteOperationClass) -> Void
    ) {
        testCompletionObserver = observer
    }

    public func close() async throws {
        guard !closed else { return }
        guard activeTransactionID == nil, queuedCount == 0 else {
            throw ServiceAPIError(
                code: .persistenceUnavailable,
                message: "Cannot close SQLite while work is active",
                retryable: true
            )
        }
        closed = true
        try await connection.close()
    }

    private var queuedCount: Int {
        queues.values.reduce(0) { $0 + $1.count }
    }

    private var nonControlQueuedCount: Int {
        queues[.interactive, default: []].count + queues[.bulk, default: []].count
    }

    private func hasAdmissionCapacity(for operationClass: SQLiteOperationClass) -> Bool {
        guard queuedCount < capacity else { return false }
        if operationClass == .control { return true }
        return nonControlQueuedCount < capacity - reservedControlCapacity
    }

    private func waitForAdmission(
        _ operationClass: SQLiteOperationClass,
        jobID: UUID
    ) async throws {
        while !hasAdmissionCapacity(for: operationClass) {
            saturationCount += 1
            try await withCheckedThrowingContinuation { continuation in
                admissionWaiters.append(.init(id: jobID, continuation: continuation))
            }
        }
    }

    private func submit(
        _ work: Work,
        operationClass: SQLiteOperationClass,
        transactionID: UUID?
    ) async throws -> [SQLiteRow] {
        let jobID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await enqueue(
                work,
                operationClass: operationClass,
                transactionID: transactionID,
                jobID: jobID
            )
        } onCancel: {
            Task { await self.cancel(jobID: jobID) }
        }
    }

    private func submitUncancelled(
        _ work: Work,
        operationClass: SQLiteOperationClass,
        transactionID: UUID?
    ) async throws -> [SQLiteRow] {
        try await enqueue(
            work,
            operationClass: operationClass,
            transactionID: transactionID,
            jobID: UUID()
        )
    }

    private func enqueue(
        _ work: Work,
        operationClass: SQLiteOperationClass,
        transactionID: UUID?,
        jobID: UUID
    ) async throws -> [SQLiteRow] {
        guard !closed else {
            throw ServiceAPIError(code: .persistenceUnavailable, message: "SQLite executor is closed")
        }
        try await waitForAdmission(operationClass, jobID: jobID)
        let sequence = nextSequence
        nextSequence &+= 1
        return try await withCheckedThrowingContinuation { continuation in
            queues[operationClass, default: []].append(
                Job(
                    id: jobID,
                    sequence: sequence,
                    operationClass: operationClass,
                    transactionID: transactionID,
                    work: work,
                    enqueuedAtNanoseconds: DispatchTime.now().uptimeNanoseconds,
                    continuation: continuation
                )
            )
            startWorkerIfNeeded()
        }
    }

    private func cancel(jobID: UUID) {
        if let index = admissionWaiters.firstIndex(where: { $0.id == jobID }) {
            let waiter = admissionWaiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
            return
        }
        for operationClass in SQLiteOperationClass.allCases {
            if let index = queues[operationClass, default: []].firstIndex(where: { $0.id == jobID }) {
                let job = queues[operationClass, default: []].remove(at: index)
                job.continuation.resume(throwing: CancellationError())
                resumeAdmissionWaiters()
                return
            }
        }
    }

    private func startWorkerIfNeeded() {
        guard !workerRunning else { return }
        workerRunning = true
        Task { await workerLoop() }
    }

    private func workerLoop() async {
        while let job = dequeueEligibleJob() {
            resumeAdmissionWaiters()
            let startedAt = DispatchTime.now().uptimeNanoseconds
            totalWaitNanosecondsByClass[job.operationClass, default: 0] &+=
                startedAt &- job.enqueuedAtNanoseconds
            do {
                let rows: [SQLiteRow]
                switch job.work {
                case let .query(sql, bindings):
                    rows = try await connection.query(sql, bindings)
                case .begin:
                    rows = try await connection.query("BEGIN IMMEDIATE")
                    activeTransactionID = job.transactionID
                case .commit:
                    rows = try await connection.query("COMMIT")
                    activeTransactionID = nil
                case .rollback:
                    rows = try await connection.query("ROLLBACK")
                    activeTransactionID = nil
                }
                let finishedAt = DispatchTime.now().uptimeNanoseconds
                totalExecuteNanosecondsByClass[job.operationClass, default: 0] &+=
                    finishedAt &- startedAt
                completedByClass[job.operationClass, default: 0] += 1
                testCompletionObserver?(job.operationClass)
                job.continuation.resume(returning: rows)
            } catch {
                let finishedAt = DispatchTime.now().uptimeNanoseconds
                totalExecuteNanosecondsByClass[job.operationClass, default: 0] &+=
                    finishedAt &- startedAt
                if case .begin = job.work {
                    activeTransactionID = nil
                } else if case .commit = job.work {
                    // A failed commit still needs a matching rollback before any
                    // unrelated statement is allowed to execute.
                } else if case .rollback = job.work {
                    activeTransactionID = nil
                }
                job.continuation.resume(throwing: error)
            }
        }
        workerRunning = false
        if hasEligibleJob { startWorkerIfNeeded() }
    }

    private var hasEligibleJob: Bool {
        if let activeTransactionID {
            return queues.values.contains { queue in
                queue.contains { $0.transactionID == activeTransactionID }
            }
        }
        return queuedCount > 0
    }

    private func dequeueEligibleJob() -> Job? {
        if let activeTransactionID {
            let candidates = SQLiteOperationClass.allCases.compactMap { operationClass -> (SQLiteOperationClass, Int, Job)? in
                guard let index = queues[operationClass, default: []].firstIndex(where: {
                    $0.transactionID == activeTransactionID
                }) else { return nil }
                return (operationClass, index, queues[operationClass, default: []][index])
            }
            guard let selected = candidates.min(by: { $0.2.sequence < $1.2.sequence }) else { return nil }
            return queues[selected.0, default: []].remove(at: selected.1)
        }

        let nonempty = SQLiteOperationClass.allCases.filter { !queues[$0, default: []].isEmpty }
        guard !nonempty.isEmpty else { return nil }

        let aged = nonempty.filter { bypasses[$0, default: 0] >= 8 }
        let selectedClass: SQLiteOperationClass
        if let selected = aged.min(by: {
            queues[$0, default: []][0].sequence < queues[$1, default: []][0].sequence
        }) {
            selectedClass = selected
        } else {
            var selected: SQLiteOperationClass?
            for _ in weightedCycle.indices {
                let candidate = weightedCycle[cycleIndex]
                cycleIndex = (cycleIndex + 1) % weightedCycle.count
                if !queues[candidate, default: []].isEmpty {
                    selected = candidate
                    break
                }
            }
            selectedClass = selected ?? nonempty[0]
        }

        for operationClass in SQLiteOperationClass.allCases {
            if operationClass == selectedClass {
                bypasses[operationClass] = 0
            } else if !queues[operationClass, default: []].isEmpty {
                bypasses[operationClass, default: 0] += 1
            }
        }
        return queues[selectedClass, default: []].removeFirst()
    }

    private func resumeAdmissionWaiters() {
        let waiters = admissionWaiters
        admissionWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.continuation.resume() }
    }
}
