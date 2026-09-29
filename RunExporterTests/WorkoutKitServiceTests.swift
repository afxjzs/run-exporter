import HealthKit
import WorkoutKit
import XCTest
@testable import RunExporter

/// The workout payload sent to Apple Watch.
///
/// The payload is built on the phone and parsed on the Watch, which can be **years older** — an
/// Apple Watch Series 5 stops at watchOS 10 while the phone runs iOS 26. Nothing here may use API
/// newer than watchOS 10, and no compiler check enforces that, because on the phone the newer API
/// is perfectly valid. These tests are the enforcement.
@MainActor
final class WorkoutKitServiceTests: XCTestCase {

    private func plan(run: Int = 240, walk: Int = 60, reps: Int = 5,
                      cooldown: CooldownMode = .open,
                      finalWalk: Bool = false) -> PlannedWorkout {
        PlannedWorkout(name: "4/1 × 5",
                       runIntervalSeconds: run,
                       walkIntervalSeconds: walk,
                       plannedRepetitions: reps,
                       includesFinalWalk: finalWalk,
                       cooldownMode: cooldown,
                       countdownSeconds: 3)
    }

    /// Every `WorkoutStep` in a workout, wherever it appears.
    private func allSteps(_ workout: CustomWorkout) -> [WorkoutStep] {
        var steps: [WorkoutStep] = []
        if let warmup = workout.warmup { steps.append(warmup) }
        steps.append(contentsOf: workout.blocks.flatMap { $0.steps.map(\.step) })
        if let cooldown = workout.cooldown { steps.append(cooldown) }
        return steps
    }

    // MARK: - watchOS 10 compatibility

    /// Regression test.
    ///
    /// `WorkoutStep.displayName` is `@available(iOS 18.0, watchOS 11.0, *)`. It was previously set
    /// behind `#available(iOS 18.0, *)`, which tests the *phone* and says nothing about the Watch
    /// that has to parse the payload. Sending it to a watchOS 10 Watch crashed and rebooted the
    /// Watch. It must never be set again.
    func testStepsCarryNoDisplayName() throws {
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("displayName is not readable before iOS 18, so nothing to assert.")
        }

        for candidate in [plan(), plan(finalWalk: true), plan(walk: 0, reps: 1),
                          plan(cooldown: .timed)] {
            candidate.cooldownSeconds = 600
            let workout = try WorkoutKitService.makeCustomWorkout(from: candidate)

            for step in allSteps(workout) {
                XCTAssertNil(step.displayName,
                             "No step may carry displayName: it does not exist on watchOS 10 and "
                                 + "crashes an older Watch")
            }
        }
    }

    /// The workout-level name is fine — `CustomWorkout.displayName` exists on watchOS 10.0. It is
    /// what identifies the workout in the Watch's list, so it must survive.
    func testWorkoutLevelNameIsKept() throws {
        let workout = try WorkoutKitService.makeCustomWorkout(from: plan())
        XCTAssertEqual(workout.displayName, "4/1 × 5")
    }

    /// Only goals that exist on watchOS 10 may be used.
    func testGoalsAreWatchOS10Compatible() throws {
        let workout = try WorkoutKitService.makeCustomWorkout(from: plan())

        for step in allSteps(workout) {
            switch step.goal {
            case .time, .open:
                break   // both watchOS 10.0
            case .distance, .energy:
                XCTFail("Unexpected goal type \(step.goal)")
            default:
                XCTFail("Goal \(step.goal) may be newer than watchOS 10")
            }
        }
    }

    // MARK: - Structure

    /// The Watch and the iPhone timer must describe the same workout: 5 runs, 4 walks.
    func testFourOneByFiveHasFiveRunsAndFourWalks() throws {
        let workout = try WorkoutKitService.makeCustomWorkout(from: plan())

        var runs = 0
        var walks = 0
        for block in workout.blocks {
            for step in block.steps {
                switch step.purpose {
                case .work: runs += block.iterations
                case .recovery: walks += block.iterations
                @unknown default: XCTFail("Unhandled purpose")
                }
            }
        }

        XCTAssertEqual(runs, 5)
        XCTAssertEqual(walks, 4, "No walk after the final run")
    }

    func testFinalWalkIsIncludedWhenRequested() throws {
        let workout = try WorkoutKitService.makeCustomWorkout(from: plan(finalWalk: true))

        let walks = workout.blocks.reduce(0) { total, block in
            total + block.steps.filter { $0.purpose == .recovery }.count * block.iterations
        }
        XCTAssertEqual(walks, 5)
    }

    func testContinuousWorkoutHasNoRecoverySteps() throws {
        let workout = try WorkoutKitService.makeCustomWorkout(from: plan(walk: 0, reps: 1))

        let recoveries = workout.blocks.flatMap { $0.steps }.filter { $0.purpose == .recovery }
        XCTAssertTrue(recoveries.isEmpty)
    }

    func testOpenCooldownIsAnOpenGoal() throws {
        let workout = try WorkoutKitService.makeCustomWorkout(from: plan())
        let cooldown = try XCTUnwrap(workout.cooldown)
        XCTAssertEqual(cooldown.goal, .open)
    }

    func testTimedCooldownCarriesItsDuration() throws {
        let candidate = plan(cooldown: .timed)
        candidate.cooldownSeconds = 600
        let workout = try WorkoutKitService.makeCustomWorkout(from: candidate)

        XCTAssertEqual(try XCTUnwrap(workout.cooldown).goal, .time(600, .seconds))
    }

    func testRunningActivityAndOutdoorLocation() throws {
        let workout = try WorkoutKitService.makeCustomWorkout(from: plan())
        XCTAssertEqual(workout.activity, .running)
        XCTAssertEqual(workout.location, .outdoor)
        XCTAssertTrue(CustomWorkout.supportsActivity(workout.activity))
    }

    /// Every plan must go to the Watch as outdoor, whatever its shape or activity.
    ///
    /// An indoor workout makes Apple Watch skip weather entirely, so this is the one setting that
    /// decides whether weather can be recorded at all. It does **not** guarantee weather — the
    /// Watch must also complete a weather fetch — but indoor guarantees its absence.
    func testEveryPlanShapeIsSentAsOutdoor() throws {
        let candidates = [plan(), plan(finalWalk: true), plan(walk: 0, reps: 1),
                          plan(cooldown: .none)]

        for candidate in candidates {
            XCTAssertEqual(try WorkoutKitService.makeCustomWorkout(from: candidate).location,
                           .outdoor)
        }

        let walking = plan()
        walking.activityType = PlannedActivityType.walking.rawValue
        XCTAssertEqual(try WorkoutKitService.makeCustomWorkout(from: walking).location, .outdoor)
    }

    func testWalkingPlanProducesWalkingWorkout() throws {
        let candidate = plan()
        candidate.activityType = PlannedActivityType.walking.rawValue
        let workout = try WorkoutKitService.makeCustomWorkout(from: candidate)
        XCTAssertEqual(workout.activity, .walking)
    }

    /// A plan the timer would refuse must not reach the Watch either.
    func testMalformedPlanIsRejectedBeforeSending() {
        let bad = plan()
        bad.cooldownMode = "nonsense"
        XCTAssertThrowsError(try WorkoutKitService.makeCustomWorkout(from: bad))
    }

    // MARK: - Blocks of differing shape

    private func blockPlan(_ shapes: [(run: Int, walk: Int, reps: Int)],
                           finalWalk: Bool = false) -> PlannedWorkout {
        let candidate = plan(finalWalk: finalWalk)
        candidate.blocks = shapes.enumerated().map { index, shape in
            PlannedWorkoutBlock(orderIndex: index,
                                runIntervalSeconds: shape.run,
                                walkIntervalSeconds: shape.walk,
                                repetitions: shape.reps)
        }
        return candidate
    }

    /// The main set as the Watch will actually run it — every step in order, as "work 300".
    ///
    /// Expanding `iterations` is the whole point: an `IntervalBlock` is a loop, and what the wrist
    /// experiences is the sequence it produces, not how the steps happen to be packed into blocks.
    private func orderedSteps(_ workout: CustomWorkout) -> [String] {
        var result: [String] = []
        for block in workout.blocks {
            for _ in 0..<block.iterations {
                for step in block.steps {
                    result.append("\(purposeName(step)) \(goalText(step.step.goal))")
                }
            }
        }
        return result
    }

    private func purposeName(_ step: IntervalStep) -> String {
        switch step.purpose {
        case .work: return "work"
        case .recovery: return "recovery"
        @unknown default: return "unknown(\(step.purpose))"
        }
    }

    private func goalText(_ goal: WorkoutGoal) -> String {
        if case .time(let value, let unit) = goal, unit == .seconds {
            return String(Int(value))
        }
        return "\(goal)"
    }

    /// The shape the owner asked for, as the Watch receives it: 5/1×1, then 8/1×2, then 5/1×1.
    ///
    /// The payload was built from the flat `runIntervalSeconds` / `plannedRepetitions` fields, so
    /// this plan reached the Watch as a plain repeat of its first block — the iPhone timer running
    /// one workout while the wrist ran another.
    func testMultiBlockPayloadRunsEveryBlockWithItsOwnDurations() throws {
        let candidate = blockPlan([(300, 60, 1), (480, 60, 2), (300, 60, 1)])

        let workout = try WorkoutKitService.makeCustomWorkout(from: candidate)

        XCTAssertEqual(orderedSteps(workout),
                       ["work 300", "recovery 60",
                        "work 480", "recovery 60",
                        "work 480", "recovery 60",
                        "work 300"],
                       "the last walk is dropped because it follows the workout's final run")
    }

    /// The Watch and the iPhone timer must not disagree about the workout. `expandedIntervals` is
    /// what the timer runs; this is built by a different path and must land on the same sequence.
    func testMultiBlockPayloadAgreesWithTheTimersOwnSequence() throws {
        let candidate = blockPlan([(300, 60, 1), (480, 60, 2), (300, 60, 1)])

        let workout = try WorkoutKitService.makeCustomWorkout(from: candidate)

        let timerSequence = candidate.expandedIntervals.map { interval in
            "\(interval.isRun ? "work" : "recovery") \(interval.seconds)"
        }
        XCTAssertEqual(orderedSteps(workout), timerSequence)
    }

    /// The walk between two blocks is not the end of the workout and must survive.
    func testTheWalkJoiningTwoBlocksIsKept() throws {
        let candidate = blockPlan([(300, 60, 1), (480, 60, 1)])

        let workout = try WorkoutKitService.makeCustomWorkout(from: candidate)

        XCTAssertEqual(orderedSteps(workout),
                       ["work 300", "recovery 60", "work 480"])
    }

    func testMultiBlockFinalWalkIsIncludedWhenRequested() throws {
        let candidate = blockPlan([(300, 60, 1), (480, 60, 2)], finalWalk: true)

        let workout = try WorkoutKitService.makeCustomWorkout(from: candidate)

        XCTAssertEqual(orderedSteps(workout),
                       ["work 300", "recovery 60",
                        "work 480", "recovery 60",
                        "work 480", "recovery 60"])
    }

    /// A block whose repetitions have no recovery walk contributes only work steps.
    func testABlockWithNoWalkContributesOnlyWorkSteps() throws {
        let candidate = blockPlan([(480, 0, 2), (300, 60, 1)])

        let workout = try WorkoutKitService.makeCustomWorkout(from: candidate)

        XCTAssertEqual(orderedSteps(workout), ["work 480", "work 480", "work 300"])
    }

    /// Regression test, extended to block plans.
    ///
    /// `WorkoutStep.displayName` is watchOS 11 and crashed and rebooted the paired Series 5. A
    /// multi-block payload builds more steps by more paths, so it gets the same enforcement.
    func testMultiBlockStepsCarryNoDisplayNameAndUseWatchOS10Goals() throws {
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("displayName is not readable before iOS 18, so nothing to assert.")
        }

        let candidates = [blockPlan([(300, 60, 1), (480, 60, 2), (300, 60, 1)]),
                          blockPlan([(300, 60, 1), (480, 60, 2)], finalWalk: true),
                          blockPlan([(480, 0, 2), (300, 60, 1)])]

        for candidate in candidates {
            let workout = try WorkoutKitService.makeCustomWorkout(from: candidate)

            for step in allSteps(workout) {
                XCTAssertNil(step.displayName,
                             "No step may carry displayName: it does not exist on watchOS 10 and "
                                 + "crashes an older Watch")
                switch step.goal {
                case .time, .open:
                    break   // both watchOS 10.0
                default:
                    XCTFail("Goal \(step.goal) may be newer than watchOS 10")
                }
            }
        }
    }

    /// A plan the timer refuses must not reach the Watch, blocks included.
    func testAPlanWithAnEmptyBlockIsRejectedBeforeSending() {
        XCTAssertThrowsError(
            try WorkoutKitService.makeCustomWorkout(from: blockPlan([(300, 60, 1), (0, 60, 2)])))
    }
}
