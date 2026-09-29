import XCTest
import SwiftData
@testable import RunExporter

/// `ActiveWorkoutModel` against a real in-memory store.
///
/// The property under test is when a timer session comes into existence. Opening the workout screen
/// used to create one immediately, which mattered more than it looked: `RecentWorkoutMatcher` links
/// a HealthKit workout to a session only when their starts are within
/// `startToleranceSeconds` (120), and the run was then started as two separate taps — the Watch,
/// then the phone. A session recorded when the screen opened spent that window on the walk between
/// devices. (Since 2026-09-29 Start launches the Watch itself and a tagged workout joins by
/// execution id; the window is the fallback for untagged workouts, and this property still holds.)
@MainActor
final class ActiveWorkoutModelTests: XCTestCase {

    private var store: LoggerStore!
    private var defaults: LoggerDefaults!
    private var audio: AudioCueEngine!

    override func setUp() {
        super.setUp()
        store = LoggerStore(inMemory: true)
        XCTAssertNil(store.containerError, "in-memory store failed to open")
        defaults = LoggerDefaults(defaults: UserDefaults(suiteName: "ActiveWorkoutModelTests")!)
        audio = AudioCueEngine()
    }

    override func tearDown() {
        audio = nil
        defaults = nil
        store = nil
        super.tearDown()
    }

    private func makePlan() -> PlannedWorkout {
        let plan = PlannedWorkout(name: "4/1 × 2",
                                  activityType: .running,
                                  runIntervalSeconds: 240,
                                  walkIntervalSeconds: 60,
                                  plannedRepetitions: 2)
        store.context?.insert(plan)
        XCTAssertNil(store.save(), "fixture insert failed")
        return plan
    }

    /// 5/1×1 → 8/1×2 → 5/1×1: four rounds, of three different shapes.
    private func makeBlockPlan() -> PlannedWorkout {
        let plan = PlannedWorkout(name: "5/1×1 · 8/1×2 · 5/1×1",
                                  activityType: .running,
                                  runIntervalSeconds: 300,
                                  walkIntervalSeconds: 60,
                                  plannedRepetitions: 1)
        plan.blocks = [
            PlannedWorkoutBlock(orderIndex: 0, runIntervalSeconds: 300,
                                walkIntervalSeconds: 60, repetitions: 1),
            PlannedWorkoutBlock(orderIndex: 1, runIntervalSeconds: 480,
                                walkIntervalSeconds: 60, repetitions: 2),
            PlannedWorkoutBlock(orderIndex: 2, runIntervalSeconds: 300,
                                walkIntervalSeconds: 60, repetitions: 1),
        ]
        store.context?.insert(plan)
        XCTAssertNil(store.save(), "fixture insert failed")
        return plan
    }

    private func executions() -> [PendingWorkoutExecution] {
        guard case .success(let rows) =
                store.fetch(FetchDescriptor<PendingWorkoutExecution>()) else {
            XCTFail("could not read executions")
            return []
        }
        return rows
    }

    /// Opening the screen must record nothing. The workout begins when the user says so, which is
    /// the whole point of arming: they start the Watch first, then tap here.
    func testAFreshModelHasNotStartedAndHasRecordedNothing() {
        let model = ActiveWorkoutModel(store: store, defaults: defaults, audio: audio, watchLink: nil)

        XCTAssertFalse(model.hasStarted)
        XCTAssertNil(model.executionID)
        XCTAssertFalse(model.isRunning)
        XCTAssertTrue(executions().isEmpty,
                      "no timer session may exist before the user has started one")
    }

    /// And starting records one, stamped at that instant rather than at whenever the screen opened.
    /// This is the timestamp the matcher compares against the Watch workout's start.
    func testStartingRecordsOneSessionStampedAtThatMoment() {
        let plan = makePlan()
        let model = ActiveWorkoutModel(store: store, defaults: defaults, audio: audio, watchLink: nil)
        let before = Date()

        model.start(plan: plan)

        XCTAssertTrue(model.hasStarted)
        let rows = executions()
        XCTAssertEqual(rows.count, 1)
        let startedAt = rows.first?.timerStartedAt
        XCTAssertNotNil(startedAt, "a session with no start cannot be matched to a workout")
        XCTAssertGreaterThanOrEqual(startedAt ?? .distantPast, before)
        XCTAssertLessThanOrEqual(startedAt ?? .distantFuture, Date())

        model.cancel()
    }

    /// Starting twice must not leave two sessions competing to be matched to the same run — two
    /// overlapping executions are what made one of the owner's real runs permanently ambiguous.
    func testStartingIsNotRepeatedOnceUnderway() {
        let plan = makePlan()
        let model = ActiveWorkoutModel(store: store, defaults: defaults, audio: audio, watchLink: nil)

        model.start(plan: plan)
        model.start(plan: plan)

        XCTAssertEqual(executions().count, 1, "a second tap must not open a second session")

        model.cancel()
    }

    // MARK: - Knowing whether this run has already been logged

    /// The cooldown button offers "Log this run now" or "Edit run log", and it was reading a flag
    /// nothing ever set true — so a run already logged mid-workout was still invited to be logged
    /// again, from a button that said it would be the first time. Same misreading `LEARNINGS.md`
    /// records fixing on the Finish path; this path kept the broken version.
    func testASessionKnowsOnceItHasBeenLogged() throws {
        let plan = makePlan()
        let logger = RunLoggerModel(store: store, defaults: defaults)
        let model = ActiveWorkoutModel(store: store, defaults: defaults, audio: audio, watchLink: nil)

        model.start(plan: plan)
        model.refreshPendingLog(using: logger)
        XCTAssertFalse(model.hasPendingLog, "nothing has been logged yet")

        let executionID = try XCTUnwrap(model.executionID)
        var draft = RunLogDraft(shoeID: nil)
        draft.effortRPE = 6
        draft.personalHeatRating = 5
        XCTAssertNil(logger.saveDuringWorkout(draft: draft,
                                              executionID: executionID,
                                              startedAt: model.startedAt,
                                              activityType: .running))

        model.refreshPendingLog(using: logger)
        XCTAssertTrue(model.hasPendingLog, "a log exists for this session and the button must say so")

        model.cancel()
    }

    /// Cancelling the sheet must not claim a log was written. The answer comes from the store, so
    /// it is right whether the sheet was saved or dismissed.
    func testDismissingTheLogSheetWithoutSavingLeavesTheSessionUnlogged() {
        let plan = makePlan()
        let logger = RunLoggerModel(store: store, defaults: defaults)
        let model = ActiveWorkoutModel(store: store, defaults: defaults, audio: audio, watchLink: nil)

        model.start(plan: plan)
        model.refreshPendingLog(using: logger)
        model.refreshPendingLog(using: logger)

        XCTAssertFalse(model.hasPendingLog)

        model.cancel()
    }

    // MARK: - Recording the shape that was actually run

    /// A session holds a copy of the plan's shape so that editing the plan afterwards cannot
    /// rewrite history. For a plan of several segments, one run length and one walk length are not
    /// that shape, and the whole of it has to be recorded or the run becomes undescribable later.
    func testAMultiBlockSessionRecordsTheWholeShape() throws {
        let plan = makeBlockPlan()
        let model = ActiveWorkoutModel(store: store, defaults: defaults, audio: audio, watchLink: nil)

        model.start(plan: plan)

        let execution = try XCTUnwrap(executions().first)
        XCTAssertEqual(execution.blockShape, "300/60x1|480/60x2|300/60x1")

        model.cancel()
    }

    /// And it must not claim a single interval shape it does not have.
    ///
    /// Zero rather than the first segment's numbers: a run interval of zero is impossible for a
    /// plan the timer would agree to run, so a reader that forgets to consult `blockShape` gets an
    /// obviously broken value instead of a plausible and wrong one.
    func testAMultiBlockSessionClaimsNoSingleIntervalShape() throws {
        let plan = makeBlockPlan()
        let model = ActiveWorkoutModel(store: store, defaults: defaults, audio: audio, watchLink: nil)

        model.start(plan: plan)

        let execution = try XCTUnwrap(executions().first)
        XCTAssertEqual(execution.runIntervalSeconds, 0)
        XCTAssertEqual(execution.walkIntervalSeconds, 0)
        XCTAssertTrue(execution.hasMultipleBlocks)
        // Rounds are well defined for any plan — four here, across three segments — so this one
        // stays populated rather than being blanked along with the two that are not.
        XCTAssertEqual(execution.plannedRepetitions, 4)

        model.cancel()
    }

    /// An ordinary plan still records exactly what it always did, and says so in one segment.
    func testASingleShapeSessionIsUnchanged() throws {
        let plan = makePlan()
        let model = ActiveWorkoutModel(store: store, defaults: defaults, audio: audio, watchLink: nil)

        model.start(plan: plan)

        let execution = try XCTUnwrap(executions().first)
        XCTAssertEqual(execution.runIntervalSeconds, 240)
        XCTAssertEqual(execution.walkIntervalSeconds, 60)
        XCTAssertEqual(execution.plannedRepetitions, 2)
        XCTAssertEqual(execution.blockShape, "240/60x2")
        XCTAssertFalse(execution.hasMultipleBlocks)

        model.cancel()
    }

    /// The post-run log form prefills from this. It must not offer a wrong interval shape for a
    /// multi-block run — a blank field asks the user, a wrong one does not.
    func testTheLogFormIsOfferedNoIntervalShapeForAMultiBlockRun() {
        let plan = makeBlockPlan()
        let model = ActiveWorkoutModel(store: store, defaults: defaults, audio: audio, watchLink: nil)

        model.start(plan: plan)

        let context = model.logDraftContext
        XCTAssertNil(context.run)
        XCTAssertNil(context.walk)
        XCTAssertEqual(context.planned, 4)

        model.cancel()
    }
}
