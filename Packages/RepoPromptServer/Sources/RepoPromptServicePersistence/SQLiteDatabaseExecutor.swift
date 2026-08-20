import Foundation
import RepoPromptRuntimeModel
import SQLiteNIO

enum SQLiteOperationClass: String, CaseIterable, Sendable {
    case control
    case interactive
    case bulk
}

struct SQLiteDatabaseExecutorMetrics: Sendable, Equatable {
    let capacity: Int
    let reservedControlCapacity: Int
    let maximumAdmissionWaiters: Int
    let queuedByClass: [SQLiteOperationClass: Int]
    let waitingByClass: [SQLiteOperationClass: Int]
    let maximumQueuedDepthObserved: Int
    let maximumWaitingDepthObserved: Int
    let saturationCount: Int
    let completedByClass: [SQLiteOperationClass: Int]
    let totalWaitNanosecondsByClass: [SQLiteOperationClass: UInt64]
    let totalExecuteNanosecondsByClass: [SQLiteOperationClass: UInt64]
}

enum SQLiteExecutionContext {
    @TaskLocal static var transactionID: UUID?
    @TaskLocal static var operationClass: SQLiteOperationClass?
}

/// The sole owner of a SQLite connection.
///
/// All statements are admitted to one bounded scheduler and executed by one
/// worker. Transaction-affine statements are the only work eligible between
/// BEGIN and COMMIT/ROLLBACK, so actor reentrancy cannot expose a partially
/// applied transaction to unrelated reads.
actor SQLiteDatabaseExecutor {
    static let defaultCapacity = 256
    static let defaultReservedControlCapacity = 32
    static let defaultMaximumAdmissionWaiters = 256
    static let maximumBulkRows = 256
    static let maximumBulkEncodedBytes = 1_048_576

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
        let sequence: UInt64
        let operationClass: SQLiteOperationClass
        let continuation: CheckedContinuation<Void, Error>
    }

    private let connection: SQLiteConnection
    private let capacity: Int
    private let reservedControlCapacity: Int
    private let maximumAdmissionWaiters: Int
    private var queues: [SQLiteOperationClass: [Job]] = [
        .control: [],
        .interactive: [],
        .bulk: [],
    ]
    private var admissionWaiters: [SQLiteOperationClass: [AdmissionWaiter]] = [
        .control: [],
        .interactive: [],
        .bulk: [],
    ]
    private var activeTransactionID: UUID?
    private var nextSequence: UInt64 = 1
    private var workerRunning = false
    private var closed = false
    private var saturationCount = 0
    private var maximumQueuedDepthObserved = 0
    private var maximumWaitingDepthObserved = 0
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
        reservedControlCapacity: Int,
        maximumAdmissionWaiters: Int
    ) {
        self.connection = connection
        self.capacity = capacity
        self.reservedControlCapacity = reservedControlCapacity
        self.maximumAdmissionWaiters = maximumAdmissionWaiters
    }

    static func open(
        storage: SQLiteConnection.Storage,
        capacity: Int = defaultCapacity,
        reservedControlCapacity: Int = defaultReservedControlCapacity,
        maximumAdmissionWaiters: Int = defaultMaximumAdmissionWaiters
    ) async throws -> SQLiteDatabaseExecutor {
        guard capacity > 0,
              reservedControlCapacity >= 16,
              reservedControlCapacity < capacity,
              maximumAdmissionWaiters >= reservedControlCapacity
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
            reservedControlCapacity: reservedControlCapacity,
            maximumAdmissionWaiters: maximumAdmissionWaiters
        )
    }

    /// Package-internal SQL seam. Production callers outside the persistence
    /// module can submit only typed `SQLiteServiceStore` operations.
    func query(
        _ sql: String,
        _ bindings: [SQLiteData] = [],
        operationClass: SQLiteOperationClass? = nil
    ) async throws -> [SQLiteRow] {
        let resolvedClass = operationClass ?? SQLiteExecutionContext.operationClass ?? .interactive
        return try await submit(
            .query(sql, bindings),
            operationClass: resolvedClass,
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

    func metrics() -> SQLiteDatabaseExecutorMetrics {
        SQLiteDatabaseExecutorMetrics(
            capacity: capacity,
            reservedControlCapacity: reservedControlCapacity,
            maximumAdmissionWaiters: maximumAdmissionWaiters,
            queuedByClass: Dictionary(uniqueKeysWithValues: SQLiteOperationClass.allCases.map {
                ($0, queues[$0, default: []].count)
            }),
            waitingByClass: Dictionary(uniqueKeysWithValues: SQLiteOperationClass.allCases.map {
                ($0, admissionWaiters[$0, default: []].count)
            }),
            maximumQueuedDepthObserved: maximumQueuedDepthObserved,
            maximumWaitingDepthObserved: maximumWaitingDepthObserved,
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

    func close() async throws {
        guard !closed else { return }
        guard activeTransactionID == nil, queuedCount == 0, waitingCount == 0 else {
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

    private var waitingCount: Int {
        admissionWaiters.values.reduce(0) { $0 + $1.count }
    }

    private var nonControlWaitingCount: Int {
        admissionWaiters[.interactive, default: []].count + admissionWaiters[.bulk, default: []].count
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
            let canWait = waitingCount < maximumAdmissionWaiters
                && (operationClass == .control
                    || nonControlWaitingCount < maximumAdmissionWaiters - reservedControlCapacity)
            guard canWait else {
                throw ServiceAPIError(
                    code: .rateLimited,
                    message: "SQLite admission is saturated",
                    retryable: true
                )
            }
            let sequence = nextSequence
            nextSequence &+= 1
            try await withCheckedThrowingContinuation { continuation in
                admissionWaiters[operationClass, default: []].append(.init(
                    id: jobID,
                    sequence: sequence,
                    operationClass: operationClass,
                    continuation: continuation
                ))
                maximumWaitingDepthObserved = max(maximumWaitingDepthObserved, waitingCount)
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
        // Cancellation can race the waiter continuation being resumed. Recheck
        // before materializing the job so a canceled producer never consumes a
        // queue slot after admission.
        try Task.checkCancellation()
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
            maximumQueuedDepthObserved = max(maximumQueuedDepthObserved, queuedCount)
            startWorkerIfNeeded()
        }
    }

    private func cancel(jobID: UUID) {
        for operationClass in SQLiteOperationClass.allCases {
            if let index = admissionWaiters[operationClass, default: []].firstIndex(where: { $0.id == jobID }) {
                let waiter = admissionWaiters[operationClass, default: []].remove(at: index)
                waiter.continuation.resume(throwing: CancellationError())
                return
            }
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
        // Wake only work that can actually claim the newly available slot. The
        // oldest eligible waiter wins, preserving FIFO admission without an
        // unbounded thundering herd of suspended producer tasks.
        let eligible = SQLiteOperationClass.allCases.compactMap { operationClass -> AdmissionWaiter? in
            guard hasAdmissionCapacity(for: operationClass) else { return nil }
            return admissionWaiters[operationClass, default: []].first
        }
        guard let selected = eligible.min(by: { $0.sequence < $1.sequence }),
              let index = admissionWaiters[selected.operationClass, default: []].firstIndex(where: { $0.id == selected.id })
        else { return }
        let waiter = admissionWaiters[selected.operationClass, default: []].remove(at: index)
        waiter.continuation.resume()
    }
}
