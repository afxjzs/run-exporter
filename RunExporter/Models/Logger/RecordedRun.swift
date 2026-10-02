import Foundation

/// What one execution actually ran, derived from its recorded legs (`workout_intervals.csv`).
///
/// Never stored. The legs are the record of what was run, and a stored summary would be a second
/// copy free to disagree with them. A plan's shape says what was decided before the run; this says
/// what happened. For a fixed plan the two usually agree. For an open-interval plan, whose legs the
/// runner ends, only this one can say anything — summaries that read the plan instead wrote zeros.
///
/// The aerobic analysis slices heart rate by these legs, so each leg's `activeWindows` are the
/// wall-clock time actually spent in it, pauses removed. That is not the leg's recorded window:
/// see `init(rows:)`.
struct RecordedRun: Equatable {

    enum Failure: Error, Equatable {
        /// A phase this build does not know. Sorting it into run, walk or pause would be a guess,
        /// and a guess moves a total.
        case unrecognizedPhase(String)
    }

    struct Leg: Equatable {
        let phase: WorkoutPhase
        let repetition: Int?
        /// The time actually spent in this leg, in order. One window unless a pause interrupted it.
        let activeWindows: [DateInterval]
        let endReason: LegEndReason?

        var activeSeconds: Double { activeWindows.reduce(0) { $0 + $1.duration } }
    }

    /// Every leg but pauses, in recorded order — countdown, warmup and cooldown included.
    let legs: [Leg]
    let pausedSeconds: Double

    /// Reads an execution's rows, in any order.
    ///
    /// **Why a leg's recorded window is not its active time.** On resume, `IntervalTimerEngine`
    /// shifts the interrupted leg's start forward by the pause, so its duration stays right. The
    /// recorded window therefore overlaps the pause and misses the leg's real first seconds —
    /// measured on a real run, a leg stored as starting a second before the end of the pause that
    /// interrupted it. The engine writes each pause as its own row on resume, before the leg it
    /// interrupted completes, so the pauses ahead of a leg are exactly the ones it absorbed:
    /// real start = recorded start − those pauses, and its active time is that span with the
    /// pauses cut out.
    init(rows: [IntervalLogExportRow]) throws {
        var legs: [Leg] = []
        var paused = 0.0
        var absorbed: [DateInterval] = []

        for row in rows.sorted(by: { $0.sequenceIndex < $1.sequenceIndex }) {
            guard let phase = WorkoutPhase(rawValue: row.phaseType) else {
                throw Failure.unrecognizedPhase(row.phaseType)
            }
            if phase == .paused {
                let pause = DateInterval(start: row.startDate, end: max(row.startDate, row.endDate))
                absorbed.append(pause)
                paused += pause.duration
                continue
            }
            let shift = absorbed.reduce(0) { $0 + $1.duration }
            let realStart = row.startDate.addingTimeInterval(-shift)
            legs.append(Leg(phase: phase,
                            repetition: row.repetitionNumber,
                            activeWindows: Self.windows(from: realStart, to: row.endDate, removing: absorbed),
                            endReason: row.endReason.flatMap(LegEndReason.init(rawValue:))))
            absorbed = []
        }
        self.legs = legs
        self.pausedSeconds = paused
    }

    /// `start…end` with each pause cut out.
    private static func windows(from start: Date, to end: Date,
                                removing pauses: [DateInterval]) -> [DateInterval] {
        var windows: [DateInterval] = []
        var cursor = start
        for pause in pauses.sorted(by: { $0.start < $1.start }) where pause.end > cursor && pause.start < end {
            if pause.start > cursor { windows.append(DateInterval(start: cursor, end: pause.start)) }
            cursor = max(cursor, pause.end)
        }
        if end > cursor { windows.append(DateInterval(start: cursor, end: end)) }
        return windows
    }

    // MARK: - Totals

    var runLegs: [Leg] { legs.filter { $0.phase == .run } }
    var runLegCount: Int { runLegs.count }
    var totalRunSeconds: Double { runLegs.reduce(0) { $0 + $1.activeSeconds } }
    var totalWalkSeconds: Double {
        legs.filter { $0.phase == .walk }.reduce(0) { $0 + $1.activeSeconds }
    }

    /// The main set as run, one round per run leg with the walk after it, whole seconds:
    /// `"752/181|354/181|209/0"`. A last run with nothing after it walked nothing, so its walk is
    /// a measured `0`, not a missing one. Nil when no run or walk was recorded at all.
    ///
    /// The same `run/walk` and `|` as `PlannedWorkout.blockShapeDescriptor`, without the `xN`:
    /// these are rounds that happened, each once, not segments that repeat.
    var shapeDescriptor: String? {
        var rounds: [(run: Double, walk: Double)] = []
        for leg in legs {
            switch leg.phase {
            case .run:
                rounds.append((leg.activeSeconds, 0))
            case .walk:
                // A walk before any run is still a round, with no running in it.
                if rounds.isEmpty { rounds.append((0, 0)) }
                rounds[rounds.count - 1].walk += leg.activeSeconds
            case .idle, .countdown, .warmup, .cooldown, .paused, .completed:
                continue
            }
        }
        guard !rounds.isEmpty else { return nil }
        return rounds
            .map { "\(Int($0.run.rounded()))/\(Int($0.walk.rounded()))" }
            .joined(separator: PlannedWorkout.blockShapeSeparator)
    }
}
