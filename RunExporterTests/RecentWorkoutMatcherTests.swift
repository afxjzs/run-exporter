import XCTest
@testable import RunExporter

/// Matching a finished HealthKit workout to a planned execution (spec §14).
///
/// The behaviour under test that matters most is the *refusal* to guess: a log attached to the
/// wrong workout is silently wrong forever.
final class RecentWorkoutMatcherTests: XCTestCase {

    private let base = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func workout(offsetMinutes: Double,
                         duration: TimeInterval = 1_500,
                         activity: PlannedActivityType = .running,
                         uuid: UUID = UUID()) -> HealthKitManager.WorkoutSummary {
        let start = base.addingTimeInterval(offsetMinutes * 60)
        return HealthKitManager.WorkoutSummary(
            uuid: uuid,
            activityType: activity,
            startDate: start,
            endDate: start.addingTimeInterval(duration),
            duration: duration,
            distanceMiles: 2.0,
            averageHeartRate: 150,
            peakHeartRate: 170,
            temperatureFahrenheit: 72,
            humidityPercent: 59,
            sourceName: "Apple Watch",
            hasWeatherMetadata: true,
            isIndoor: false,
            metadataKeys: ["HKWeatherTemperature"],
            isReclassifiedAsRunning: false)
    }

    private func candidate(duration: Int = 1_500,
                           activity: PlannedActivityType = .running,
                           createdOffsetMinutes: Double = 0,
                           timerStartedOffsetMinutes: Double? = nil,
                           timerEndedOffsetMinutes: Double? = nil) -> RecentWorkoutMatcher.Candidate {
        RecentWorkoutMatcher.Candidate(executionID: UUID(),
                                       plannedWorkoutID: UUID(),
                                       plannedWorkoutName: "4/1 × 5",
                                       expectedActivityType: activity,
                                       expectedDurationSeconds: duration,
                                       createdAt: base.addingTimeInterval(createdOffsetMinutes * 60),
                                       timerStartedAt: timerStartedOffsetMinutes
                                           .map { base.addingTimeInterval($0 * 60) },
                                       timerEndedAt: timerEndedOffsetMinutes
                                           .map { base.addingTimeInterval($0 * 60) })
    }

    func testSingleNearbyWorkoutMatches() {
        let target = workout(offsetMinutes: 2)
        let execution = candidate()

        let outcome = RecentWorkoutMatcher.match(workouts: [target], execution: execution)

        XCTAssertEqual(outcome, .matched(workoutUUID: target.uuid,
                                         executionID: execution.executionID))
    }

    func testWorkoutOutsideTimeWindowIsNotMatched() {
        let far = workout(offsetMinutes: 600)   // ten hours later

        let outcome = RecentWorkoutMatcher.match(workouts: [far], execution: candidate())

        XCTAssertEqual(outcome, .noCandidates)
    }

    /// A run that missed the window by a minute is a *diagnosable* miss, and must not be reported
    /// as the same nothing a phone-only run produces.
    ///
    /// The distinction is the whole point: told "no workout found", the user waits for a sync that
    /// will never help, because the reverse direction applies this same gate forever.
    func testAWorkoutJustOutsideTheWindowIsOfferedAsANearMiss() {
        let justOutside = workout(offsetMinutes: 3)

        let outcome = RecentWorkoutMatcher.match(workouts: [justOutside], execution: candidate())

        XCTAssertEqual(outcome, .outsideWindow(workoutUUIDs: [justOutside.uuid],
                                               closestOffsetSeconds: 180))
    }

    /// Nearest first, so the caller can offer one workout rather than a list.
    func testNearMissesAreOrderedByHowFarOutTheyAre() {
        let nearer = workout(offsetMinutes: 4)
        let further = workout(offsetMinutes: 20)

        let outcome = RecentWorkoutMatcher.match(workouts: [further, nearer],
                                                 execution: candidate())

        XCTAssertEqual(outcome, .outsideWindow(workoutUUIDs: [nearer.uuid, further.uuid],
                                               closestOffsetSeconds: 240))
    }

    /// The near miss inherits the activity rule rather than relaxing it. Offering a walk as the
    /// planned run would invite exactly the confirmation this file refuses to make on its own.
    func testANearMissIsNeverClaimedForTheWrongActivity() {
        let walk = workout(offsetMinutes: 3, activity: .walking)

        let outcome = RecentWorkoutMatcher.match(workouts: [walk], execution: candidate())

        XCTAssertEqual(outcome, .noCandidates)
    }

    /// Bounded, so yesterday's run is never proposed as the one just finished.
    func testAWorkoutBeyondTheNearMissBoundIsNotOffered() {
        let tooFar = workout(offsetMinutes: 91)

        let outcome = RecentWorkoutMatcher.match(workouts: [tooFar], execution: candidate())

        XCTAssertEqual(outcome, .noCandidates)
    }

    /// Activity type outranks timing: a walk is never the run that was planned.
    func testWrongActivityTypeIsNotSilentlyMatched() {
        let walk = workout(offsetMinutes: 1, activity: .walking)

        let outcome = RecentWorkoutMatcher.match(workouts: [walk],
                                                 execution: candidate(activity: .running))

        if case .matched = outcome {
            XCTFail("A walk must not be matched to a planned run without asking, got \(outcome)")
        }
    }

    func testCorrectActivityIsPreferredOverCloserTiming() {
        let closerWalk = workout(offsetMinutes: 0, activity: .walking)
        // 1.5 minutes, not 8: the eligibility window is 2 minutes, and a run outside it is excluded
        // before activity preference is ever consulted. The point of this test is that the *correct
        // activity* beats *closer timing*, so both have to be eligible for the comparison to mean
        // anything.
        let run = workout(offsetMinutes: 1.5, activity: .running)

        let outcome = RecentWorkoutMatcher.match(workouts: [closerWalk, run],
                                                 execution: candidate(activity: .running))

        if case .matched(let uuid, _) = outcome {
            XCTAssertEqual(uuid, run.uuid)
        } else {
            XCTFail("Expected the running workout to match, got \(outcome)")
        }
    }

    /// Two equally plausible workouts must produce a question, not a coin flip.
    func testTwoSimilarWorkoutsAreAmbiguous() {
        let first = workout(offsetMinutes: 1, duration: 1_500)
        let second = workout(offsetMinutes: 2, duration: 1_505)

        let outcome = RecentWorkoutMatcher.match(workouts: [first, second],
                                                 execution: candidate())

        guard case .ambiguous(let uuids) = outcome else {
            return XCTFail("Expected ambiguity, got \(outcome)")
        }
        XCTAssertEqual(Set(uuids), Set([first.uuid, second.uuid]))
    }

    /// A clearly better candidate is still matched automatically.
    func testClearlyBetterCandidateWins() {
        let good = workout(offsetMinutes: 1, duration: 1_500)
        let poor = workout(offsetMinutes: 70, duration: 300)

        let outcome = RecentWorkoutMatcher.match(workouts: [good, poor], execution: candidate())

        if case .matched(let uuid, _) = outcome {
            XCTAssertEqual(uuid, good.uuid)
        } else {
            XCTFail("Expected a clear match, got \(outcome)")
        }
    }

    func testNoExecutionAndOneWorkoutMatches() {
        let only = workout(offsetMinutes: 5)

        let outcome = RecentWorkoutMatcher.match(workouts: [only], execution: nil)

        XCTAssertEqual(outcome, .matched(workoutUUID: only.uuid, executionID: nil))
    }

    /// With no plan to compare against, "the most recent" is a guess, so it asks instead.
    func testNoExecutionAndSeveralWorkoutsIsAmbiguous() {
        let outcome = RecentWorkoutMatcher.match(
            workouts: [workout(offsetMinutes: 1), workout(offsetMinutes: 200)],
            execution: nil)

        guard case .ambiguous = outcome else {
            return XCTFail("Expected ambiguity with no plan, got \(outcome)")
        }
    }

    func testEmptyInputYieldsNoCandidates() {
        XCTAssertEqual(RecentWorkoutMatcher.match(workouts: [], execution: candidate()),
                       .noCandidates)
    }

    // MARK: - Unlogged queue

    func testUnloggedExcludesLoggedAndHiddenWorkouts() {
        let logged = workout(offsetMinutes: 0)
        let recent = workout(offsetMinutes: 10)
        let ancient = workout(offsetMinutes: -60 * 24 * 30)

        let result = RecentWorkoutMatcher.unloggedWorkouts(
            from: [logged, recent, ancient],
            loggedUUIDs: [logged.uuid],
            hideBefore: base.addingTimeInterval(-60 * 60 * 24 * 7))

        XCTAssertEqual(result.map(\.uuid), [recent.uuid])
    }

    func testUnloggedIsSortedNewestFirst() {
        let older = workout(offsetMinutes: 0)
        let newer = workout(offsetMinutes: 30)

        let result = RecentWorkoutMatcher.unloggedWorkouts(from: [older, newer],
                                                           loggedUUIDs: [],
                                                           hideBefore: nil)

        XCTAssertEqual(result.map(\.uuid), [newer.uuid, older.uuid])
    }

    // MARK: - The reverse direction: which execution produced this workout

    /// These cover logging a run **after** it finished, from the unlogged queue — the ordinary way
    /// to use the app, and the way that used to lose the link entirely.
    ///
    /// A real export showed the consequence: 98 recorded interval boundaries, 23 workouts, and
    /// nothing joining them, because only a log written *during* the run ever carried its
    /// execution. Nothing errored.

    func testExecutionIsResolvedForAWorkoutLoggedAfterwards() {
        let target = workout(offsetMinutes: 2)
        let execution = candidate()

        let outcome = RecentWorkoutMatcher.execution(forWorkout: target, candidates: [execution])

        XCTAssertEqual(outcome, .matched(executionID: execution.executionID))
    }

    func testNoExecutionWhenNoneIsNearbyInTime() {
        let target = workout(offsetMinutes: 600)   // ten hours after the execution was created

        let outcome = RecentWorkoutMatcher.execution(forWorkout: target,
                                                     candidates: [candidate()])

        XCTAssertEqual(outcome, .none)
    }

    /// A walk is never accepted as the run that was planned, in either direction.
    func testExecutionActivityTypeMustAgree() {
        let run = workout(offsetMinutes: 2, activity: .running)

        let outcome = RecentWorkoutMatcher.execution(forWorkout: run,
                                                     candidates: [candidate(activity: .walking)])

        XCTAssertEqual(outcome, .none)
    }

    /// The refusal to guess, in the reverse direction. Stamping interval records onto the wrong run
    /// is not something the user could ever notice afterwards, so indistinguishable candidates are
    /// reported rather than resolved by a tiebreak.
    func testTwoEquallyPlausibleExecutionsAreAmbiguous() {
        let target = workout(offsetMinutes: 0, duration: 1_500)
        let first = candidate(duration: 1_500, createdOffsetMinutes: 0)
        let second = candidate(duration: 1_500, createdOffsetMinutes: 0)

        let outcome = RecentWorkoutMatcher.execution(forWorkout: target,
                                                     candidates: [first, second])

        guard case .ambiguous(let ids) = outcome else {
            return XCTFail("Expected ambiguity, got \(outcome)")
        }
        XCTAssertEqual(Set(ids), Set([first.executionID, second.executionID]))
    }

    func testClearlyCloserExecutionWinsOverAWorseOne() {
        let target = workout(offsetMinutes: 0, duration: 1_500)
        let best = candidate(duration: 1_500, createdOffsetMinutes: 1)
        let worse = candidate(duration: 200, createdOffsetMinutes: 80)

        let outcome = RecentWorkoutMatcher.execution(forWorkout: target,
                                                     candidates: [best, worse])

        XCTAssertEqual(outcome, .matched(executionID: best.executionID))
    }

    func testNoCandidatesAtAllResolvesToNone() {
        XCTAssertEqual(RecentWorkoutMatcher.execution(forWorkout: workout(offsetMinutes: 0),
                                                      candidates: []),
                       .none)
    }

    // MARK: - The timer window, which `createdAt` proximity cannot substitute for

    /// A timer that had already stopped before the workout began cannot have produced it, however
    /// close the two were created.
    ///
    /// Real data forced this. Eight cue-test executions sat within 90 minutes of one 7.4-minute
    /// run; five had already ended before it started, some after 13 seconds. Comparing `createdAt`
    /// alone called them indistinguishable and refused to link anything, when the right answer was
    /// that none of them produced that run.
    func testExecutionWhoseTimerEndedBeforeTheWorkoutIsExcluded() {
        let target = workout(offsetMinutes: 0, duration: 450)
        let finishedEarlier = candidate(createdOffsetMinutes: -20,
                                        timerStartedOffsetMinutes: -20,
                                        timerEndedOffsetMinutes: -19)

        XCTAssertEqual(RecentWorkoutMatcher.execution(forWorkout: target,
                                                      candidates: [finishedEarlier]),
                       .none)
    }

    /// The mirror image: a timer started after the workout was already over.
    func testExecutionWhoseTimerStartedAfterTheWorkoutIsExcluded() {
        let target = workout(offsetMinutes: 0, duration: 600)
        let startedLater = candidate(createdOffsetMinutes: 30, timerStartedOffsetMinutes: 30)

        XCTAssertEqual(RecentWorkoutMatcher.execution(forWorkout: target,
                                                      candidates: [startedLater]),
                       .none)
    }

    /// The case that must keep working: a timer that ran across the workout.
    ///
    /// Modeled on a real export: the timer started a second before the workout and stopped a couple
    /// of minutes before the workout ended.
    func testExecutionWhoseTimerRanAcrossTheWorkoutStillMatches() {
        let target = workout(offsetMinutes: 0, duration: 27.8 * 60)
        let overlapping = candidate(duration: 1_440,
                                    createdOffsetMinutes: 0,
                                    timerStartedOffsetMinutes: 0,
                                    timerEndedOffsetMinutes: 25.6)

        XCTAssertEqual(RecentWorkoutMatcher.execution(forWorkout: target,
                                                      candidates: [overlapping]),
                       .matched(executionID: overlapping.executionID))
    }

    /// The whole point: an overlapping timer wins outright against a crowd of ones that had already
    /// finished, instead of the crowd drowning it out as ambiguity.
    func testOverlappingTimerWinsAgainstACrowdOfFinishedOnes() {
        let target = workout(offsetMinutes: 0, duration: 450)
        let overlapping = candidate(createdOffsetMinutes: 0,
                                    timerStartedOffsetMinutes: 0,
                                    timerEndedOffsetMinutes: 7)
        // Explicitly typed, with Double literals: inferring this closure from `(1...5).map` and
        // `Double(-i * 5)` overwhelmed the type-checker outright ("unable to type-check this
        // expression in reasonable time"), the same trap the Live Activity summary hit.
        let minutesAgo: [Double] = [5, 10, 15, 20, 25]
        let alreadyFinished: [RecentWorkoutMatcher.Candidate] = minutesAgo.map { ago in
            candidate(createdOffsetMinutes: -ago,
                      timerStartedOffsetMinutes: -ago,
                      timerEndedOffsetMinutes: -ago + 0.2)
        }

        let outcome = RecentWorkoutMatcher.execution(forWorkout: target,
                                                     candidates: alreadyFinished + [overlapping])

        XCTAssertEqual(outcome, .matched(executionID: overlapping.executionID))
    }

    /// A timer that was started and never stopped stays a candidate: it may well have still been
    /// running. Nothing here is allowed to guess it away *on the evidence of the missing end*.
    func testStartedButNeverEndedTimerRemainsACandidate() {
        let target = workout(offsetMinutes: 0, duration: 450)
        let abandoned = candidate(createdOffsetMinutes: -1.5, timerStartedOffsetMinutes: -1.5)

        XCTAssertEqual(RecentWorkoutMatcher.execution(forWorkout: target,
                                                      candidates: [abandoned]),
                       .matched(executionID: abandoned.executionID))
    }

    /// The counterpart to the test above, and the reason the window was narrowed.
    ///
    /// A never-ended timer from long before the run is still not ruled out *by evidence* — that is
    /// what the test above pins. It is ruled out by **eligibility**: it started far outside the
    /// window, so it is not a candidate in the first place. Under the previous 90-minute window it
    /// was, and three such timers are what made one of the owner's real runs permanently
    /// unlinkable.
    func testStartedButNeverEndedTimerLongBeforeTheRunIsNotEligible() {
        let target = workout(offsetMinutes: 0, duration: 450)
        let longAbandoned = candidate(createdOffsetMinutes: -30, timerStartedOffsetMinutes: -30)

        XCTAssertEqual(RecentWorkoutMatcher.execution(forWorkout: target,
                                                      candidates: [longAbandoned]),
                       RecentWorkoutMatcher.ExecutionMatch.none)
    }

    /// Two abandoned timers either side of a run used to make it ambiguous forever; now neither is
    /// eligible, so the run simply has no plan — which is a state the user can act on.
    func testACrowdOfAbandonedTimersNoLongerCreatesAmbiguity() {
        let target = workout(offsetMinutes: 0, duration: 450)
        let staleOffsets: [Double] = [-62, -41, -30]
        let stale: [RecentWorkoutMatcher.Candidate] = staleOffsets.map { offset in
            candidate(createdOffsetMinutes: offset, timerStartedOffsetMinutes: offset)
        }

        XCTAssertEqual(RecentWorkoutMatcher.execution(forWorkout: target, candidates: stale),
                       RecentWorkoutMatcher.ExecutionMatch.none)
    }

    /// Narrowing the eligibility window must not make the matcher bolder.
    ///
    /// `score()` divides the start gap by a reference span. While that reference *was*
    /// `startToleranceSeconds`, tightening the window scaled every score up by the same factor and
    /// pushed indistinguishable pairs past `ambiguityMargin` — turning "ask" into a confident pick as
    /// a side effect. Two executions a few seconds apart must still be a question.
    func testTighteningTheWindowDidNotMakeCloseCallsConfident() {
        let target = workout(offsetMinutes: 0, duration: 1_500)
        let first = candidate(createdOffsetMinutes: -0.1, timerStartedOffsetMinutes: -0.1)
        let second = candidate(createdOffsetMinutes: 0.1, timerStartedOffsetMinutes: 0.1)

        let outcome = RecentWorkoutMatcher.execution(forWorkout: target,
                                                     candidates: [first, second])

        guard case .ambiguous(let ids) = outcome else {
            return XCTFail("Two near-identical executions must be ambiguous, got \(outcome)")
        }
        XCTAssertEqual(Set(ids), Set([first.executionID, second.executionID]))
    }
}
