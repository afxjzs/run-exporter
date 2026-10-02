import XCTest
@testable import RunExporter

/// What a run actually ran, as the export reports it: `pending_workout_executions.csv` and the
/// `workouts.csv` join.
///
/// Measured in a real export: every open-interval run's execution row read run 0, walk 0, rounds 0,
/// although each of its legs was recorded in `workout_intervals.csv`. These columns report the legs.
final class RecordedRunExportTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    private func leg(_ sequence: Int, _ phase: String, _ start: Double, _ end: Double,
                     execution: String = "exec-open", workout: String? = "w1") -> IntervalLogExportRow {
        IntervalLogExportRow(intervalLogID: UUID().uuidString,
                             healthKitWorkoutUUID: workout,
                             executionID: execution,
                             sequenceIndex: sequence,
                             phaseType: phase,
                             repetitionNumber: nil,
                             plannedDurationSeconds: nil,
                             actualDurationSeconds: end - start,
                             startDate: t0.addingTimeInterval(start),
                             endDate: t0.addingTimeInterval(end),
                             wasSkipped: false,
                             wasInterrupted: false)
    }

    private func execution(_ id: String) -> ExecutionExportRow {
        ExecutionExportRow(executionID: id, plannedWorkoutID: UUID().uuidString,
                           plannedWorkoutName: "Run to 30 min · 3 min walks",
                           expectedActivityType: "running", expectedDurationSeconds: 1_800,
                           runIntervalSeconds: 0, walkIntervalSeconds: 0, plannedRepetitions: 0,
                           completedRepetitions: 2, blockShape: "open:1800/180", status: "matched",
                           matchedHealthKitWorkoutUUID: "w1", timerStartedAt: t0, timerEndedAt: nil,
                           createdAt: t0, updatedAt: t0)
    }

    private func runLog(executionID: String) -> RunLogExportRow {
        RunLogExportRow(runLogID: UUID().uuidString, healthKitWorkoutUUID: "w1",
                        plannedWorkoutID: nil, executionID: executionID,
                        createdAt: t0, updatedAt: t0,
                        effortRPE: 4, personalHeatRating: 5,
                        lowerBackSeverity: 0, leftAnkleSeverity: 0, rightAnkleSeverity: 0,
                        leftKneeSeverity: 0, rightKneeSeverity: 0,
                        workoutStartDate: t0, workoutDistanceMiles: 3, workoutActivityType: "running")
    }

    /// An open run: two legs the runner ended, a walk between, then cooldown.
    private func openRunLegs() -> [IntervalLogExportRow] {
        [leg(0, "run", 0, 752), leg(1, "walk", 752, 933), leg(2, "run", 933, 1_142),
         leg(3, "cooldown", 1_142, 1_500)]
    }

    func testAnOpenRunsExecutionRowReportsTheLegsItRan() throws {
        var data = LoggerExportData()
        data.executions = [execution("exec-open")]
        data.intervalLogs = openRunLegs()
        data.index()

        let row = try XCTUnwrap(data.executions.first)
        XCTAssertEqual(row.actualShape, "752/181|209/0")
        XCTAssertEqual(row.actualRunLegCount, 2)
        XCTAssertEqual(try XCTUnwrap(row.actualRunSeconds), 961, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(row.actualWalkSeconds), 181, accuracy: 0.001)
    }

    /// One derivation, read twice. A second calculation for the join is how two files come to
    /// disagree about the same run.
    func testTheWorkoutJoinReportsTheSameActualsAsItsExecution() throws {
        var data = LoggerExportData()
        data.executions = [execution("exec-open")]
        data.intervalLogs = openRunLegs()
        data.runLogs = [runLog(executionID: "exec-open")]
        data.index()

        let join = try XCTUnwrap(data.join(forWorkoutUUID: "w1"))
        let row = try XCTUnwrap(data.executions.first)
        XCTAssertEqual(join.actualShape, "752/181|209/0", "equal-but-both-blank would pass the rest")
        XCTAssertEqual(join.actualShape, row.actualShape)
        XCTAssertEqual(join.actualRunLegCount, row.actualRunLegCount)
        XCTAssertEqual(join.actualRunSeconds, row.actualRunSeconds)
        XCTAssertEqual(join.actualWalkSeconds, row.actualWalkSeconds)
    }

    /// A timer that never started has no legs. Totals over nothing are zero, and a zero here would
    /// read as a run of no running — the very smell this removes.
    func testAnExecutionWithNoLegsReportsNothingRatherThanZero() throws {
        var data = LoggerExportData()
        data.executions = [execution("exec-empty")]
        data.index()

        let row = try XCTUnwrap(data.executions.first)
        XCTAssertNil(row.actualShape)
        XCTAssertNil(row.actualRunLegCount)
        XCTAssertNil(row.actualRunSeconds)
        XCTAssertNil(row.actualWalkSeconds)
    }

    /// Blank, and said so in export_log.json. Blank alone would read as "no legs recorded".
    func testUnreadableLegsAreBlankAndReported() throws {
        var data = LoggerExportData()
        data.executions = [execution("exec-odd")]
        data.intervalLogs = [leg(0, "sprint", 0, 60, execution: "exec-odd")]
        data.index()

        XCTAssertNil(try XCTUnwrap(data.executions.first).actualShape)
        XCTAssertTrue(data.issues.contains { $0.message.contains("exec-odd") && $0.message.contains("sprint") },
                      "the execution and the unknown phase must both be named; got \(data.issues.map(\.message))")
    }
}
