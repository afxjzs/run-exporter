import XCTest
import SwiftData
@testable import RunExporter

/// How a plan's shape reaches the export.
///
/// `planned_workouts.csv` describes a plan with one `runIntervalSeconds`, one
/// `walkIntervalSeconds` and one `plannedRepetitions`. Those three columns cannot describe
/// `5/1×1 → 8/1×2 → 5/1×1`, and filling them with the first block's numbers would state something
/// false about the whole run — the kind of quiet wrongness that is only discovered months later,
/// in analysis, when nobody remembers the plan.
@MainActor
final class PlannedWorkoutBlockExportTests: XCTestCase {

    private var store: LoggerStore!

    override func setUp() {
        super.setUp()
        store = LoggerStore(inMemory: true)
        XCTAssertNil(store.containerError, "in-memory store failed to open")
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    @discardableResult
    private func insertPlan(name: String,
                            run: Int = 240, walk: Int = 60, reps: Int = 5,
                            blocks: [(run: Int, walk: Int, reps: Int)] = []) throws
        -> PlannedWorkout {
        let context = try XCTUnwrap(store.context)
        let plan = PlannedWorkout(name: name,
                                  runIntervalSeconds: run,
                                  walkIntervalSeconds: walk,
                                  plannedRepetitions: reps)
        plan.blocks = blocks.enumerated().map { index, shape in
            PlannedWorkoutBlock(orderIndex: index,
                                runIntervalSeconds: shape.run,
                                walkIntervalSeconds: shape.walk,
                                repetitions: shape.reps)
        }
        context.insert(plan)
        XCTAssertNil(store.save())
        return plan
    }

    /// A row's columns by name, so an assertion never depends on column order.
    private func fields(_ row: PlannedWorkoutExportRow) -> [String: String] {
        Dictionary(uniqueKeysWithValues: zip(PlannedWorkoutExportRow.columns, row.values))
    }

    private func fields(_ row: PlannedWorkoutBlockExportRow) -> [String: String] {
        Dictionary(uniqueKeysWithValues: zip(PlannedWorkoutBlockExportRow.columns, row.values))
    }

    // MARK: - planned_workouts.csv

    /// The three flat columns are blanked for a plan they cannot describe.
    ///
    /// Blank, not zero: a zero would read as "runs for no time". This export's own convention is
    /// that a blank column is visibly unknown and an invented number is not.
    func testMultiBlockPlanBlanksTheColumnsThatCannotDescribeIt() throws {
        try insertPlan(name: "5/1×1 · 8/1×2 · 5/1×1",
                       blocks: [(300, 60, 1), (480, 60, 2), (300, 60, 1)])

        let data = LoggerExportSnapshot.make(store: store)
        let row = try XCTUnwrap(data.plannedWorkouts.first)

        XCTAssertEqual(fields(row)["runIntervalSeconds"], "")
        XCTAssertEqual(fields(row)["walkIntervalSeconds"], "")
        XCTAssertEqual(fields(row)["plannedRepetitions"], "")
    }

    /// An ordinary plan is unchanged — those columns describe it perfectly well.
    func testSingleShapePlanKeepsItsIntervalColumns() throws {
        try insertPlan(name: "4/1 × 5")

        let data = LoggerExportSnapshot.make(store: store)
        let row = try XCTUnwrap(data.plannedWorkouts.first)

        XCTAssertEqual(fields(row)["runIntervalSeconds"], "240")
        XCTAssertEqual(fields(row)["walkIntervalSeconds"], "60")
        XCTAssertEqual(fields(row)["plannedRepetitions"], "5")
    }

    /// The totals stay populated for every plan. Unlike the three interval columns, they are
    /// perfectly well defined for a multi-block plan — they sum every block.
    func testTotalsDescribeTheWholePlanEvenWhenItHasBlocks() throws {
        try insertPlan(name: "blocks", blocks: [(300, 60, 1), (480, 60, 2), (300, 60, 1)])

        let data = LoggerExportSnapshot.make(store: store)
        let row = try XCTUnwrap(data.plannedWorkouts.first)

        // 5 + 8 + 8 + 5 running, with three 1:00 walks between them.
        XCTAssertEqual(fields(row)["totalRunSeconds"], "1560")
        XCTAssertEqual(fields(row)["totalWalkSeconds"], "180")
        XCTAssertEqual(fields(row)["mainSetSeconds"], "1740")
    }

    // MARK: - planned_workout_blocks.csv

    /// Every plan contributes its segments, so this file is the one uniform place a plan's shape
    /// can be read — no special case for the plans whose columns were blanked.
    func testEveryPlanContributesItsSegmentsInOrder() throws {
        try insertPlan(name: "blocks", blocks: [(300, 60, 1), (480, 60, 2), (300, 60, 1)])

        let data = LoggerExportSnapshot.make(store: store)
        let rows = data.plannedWorkoutBlocks

        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map { fields($0)["position"] }, ["0", "1", "2"])
        XCTAssertEqual(rows.map { fields($0)["runIntervalSeconds"] }, ["300", "480", "300"])
        XCTAssertEqual(rows.map { fields($0)["walkIntervalSeconds"] }, ["60", "60", "60"])
        XCTAssertEqual(rows.map { fields($0)["repetitions"] }, ["1", "2", "1"])
    }

    /// A plan with no stored blocks is a one-segment plan, and says so here rather than being
    /// absent. An analyst reading this file never has to ask which plans are missing from it.
    func testASingleShapePlanIsExportedAsOneSegment() throws {
        try insertPlan(name: "4/1 × 5")

        let data = LoggerExportSnapshot.make(store: store)
        let rows = data.plannedWorkoutBlocks

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(fields(rows[0])["position"], "0")
        XCTAssertEqual(fields(rows[0])["runIntervalSeconds"], "240")
        XCTAssertEqual(fields(rows[0])["walkIntervalSeconds"], "60")
        XCTAssertEqual(fields(rows[0])["repetitions"], "5")
    }

    /// Segments carry the id of the plan they belong to, which is what makes the join possible.
    func testSegmentsCarryTheirPlanIdentifier() throws {
        let plan = try insertPlan(name: "blocks", blocks: [(300, 60, 1), (480, 60, 2)])

        let data = LoggerExportSnapshot.make(store: store)

        XCTAssertEqual(Set(data.plannedWorkoutBlocks.map { fields($0)["plannedWorkoutID"] }),
                       [plan.id.uuidString])
    }

    // MARK: - pending_workout_executions.csv

    private func fields(_ row: ExecutionExportRow) -> [String: String] {
        Dictionary(uniqueKeysWithValues: zip(ExecutionExportRow.columns, row.values))
    }

    @discardableResult
    private func insertExecution(run: Int, walk: Int, reps: Int,
                                 blockShape: String?) throws -> PendingWorkoutExecution {
        let context = try XCTUnwrap(store.context)
        let execution = PendingWorkoutExecution(plannedWorkoutID: UUID(),
                                                plannedWorkoutName: "session",
                                                expectedActivityType: .running,
                                                expectedDurationSeconds: 1_740,
                                                runIntervalSeconds: run,
                                                walkIntervalSeconds: walk,
                                                plannedRepetitions: reps)
        execution.blockShape = blockShape
        context.insert(execution)
        XCTAssertNil(store.save())
        return execution
    }

    /// A run of several segments reports its shape, and blanks the two columns that cannot hold it.
    func testAMultiBlockExecutionReportsItsShapeAndBlanksWhatCannotDescribeIt() throws {
        try insertExecution(run: 0, walk: 0, reps: 4,
                            blockShape: "300/60x1|480/60x2|300/60x1")

        let data = LoggerExportSnapshot.make(store: store)
        let row = try XCTUnwrap(data.executions.first)

        XCTAssertEqual(fields(row)["runIntervalSeconds"], "")
        XCTAssertEqual(fields(row)["walkIntervalSeconds"], "")
        XCTAssertEqual(fields(row)["blockShape"], "300/60x1|480/60x2|300/60x1")
        // Rounds are well defined across segments, so this one is not blanked.
        XCTAssertEqual(fields(row)["plannedRepetitions"], "4")
    }

    /// An ordinary run is unchanged, and still says so in one segment.
    func testASingleShapeExecutionKeepsItsColumns() throws {
        try insertExecution(run: 240, walk: 60, reps: 5, blockShape: "240/60x5")

        let data = LoggerExportSnapshot.make(store: store)
        let row = try XCTUnwrap(data.executions.first)

        XCTAssertEqual(fields(row)["runIntervalSeconds"], "240")
        XCTAssertEqual(fields(row)["walkIntervalSeconds"], "60")
        XCTAssertEqual(fields(row)["plannedRepetitions"], "5")
        XCTAssertEqual(fields(row)["blockShape"], "240/60x5")
    }

    /// A session recorded before this column existed carries no shape string, and its own columns
    /// are still the truth about it. It must not be blanked as though it were multi-block.
    func testASessionRecordedBeforeShapesWereStoredKeepsItsColumns() throws {
        try insertExecution(run: 240, walk: 60, reps: 5, blockShape: nil)

        let data = LoggerExportSnapshot.make(store: store)
        let row = try XCTUnwrap(data.executions.first)

        XCTAssertEqual(fields(row)["runIntervalSeconds"], "240")
        XCTAssertEqual(fields(row)["walkIntervalSeconds"], "60")
        XCTAssertEqual(fields(row)["plannedRepetitions"], "5")
        XCTAssertEqual(fields(row)["blockShape"], "")
    }

    // MARK: - What the export considers still waiting to be joined

    /// A run with notes and no run log is an ordinary run — a note asks for no RPE.
    ///
    /// The export's pre-flight reconciliation gated on a count of orphaned `RunLog`s alone, so such
    /// a run scored zero, no reconciliation ran, and its notes exported with a blank workout UUID
    /// and no line in `export_log.json`. That is the exact failure `LEARNINGS.md` records the sweep
    /// being reshaped to fix — "the subject of reconciliation is the execution, not the run log" —
    /// reintroduced at the export boundary.
    func testANoteWaitingToBeJoinedCountsAsPendingWork() throws {
        let context = try XCTUnwrap(store.context)
        let executionID = UUID()
        context.insert(WorkoutNote(executionID: executionID,
                                   phaseType: .walk,
                                   repetitionNumber: 3,
                                   secondsIntoWorkout: 742,
                                   text: "calf tight"))
        XCTAssertNil(store.save())

        let counts = LoggerExportSnapshot.pendingCaptureCounts(store: store)

        XCTAssertEqual(counts.logs, 0)
        XCTAssertEqual(counts.notes, 1)
        XCTAssertEqual(counts.total, 1, "the export must see something left to reconcile")
    }

    /// A note already joined to its workout is not waiting for anything.
    func testAJoinedNoteIsNotPendingWork() throws {
        let context = try XCTUnwrap(store.context)
        context.insert(WorkoutNote(executionID: UUID(),
                                   healthKitWorkoutUUID: UUID(),
                                   phaseType: .run,
                                   repetitionNumber: 1,
                                   secondsIntoWorkout: 60,
                                   text: "joined"))
        XCTAssertNil(store.save())

        XCTAssertEqual(LoggerExportSnapshot.pendingCaptureCounts(store: store).total, 0)
    }

    /// And a log with no workout still counts, as it always did.
    func testALogWaitingToBeJoinedStillCountsAsPendingWork() throws {
        let context = try XCTUnwrap(store.context)
        let log = RunLog(healthKitWorkoutUUID: nil,
                         workoutStartDate: Date(),
                         workoutDistanceMiles: nil,
                         workoutActivityType: "running",
                         executionID: UUID(),
                         effortRPE: 6,
                         personalHeatRating: 5)
        context.insert(log)
        XCTAssertNil(store.save())

        let counts = LoggerExportSnapshot.pendingCaptureCounts(store: store)

        XCTAssertEqual(counts.logs, 1)
        XCTAssertEqual(counts.notes, 0)
    }

    /// Order comes from `orderIndex`. SwiftData returns the relationship unordered, so a segment
    /// list that trusted array position would export a workout in the wrong order.
    func testSegmentsAreOrderedByOrderIndexNotArrayPosition() throws {
        let context = try XCTUnwrap(store.context)
        let plan = PlannedWorkout(name: "unordered",
                                  runIntervalSeconds: 240,
                                  walkIntervalSeconds: 60,
                                  plannedRepetitions: 5)
        plan.blocks = [
            PlannedWorkoutBlock(orderIndex: 2, runIntervalSeconds: 300,
                                walkIntervalSeconds: 60, repetitions: 1),
            PlannedWorkoutBlock(orderIndex: 0, runIntervalSeconds: 300,
                                walkIntervalSeconds: 60, repetitions: 1),
            PlannedWorkoutBlock(orderIndex: 1, runIntervalSeconds: 480,
                                walkIntervalSeconds: 60, repetitions: 2),
        ]
        context.insert(plan)
        XCTAssertNil(store.save())

        let data = LoggerExportSnapshot.make(store: store)

        XCTAssertEqual(data.plannedWorkoutBlocks.map { fields($0)["runIntervalSeconds"] },
                       ["300", "480", "300"])
    }
}
