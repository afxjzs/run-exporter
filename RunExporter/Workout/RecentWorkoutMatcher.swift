import Foundation

/// Decides which finished HealthKit workout belongs to which planned execution (spec §14).
///
/// The rule that governs everything here: **an uncertain match is never made silently.** When the
/// evidence does not clearly favour one workout, the matcher says so and the UI asks the user.
/// Attaching a subjective log to the wrong workout is unrecoverable in practice — the user has no
/// way to notice it later — so ambiguity is always escalated rather than resolved by a tiebreak.
enum RecentWorkoutMatcher {

    /// A pending execution reduced to the facts matching needs.
    struct Candidate {
        let executionID: UUID
        let plannedWorkoutID: UUID
        let plannedWorkoutName: String
        let expectedActivityType: PlannedActivityType
        let expectedDurationSeconds: Int
        let createdAt: Date

        /// When this app's interval timer actually ran, when it ran at all.
        ///
        /// Decisive where `createdAt` is not. Real data had eight cue-test executions inside 90
        /// minutes of one 7.4-minute run; five had already *finished* before that run began, some
        /// after 13 seconds. Judged on `createdAt` alone they looked indistinguishable, so nothing
        /// was linked — when the truthful answer was that none of them produced the run.
        ///
        /// Both default to nil so the forward direction, which runs while the timer is still going
        /// and has no end to report, is unaffected.
        let timerStartedAt: Date?
        let timerEndedAt: Date?

        init(executionID: UUID,
             plannedWorkoutID: UUID,
             plannedWorkoutName: String,
             expectedActivityType: PlannedActivityType,
             expectedDurationSeconds: Int,
             createdAt: Date,
             timerStartedAt: Date? = nil,
             timerEndedAt: Date? = nil) {
            self.executionID = executionID
            self.plannedWorkoutID = plannedWorkoutID
            self.plannedWorkoutName = plannedWorkoutName
            self.expectedActivityType = expectedActivityType
            self.expectedDurationSeconds = expectedDurationSeconds
            self.createdAt = createdAt
            self.timerStartedAt = timerStartedAt
            self.timerEndedAt = timerEndedAt
        }
    }

    enum Outcome: Equatable {
        /// One workout is clearly the right one.
        case matched(workoutUUID: UUID, executionID: UUID?)
        /// More than one plausible workout — the user must choose (spec §14).
        case ambiguous(workoutUUIDs: [UUID])
        /// Nothing recent enough to match.
        case noCandidates
        /// Workouts of the right activity exist, and every one of them starts further from the
        /// timer than `startToleranceSeconds` allows. Nearest first.
        ///
        /// Distinct from `.noCandidates` because the cause is knowable and the remedy differs.
        /// Collapsing the two told the user a start-time mismatch was a Watch that had not finished
        /// syncing, and advised waiting — which cannot help, since the reverse direction applies
        /// this same gate however long they wait. The evidence was in the caller's hand the whole
        /// time and was being thrown away.
        case outsideWindow(workoutUUIDs: [UUID], closestOffsetSeconds: TimeInterval)
    }

    /// How far from the expected start a workout can be and still be considered the same session.
    ///
    /// Compared against `createdAt`, which is the same instant as `timerStartedAt` for every
    /// execution this app has ever recorded (measured: 23 of 23 identical), so this is in practice
    /// "how long after starting the timer did the Watch workout start".
    ///
    /// Was 90 minutes, which measurement showed was strictly worse than any window under half an
    /// hour: across the owner's 23 real workouts, every window from 30s to 90min produced the same
    /// single automatic match, while only the windows at 60min and above pulled in abandoned timers
    /// and turned one workout into an unresolvable ambiguity. A wider window bought no matches and
    /// cost a link. The one verified match started its timer **1 second** before the workout began,
    /// so 120s leaves two orders of magnitude of headroom over real usage while still excluding the
    /// nearest stale timer by a margin of 28 minutes.
    ///
    /// Kept deliberately loose enough to survive starting the timer a minute late; tighter than
    /// that would trade a real fumble for no measurable gain.
    static let startToleranceSeconds: TimeInterval = 120

    /// How far out a workout can start and still be **offered** to the user as a near miss.
    ///
    /// Emphatically not a matching window. Nothing inside this bound is ever linked automatically;
    /// it only decides what is worth putting in front of someone, so that a run from yesterday is
    /// never proposed as the one just finished. Widening `startToleranceSeconds` instead would be
    /// the change measurement has already ruled out — see its own comment.
    ///
    /// Set to the same 90 minutes `score` treats as a completely wrong start, because that is
    /// already this file's stated opinion on when two sessions stop being plausibly related.
    static let nearMissWindowSeconds: TimeInterval = 90 * 60

    /// Two candidates whose scores are within this of each other are treated as indistinguishable.
    private static let ambiguityMargin = 0.15

    /// The start-time gap treated as "completely wrong" when scoring one candidate against another.
    ///
    /// Deliberately **not** `startToleranceSeconds`, though it was until the window was narrowed.
    /// The two answer different questions: the tolerance decides which candidates are *eligible at
    /// all*, while this decides how strongly to *prefer* one eligible candidate over another. Fusing
    /// them meant the confidence threshold moved whenever the window did — narrowing the window from
    /// 90 minutes to 2 scaled the start component of every score by 45, pushed every realistic pair
    /// past `ambiguityMargin`, and quietly converted "too close to call, so ask" into a confident
    /// pick. That is a behavior change nobody asked for, arriving as a side effect of an unrelated
    /// constant.
    ///
    /// Held at the original 90 minutes so that narrowing the window changed eligibility and nothing
    /// else. `testTwoSimilarWorkoutsAreAmbiguous` is what catches a regression here.
    private static let startScoreReferenceSeconds: TimeInterval = 90 * 60

    /// Picks the workout for a pending execution.
    ///
    /// - Parameters:
    ///   - workouts: unlogged workouts, any order.
    ///   - execution: the pending execution, or nil when the user is logging a workout that was
    ///     never planned in the app.
    static func match(workouts: [HealthKitManager.WorkoutSummary],
                      execution: Candidate?,
                      now: Date = Date()) -> Outcome {
        guard !workouts.isEmpty else { return .noCandidates }

        guard let execution else {
            // No plan to match against. One recent workout is unambiguous; several are not, and
            // guessing "the newest" would attach the log to whichever run happened to be last.
            if workouts.count == 1 {
                return .matched(workoutUUID: workouts[0].uuid, executionID: nil)
            }
            return .ambiguous(workoutUUIDs: workouts.map(\.uuid).sorted { $0.uuidString < $1.uuidString })
        }

        // Priority 0 (watch plan step 3): a workout our watch app saved carries the execution id.
        // That is proof rather than a guess, so it wins outright — whatever its start time — and a
        // workout tagged for a *different* run is never time-matched to this one. Untagged workouts
        // (older runs, Apple's Workout app) go on through the window below.
        if let tagged = workouts.first(where: { $0.executionID == execution.executionID }) {
            return .matched(workoutUUID: tagged.uuid, executionID: execution.executionID)
        }
        let workouts = workouts.filter { $0.executionID == nil }
        guard !workouts.isEmpty else { return .noCandidates }

        // Priority 1: the activity type must agree. A walk is never automatically accepted as the
        // run that was planned — the mismatch is offered to the user instead.
        let sameActivity = workouts.filter { $0.activityType == execution.expectedActivityType }
        let activityMatches = !sameActivity.isEmpty
        let pool = activityMatches ? sameActivity : workouts

        // Priority 2: it has to have happened around when the workout was prepared.
        let inWindow = pool.filter {
            abs($0.startDate.timeIntervalSince(execution.createdAt)) <= startToleranceSeconds
        }
        guard !inWindow.isEmpty else {
            return nearMiss(pool: pool, activityMatches: activityMatches, execution: execution)
        }

        // Checked before the single-candidate shortcut: being the only workout nearby is not
        // evidence that a walk was the planned run.
        guard activityMatches else {
            return .ambiguous(workoutUUIDs: inWindow.map(\.uuid))
        }

        if inWindow.count == 1 {
            return .matched(workoutUUID: inWindow[0].uuid, executionID: execution.executionID)
        }

        // Priorities 3 and 4: prefer the workout closest in start time and in duration to what
        // was planned.
        let scored = inWindow
            .map { (workout: $0, score: score($0, against: execution)) }
            .sorted { $0.score < $1.score }

        guard let best = scored.first, let runnerUp = scored.dropFirst().first else {
            // Unreachable: the empty case returned .noCandidates above and the single-candidate case
            // matched, so `scored` holds at least two entries by here. Kept as a guard rather than a
            // direct index so that if that ever stops being true this refuses instead of guessing.
            // The previous body indexed `scored[0]` immediately after testing `scored.first` for
            // nil, which means the one input it nominally protected against — an empty list — is
            // precisely the input it would have trapped on.
            return .noCandidates
        }

        // Priority 6: too close to call, so ask instead of picking.
        if runnerUp.score - best.score < ambiguityMargin {
            return .ambiguous(workoutUUIDs: scored.map(\.workout.uuid))
        }

        return .matched(workoutUUID: best.workout.uuid, executionID: execution.executionID)
    }

    /// Which execution produced a given workout.
    enum ExecutionMatch: Equatable {
        case matched(executionID: UUID)
        /// Nothing plausible. The ordinary result for a workout that was never planned in the app.
        case none
        /// More than one execution is equally plausible, so the caller must not pick one.
        case ambiguous(executionIDs: [UUID])
    }

    /// The execution that produced `workout`, for a run being logged **after** it finished.
    ///
    /// The reverse of `match(workouts:execution:)`, and it exists because the forward direction is
    /// only reachable from the active-workout screen. A run logged later, from the unlogged queue,
    /// had no execution on its draft at all — so its recorded interval boundaries were never
    /// stamped with a workout UUID and became permanently unjoinable. A real export showed 98
    /// interval records and 23 workouts with nothing connecting them, and no error anywhere.
    ///
    /// Same two rules as the forward direction, and the same refusal to guess: stamping intervals
    /// onto the wrong run is not something the user could notice later, so indistinguishable
    /// candidates are returned as `ambiguous` rather than resolved by a tiebreak.
    ///
    /// - Parameter candidates: executions still eligible to be matched. Filtering out ones already
    ///   matched is the caller's job — see `PendingWorkoutExecution.isMatchCandidate(now:window:)`.
    static func execution(forWorkout workout: HealthKitManager.WorkoutSummary,
                          candidates: [Candidate]) -> ExecutionMatch {
        // Priority 0, as in the forward direction: the tag names the run. A tag naming no eligible
        // candidate means its run is already matched or gone — guessing by time would stamp the
        // workout onto a different run, which is the one error nobody could notice later.
        if let tag = workout.executionID {
            return candidates.contains { $0.executionID == tag } ? .matched(executionID: tag) : .none
        }
        let sameActivity = candidates.filter { $0.expectedActivityType == workout.activityType }
        let inWindow = sameActivity.filter { candidate in
            // The timer has to have been running *during* the workout. A timer that had already
            // stopped before the workout began, or that started after it ended, cannot have
            // produced it however close the two were prepared. This is an exclusion on hard
            // evidence, not a preference — a timer left running with no end recorded stays a
            // candidate, because it may genuinely still have been going.
            if let ended = candidate.timerEndedAt, ended < workout.startDate { return false }
            if let started = candidate.timerStartedAt, started > workout.endDate { return false }
            return abs(workout.startDate.timeIntervalSince(candidate.createdAt)) <= startToleranceSeconds
        }
        guard !inWindow.isEmpty else { return .none }

        if inWindow.count == 1 {
            return .matched(executionID: inWindow[0].executionID)
        }

        let scored = inWindow
            .map { (candidate: $0, score: score(workout, against: $0)) }
            .sorted { $0.score < $1.score }

        guard let best = scored.first, let runnerUp = scored.dropFirst().first else {
            // Unreachable for the same reason as the forward direction: an empty list returned
            // .none above and a single candidate matched, so there are at least two here. Refusing
            // beats indexing blindly straight after a nil test.
            return .none
        }
        if runnerUp.score - best.score < ambiguityMargin {
            return .ambiguous(executionIDs: scored.map(\.candidate.executionID))
        }
        return .matched(executionID: best.candidate.executionID)
    }

    /// What to report when nothing fell inside the window: a diagnosable near miss, or nothing.
    ///
    /// A near miss is claimed only for workouts of the **right activity**. A walk sitting near a
    /// planned run is a different problem, and offering it would invite precisely the wrong
    /// confirmation — the one this file exists to refuse. Anything further out than
    /// `nearMissWindowSeconds` is not offered either, so yesterday's run is never proposed as this
    /// one.
    private static func nearMiss(pool: [HealthKitManager.WorkoutSummary],
                                 activityMatches: Bool,
                                 execution: Candidate) -> Outcome {
        guard activityMatches else { return .noCandidates }

        let byDistance = pool
            .map { (uuid: $0.uuid,
                    offset: abs($0.startDate.timeIntervalSince(execution.createdAt))) }
            .filter { $0.offset <= nearMissWindowSeconds }
            .sorted { $0.offset < $1.offset }

        guard let closest = byDistance.first else { return .noCandidates }
        return .outsideWindow(workoutUUIDs: byDistance.map(\.uuid),
                              closestOffsetSeconds: closest.offset)
    }

    /// Lower is better. Combines how far off the start was and how far off the duration was, each
    /// normalized so neither can dominate purely because it is measured in bigger numbers.
    private static func score(_ workout: HealthKitManager.WorkoutSummary,
                              against execution: Candidate) -> Double {
        let startOffset = abs(workout.startDate.timeIntervalSince(execution.createdAt))
        let startScore = startOffset / startScoreReferenceSeconds

        let expected = Double(execution.expectedDurationSeconds)
        let durationScore: Double
        if expected > 0 {
            durationScore = min(1, abs(workout.duration - expected) / expected)
        } else {
            // No expected duration to compare against, so it contributes nothing rather than a
            // fabricated penalty.
            durationScore = 0
        }

        return startScore + durationScore
    }

    /// Workouts with no run log, newest first — the "needs logging" queue.
    ///
    /// - Parameter hideBefore: workouts starting before this are never offered (spec §21).
    static func unloggedWorkouts(from workouts: [HealthKitManager.WorkoutSummary],
                                 loggedUUIDs: Set<UUID>,
                                 hideBefore: Date?) -> [HealthKitManager.WorkoutSummary] {
        workouts
            .filter { !loggedUUIDs.contains($0.uuid) }
            .filter { summary in
                guard let hideBefore else { return true }
                return summary.startDate >= hideBefore
            }
            .sorted { $0.startDate > $1.startDate }
    }
}
