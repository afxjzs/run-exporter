import XCTest
@testable import RunExporter

/// Timing behaviour, driven by injected dates rather than by waiting on a real clock.
@MainActor
final class IntervalTimerEngineTests: XCTestCase {

    private var suiteName = ""
    private var settings: LoggerDefaults!

    override func setUp() {
        super.setUp()
        // A private suite so tests never read or write the user's real settings.
        suiteName = "IntervalTimerEngineTests.\(UUID().uuidString)"
        settings = LoggerDefaults(defaults: UserDefaults(suiteName: suiteName)!)
        settings.cueSource = .iphoneAudioEngine
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        settings = nil
        super.tearDown()
    }

    private func plan(run: Int = 60, walk: Int = 30, reps: Int = 3,
                      countdown: Int = 3,
                      cooldown: CooldownMode = .open) -> PlannedWorkout {
        PlannedWorkout(name: "test",
                       runIntervalSeconds: run,
                       walkIntervalSeconds: walk,
                       plannedRepetitions: reps,
                       cooldownMode: cooldown,
                       countdownSeconds: countdown)
    }

    /// A plan whose legs the runner ends. Its flat interval fields are zero, which is
    /// what `WorkoutPhaseSchedule.build` refuses by design — the engine has to read `shape` first.
    private func openIntervalPlan(target: Int = 1800,
                                   walkFloor: Int = 180,
                                   countdown: Int = 0) -> PlannedWorkout {
        let workout = PlannedWorkout(name: "signal threshold",
                                     runIntervalSeconds: 0,
                                     walkIntervalSeconds: 0,
                                     plannedRepetitions: 0,
                                     cooldownMode: .open,
                                     countdownSeconds: countdown)
        workout.openIntervalShape = OpenIntervalShape(targetRunSeconds: target,
                                                   walkFloorSeconds: walkFloor)
        return workout
    }

    /// Collects everything the engine emits so a whole workout can be asserted at once.
    private final class Recorder {
        var cues: [String] = []
        var intervals: [IntervalTimerEngine.RecordedInterval] = []
        var finished = false

        @MainActor
        func attach(to engine: IntervalTimerEngine) {
            engine.onCue = { [weak self] in self?.cues.append($0.identifier) }
            engine.onIntervalCompleted = { [weak self] in self?.intervals.append($0) }
            engine.onFinished = { [weak self] in self?.finished = true }
        }
    }

    // MARK: - Sequencing

    func testFullWorkoutProducesExpectedPhasesAndCues() throws {
        let engine = IntervalTimerEngine()
        let recorder = Recorder()
        recorder.attach(to: engine)

        let start = Date(timeIntervalSinceReferenceDate: 0)
        try engine.start(plan: plan(), settings: settings, now: start)

        // Countdown ticks fire one per second.
        engine.tick(now: start)
        engine.tick(now: start.addingTimeInterval(1))
        engine.tick(now: start.addingTimeInterval(2))
        XCTAssertEqual(recorder.cues, ["countdown_3", "countdown_2", "countdown_1"])

        // Cross every boundary of a 60/30 × 3 workout.
        var offset = 3.0
        for _ in 0..<5 {   // run, walk, run, walk, run
            engine.tick(now: start.addingTimeInterval(offset + 0.5))
            offset += (recorder.cues.last == "run") ? 60 : 30
            engine.tick(now: start.addingTimeInterval(offset))
        }

        XCTAssertTrue(recorder.cues.contains("run"))
        XCTAssertTrue(recorder.cues.contains("walk"))
        XCTAssertTrue(recorder.cues.contains("cooldown"),
                      "Cooldown must be announced after the final run")

        let phases = recorder.intervals.map(\.phase)
        XCTAssertEqual(phases, [.countdown, .run, .walk, .run, .walk, .run])
        XCTAssertEqual(engine.phase, .cooldown)
    }

    /// The core anti-drift property: boundaries chain off the planned end, not off "now".
    func testLateTickDoesNotShiftLaterBoundaries() throws {
        let engine = IntervalTimerEngine()
        let recorder = Recorder()
        recorder.attach(to: engine)

        let start = Date(timeIntervalSinceReferenceDate: 0)
        try engine.start(plan: plan(countdown: 0), settings: settings, now: start)

        // The run should end at t=60. Tick 7.4 seconds late.
        engine.tick(now: start.addingTimeInterval(67.4))

        let run = try XCTUnwrap(recorder.intervals.first { $0.phase == .run })
        XCTAssertEqual(run.end.timeIntervalSince(start), 60, accuracy: 0.0001,
                       "The run must end at its planned boundary, not when the tick arrived")
        XCTAssertEqual(run.actualSeconds, 60, accuracy: 0.0001)

        // The walk therefore started at t=60 and still ends at t=90.
        XCTAssertEqual(engine.phase, .walk)
        XCTAssertEqual(try XCTUnwrap(engine.phaseEndDate).timeIntervalSince(start), 90,
                       accuracy: 0.0001)
    }

    /// Waking up after several boundaries elapsed must not replay every missed cue.
    func testCatchUpAfterSuspensionDoesNotReplayCues() throws {
        let engine = IntervalTimerEngine()
        let recorder = Recorder()
        recorder.attach(to: engine)

        let start = Date(timeIntervalSinceReferenceDate: 0)
        try engine.start(plan: plan(countdown: 0), settings: settings, now: start)
        recorder.cues.removeAll()

        // Jump past run 1, walk 1 and run 2 in a single tick.
        engine.tick(now: start.addingTimeInterval(155))

        XCTAssertLessThanOrEqual(recorder.cues.count, 1,
                                 "Only the phase landed on may be announced, got \(recorder.cues)")

        // The skipped-over phases are still recorded, with accurate boundaries, and flagged.
        let missed = recorder.intervals.filter(\.wasInterrupted)
        XCTAssertFalse(missed.isEmpty, "Phases crossed while asleep must be flagged as interrupted")
        for interval in recorder.intervals where interval.plannedSeconds != nil {
            XCTAssertEqual(interval.actualSeconds,
                           Double(interval.plannedSeconds!),
                           accuracy: 0.0001,
                           "Boundaries stay exact even when no tick observed them")
        }
    }

    // MARK: - Pause

    /// Spec §25: a long pause must not shorten the interval it interrupted.
    func testPauseShiftsBoundaryByExactlyThePausedTime() throws {
        let engine = IntervalTimerEngine()
        let recorder = Recorder()
        recorder.attach(to: engine)

        let start = Date(timeIntervalSinceReferenceDate: 0)
        try engine.start(plan: plan(countdown: 0), settings: settings, now: start)

        engine.pause(now: start.addingTimeInterval(20))
        engine.resume(now: start.addingTimeInterval(320))   // paused for 5 minutes

        XCTAssertEqual(try XCTUnwrap(engine.phaseEndDate).timeIntervalSince(start), 360,
                       accuracy: 0.0001, "60s run paused for 300s must end at t=360")

        let pause = try XCTUnwrap(recorder.intervals.first { $0.phase == .paused })
        XCTAssertEqual(pause.actualSeconds, 300, accuracy: 0.0001)

        // The run itself still measures its full planned length.
        engine.tick(now: start.addingTimeInterval(360))
        let run = try XCTUnwrap(recorder.intervals.first { $0.phase == .run })
        XCTAssertEqual(run.actualSeconds, 60, accuracy: 0.0001)
    }

    // MARK: - Cooldown isolation

    /// Spec §26 Test 8: a very long open cooldown must stay out of the main set.
    func testLongOpenCooldownDoesNotContaminateMainSet() throws {
        let engine = IntervalTimerEngine()
        let recorder = Recorder()
        recorder.attach(to: engine)

        let start = Date(timeIntervalSinceReferenceDate: 0)
        try engine.start(plan: plan(run: 60, walk: 30, reps: 2, countdown: 0),
                         settings: settings, now: start)

        // run 60 + walk 30 + run 60 = 150s of main set.
        engine.tick(now: start.addingTimeInterval(150))
        XCTAssertEqual(engine.phase, .cooldown)

        // Five minutes walking, then a twenty-minute conversation, then finish.
        engine.tick(now: start.addingTimeInterval(150 + 300))
        engine.finishCooldown(now: start.addingTimeInterval(150 + 300 + 1200))

        let mainSet = recorder.intervals
            .filter { $0.phase.isMainSet }
            .reduce(0) { $0 + $1.actualSeconds }
        let cooldown = recorder.intervals
            .filter { $0.phase == .cooldown }
            .reduce(0) { $0 + $1.actualSeconds }

        XCTAssertEqual(mainSet, 150, accuracy: 0.0001,
                       "Main set must be exactly the run and walk intervals")
        XCTAssertEqual(cooldown, 1500, accuracy: 0.0001,
                       "The whole 25-minute cooldown is recorded, separately")
        XCTAssertTrue(recorder.finished)
    }

    // MARK: - Skip and completed count

    func testSkippedRunDoesNotCountAsCompleted() throws {
        let engine = IntervalTimerEngine()
        let recorder = Recorder()
        recorder.attach(to: engine)

        let start = Date(timeIntervalSinceReferenceDate: 0)
        try engine.start(plan: plan(countdown: 0), settings: settings, now: start)

        engine.skip(now: start.addingTimeInterval(10))    // abandons run 1

        XCTAssertEqual(engine.completedRunIntervals, 0)
        let run = try XCTUnwrap(recorder.intervals.first { $0.phase == .run })
        XCTAssertTrue(run.wasSkipped)
        XCTAssertEqual(run.actualSeconds, 10, accuracy: 0.0001)
    }

    func testCompletedRunsAreCounted() throws {
        // No recorder: this asserts the engine's own counter, not what it emits.
        let engine = IntervalTimerEngine()

        let start = Date(timeIntervalSinceReferenceDate: 0)
        try engine.start(plan: plan(countdown: 0), settings: settings, now: start)
        engine.tick(now: start.addingTimeInterval(150))   // through run 1, walk 1, run 2

        XCTAssertEqual(engine.completedRunIntervals, 2)
    }

    /// Ending during a pause must not fold the paused time into the interval.
    func testEndingWhilePausedExcludesPausedTime() throws {
        let engine = IntervalTimerEngine()
        let recorder = Recorder()
        recorder.attach(to: engine)

        let start = Date(timeIntervalSinceReferenceDate: 0)
        try engine.start(plan: plan(countdown: 0), settings: settings, now: start)

        engine.pause(now: start.addingTimeInterval(15))
        engine.end(now: start.addingTimeInterval(900))

        let run = try XCTUnwrap(recorder.intervals.first { $0.phase == .run })
        XCTAssertEqual(run.actualSeconds, 15, accuracy: 0.0001,
                       "The run stopped when the pause began, not when End was tapped")
    }

    // MARK: - Cue options

    func testFinalRoundAnnouncedOnLastRunOnly() throws {
        settings.finalRoundAnnouncement = true
        let engine = IntervalTimerEngine()
        let recorder = Recorder()
        recorder.attach(to: engine)

        let start = Date(timeIntervalSinceReferenceDate: 0)
        try engine.start(plan: plan(reps: 3, countdown: 0), settings: settings, now: start)
        // run1 0-60, walk1 60-90, run2 90-150, walk2 150-180, run3 starts at 180.
        engine.tick(now: start.addingTimeInterval(185))

        XCTAssertEqual(engine.currentRepetition, 3)
        XCTAssertEqual(recorder.cues.filter { $0 == "final_round" }.count, 1)
    }

    func testUnschedulablePlanThrowsInsteadOfStarting() {
        let engine = IntervalTimerEngine()
        let bad = plan()
        bad.cooldownMode = "nonsense"

        XCTAssertThrowsError(try engine.start(plan: bad, settings: settings))
        XCTAssertFalse(engine.isRunning)
    }

    // MARK: - Open-interval legs

    /// The first leg of an open-interval run is capped by the whole target: 30 minutes of running
    /// without the signal ever appearing is a finished workout, not a leg that runs forever.
    ///
    /// Reaching this at all means `start` read the plan's `shape` before trying to build a phase
    /// list, which is the thing `WorkoutPhaseSchedule.build` correctly refuses to do for a plan
    /// whose run interval is zero.
    func testStartingAnOpenIntervalPlanEntersALegCappedByTheTarget() throws {
        let engine = IntervalTimerEngine()
        let start = Date()

        try engine.start(plan: openIntervalPlan(target: 1800), settings: settings, now: start)

        XCTAssertEqual(engine.phase, .run)
        XCTAssertEqual(engine.phaseRemainingSeconds, 1800)
    }

    /// Ending a leg when the tracked signal appears is that leg's **normal completion**, not a skip.
    ///
    /// `skip()` is the obvious thing to reach for and would be wrong: it records `wasSkipped`, and
    /// `completeCurrentPhase` deliberately refuses to count a skipped run toward
    /// `completedRunIntervals`, on the grounds that "how many did I actually do?" must not be
    /// overstated. Under an open-interval plan every single leg ends by the owner's hand, so
    /// reusing skip would report a workout in which no leg was ever completed.
    func testEndingABoutAtOnsetRecordsACompletedRunNotASkip() throws {
        let engine = IntervalTimerEngine()
        let recorder = Recorder()
        recorder.attach(to: engine)
        let start = Date()

        try engine.start(plan: openIntervalPlan(), settings: settings, now: start)
        engine.endLeg(reason: .runnerEnded, now: start.addingTimeInterval(500))

        let leg = try XCTUnwrap(recorder.intervals.first { $0.phase == .run })
        XCTAssertFalse(leg.wasSkipped)
        XCTAssertEqual(leg.endReason, .runnerEnded)
        XCTAssertEqual(engine.completedRunIntervals, 1)
        XCTAssertEqual(engine.accumulatedRunSeconds, 500)
    }

    /// The leg's running counts toward the target, and what follows it is the recovery walk —
    /// open, because only the runner can say when the signal is back to baseline.
    func testALegIsFollowedByAnOpenRecoveryWalk() throws {
        let engine = IntervalTimerEngine()
        let start = Date()

        try engine.start(plan: openIntervalPlan(), settings: settings, now: start)
        engine.endLeg(reason: .runnerEnded, now: start.addingTimeInterval(500))

        XCTAssertEqual(engine.phase, .walk)
        XCTAssertNil(engine.phaseRemainingSeconds, "A recovery walk has no end the clock decides")
    }

    /// The walk has a number to show even though it has no end: how long until its floor.
    ///
    /// The run screen renders `phaseRemainingSeconds`, which an open walk does not have, so the
    /// largest number on the screen read "—" for the whole walk and the only countdown lived in the
    /// Start button's label. Asked for after the first outdoor run.
    func testAnOpenWalkCountsDownToItsFloor() throws {
        let engine = IntervalTimerEngine()
        let start = Date(timeIntervalSinceReferenceDate: 0)

        try engine.start(plan: openIntervalPlan(walkFloor: 180), settings: settings, now: start)
        engine.endLeg(reason: .runnerEnded, now: start.addingTimeInterval(500))
        XCTAssertEqual(engine.phase, .walk)

        engine.tick(now: start.addingTimeInterval(560))
        XCTAssertEqual(try XCTUnwrap(engine.walkFloorRemainingSeconds), 120, accuracy: 0.001)

        // At the floor it stops being a countdown, so the caller cannot render a stopped clock.
        engine.tick(now: start.addingTimeInterval(680))
        XCTAssertNil(engine.walkFloorRemainingSeconds)

        engine.tick(now: start.addingTimeInterval(740))
        XCTAssertNil(engine.walkFloorRemainingSeconds,
                     "Past the floor the walk is waiting on the runner, not on a clock")
    }

    /// A timed walk gets "3, 2, 1" on its way out; the floor used to arrive with no run-up at all,
    /// because every transition cue is gated on a `plannedSeconds` an open walk does not have.
    ///
    /// Also pins what must **not** be announced. The five-second warning names the phase that
    /// follows and says it is seconds away, which is false at a floor: the floor does not start the
    /// next leg, the runner does.
    func testTheWalkFloorArrivesWithACountdownButNoPromiseOfARun() throws {
        let engine = IntervalTimerEngine()
        let recorder = Recorder()
        recorder.attach(to: engine)
        let start = Date(timeIntervalSinceReferenceDate: 0)

        try engine.start(plan: openIntervalPlan(walkFloor: 180), settings: settings, now: start)
        engine.endLeg(reason: .runnerEnded, now: start.addingTimeInterval(500))

        // Walk out the floor a second at a time, so every scheduled cue has a tick to fire on.
        for offset in stride(from: 500.0, through: 682.0, by: 1.0) {
            engine.tick(now: start.addingTimeInterval(offset))
        }

        XCTAssertEqual(Array(recorder.cues.suffix(4)),
                       ["countdown_3", "countdown_2", "countdown_1", "recovery_floor_reached"],
                       "The floor must be counted down to, then announced")
        XCTAssertFalse(recorder.cues.contains { $0.hasPrefix("next_phase") },
                       "Nothing may promise a run the floor will not start")
    }

    /// A leg that ends because the target arrived has to say so.
    ///
    /// Its duration cannot: a 2:40 leg that ran out of target looks exactly like a 2:40 leg the
    /// runner ended, and telling those apart is the only reason `endReason` exists. This path does
    /// not go through `endLeg` — the clock crosses the boundary and the engine advances itself — so
    /// the reason has to be supplied there or the column is blank for every leg that ends this way.
    func testALegEndedByTheTargetSaysSo() throws {
        let engine = IntervalTimerEngine()
        let recorder = Recorder()
        recorder.attach(to: engine)
        let start = Date()

        // A one-minute target, so the first leg's cap is the whole of it.
        try engine.start(plan: openIntervalPlan(target: 60), settings: settings, now: start)
        engine.tick(now: start.addingTimeInterval(61))

        let leg = try XCTUnwrap(recorder.intervals.first { $0.phase == .run })
        XCTAssertEqual(leg.endReason, .targetReached)
        XCTAssertFalse(leg.wasSkipped)
    }

    /// The baseline tap records a moment inside the walk and does not end it.
    ///
    /// These are two different events, and the gap between them is the number the protocol exists
    /// to measure: the signal returns to baseline partway through, and the walk runs on to its floor
    /// and beyond. One tap
    /// meaning both would collapse them, and the recorded walk length would then just be the floor
    /// on every row.
    func testMarkingBaselineTimestampsTheWalkWithoutEndingIt() throws {
        let engine = IntervalTimerEngine()
        let recorder = Recorder()
        recorder.attach(to: engine)
        let start = Date()

        try engine.start(plan: openIntervalPlan(), settings: settings, now: start)
        engine.endLeg(reason: .runnerEnded, now: start.addingTimeInterval(500))

        let baseline = start.addingTimeInterval(570)
        engine.markBaseline(now: baseline)
        XCTAssertEqual(engine.phase, .walk, "The tap records a moment, it does not end the walk")

        engine.startNextLeg(now: start.addingTimeInterval(700))

        let walk = try XCTUnwrap(recorder.intervals.first { $0.phase == .walk })
        XCTAssertEqual(walk.baselineReachedAt, baseline)
        XCTAssertFalse(walk.wasSkipped, "Starting the next leg is the walk's normal completion")
        XCTAssertEqual(engine.phase, .run)
    }
}
