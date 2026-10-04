import XCTest
import SwiftData
@testable import RunExporter

/// A plan's aerobic intent and the post-run talk test, as the export reports them (aerobic spec §1,
/// §7, §17; Decisions D18).
///
/// Each test plans a run, starts it, logs it through `RunLoggerModel` against an in-memory store,
/// and reads the `run_logs.csv` row the export snapshot writes. Every value is invented.
@MainActor
final class AerobicIntentTests: XCTestCase {

    private var store: LoggerStore!
    private var defaults: LoggerDefaults!
    private var model: RunLoggerModel!
    private let base = Date(timeIntervalSince1970: 1_775_000_000)

    override func setUp() {
        super.setUp()
        store = LoggerStore(inMemory: true)
        XCTAssertNil(store.containerError, "in-memory store failed to open")
        defaults = LoggerDefaults(defaults: UserDefaults(suiteName: "AerobicIntentTests")!)
        model = RunLoggerModel(store: store, defaults: defaults)
    }

    override func tearDown() {
        model = nil
        defaults = nil
        store = nil
        super.tearDown()
    }

    /// The owner's case: an easy aerobic run, logged during cooldown with a talk test. The plan is
    /// edited before the log is saved, and the run must still report what it set out to do — the
    /// same reason a run keeps a copy of its plan's shape.
    func testARunReportsTheIntentItsPlanHadWhenItStarted() throws {
        let plan = PlannedWorkout(name: "Easy 30", runIntervalSeconds: 1_800,
                                  walkIntervalSeconds: 0, plannedRepetitions: 1)
        plan.intensityMode = WorkoutIntensityMode.easyAerobicObservation.rawValue
        plan.targetRPEMin = 3
        plan.targetRPEMax = 4
        let execution = try start(plan)

        plan.intensityMode = WorkoutIntensityMode.notSpecified.rawValue
        plan.targetRPEMin = nil
        plan.targetRPEMax = nil
        XCTAssertNil(store.save())

        var draft = completeDraft()
        draft.talkTest = .comfortable
        XCTAssertNil(model.saveDuringWorkout(draft: draft, executionID: execution.id,
                                             startedAt: base, activityType: .running))

        let row = try exportedLog()
        XCTAssertEqual(row["intensityMode"], "easyAerobicObservation")
        XCTAssertEqual(row["targetRPEMin"], "3")
        XCTAssertEqual(row["targetRPEMax"], "4")
        XCTAssertEqual(row["targetHeartRateMin"], "", "no heart-rate range is set (§1)")
        XCTAssertEqual(row["targetHeartRateMax"], "")
        XCTAssertEqual(row["talkTest"], "comfortable")
    }

    /// An ordinary run says so: its intent is `none`, and the talk test, never asked, is blank —
    /// not `notRecorded`, which is an answer.
    func testAnOrdinaryRunReportsNoIntentAndNoTalkTest() throws {
        let plan = PlannedWorkout(name: "4/1 × 5", runIntervalSeconds: 240,
                                  walkIntervalSeconds: 60, plannedRepetitions: 5)
        let execution = try start(plan)

        XCTAssertNil(model.save(draft: completeDraft(),
                                for: workout(executionID: execution.id)))

        let row = try exportedLog()
        XCTAssertEqual(row["intensityMode"], "none")
        XCTAssertEqual(row["targetRPEMin"], "")
        XCTAssertEqual(row["talkTest"], "")
    }

    /// Duplicating a plan keeps its intent. `duplicate()` has dropped part of a plan before (an
    /// open-interval plan's shape), and an aerobic plan silently copied as an ordinary one would
    /// record every run of the copy as `none`.
    func testDuplicatingAnAerobicPlanKeepsItsIntent() {
        let plan = PlannedWorkout(name: "Easy 30", runIntervalSeconds: 1_800,
                                  walkIntervalSeconds: 0, plannedRepetitions: 1)
        plan.intensityMode = WorkoutIntensityMode.easyAerobicObservation.rawValue
        plan.targetRPEMin = 3
        plan.targetRPEMax = 4

        let copy = plan.duplicate()

        XCTAssertEqual(copy.intensityMode, "easyAerobicObservation")
        XCTAssertEqual(copy.targetRPEMin, 3)
        XCTAssertEqual(copy.targetRPEMax, 4)
    }

    // MARK: - Fixtures

    /// Inserts the plan and starts a run of it the way the run screen does.
    private func start(_ plan: PlannedWorkout) throws -> PendingWorkoutExecution {
        let context = try XCTUnwrap(store.context)
        context.insert(plan)
        let execution = try XCTUnwrap(PendingWorkoutExecution.started(from: plan, at: base),
                                      "the plan could not be started")
        context.insert(execution)
        XCTAssertNil(store.save())
        return execution
    }

    private func completeDraft() -> RunLogDraft {
        var draft = RunLogDraft(shoeID: nil)
        draft.effortRPE = 3.5
        draft.personalHeatRating = 5
        return draft
    }

    private func workout(executionID: UUID) -> HealthKitManager.WorkoutSummary {
        HealthKitManager.WorkoutSummary(
            uuid: UUID(), activityType: .running,
            startDate: base, endDate: base.addingTimeInterval(1_500), duration: 1_500,
            distanceMiles: 2, averageHeartRate: nil, peakHeartRate: nil,
            temperatureFahrenheit: nil, humidityPercent: nil, sourceName: "invented",
            hasWeatherMetadata: false, isIndoor: false, metadataKeys: [],
            isReclassifiedAsRunning: false, executionID: executionID)
    }

    /// The one run log's `run_logs.csv` cells, by column, exactly as the export writes them.
    private func exportedLog() throws -> [String: String] {
        let data = LoggerExportSnapshot.make(store: store)
        XCTAssertEqual(data.runLogs.count, 1)
        let row = try XCTUnwrap(data.runLogs.first)
        return Dictionary(uniqueKeysWithValues: zip(RunLogExportRow.columns, row.values))
    }
}
