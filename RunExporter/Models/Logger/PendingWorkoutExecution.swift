import Foundation
import SwiftData

/// One attempt to actually perform a `PlannedWorkout` (spec §8.2).
///
/// Created when the plan is sent to the Watch or the iPhone timer is started, and later used to
/// match the finished HealthKit workout back to the plan. Holds a copy of the plan's shape rather
/// than a relationship, so editing the plan afterwards cannot rewrite what was actually run.
@Model
final class PendingWorkoutExecution {

    @Attribute(.unique) var id: UUID
    var plannedWorkoutID: UUID
    var expectedActivityType: String
    var createdAt: Date
    /// The plan's `expectedTotalSeconds` when the run began. Not set for an open-interval run, whose
    /// length is not known in advance; the matcher then scores on start time alone.
    var expectedDurationSeconds: Int?
    var status: String
    var matchedHealthKitWorkoutUUID: UUID?

    /// Plan shape at execution time, so a later edit to the plan cannot rewrite history.
    var plannedWorkoutName: String
    /// Not set when the run had no single interval shape — see `blockShape`. Never the first
    /// segment's length, which would be plausible and wrong. (Stored as 0 until `ShapeZeroRepair`.)
    var runIntervalSeconds: Int?
    var walkIntervalSeconds: Int?
    /// Rounds across the whole run. Well defined however many segments there were — four, for
    /// `5/1×1 → 8/1×2 → 5/1×1` — but not set for an open-interval run, whose rounds are decided
    /// during it. What was actually run is `completedRepetitions` and the run's legs.
    var plannedRepetitions: Int?

    /// The full shape that was run, as `"300/60x1|480/60x2|300/60x1"`.
    ///
    /// Optional only because sessions recorded before this column existed do not have one. For
    /// those, `runIntervalSeconds` and the two beside it are the truth about the run and must be
    /// read as such — a nil here means "not recorded", never "had several segments".
    ///
    /// Written from `PlannedWorkout.blockShapeDescriptor` for every new session, single-shape runs
    /// included, so it is not a column that only sometimes applies.
    var blockShape: String?

    /// Set when the iPhone timer is started; nil for a plan that was only sent to the Watch.
    var timerStartedAt: Date?
    var timerEndedAt: Date?
    /// Repetitions the timer actually completed. Nil when this app did not run the timer.
    var completedRepetitions: Int?

    /// The plan's intent when the run began (aerobic spec §1), copied for the same reason as its
    /// shape. Not set for a run recorded before intent existed — "not recorded", not `none`.
    var intensityMode: String?
    var targetRPEMin: Double?
    var targetRPEMax: Double?
    var targetHeartRateMin: Int?
    var targetHeartRateMax: Int?

    var updatedAt: Date

    init(id: UUID = UUID(),
         plannedWorkoutID: UUID,
         plannedWorkoutName: String,
         expectedActivityType: PlannedActivityType,
         expectedDurationSeconds: Int?,
         runIntervalSeconds: Int?,
         walkIntervalSeconds: Int?,
         plannedRepetitions: Int?,
         status: ExecutionStatus = .prepared,
         createdAt: Date = Date()) {
        self.id = id
        self.plannedWorkoutID = plannedWorkoutID
        self.plannedWorkoutName = plannedWorkoutName
        self.expectedActivityType = expectedActivityType.rawValue
        self.expectedDurationSeconds = expectedDurationSeconds
        self.runIntervalSeconds = runIntervalSeconds
        self.walkIntervalSeconds = walkIntervalSeconds
        self.plannedRepetitions = plannedRepetitions
        self.status = status.rawValue
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// A run of `plan` starting now on the phone's timer, with a copy of everything the plan
    /// decided in advance.
    ///
    /// Nil when the plan's activity type is not one this build recognizes; the caller says so.
    static func started(from plan: PlannedWorkout, at date: Date = Date()) -> PendingWorkoutExecution? {
        guard let activity = plan.activityTypeValue else { return nil }

        // A plan of several segments, or an open-interval one, has no single run or walk length,
        // so it records none — never the first segment's. `blockShape` carries the whole of it.
        // An open plan has no fixed rounds or length either; those come back nil from the plan.
        let singleShape = plan.singleShape

        let execution = PendingWorkoutExecution(
            plannedWorkoutID: plan.id,
            plannedWorkoutName: plan.name,
            expectedActivityType: activity,
            expectedDurationSeconds: plan.expectedTotalSeconds,
            runIntervalSeconds: singleShape?.runSeconds,
            walkIntervalSeconds: singleShape?.walkSeconds,
            plannedRepetitions: plan.totalRepetitions,
            status: .started,
            createdAt: date)
        execution.blockShape = plan.blockShapeDescriptor
        execution.timerStartedAt = date
        // Written for every new run, `none` included, so not set keeps meaning "recorded before
        // intent existed". A plan that predates the field has no intent, and says `none`.
        execution.intensityMode = plan.intensityMode ?? WorkoutIntensityMode.notSpecified.rawValue
        execution.targetRPEMin = plan.targetRPEMin
        execution.targetRPEMax = plan.targetRPEMax
        execution.targetHeartRateMin = plan.targetHeartRateMin
        execution.targetHeartRateMax = plan.targetHeartRateMax
        return execution
    }

    // MARK: - Typed accessors

    /// True when this run had segments of differing shape, so `runIntervalSeconds` and
    /// `walkIntervalSeconds` describe nothing and `blockShape` is the record of what was run.
    ///
    /// False for a session recorded before shapes were stored: nil means "not recorded", and that
    /// session's own columns are the truth about it.
    var hasMultipleBlocks: Bool {
        guard let blockShape else { return false }
        return blockShape.components(separatedBy: PlannedWorkout.blockShapeSeparator).count > 1
    }

    var statusValue: ExecutionStatus? { ExecutionStatus(rawValue: status) }
    var expectedActivityTypeValue: PlannedActivityType? {
        PlannedActivityType(rawValue: expectedActivityType)
    }

    func setStatus(_ newStatus: ExecutionStatus, at date: Date = Date()) {
        status = newStatus.rawValue
        updatedAt = date
    }

    /// An execution is still a matching candidate while it is unmatched and close enough in time
    /// that a finished workout could plausibly belong to it.
    ///
    /// The comparison is on the **absolute** distance deliberately. It used to be signed
    /// (`now.timeIntervalSince(createdAt) <= window`), which is true for *every* execution created
    /// after `now` however far after — so the method bounded nothing in one direction and only the
    /// caller's own `abs(...)` was doing the work. A guard that does not guard is worse than no
    /// guard, because every reader assumes it holds.
    func isMatchCandidate(now: Date, window: TimeInterval) -> Bool {
        guard matchedHealthKitWorkoutUUID == nil,
              let statusValue,
              ExecutionStatus.matchable.contains(statusValue) else { return false }
        return abs(now.timeIntervalSince(createdAt)) <= window
    }

    /// This execution expressed as something the matcher can score.
    ///
    /// One factory rather than a mapping written out at each call site. There were two — one per
    /// matching direction — and they disagreed about which timestamp to pass as `createdAt`, which
    /// is the field `score()` keys on. The same workout and execution could therefore score
    /// differently depending on which direction happened to ask.
    ///
    /// Anchors on `timerStartedAt` when there is one, because when the timer actually started is a
    /// better claim about when the run happened than when the record was created. For every
    /// execution in the owner's real data those are the same instant (measured: 23 of 23), so
    /// unifying on it changes no existing behavior — it only removes the chance of divergence.
    ///
    /// `nil` when the stored activity type is not one this build recognizes, which is the one case
    /// where the execution genuinely cannot be scored.
    var matchCandidate: RecentWorkoutMatcher.Candidate? {
        guard let activity = expectedActivityTypeValue else { return nil }
        return RecentWorkoutMatcher.Candidate(
            executionID: id,
            plannedWorkoutID: plannedWorkoutID,
            plannedWorkoutName: plannedWorkoutName,
            expectedActivityType: activity,
            expectedDurationSeconds: expectedDurationSeconds,
            createdAt: timerStartedAt ?? createdAt,
            timerStartedAt: timerStartedAt,
            timerEndedAt: timerEndedAt)
    }

    /// Whether this execution is an abandoned timer that should be retired to `.expired`.
    ///
    /// A timer that was *started and never stopped* has no end recorded, so the matcher cannot rule
    /// it out on evidence — `execution(forWorkout:candidates:)` keeps it as a candidate precisely
    /// because it may genuinely still have been running. Left alone it stays a candidate forever,
    /// and enough of them accumulating near a real run turns that run into an unresolvable
    /// ambiguity. Three abandoned timers are why one of the owner's real workouts cannot be linked.
    ///
    /// Deliberately narrow, and the narrowness is the point:
    ///
    /// - **`.completed` is never abandoned, however old.** The reverse matcher anchors on the
    ///   workout's own start date so that a run logged days later still resolves, and expiring
    ///   completed executions on age would break exactly that. Measured against the owner's real
    ///   data: every execution that has a `timerEndedAt` is `completed`, `matched` or `cancelled`,
    ///   and every one without is `started` — so this rule selects abandoned timers and nothing
    ///   else.
    /// - **`.prepared` and `.sentToWatch` are left alone** too. They are harmless under a 120-second
    ///   match window, and no real data has ever contained one. Not an oversight.
    func isAbandoned(now: Date, after threshold: TimeInterval) -> Bool {
        guard statusValue == .started, timerEndedAt == nil else { return false }
        return now.timeIntervalSince(createdAt) > threshold
    }
}
