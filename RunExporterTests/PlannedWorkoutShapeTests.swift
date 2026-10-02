import XCTest
@testable import RunExporter

/// How a plan describes and copies its own shape.
///
/// Both of these read the flat `runIntervalSeconds` / `walkIntervalSeconds` / `plannedRepetitions`
/// fields historically, which is correct only while every interval in a workout is identical. A
/// plan that says `5/1×1 → 8/1×2 → 5/1×1` and renders as "5/1 × 1" is not a cosmetic bug: it is the
/// app doing one thing and saying another, which is the failure mode this project is built around.
final class PlannedWorkoutShapeTests: XCTestCase {

    private func plan(run: Int = 240, walk: Int = 60, reps: Int = 5,
                      name: String = "4/1 × 5") -> PlannedWorkout {
        PlannedWorkout(name: name,
                       runIntervalSeconds: run,
                       walkIntervalSeconds: walk,
                       plannedRepetitions: reps)
    }

    /// Order comes from `orderIndex`, never array position — the relationship is unordered.
    private func withBlocks(_ shapes: [(run: Int, walk: Int, reps: Int)],
                            on workout: PlannedWorkout) -> PlannedWorkout {
        workout.blocks = shapes.enumerated().map { index, shape in
            PlannedWorkoutBlock(orderIndex: index,
                                runIntervalSeconds: shape.run,
                                walkIntervalSeconds: shape.walk,
                                repetitions: shape.reps)
        }
        return workout
    }

    // MARK: - intervalSummary

    /// The shape the owner asked for. Every block is named, in order, so the row on the plan list
    /// says what the workout will actually do.
    func testMultiBlockSummaryNamesEveryBlockInOrder() {
        let workout = withBlocks([(300, 60, 1), (480, 60, 2), (300, 60, 1)], on: plan())

        XCTAssertEqual(workout.intervalSummary, "5/1×1 · 8/1×2 · 5/1×1")
    }

    /// Blocks are ordered by `orderIndex`, and SwiftData hands the relationship back unordered, so
    /// the summary must sort rather than trust array position.
    func testMultiBlockSummaryFollowsOrderIndexNotArrayPosition() {
        let workout = plan()
        workout.blocks = [
            PlannedWorkoutBlock(orderIndex: 2, runIntervalSeconds: 300,
                                walkIntervalSeconds: 60, repetitions: 1),
            PlannedWorkoutBlock(orderIndex: 0, runIntervalSeconds: 300,
                                walkIntervalSeconds: 60, repetitions: 1),
            PlannedWorkoutBlock(orderIndex: 1, runIntervalSeconds: 480,
                                walkIntervalSeconds: 60, repetitions: 2),
        ]

        XCTAssertEqual(workout.intervalSummary, "5/1×1 · 8/1×2 · 5/1×1")
    }

    /// An ordinary plan is unchanged. This is what makes blocks need no migration: a plan with no
    /// stored blocks is a one-block plan, and must read exactly as it always has.
    func testSingleShapePlanSummaryIsUnchanged() {
        XCTAssertEqual(plan().intervalSummary, "4/1 × 5")
        XCTAssertEqual(plan(run: 1200, walk: 0, reps: 1).intervalSummary, "20 continuous")
    }

    /// A block with no recovery walk is written without one rather than as "8/0×2".
    func testBlockWithoutAWalkOmitsIt() {
        let workout = withBlocks([(480, 0, 2), (300, 60, 1)], on: plan())

        XCTAssertEqual(workout.intervalSummary, "8×2 · 5/1×1")
    }

    /// A single round that ends with a walk is not continuous, and must not say it is.
    ///
    /// `expandedIntervals` appends that walk when `includesFinalWalk` is set — spec §11.1 drops the
    /// walk after the workout's final run *unless the plan asks for it*. The summary could not see
    /// that flag, so it called the plan continuous while it ran a minute of walking. Its sibling
    /// `mainSetSeconds(blocks:includesFinalWalk:)` had the flag all along.
    func testASingleRoundEndingInAWalkIsNotCalledContinuous() {
        let workout = plan(run: 300, walk: 60, reps: 1)
        workout.includesFinalWalk = true

        XCTAssertEqual(workout.expandedIntervals.count, 2, "it really does run a walk")
        XCTAssertEqual(workout.intervalSummary, "5/1 × 1")
    }

    /// Without that flag the same plan genuinely is continuous: the walk after the final run is
    /// dropped, and with one round that is the only run.
    func testASingleRoundWithoutAFinalWalkStillReadsAsContinuous() {
        let workout = plan(run: 300, walk: 60, reps: 1)

        XCTAssertEqual(workout.expandedIntervals.count, 1)
        XCTAssertEqual(workout.intervalSummary, "5 continuous")
    }

    // MARK: - Previewing a shape that has not been saved yet

    /// A shape with nothing in it names nothing, rather than being given a plausible name.
    func testAnEmptyShapeHasNoName() {
        XCTAssertEqual(PlannedWorkout.summary(blocks: [], includesFinalWalk: false), "")
    }

    /// The main set the editor shows for blocks the user is still assembling, pinned to a literal.
    ///
    /// As above, the comparison against `saved.mainSetSeconds` is the weaker half: both sides run
    /// through `expandedIntervals(blocks:includesFinalWalk:)`, so it can only fail if
    /// `resolvedBlocks` is wrong. The 1740 is what pins the arithmetic.
    func testTheMainSetPreviewAgreesWithTheSavedPlan() {
        let shapes = [PlannedWorkout.Block(runSeconds: 300, walkSeconds: 60, repetitions: 1),
                      PlannedWorkout.Block(runSeconds: 480, walkSeconds: 60, repetitions: 2),
                      PlannedWorkout.Block(runSeconds: 300, walkSeconds: 60, repetitions: 1)]
        let saved = withBlocks([(300, 60, 1), (480, 60, 2), (300, 60, 1)], on: plan())

        let preview = PlannedWorkout.mainSetSeconds(blocks: shapes, includesFinalWalk: false)

        XCTAssertEqual(preview, saved.mainSetSeconds)
        // 5 + 8 + 8 + 5 running, three 1:00 walks between them.
        XCTAssertEqual(preview, 1740)
    }

    /// Including the final walk adds exactly one more walk, in the preview as in the plan.
    func testTheMainSetPreviewHonoursTheFinalWalk() {
        let shapes = [PlannedWorkout.Block(runSeconds: 300, walkSeconds: 60, repetitions: 1),
                      PlannedWorkout.Block(runSeconds: 480, walkSeconds: 60, repetitions: 2)]
        let saved = withBlocks([(300, 60, 1), (480, 60, 2)], on: plan())
        saved.includesFinalWalk = true

        let preview = PlannedWorkout.mainSetSeconds(blocks: shapes, includesFinalWalk: true)

        XCTAssertEqual(preview, saved.mainSetSeconds)
        XCTAssertEqual(preview, 300 + 480 + 480 + 180)
    }

    // MARK: - A shape that was destroyed rather than authored

    /// The state a downgrade leaves behind: block rows dropped from the store, flat fields still
    /// zeroed. Measured in LEARNINGS.md — SwiftData drops the table without erroring.
    private func damagedPlan() -> PlannedWorkout {
        plan(run: 0, walk: 0, reps: 0)
    }

    /// It must not read as a workout. Rendering "0 continuous" would describe a real plan that runs
    /// for no time, which is a claim, not a blank.
    func testADamagedPlanSaysSoRatherThanReadingAsZero() {
        let workout = damagedPlan()

        XCTAssertTrue(workout.hasDamagedShape)
        XCTAssertEqual(workout.intervalSummary, PlannedWorkout.damagedShapeSummary)
        XCTAssertNotEqual(workout.intervalSummary, "0 continuous")
    }

    /// And an ordinary plan is never mistaken for a damaged one.
    func testARunnablePlanIsNotReportedAsDamaged() {
        XCTAssertFalse(plan().hasDamagedShape)
        XCTAssertFalse(withBlocks([(300, 60, 1), (480, 60, 2)], on: plan()).hasDamagedShape)
        XCTAssertFalse(plan(run: 1200, walk: 0, reps: 1).hasDamagedShape,
                       "a continuous run has no walk, which is not damage")
    }

    // MARK: - duplicate

    /// Duplicating a multi-block plan must reproduce the workout, not flatten it to its first
    /// block. Both screens that duplicate a plan built the copy from the flat fields alone.
    func testDuplicateReproducesEveryBlockInOrder() {
        let workout = withBlocks([(300, 60, 1), (480, 60, 2), (300, 60, 1)], on: plan())

        let copy = workout.duplicate()

        XCTAssertEqual(copy.resolvedBlocks, workout.resolvedBlocks)
        XCTAssertEqual(copy.intervalSummary, "5/1×1 · 8/1×2 · 5/1×1")
        XCTAssertEqual(copy.name, "4/1 × 5 copy")
    }

    /// The copy must own new block records. Assigning the originals would re-parent them through
    /// the inverse relationship and strip the plan being copied.
    func testDuplicateLeavesTheOriginalIntact() {
        let workout = withBlocks([(300, 60, 1), (480, 60, 2)], on: plan())

        let copy = workout.duplicate()

        XCTAssertEqual(workout.blocks.count, 2, "the original keeps its own blocks")
        XCTAssertEqual(workout.intervalSummary, "5/1×1 · 8/1×2")
        XCTAssertTrue(copy.blocks.allSatisfy { block in
            !workout.blocks.contains { $0 === block }
        }, "the copy must hold new block records, not the original's")
    }

    /// A copy is not queued for the Watch and is not the next workout.
    ///
    /// `workoutKitIdentifier` especially: it names an entry in this iPhone's workout queue, and
    /// deleting a plan removes whatever it names. A copy carrying the original's identifier would
    /// mean deleting the copy clears the original's queue entry.
    func testDuplicateCarriesNoQueueEntryAndIsNotNext() {
        let workout = plan()
        workout.workoutKitIdentifier = UUID().uuidString
        workout.isNextWorkout = true

        let copy = workout.duplicate()

        XCTAssertNil(copy.workoutKitIdentifier)
        XCTAssertFalse(copy.isNextWorkout)
    }

    /// Everything that describes the workout itself does carry over.
    func testDuplicateKeepsTheRestOfThePlan() {
        let workout = plan()
        workout.warmupMode = WarmupMode.timed.rawValue
        workout.warmupSeconds = 300
        workout.cooldownMode = CooldownMode.timed.rawValue
        workout.cooldownSeconds = 600
        workout.includesFinalWalk = true
        workout.countdownSeconds = 3
        workout.activityType = PlannedActivityType.walking.rawValue

        let copy = workout.duplicate()

        XCTAssertEqual(copy.warmupModeValue, WarmupMode.timed)
        XCTAssertEqual(copy.warmupSeconds, 300)
        XCTAssertEqual(copy.cooldownModeValue, CooldownMode.timed)
        XCTAssertEqual(copy.cooldownSeconds, 600)
        XCTAssertTrue(copy.includesFinalWalk)
        XCTAssertEqual(copy.countdownSeconds, 3)
        XCTAssertEqual(copy.activityTypeValue, PlannedActivityType.walking)
    }

    /// An open-interval plan's shape lives in `openIntervalShape`, not in `blocks`, and its flat
    /// fields are zero by design. Copying the blocks alone hands back a plan whose `shape` is
    /// `.damaged`: the copy sits on the plan list telling its owner to restore it from an export.
    /// Neither Duplicate button is hidden for open-interval plans.
    func testDuplicatingAnOpenIntervalPlanKeepsItOpen() {
        let workout = plan(run: 0, walk: 0, reps: 0)
        workout.openIntervalShape = OpenIntervalShape(targetRunSeconds: 1800, walkFloorSeconds: 180)

        let copy = workout.duplicate()

        XCTAssertEqual(copy.shape, .openIntervals(target: 1800, walkFloor: 180))
        XCTAssertFalse(copy.openIntervalShape === workout.openIntervalShape,
                       "the copy must hold a new record; the original's would be re-parented away")
        XCTAssertEqual(workout.shape, .openIntervals(target: 1800, walkFloor: 180),
                       "the original keeps its shape")
    }

    // MARK: - Nothing invented

    /// `resolvedBlocks` used to synthesize a block from the flat fields whenever a plan stored
    /// none — `0/0×0` for an open-interval or damaged plan. Nine readers turned that block into
    /// exported and displayed zeros. A plan the flat fields do not describe has no blocks.
    func testAPlanTheFlatFieldsDoNotDescribeHasNoBlocks() {
        let notSet = PlannedWorkout(name: "lost", runIntervalSeconds: nil,
                                    walkIntervalSeconds: nil, plannedRepetitions: nil)
        XCTAssertEqual(notSet.resolvedBlocks, [])
        XCTAssertEqual(notSet.shape, .damaged, "nothing describes it: the data-loss alarm")

        // A store not yet repaired still holds zeros; they describe nothing either.
        XCTAssertEqual(plan(run: 0, walk: 0, reps: 0).resolvedBlocks, [])
    }

    /// What an open-interval plan decides in advance is its running target and its walk floor.
    /// How long its walks add up to, its main set, its total and its rounds are not known until
    /// it is run, and a number for any of them would be invented.
    func testAnOpenPlanAnswersOnlyWhatItDecidesInAdvance() {
        let workout = PlannedWorkout(name: "Run to 30 min", runIntervalSeconds: nil,
                                     walkIntervalSeconds: nil, plannedRepetitions: nil)
        workout.openIntervalShape = OpenIntervalShape(targetRunSeconds: 1800, walkFloorSeconds: 180)

        XCTAssertEqual(workout.totalRunSeconds, 1800)
        XCTAssertNil(workout.totalWalkSeconds)
        XCTAssertNil(workout.mainSetSeconds)
        XCTAssertNil(workout.expectedTotalSeconds)
        XCTAssertNil(workout.totalRepetitions)
        XCTAssertNil(workout.walkIntervalCount)
    }

    // MARK: - shape

    /// A open-interval plan has no run interval and no known leg count — which is precisely the
    /// state `hasDamagedShape` reports as destroyed data. Read through `shape` it has to come back
    /// as a plan in its own right, or a healthy new plan tells its owner to restore from an export
    /// and the warning that guards real data loss stops meaning anything.
    func testBackThresholdPlanIsNotMistakenForADamagedPlan() {
        let workout = plan(run: 0, walk: 0, reps: 0)
        workout.openIntervalShape = OpenIntervalShape(targetRunSeconds: 1800, walkFloorSeconds: 180)

        guard case .openIntervals(let target, let walkFloor) = workout.shape else {
            return XCTFail("Expected .openIntervals, got \(workout.shape)")
        }

        XCTAssertEqual(target, 1800)
        XCTAssertEqual(walkFloor, 180)
    }

    /// The plan list reads `intervalSummary`, which asks `hasDamagedShape` first. An open-interval
    /// plan satisfies that predicate by construction, so without routing the summary through
    /// `shape` the owner's healthy new plan sits in the list telling him to restore it from an
    /// export. A UI string that promises the wrong thing is a bug here, not a nit.
    func testBackThresholdPlanSummaryDescribesItRatherThanClaimingDamage() {
        let workout = plan(run: 0, walk: 0, reps: 0)
        workout.openIntervalShape = OpenIntervalShape(targetRunSeconds: 1800, walkFloorSeconds: 180)

        XCTAssertEqual(workout.intervalSummary, "Run to 30 min · 3 min walks")
    }

    /// `hasDamagedShape` is this app's data-loss alarm: it raises the warning on the plan list
    /// (`HomeView`) and blanks three columns in the export. An open-interval plan satisfies its
    /// predicate exactly — no run interval, no repetitions — so unless it too is answered from
    /// `shape`, every healthy open-interval plan trips the alarm. An alarm that cries wolf stops
    /// protecting the thing it exists to guard, which here is silent destruction of block plans.
    func testAnOpenIntervalPlanIsNotReportedAsDamaged() {
        let workout = plan(run: 0, walk: 0, reps: 0)
        workout.openIntervalShape = OpenIntervalShape(targetRunSeconds: 1800,
                                                      walkFloorSeconds: 180)

        XCTAssertFalse(workout.hasDamagedShape)
    }

    private func openIntervalPlan(target: Int = 1800, walkFloor: Int = 180) -> PlannedWorkout {
        let workout = plan(run: 0, walk: 0, reps: 0)
        workout.openIntervalShape = OpenIntervalShape(targetRunSeconds: target,
                                                      walkFloorSeconds: walkFloor)
        return workout
    }

    /// `singleShape` answers "does this plan have one run length and one walk length, and what are
    /// they?" An open-interval plan has neither, so the answer is nil — the same answer a
    /// multi-block plan gives. Reading the flat fields instead hands back a `0/0` block, and
    /// `HomeView` renders exactly that on the plan card.
    func testAnOpenIntervalPlanHasNoSingleShape() {
        XCTAssertNil(openIntervalPlan().singleShape)
    }

    /// `blockShapeDescriptor` is copied onto every timer session so a later edit cannot rewrite
    /// what was actually run. For an open-interval plan the flat fields would write `0/0x0`, which
    /// is the exact string a destroyed block plan writes — the record would describe the run as
    /// data loss.
    func testAnOpenIntervalPlanDescribesItsShapeRatherThanWritingZeroes() {
        XCTAssertEqual(openIntervalPlan().blockShapeDescriptor, "open:1800/180")
    }

    /// The planned running time of an open-interval plan is its target. That number is known in
    /// advance — it is the one thing the plan does decide — and exporting `0` for it would report
    /// no running planned for a workout defined by thirty minutes of it.
    func testAnOpenIntervalPlanPlansItsTargetOfRunning() {
        XCTAssertEqual(openIntervalPlan().totalRunSeconds, 1800)
    }

    /// A new plan starts with the Settings countdown, open-interval plans included (BACKLOG
    /// Decision 12: the Watch usually connects within it). Found by review: the open-interval editor
    /// built its plan without one, so every new open-interval plan started with no countdown.
    func testANewOpenIntervalPlanStartsWithTheSettingsCountdown() {
        let suiteName = "PlannedWorkoutShapeTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let defaults = LoggerDefaults(defaults: suite)
        defaults.countdownSeconds = 5

        let workout = PlannedWorkout.newOpenIntervalPlan(name: "Open", defaults: defaults)

        XCTAssertEqual(workout.countdownSeconds, 5)
    }
}
