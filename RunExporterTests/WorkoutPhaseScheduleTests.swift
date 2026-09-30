import XCTest
@testable import RunExporter

/// The sequencing rules from spec §11.1, which everything else depends on being right.
final class WorkoutPhaseScheduleTests: XCTestCase {

    private func plan(run: Int = 240, walk: Int = 60, reps: Int = 5,
                      countdown: Int = 3,
                      warmup: WarmupMode = .none, warmupSeconds: Int? = nil,
                      cooldown: CooldownMode = .open, cooldownSeconds: Int? = nil,
                      finalWalk: Bool = false) -> PlannedWorkout {
        PlannedWorkout(name: "test",
                       warmupMode: warmup,
                       warmupSeconds: warmupSeconds,
                       runIntervalSeconds: run,
                       walkIntervalSeconds: walk,
                       plannedRepetitions: reps,
                       includesFinalWalk: finalWalk,
                       cooldownMode: cooldown,
                       cooldownSeconds: cooldownSeconds,
                       countdownSeconds: countdown)
    }

    /// The example the spec spells out: countdown, run/walk × 5 with no trailing walk, cooldown.
    func testFourOneByFiveMatchesSpecSequence() throws {
        let schedule = try WorkoutPhaseSchedule.build(from: plan())
        let phases = schedule.phases.map(\.phase)

        XCTAssertEqual(phases, [.countdown,
                                .run, .walk, .run, .walk, .run, .walk, .run, .walk, .run,
                                .cooldown])
    }

    func testFinalWalkIncludedWhenPlanAsksForIt() throws {
        let schedule = try WorkoutPhaseSchedule.build(from: plan(finalWalk: true))
        let phases = schedule.phases.map(\.phase)

        XCTAssertEqual(phases.filter { $0 == .walk }.count, 5)
        // Cooldown is last; the walk immediately precedes it.
        XCTAssertEqual(phases[phases.count - 2], .walk)
    }

    // MARK: - Blocks of differing shape

    /// Attaches blocks to a plan. Order is given by `orderIndex`, not array position, because the
    /// relationship comes back from SwiftData unordered.
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

    /// The shape the owner asked for and could not express: 5/1×1, then 8/1×2, then 5/1×1. The plan
    /// carried exactly one run/walk/reps triple, so every interval in a workout had to be identical.
    func testBlocksRunInOrderEachWithItsOwnDurations() throws {
        let workout = withBlocks([(300, 60, 1), (480, 60, 2), (300, 60, 1)],
                                 on: plan(countdown: 0))

        let schedule = try WorkoutPhaseSchedule.build(from: workout)

        XCTAssertEqual(schedule.phases.map(\.phase),
                       [.run, .walk, .run, .walk, .run, .walk, .run, .cooldown])
        XCTAssertEqual(schedule.phases.compactMap { $0.phase == .run ? $0.plannedSeconds : nil },
                       [300, 480, 480, 300])
    }

    /// "No walk after the final run" is a rule about the **workout**, not about each block. Applied
    /// per block it would strip the walk between blocks, silently welding 8:00 of running onto the
    /// end of the previous rep.
    func testTheWalkBetweenBlocksSurvivesAndOnlyTheLastOneIsDropped() throws {
        let workout = withBlocks([(300, 60, 1), (480, 60, 1)], on: plan(countdown: 0))

        let schedule = try WorkoutPhaseSchedule.build(from: workout)

        XCTAssertEqual(schedule.phases.map(\.phase), [.run, .walk, .run, .cooldown],
                       "the walk joining the two blocks must remain")
    }

    /// Rounds are numbered across the whole workout, so "Round 3 of 4" on the running screen still
    /// means something when the rounds are different lengths.
    func testRepetitionsAreNumberedContinuouslyAcrossBlocks() throws {
        let workout = withBlocks([(300, 60, 1), (480, 60, 2), (300, 60, 1)],
                                 on: plan(countdown: 0))

        let schedule = try WorkoutPhaseSchedule.build(from: workout)

        XCTAssertEqual(schedule.totalRepetitions, 4)
        XCTAssertEqual(schedule.phases.compactMap { $0.phase == .run ? $0.repetition : nil },
                       [1, 2, 3, 4])
    }

    /// Main set adds up across blocks: 5 + 8 + 8 + 5 running, three 1:00 walks between them.
    func testMainSetSecondsSumsEveryBlock() throws {
        let workout = withBlocks([(300, 60, 1), (480, 60, 2), (300, 60, 1)],
                                 on: plan(countdown: 0))

        let schedule = try WorkoutPhaseSchedule.build(from: workout)

        XCTAssertEqual(schedule.mainSetSeconds, 300 + 480 + 480 + 300 + (60 * 3))
        XCTAssertEqual(workout.mainSetSeconds, schedule.mainSetSeconds,
                       "the plan and the schedule must never disagree about the main set")
    }

    /// A plan with no blocks is the ordinary case and must behave exactly as it did before blocks
    /// existed — that is what makes this change need no migration.
    func testAPlanWithNoBlocksStillUsesItsFlatShape() throws {
        let schedule = try WorkoutPhaseSchedule.build(from: plan(countdown: 0))

        XCTAssertEqual(schedule.phases.map(\.phase),
                       [.run, .walk, .run, .walk, .run, .walk, .run, .walk, .run, .cooldown])
        XCTAssertEqual(schedule.totalRepetitions, 5)
        XCTAssertEqual(schedule.mainSetSeconds, 24 * 60)
    }

    func testContinuousWorkoutHasNoWalks() throws {
        let schedule = try WorkoutPhaseSchedule.build(from: plan(run: 1200, walk: 0, reps: 1))
        XCTAssertEqual(schedule.phases.map(\.phase), [.countdown, .run, .cooldown])
    }

    func testCountdownOffOmitsCountdownPhase() throws {
        let schedule = try WorkoutPhaseSchedule.build(from: plan(countdown: 0))
        XCTAssertFalse(schedule.phases.contains { $0.phase == .countdown })
    }

    func testOpenCooldownHasNoPlannedDuration() throws {
        let schedule = try WorkoutPhaseSchedule.build(from: plan())
        let cooldown = try XCTUnwrap(schedule.phases.last)
        XCTAssertEqual(cooldown.phase, .cooldown)
        XCTAssertTrue(cooldown.isOpen)
    }

    func testTimedWarmupAndCooldownAreIncluded() throws {
        let schedule = try WorkoutPhaseSchedule.build(
            from: plan(warmup: .timed, warmupSeconds: 300,
                       cooldown: .timed, cooldownSeconds: 600))

        XCTAssertEqual(schedule.phases[1].phase, .warmup)
        XCTAssertEqual(schedule.phases[1].plannedSeconds, 300)
        XCTAssertEqual(schedule.phases.last?.plannedSeconds, 600)
        // Warmup and cooldown must not inflate the main set.
        XCTAssertEqual(schedule.mainSetSeconds, 24 * 60)
    }

    func testNoCooldownEndsAfterFinalRun() throws {
        let schedule = try WorkoutPhaseSchedule.build(from: plan(cooldown: .none))
        XCTAssertEqual(schedule.phases.last?.phase, .run)
    }

    func testIsFinalRunIdentifiesLastRunOnly() throws {
        let schedule = try WorkoutPhaseSchedule.build(from: plan())
        let runIndices = schedule.phases.filter { $0.phase == .run }.map(\.index)

        for index in runIndices.dropLast() {
            XCTAssertFalse(schedule.isFinalRun(at: index))
        }
        XCTAssertTrue(schedule.isFinalRun(at: runIndices.last!))
    }

    // MARK: - Refusing malformed plans

    func testUnknownWarmupModeThrowsRatherThanDefaulting() {
        let bad = plan()
        bad.warmupMode = "sprint-first"

        XCTAssertThrowsError(try WorkoutPhaseSchedule.build(from: bad)) { error in
            XCTAssertEqual(error as? WorkoutPhaseSchedule.ScheduleError,
                           .unknownWarmupMode("sprint-first"))
        }
    }

    func testUnknownCooldownModeThrows() {
        let bad = plan()
        bad.cooldownMode = "vibes"

        XCTAssertThrowsError(try WorkoutPhaseSchedule.build(from: bad)) { error in
            XCTAssertEqual(error as? WorkoutPhaseSchedule.ScheduleError,
                           .unknownCooldownMode("vibes"))
        }
    }

    func testTimedWarmupWithoutDurationThrows() {
        XCTAssertThrowsError(
            try WorkoutPhaseSchedule.build(from: plan(warmup: .timed, warmupSeconds: nil))
        ) { error in
            XCTAssertEqual(error as? WorkoutPhaseSchedule.ScheduleError, .missingWarmupDuration)
        }
    }

    func testZeroRunIntervalThrows() {
        XCTAssertThrowsError(try WorkoutPhaseSchedule.build(from: plan(run: 0))) { error in
            XCTAssertEqual(error as? WorkoutPhaseSchedule.ScheduleError, .nonPositiveRunInterval(0))
        }
    }

    // MARK: - Validation reads the blocks, not the flat fields

    /// A block that runs for no time is rejected rather than scheduled.
    ///
    /// The guards used to read `plan.runIntervalSeconds`, which for a multi-block plan describes
    /// only the first block. A second block of 0 seconds passed validation and reached
    /// `expandedIntervals`, which happily produced a 0-second run phase for the timer to run.
    func testABlockWithNoRunTimeIsRejected() {
        let workout = withBlocks([(300, 60, 1), (0, 60, 2)], on: plan())

        XCTAssertThrowsError(try WorkoutPhaseSchedule.build(from: workout)) { error in
            XCTAssertEqual(error as? WorkoutPhaseSchedule.ScheduleError, .nonPositiveRunInterval(0))
        }
    }

    /// A block with no repetitions is rejected rather than silently dropped.
    ///
    /// `expandedIntervals` skips a block whose `repetitions` is not positive, so this would not
    /// crash or misbehave — it would quietly run a different workout than the plan describes,
    /// which is worse.
    func testABlockWithNoRepetitionsIsRejected() {
        let workout = withBlocks([(300, 60, 1), (480, 60, 0)], on: plan())

        XCTAssertThrowsError(try WorkoutPhaseSchedule.build(from: workout)) { error in
            XCTAssertEqual(error as? WorkoutPhaseSchedule.ScheduleError, .nonPositiveRepetitions(0))
        }
    }

    /// The stored blocks are the authority on a plan's shape. The flat fields are a description of
    /// a single-block plan and say nothing about a plan that carries blocks of its own.
    func testBlocksAreValidatedRatherThanTheFlatFields() throws {
        let workout = withBlocks([(300, 60, 1), (480, 60, 2)],
                                 on: plan(run: 0, walk: 0, reps: 0, countdown: 0))

        let schedule = try WorkoutPhaseSchedule.build(from: workout)

        XCTAssertEqual(schedule.phases.map(\.phase),
                       [.run, .walk, .run, .walk, .run, .cooldown])
        XCTAssertEqual(schedule.totalRepetitions, 3)
    }

    // MARK: - Presets must produce runnable plans

    /// Regression test.
    ///
    /// A preset created while the default cooldown mode is `timed` previously carried no
    /// duration, because `makeWorkout` never passed one. The plan saved cleanly and then failed
    /// at the start line with "timed cooldown but no duration" — a mistake made in Settings that
    /// only surfaced when the user tried to run.
    func testEveryPresetIsSchedulableUnderEveryCooldownDefault() throws {
        let suiteName = "PresetScheduleTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        for mode in CooldownMode.allCases {
            let defaults = LoggerDefaults(defaults: suite)
            defaults.cooldownMode = mode

            for preset in PlannedWorkoutPreset.all {
                let plan = preset.makeWorkout(defaults: defaults)
                XCTAssertNoThrow(try WorkoutPhaseSchedule.build(from: plan),
                                 "\(preset.name) is not runnable with cooldown \(mode.rawValue)")
            }
        }
    }

    /// A timed cooldown default must carry its length into the plan.
    func testTimedCooldownDefaultSuppliesADuration() throws {
        let suiteName = "PresetCooldownTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let defaults = LoggerDefaults(defaults: suite)
        defaults.cooldownMode = .timed
        defaults.defaultCooldownSeconds = 300

        let plan = try XCTUnwrap(PlannedWorkoutPreset.all.first).makeWorkout(defaults: defaults)

        XCTAssertEqual(plan.cooldownSeconds, 300)
        let schedule = try WorkoutPhaseSchedule.build(from: plan)
        XCTAssertEqual(schedule.phases.last?.plannedSeconds, 300)
    }

    /// Open and none cooldowns must stay duration-free — a stray value would be misleading.
    func testNonTimedCooldownDefaultsCarryNoDuration() throws {
        let suiteName = "PresetOpenTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        for mode in [CooldownMode.open, .none] {
            let defaults = LoggerDefaults(defaults: suite)
            defaults.cooldownMode = mode
            let plan = try XCTUnwrap(PlannedWorkoutPreset.all.first).makeWorkout(defaults: defaults)
            XCTAssertNil(plan.cooldownSeconds, "\(mode.rawValue) must not carry a duration")
        }
    }

    func testZeroRepetitionsThrows() {
        XCTAssertThrowsError(try WorkoutPhaseSchedule.build(from: plan(reps: 0))) { error in
            XCTAssertEqual(error as? WorkoutPhaseSchedule.ScheduleError, .nonPositiveRepetitions(0))
        }
    }
}
