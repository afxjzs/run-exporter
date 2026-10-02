import Foundation

/// Where the engine gets the phases it runs, in order.
///
/// Two things answer this. `WorkoutPhaseSchedule` holds a fixed array, because an interval plan's
/// whole shape is known before it starts. `OpenIntervalSchedule` computes each answer, because a
/// open-interval run's length is the measurement and cannot be known in advance.
///
/// `accumulatedRunSeconds` is what separates them: a fixed schedule ignores it, and for a
/// open-interval run it is the only thing that decides whether the next phase is another leg or
/// the cooldown. Passing it on every call is what lets the engine keep one code path.
protocol WorkoutPhaseSource {

    /// Rounds the workout will run, or `0` when that is not knowable until it has been run.
    var totalRepetitions: Int { get }

    var countdownSeconds: Int { get }

    /// Every phase, for surfaces that must draw the whole workout at once — the Live Activity
    /// timeline above all. **Empty when the workout has no knowable end**, so a card renders no
    /// timeline rather than a row of zero-length phases it invented.
    var fixedPhases: [WorkoutPhaseSchedule.PlannedPhase] { get }

    /// True when the owner ends each running leg by hand rather than the clock ending it.
    ///
    /// Guards `IntervalTimerEngine.endLeg`. Under an interval plan that call would close a run
    /// early while recording it as having run to plan, overstating a workout that did not happen.
    var legsEndByHand: Bool { get }

    /// The shortest a recovery walk runs, or nil when this workout's walks are timed and end on
    /// their own. It never ends a walk — it is the point past which starting the next leg stops
    /// contradicting the plan.
    var walkFloorSeconds: Int? { get }

    func phase(at index: Int, accumulatedRunSeconds: Int) -> WorkoutPhaseSchedule.PlannedPhase?

    /// True when this is the last run of the workout — what "Final round" announces.
    func isFinalRun(at index: Int, accumulatedRunSeconds: Int) -> Bool
}

extension PlannedWorkout {

    /// The phase source this plan runs through, or a thrown reason it cannot run at all.
    ///
    /// The single place a plan's kind decides how it is sequenced. The timer calls it to start a
    /// workout and the editors call it to refuse saving one the timer would not accept — asking the
    /// question twice in two switches is how a plan comes to save cleanly and fail at the start
    /// line.
    func makePhaseSource() throws -> any WorkoutPhaseSource {
        switch shape {
        case .intervals, .damaged:
            return try WorkoutPhaseSchedule.build(from: self)
        case .openIntervals(let target, let walkFloor):
            return try OpenIntervalSchedule.build(from: self, target: target, walkFloor: walkFloor)
        }
    }
}

/// The ordered phases of a planned workout, with no notion of wall-clock time.
///
/// Pure and value-typed so the sequencing rules — above all "no walk after the final run"
/// (spec §11.1) — can be tested directly, without an audio session, a store, or a running timer.
struct WorkoutPhaseSchedule {

    /// One phase as planned. `plannedSeconds` is nil for an open-ended phase, which ends only when
    /// the user says so.
    struct PlannedPhase: Equatable {
        let index: Int
        let phase: WorkoutPhase
        /// 1-based, for run and walk phases only.
        let repetition: Int?
        let plannedSeconds: Int?

        var isOpen: Bool { plannedSeconds == nil }
    }

    /// Why a plan could not be turned into a schedule. Every case is a real user-facing problem,
    /// never a silently-substituted default.
    enum ScheduleError: LocalizedError, Equatable {
        case unknownWarmupMode(String)
        case unknownCooldownMode(String)
        case nonPositiveRunInterval(Int)
        case nonPositiveRepetitions(Int)
        case missingWarmupDuration
        case missingCooldownDuration
        /// Nothing describes the plan's intervals: no blocks, and its own fields not set.
        case missingShape

        var errorDescription: String? {
            switch self {
            case .missingShape:
                return PlannedWorkout.damagedShapeSummary
            case .unknownWarmupMode(let raw):
                return "This workout's warmup mode is \"\(raw)\", which this version does not "
                    + "understand. Edit the workout and choose a warmup."
            case .unknownCooldownMode(let raw):
                return "This workout's cooldown mode is \"\(raw)\", which this version does not "
                    + "understand. Edit the workout and choose a cooldown."
            case .nonPositiveRunInterval(let value):
                return "The run interval is \(value) seconds. Set a run interval of at least "
                    + "1 second."
            case .nonPositiveRepetitions(let value):
                return "This workout has \(value) repetitions. Set at least 1."
            case .missingWarmupDuration:
                return "The warmup is set to a timed warmup but has no duration."
            case .missingCooldownDuration:
                return "The cooldown is set to a timed cooldown but has no duration."
            }
        }
    }

    let phases: [PlannedPhase]
    let totalRepetitions: Int
    let countdownSeconds: Int

    /// Total planned seconds of run and walk only. Warmup and cooldown are excluded so this stays
    /// comparable with `mainSetDurationSeconds` in the export.
    var mainSetSeconds: Int {
        phases.reduce(0) { total, phase in
            guard phase.phase.isMainSet, let seconds = phase.plannedSeconds else { return total }
            return total + seconds
        }
    }

    // MARK: - Building

    /// Turns a plan into its phase sequence.
    ///
    /// Throws rather than repairing a malformed plan: silently running a workout that is not the
    /// one the user configured is worse than refusing to start.
    static func build(from plan: PlannedWorkout) throws -> WorkoutPhaseSchedule {
        guard let warmupMode = plan.warmupModeValue else {
            throw ScheduleError.unknownWarmupMode(plan.warmupMode)
        }
        guard let cooldownMode = plan.cooldownModeValue else {
            throw ScheduleError.unknownCooldownMode(plan.cooldownMode)
        }
        // Validated per block, from `resolvedBlocks`, because the flat fields describe only a
        // single-shape plan. Reading them here meant a plan of 5/1×1 → 0/1×2 → 5/1×1 passed — the
        // guard inspected block one and `expandedIntervals` then produced a 0-second run phase for
        // the timer to run. A block with no repetitions is refused for the same reason in reverse:
        // `expandedIntervals` skips it, so nothing breaks and the workout is quietly not the one
        // the plan describes.
        //
        // A plan with no stored blocks is checked from its own three fields. `resolvedBlocks` gives
        // no block for fields that describe nothing, and a loop over no blocks would pass the plan:
        // it used to get a `0/0×0` block here, which this loop refused. The editor shows these
        // errors to say why Save is disabled, so they stay the specific ones.
        if plan.blocks.isEmpty {
            guard let run = plan.runIntervalSeconds,
                  plan.walkIntervalSeconds != nil,
                  let repetitions = plan.plannedRepetitions else {
                throw ScheduleError.missingShape
            }
            guard run > 0 else { throw ScheduleError.nonPositiveRunInterval(run) }
            guard repetitions > 0 else { throw ScheduleError.nonPositiveRepetitions(repetitions) }
        }
        for block in plan.resolvedBlocks {
            guard block.runSeconds > 0 else {
                throw ScheduleError.nonPositiveRunInterval(block.runSeconds)
            }
            guard block.repetitions > 0 else {
                throw ScheduleError.nonPositiveRepetitions(block.repetitions)
            }
        }

        var phases: [PlannedPhase] = []
        var index = 0

        func append(_ phase: WorkoutPhase, repetition: Int? = nil, seconds: Int?) {
            phases.append(PlannedPhase(index: index, phase: phase,
                                       repetition: repetition, plannedSeconds: seconds))
            index += 1
        }

        let countdown = max(0, plan.countdownSeconds)
        for entry in try leadIn(for: plan, warmupMode: warmupMode) {
            append(entry.phase, seconds: entry.seconds)
        }

        // The main set comes from `plan.expandedIntervals`, which is the single place a plan's
        // shape is turned into a list of intervals — one block or several, the flat fields or the
        // stored ones. Expanding it a second time here is what would let the schedule and the
        // plan's advertised main set drift apart, and spec §11.1's "no walk after the final run"
        // is applied there, across the whole workout rather than per block.
        // From the blocks just validated: the plan's own `totalRepetitions` is optional because an
        // open-interval plan has none, and that plan is never built here.
        let repetitions = PlannedWorkout.totalRepetitions(blocks: plan.resolvedBlocks)
        for interval in plan.expandedIntervals {
            append(interval.isRun ? .run : .walk,
                   repetition: interval.repetition,
                   seconds: interval.seconds)
        }

        for entry in try tail(for: plan, cooldownMode: cooldownMode) {
            append(entry.phase, seconds: entry.seconds)
        }

        return WorkoutPhaseSchedule(phases: phases,
                                    totalRepetitions: repetitions,
                                    countdownSeconds: countdown)
    }

    // MARK: - Shared opening and closing

    /// The phases before the main set — countdown, then warmup — as unplaced `(phase, seconds)`
    /// pairs the caller indexes.
    ///
    /// Shared with `OpenIntervalSchedule`. A plan's opening is the same question whichever kind of
    /// main set follows it, and two copies of the answer is how the two come to disagree.
    static func leadIn(for plan: PlannedWorkout,
                       warmupMode: WarmupMode) throws -> [(phase: WorkoutPhase, seconds: Int?)] {
        var entries: [(phase: WorkoutPhase, seconds: Int?)] = []

        let countdown = max(0, plan.countdownSeconds)
        if countdown > 0 {
            entries.append((.countdown, countdown))
        }

        switch warmupMode {
        case .none:
            break
        case .timed:
            guard let seconds = plan.warmupSeconds, seconds > 0 else {
                throw ScheduleError.missingWarmupDuration
            }
            entries.append((.warmup, seconds))
        case .open:
            entries.append((.warmup, nil))
        }
        return entries
    }

    /// The phases after the main set — the cooldown, when the plan has one.
    static func tail(for plan: PlannedWorkout,
                     cooldownMode: CooldownMode) throws -> [(phase: WorkoutPhase, seconds: Int?)] {
        switch cooldownMode {
        case .none:
            return []
        case .timed:
            guard let seconds = plan.cooldownSeconds, seconds > 0 else {
                throw ScheduleError.missingCooldownDuration
            }
            return [(.cooldown, seconds)]
        case .open:
            return [(.cooldown, nil)]
        }
    }

    // MARK: - Lookup

    func phase(at index: Int) -> PlannedPhase? {
        guard phases.indices.contains(index) else { return nil }
        return phases[index]
    }

    /// The phase after `index`, or nil when `index` is the last one.
    func phase(after index: Int) -> PlannedPhase? {
        phase(at: index + 1)
    }

    /// True when the given phase is the final run of the workout — what "Final round" announces.
    func isFinalRun(at index: Int) -> Bool {
        guard let current = phase(at: index), current.phase == .run else { return false }
        return !phases.dropFirst(index + 1).contains { $0.phase == .run }
    }
}

// MARK: - WorkoutPhaseSource

extension WorkoutPhaseSchedule: WorkoutPhaseSource {

    /// A fixed schedule ignores how much running has happened: the plan said what every phase
    /// would be before the workout started, and nothing measured since can change it.
    func phase(at index: Int, accumulatedRunSeconds: Int) -> PlannedPhase? {
        phase(at: index)
    }

    func isFinalRun(at index: Int, accumulatedRunSeconds: Int) -> Bool {
        isFinalRun(at: index)
    }

    var fixedPhases: [PlannedPhase] { phases }

    /// An interval plan's runs end when their planned duration does.
    var legsEndByHand: Bool { false }

    /// An interval plan's walks have a length, not a floor.
    var walkFloorSeconds: Int? { nil }
}
