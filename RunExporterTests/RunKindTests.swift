import XCTest
import SwiftData
@testable import RunExporter

/// A run's kind — Speed, Recovery or Endurance — as the export reports it.
///
/// The kind is chosen on the plan and copied onto the run when it starts, like the plan's shape and
/// intent, so editing the plan afterwards cannot rewrite what a past run was. Every value is
/// invented.
@MainActor
final class RunKindTests: XCTestCase {

    private var store: LoggerStore!
    private let base = Date(timeIntervalSince1970: 1_775_000_000)

    override func setUp() {
        super.setUp()
        store = LoggerStore(inMemory: true)
        XCTAssertNil(store.containerError, "in-memory store failed to open")
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    /// History compares runs of one kind, so a run must keep the kind it was run as. Re-tagging a
    /// plan from Speed to Endurance must not move its past runs into the other chart.
    func testARunReportsTheKindItsPlanHadWhenItStarted() throws {
        let plan = PlannedWorkout(name: "1/2 × 8", runIntervalSeconds: 60,
                                  walkIntervalSeconds: 120, plannedRepetitions: 8)
        plan.runKind = RunKind.speed.rawValue
        let context = try XCTUnwrap(store.context)
        context.insert(plan)
        let execution = try XCTUnwrap(PendingWorkoutExecution.started(from: plan, at: base))
        context.insert(execution)
        XCTAssertNil(store.save())

        plan.runKind = RunKind.endurance.rawValue
        XCTAssertNil(store.save())

        let data = LoggerExportSnapshot.make(store: store)
        let row = try XCTUnwrap(data.executions.first)
        let fields = Dictionary(uniqueKeysWithValues: zip(ExecutionExportRow.columns, row.values))
        XCTAssertEqual(fields["runKind"], "speed")
    }

    /// The owner builds new plans by duplicating a close one and editing it. `duplicate()` has
    /// dropped part of a plan before (an open-interval plan's shape); a copy without its kind would
    /// fail the required-kind check the moment it was edited.
    func testDuplicatingAPlanKeepsItsKind() {
        let plan = PlannedWorkout(name: "3/1 × 6", runIntervalSeconds: 180,
                                  walkIntervalSeconds: 60, plannedRepetitions: 6)
        plan.runKind = RunKind.recovery.rawValue

        XCTAssertEqual(plan.duplicate().runKind, "recovery")
    }
}
