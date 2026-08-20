import Foundation
import SQLiteNIO
import XCTest
@testable import RepoPromptServicePersistence

final class SQLiteDatabaseExecutorTests: XCTestCase {
    func testTransactionAffinityPreventsConcurrentReadFromEnteringOpenTransaction() async throws {
        let database = try await SQLiteDatabaseExecutor.open(storage: .memory)
        _ = try await database.query("CREATE TABLE values_table(value INTEGER NOT NULL)")
        let transactionID = UUID()
        try await database.beginTransaction(transactionID)
        try await SQLiteExecutionContext.$transactionID.withValue(transactionID) {
            _ = try await database.query("INSERT INTO values_table(value) VALUES(1)")
        }

        let outsideRead = Task {
            try await database.query("SELECT COUNT(*) AS count FROM values_table").first?.column("count")?.integer
        }
        await Task.yield()
        let queued = await database.metrics()
        XCTAssertEqual(queued.queuedByClass[.interactive], 1)

        try await database.commitTransaction(transactionID)
        let outsideCount = try await outsideRead.value
        XCTAssertEqual(outsideCount, 1)
        try await database.close()
    }

    func testControlAdmissionHasPilotSizedReservedCapacity() async throws {
        let database = try await SQLiteDatabaseExecutor.open(storage: .memory)
        let metrics = await database.metrics()
        XCTAssertEqual(metrics.capacity, 256)
        XCTAssertGreaterThanOrEqual(metrics.reservedControlCapacity, 16)
        XCTAssertEqual(SQLiteDatabaseExecutor.maximumBulkRows, 256)
        XCTAssertEqual(SQLiteDatabaseExecutor.maximumBulkEncodedBytes, 1_048_576)
        try await database.close()
    }

    func testQueuedCancellationRemovesWorkAndFreesCapacity() async throws {
        let database = try await SQLiteDatabaseExecutor.open(storage: .memory)
        let transactionID = UUID()
        try await database.beginTransaction(transactionID)
        let queued = Task {
            try await database.query("SELECT 1", operationClass: .bulk)
        }
        while await database.metrics().queuedByClass[.bulk] != 1 { await Task.yield() }
        queued.cancel()
        do {
            _ = try await queued.value
            XCTFail("queued database work should be canceled before execution")
        } catch is CancellationError {}
        let afterCancellation = await database.metrics()
        XCTAssertEqual(afterCancellation.queuedByClass[.bulk], 0)
        await database.rollbackTransaction(transactionID)
        try await database.close()
    }
}

final class SQLiteDatabaseExecutorFairnessTests: XCTestCase {
    func testEveryClassAdvancesUnderMixedPressureAndQueuesDrainWithinCapacity() async throws {
        let database = try await SQLiteDatabaseExecutor.open(storage: .memory)
        let transactionID = UUID()
        try await database.beginTransaction(transactionID)
        let jobs = (0 ..< 24).map { index in
            Task {
                let operationClass: SQLiteOperationClass = switch index % 3 {
                case 0: .control
                case 1: .interactive
                default: .bulk
                }
                return try await database.query("SELECT ? AS value", [.integer(index)], operationClass: operationClass)
            }
        }
        await Task.yield()
        let pressured = await database.metrics()
        XCTAssertLessThanOrEqual(pressured.queuedByClass.values.reduce(0, +), pressured.capacity)
        try await database.commitTransaction(transactionID)
        for job in jobs { _ = try await job.value }
        let finished = await database.metrics()
        for operationClass in SQLiteOperationClass.allCases {
            XCTAssertGreaterThan(finished.completedByClass[operationClass, default: 0], 0)
            XCTAssertEqual(finished.queuedByClass[operationClass], 0)
        }
        try await database.close()
    }


    func testWeightedCycleAndAgingBoundAreDeterministic() async throws {
        let recorder = SQLiteCompletionRecorder()
        let database = try await SQLiteDatabaseExecutor.open(storage: .memory)
        let transactionID = UUID()
        try await database.beginTransaction(transactionID)
        await database.installTestCompletionObserver { recorder.append($0) }

        let classes: [SQLiteOperationClass] =
            Array(repeating: .control, count: 12)
                + Array(repeating: .interactive, count: 6)
                + Array(repeating: .bulk, count: 3)
        let jobs = classes.map { operationClass in
            Task { try await database.query("SELECT 1", operationClass: operationClass) }
        }
        while await database.metrics().queuedByClass.values.reduce(0, +) != classes.count {
            await Task.yield()
        }
        try await database.commitTransaction(transactionID)
        for job in jobs { _ = try await job.value }

        let completions = recorder.values.dropFirst() // transaction COMMIT
        let firstCycle = Array(completions.prefix(7))
        XCTAssertEqual(firstCycle.count(where: { $0 == .control }), 4)
        XCTAssertEqual(firstCycle.count(where: { $0 == .interactive }), 2)
        XCTAssertEqual(firstCycle.count(where: { $0 == .bulk }), 1)
        for operationClass in SQLiteOperationClass.allCases {
            let positions = completions.indices.filter { completions[$0] == operationClass }
            XCTAssertFalse(positions.isEmpty)
            if let first = positions.first {
                XCTAssertLessThanOrEqual(first, 8)
            }
        }
        try await database.close()
    }
}

private final class SQLiteCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SQLiteOperationClass] = []

    var values: [SQLiteOperationClass] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: SQLiteOperationClass) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
