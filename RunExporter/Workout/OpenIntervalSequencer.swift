import Foundation

/// The sequencing rules of an open-interval run, with no notion of wall-clock time.
///
/// `WorkoutPhaseSchedule` builds an interval plan's phases up front because that plan's whole shape
/// is known in advance. A open-interval plan's is not: you run until the first clearly
/// identifiable sign of whatever the plan watches for, walk until it has gone, and repeat until a
/// target amount of
/// running has accumulated. How many legs that takes is the measurement the run exists to make, so
/// there is no array to build.
///
/// This type answers what comes next from the only thing that decides it — the running time
/// accumulated so far. Pure and value-typed, for the same reason `WorkoutPhaseSchedule` is: the
/// rules can be tested without an audio session, a store, or a running timer.
struct OpenIntervalSequencer {

    /// Total running to accumulate before the workout ends. Walks are not counted toward it.
    let targetRunSeconds: Int

    /// The shortest walk between legs. A cue marks it; it does not end the walk.
    let walkFloorSeconds: Int

    /// The longest a leg started now may last: whatever running is left to the target.
    ///
    /// A leg ends when the runner ends it or at the target, whichever comes first. Without the cap the
    /// workout runs past the number the plan is defined by, and the final row of the dataset
    /// records a leg length that was never a threshold measurement — a fabricated data point in
    /// the one place the whole run exists to measure honestly.
    func legCapSeconds(accumulatedRunSeconds: Int) -> Int {
        max(0, targetRunSeconds - accumulatedRunSeconds)
    }

    /// What follows a leg that has just ended.
    enum NextStep: Equatable {
        /// Walk, for at least `floorSeconds`, then run again.
        case recoveryWalk(floorSeconds: Int)
        /// The target is met; the workout hands over to its cooldown.
        case finished
    }

    /// What follows the leg that ended with `accumulatedRunSeconds` of running behind it.
    ///
    /// Reaching the target finishes the workout rather than starting another recovery walk. A
    /// recovery walk exists to prepare the next leg, so once there is no next leg it is walking
    /// the owner did not ask for, recorded as though the protocol called for it. Spec §11.1 states
    /// the same rule for interval plans, where it reads "no walk after the final run".
    func next(afterLegEndingAt accumulatedRunSeconds: Int) -> NextStep {
        guard accumulatedRunSeconds < targetRunSeconds else { return .finished }
        return .recoveryWalk(floorSeconds: walkFloorSeconds)
    }
}

/// A open-interval plan as a source of phases for the timer.
///
/// The opening and the cooldown come from `WorkoutPhaseSchedule`'s shared helpers, so a plan's
/// warmup and cooldown are read identically whichever kind of main set sits between them. Only the
/// middle belongs to this type, and the middle is unbounded: leg, recovery walk, leg, … until the
/// accumulated running reaches the target.
///
/// Phases are computed rather than stored. Asked for the phase at an index, it works out from the
/// running accumulated so far whether that slot holds another leg, a recovery walk, the cooldown,
/// or nothing at all because the workout is over.
struct OpenIntervalSchedule: WorkoutPhaseSource {

    let sequencer: OpenIntervalSequencer
    let countdownSeconds: Int

    private let leadIn: [(phase: WorkoutPhase, seconds: Int?)]
    private let tail: [(phase: WorkoutPhase, seconds: Int?)]

    /// Zero, because the number of rounds is the measurement and is not known in advance.
    ///
    /// The engine's "final round" announcement is gated on this being greater than one, so a
    /// open-interval run never claims to know which leg is its last — it cannot, until the leg
    /// after it fails to happen.
    var totalRepetitions: Int { 0 }

    /// Empty, which is what tells the Live Activity to draw no timeline.
    ///
    /// A timeline needs every phase and its length up front. This workout has neither, and a card
    /// showing a row of zero-length phases would be an invented picture of a run nobody has done
    /// yet. See `IntervalTimerEngine.liveActivityTimeline`.
    var fixedPhases: [WorkoutPhaseSchedule.PlannedPhase] { [] }

    /// Every leg ends by the owner's hand — that is the whole protocol. The cap is a ceiling, not
    /// the expected ending.
    var legsEndByHand: Bool { true }

    var walkFloorSeconds: Int? { sequencer.walkFloorSeconds }

    static func build(from plan: PlannedWorkout,
                      target: Int,
                      walkFloor: Int) throws -> OpenIntervalSchedule {
        guard let warmupMode = plan.warmupModeValue else {
            throw WorkoutPhaseSchedule.ScheduleError.unknownWarmupMode(plan.warmupMode)
        }
        guard let cooldownMode = plan.cooldownModeValue else {
            throw WorkoutPhaseSchedule.ScheduleError.unknownCooldownMode(plan.cooldownMode)
        }
        // A target of zero describes a workout with no running in it. Refused for the same reason
        // a run interval of zero is: a workout that cannot run is reported, never started.
        guard target > 0 else {
            throw WorkoutPhaseSchedule.ScheduleError.nonPositiveRunInterval(target)
        }

        return OpenIntervalSchedule(
            sequencer: OpenIntervalSequencer(targetRunSeconds: target,
                                              walkFloorSeconds: max(0, walkFloor)),
            countdownSeconds: max(0, plan.countdownSeconds),
            leadIn: try WorkoutPhaseSchedule.leadIn(for: plan, warmupMode: warmupMode),
            tail: try WorkoutPhaseSchedule.tail(for: plan, cooldownMode: cooldownMode))
    }

    /// The phase in slot `index`, given the running accumulated so far.
    ///
    /// After the opening, even slots hold legs and odd slots hold what follows a leg. Finishing
    /// is therefore always detected in an odd slot, which is what keeps the cooldown from being
    /// offered twice: once it has been handed out, the next slot is even, its leg cap is zero, and
    /// the workout ends.
    func phase(at index: Int, accumulatedRunSeconds: Int) -> WorkoutPhaseSchedule.PlannedPhase? {
        if index < leadIn.count {
            let entry = leadIn[index]
            return WorkoutPhaseSchedule.PlannedPhase(index: index,
                                                     phase: entry.phase,
                                                     repetition: nil,
                                                     plannedSeconds: entry.seconds)
        }

        let offset = index - leadIn.count
        let legNumber = offset / 2 + 1

        guard offset.isMultiple(of: 2) else {
            switch sequencer.next(afterLegEndingAt: accumulatedRunSeconds) {
            case .finished:
                guard let entry = tail.first else { return nil }
                return WorkoutPhaseSchedule.PlannedPhase(index: index,
                                                         phase: entry.phase,
                                                         repetition: nil,
                                                         plannedSeconds: entry.seconds)
            case .recoveryWalk:
                // Open: the walk's floor is announced, and the runner decides when the signal has
                // returned to baseline. A duration here would end it for them.
                return WorkoutPhaseSchedule.PlannedPhase(index: index,
                                                         phase: .walk,
                                                         repetition: legNumber,
                                                         plannedSeconds: nil)
            }
        }

        let cap = sequencer.legCapSeconds(accumulatedRunSeconds: accumulatedRunSeconds)
        guard cap > 0 else { return nil }
        return WorkoutPhaseSchedule.PlannedPhase(index: index,
                                                 phase: .run,
                                                 repetition: legNumber,
                                                 plannedSeconds: cap)
    }

    /// Always false: which leg is the last one is not knowable while it is being run.
    func isFinalRun(at index: Int, accumulatedRunSeconds: Int) -> Bool { false }
}
