import Foundation
import HealthKit
import WorkoutKit

/// Converts a `PlannedWorkout` into a WorkoutKit `CustomWorkout` and gets it onto the Watch
/// (spec §8).
///
/// `WorkoutScheduler.schedule(_:at:)` neither throws nor returns anything, so "it was sent" cannot
/// be inferred from calling it. Every send therefore reads the scheduled list back and confirms
/// the plan is actually there before reporting success — the UI must never claim a workout reached
/// the Watch when it did not.
@MainActor
struct WorkoutKitService {

    /// Only failures this app can actually observe.
    ///
    /// WorkoutKit's `StateError` (watch not paired, Workout app missing) is never thrown by any
    /// API reachable from iOS, so those are not separate cases here — claiming to distinguish them
    /// would be inventing a diagnosis. They surface as `notConfirmed`, whose message names them as
    /// the likely causes.
    enum SendError: LocalizedError {
        case unsupported
        case notAuthorized(WorkoutScheduler.AuthorizationState)
        case notConfirmed
        case scheduleFull(Int)

        var errorDescription: String? {
            switch self {
            case .unsupported:
                return "Sending workouts to Apple Watch is not supported on this device."
            case .notAuthorized(let state):
                switch state {
                case .denied:
                    return "This app is not allowed to schedule Watch workouts. Turn it on in "
                        + "Settings › Privacy & Security › Workout Scheduling."
                case .restricted:
                    return "Scheduling Watch workouts is restricted on this device."
                case .notDetermined:
                    return "Permission to schedule Watch workouts has not been granted yet."
                case .authorized:
                    // Reaching here means authorization was granted and the send still failed,
                    // which is a different problem than permission. Say so rather than showing a
                    // permissions message that would send the user to the wrong Settings screen.
                    return "Watch workout scheduling is authorized, but the workout still could "
                        + "not be sent. Try again."
                @unknown default:
                    return "Scheduling Watch workouts is unavailable (state \(state.rawValue))."
                }
            case .notConfirmed:
                return "This iPhone did not record the workout in its schedule, so it was not "
                    + "sent. Check that an Apple Watch is paired, that the Workout app is "
                    + "installed on it, and that it is nearby and unlocked, then try again."
            case .scheduleFull(let maximum):
                // The limit is on this iPhone's queue, not on the Watch, and the previous wording
                // said "Apple Watch already has…" — a claim about hardware this code cannot see.
                return "This iPhone's workout queue is full at \(maximum) entries. Clear it from "
                    + "Send to Watch, or restart the iPhone if clearing does not work."
            }
        }
    }

    /// A send this iPhone accepted and recorded in its own schedule.
    ///
    /// Says nothing about whether the Watch received it — `send` cannot know that, and no caller
    /// may present these fields as a fact about the wrist.
    struct SendResult {
        let workoutKitIdentifier: UUID
        let displayName: String
        let scheduledFor: DateComponents

        /// Whether this plan's previously-scheduled copy was cleared. `nil` when there was none.
        ///
        /// Carried rather than discarded because a failed cleanup is why duplicates accumulate, and
        /// the user is the only one who can see the resulting mess on the wrist.
        let previousInstanceRemoved: Bool?

        /// The moment this was scheduled for, when the components describe one.
        var scheduledDate: Date? { Calendar.current.date(from: scheduledFor) }
    }

    /// How far ahead of "now" a send schedules the workout.
    ///
    /// Sends used to schedule at `Date()` — the minute already in progress — which is an odd thing
    /// to ask a scheduler for: the appointment is in the past before the Watch has finished
    /// receiving it. Whether watchOS declines to surface a past-dated workout is **not established**
    /// (there is no documented rule and it has not been measured on the paired Series 5), so this is
    /// not presented as a fix for the sync failure. It removes a known-odd input, and the scheduled
    /// time is now shown to the user so the two can actually be compared.
    static let scheduleLeadSeconds: TimeInterval = 5 * 60

    var isSupported: Bool { WorkoutScheduler.isSupported }

    // MARK: - Conversion

    /// Builds the WorkoutKit representation of a plan.
    ///
    /// Mirrors `WorkoutPhaseSchedule` exactly, including the rule that the final run is not
    /// followed by a walk unless the plan asks for one — the Watch and the iPhone timer must not
    /// disagree about the shape of the workout.
    static func makeCustomWorkout(from plan: PlannedWorkout) throws -> CustomWorkout {
        let schedule = try WorkoutPhaseSchedule.build(from: plan)
        let activity = healthKitActivity(for: plan)

        var warmup: WorkoutStep?
        if let warmupPhase = schedule.phases.first(where: { $0.phase == .warmup }) {
            warmup = step(goal: goal(seconds: warmupPhase.plannedSeconds))
        }

        // One `IntervalBlock` per segment of the plan, built from `resolvedBlocks` — the same
        // source `WorkoutPhaseSchedule` expands for the iPhone timer. This used to read the flat
        // `runIntervalSeconds` / `plannedRepetitions` fields, which describe only a single-shape
        // plan: a plan of 5/1×1 → 8/1×2 → 5/1×1 reached the Watch as a plain repeat of its first
        // block, so the wrist ran a different workout from the phone without either saying so.
        //
        // A plan with no stored blocks resolves to exactly one segment carrying those same flat
        // fields, so an ordinary 4/1 × 5 is built precisely as it was before.
        var blocks: [IntervalBlock] = []
        let totalRepetitions = plan.totalRepetitions
        var repetitionsSoFar = 0

        for segment in plan.resolvedBlocks {
            // `WorkoutPhaseSchedule.build` above has already refused a segment with no repetitions
            // or no run time. This guards the arithmetic below rather than tolerating one.
            guard segment.repetitions > 0 else { continue }

            let runStep = IntervalStep(
                .work, step: step(goal: .time(Double(segment.runSeconds), .seconds)))

            repetitionsSoFar += segment.repetitions
            let endsTheWorkout = repetitionsSoFar == totalRepetitions

            guard segment.walkSeconds > 0 else {
                blocks.append(IntervalBlock(steps: [runStep], iterations: segment.repetitions))
                continue
            }

            let walkStep = IntervalStep(
                .recovery, step: step(goal: .time(Double(segment.walkSeconds), .seconds)))

            // "No walk after the final run" is a rule about the workout, not about each segment —
            // applied per segment it would strip the walk joining one segment to the next and weld
            // two runs together. Only the segment that ends the workout drops its trailing walk.
            if endsTheWorkout && !plan.includesFinalWalk {
                if segment.repetitions > 1 {
                    blocks.append(IntervalBlock(steps: [runStep, walkStep],
                                                iterations: segment.repetitions - 1))
                }
                blocks.append(IntervalBlock(steps: [runStep], iterations: 1))
            } else {
                blocks.append(IntervalBlock(steps: [runStep, walkStep],
                                            iterations: segment.repetitions))
            }
        }

        var cooldown: WorkoutStep?
        if let cooldownPhase = schedule.phases.first(where: { $0.phase == .cooldown }) {
            cooldown = step(goal: goal(seconds: cooldownPhase.plannedSeconds))
        }

        return CustomWorkout(activity: activity,
                             location: .outdoor,
                             displayName: plan.name,
                             warmup: warmup,
                             blocks: blocks,
                             cooldown: cooldown)
    }

    /// Builds a step using only API that exists on **watchOS 10**, the oldest watchOS this app can
    /// end up talking to.
    ///
    /// `WorkoutStep.displayName` is deliberately not set, even though the SDK offers it and the
    /// iPhone supports it. It is `@available(iOS 18.0, watchOS 11.0, *)`, and a workout built here
    /// is serialized and handed to the **paired Watch**, which may be older than this phone — an
    /// Apple Watch Series 5 cannot go beyond watchOS 10. Guarding it with `#available(iOS 18, *)`
    /// compiles cleanly and is wrong: an availability check describes *this* device, and says
    /// nothing about the one that will parse the payload. Sending a watchOS 11 field to a
    /// watchOS 10 Watch crashed and rebooted the Watch.
    ///
    /// There is no supported way to ask WorkoutKit what the paired Watch runs, so the only safe
    /// choice is to send nothing newer than the oldest Watch that can receive it. The cost is
    /// cosmetic: steps show Apple's generic labels instead of "Run"/"Walk". `IntervalStep.Purpose`
    /// still marks them as work and recovery, which is what the Watch actually cues from.
    private static func step(goal: WorkoutGoal) -> WorkoutStep {
        WorkoutStep(goal: goal)
    }

    private static func goal(seconds: Int?) -> WorkoutGoal {
        guard let seconds, seconds > 0 else { return .open }
        return .time(Double(seconds), .seconds)
    }

    private static func healthKitActivity(for plan: PlannedWorkout) -> HKWorkoutActivityType {
        switch plan.activityTypeValue {
        case .walking: return .walking
        case .running, nil: return .running
        }
    }

    // MARK: - Authorization

    @discardableResult
    func requestAuthorization() async -> WorkoutScheduler.AuthorizationState {
        await WorkoutScheduler.shared.requestAuthorization()
    }

    func authorizationState() async -> WorkoutScheduler.AuthorizationState {
        await WorkoutScheduler.shared.authorizationState
    }

    // MARK: - Sending

    /// Schedules the plan on **this iPhone's** WorkoutKit schedule and confirms it landed there.
    ///
    /// The confirmation below reads `WorkoutScheduler.shared.scheduledWorkouts`, which is the
    /// phone's copy of the schedule. It proves the phone accepted and recorded the workout. It does
    /// **not** prove the Watch received it — those are separate events, and nothing reachable from
    /// iOS can observe the second. Callers must not describe this result as a fact about the Watch.
    func send(plan: PlannedWorkout, on date: Date = Date()) async throws -> SendResult {
        guard WorkoutScheduler.isSupported else { throw SendError.unsupported }

        let state = await WorkoutScheduler.shared.requestAuthorization()
        guard state == .authorized else { throw SendError.notAuthorized(state) }

        let custom = try Self.makeCustomWorkout(from: plan)
        let workoutPlan = WorkoutPlan(.custom(custom))

        // Clear this plan's previous copy first. Every send builds a fresh `WorkoutPlan` with a new
        // id, and the plan only remembers the newest — so without this, re-sending stacks up copies
        // that share a display name and that the app can no longer address individually. Done before
        // the capacity check so freeing a slot actually counts toward it.
        var previousInstanceRemoved: Bool?
        if let identifier = plan.workoutKitIdentifier, let uuid = UUID(uuidString: identifier) {
            previousInstanceRemoved = await remove(identifier: uuid)
        }

        let existing = await WorkoutScheduler.shared.scheduledWorkouts
        let maximum = WorkoutScheduler.maxAllowedScheduledWorkoutCount
        if existing.count >= maximum {
            throw SendError.scheduleFull(maximum)
        }

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date.addingTimeInterval(Self.scheduleLeadSeconds))
        await WorkoutScheduler.shared.schedule(workoutPlan, at: components)

        // `schedule` reports nothing at all — no return value, no thrown error — so the only
        // honest confirmation is to read the list back and look for the plan just added.
        let updated = await WorkoutScheduler.shared.scheduledWorkouts
        guard updated.contains(where: { $0.plan.id == workoutPlan.id }) else {
            throw SendError.notConfirmed
        }

        return SendResult(workoutKitIdentifier: workoutPlan.id,
                          displayName: plan.name,
                          scheduledFor: components,
                          previousInstanceRemoved: previousInstanceRemoved)
    }

    // MARK: - Diagnostics

    /// What **this iPhone** currently holds in its WorkoutKit schedule.
    ///
    /// Exists because "I didn't see it on the Watch" has several very different causes —
    /// permission never granted, nothing ever scheduled, or scheduled but not delivered — and
    /// guessing between them wastes a Watch reboot per attempt.
    ///
    /// Every field here is read from the **phone's** schedule. None of it is an observation of the
    /// Watch, and no caller may present it as one: measured on 2026-08-07, a workout sat in this
    /// list for minutes before reaching the wrist, and the reverse (a removal not yet applied on
    /// the Watch) is equally possible. The screen that shows this is responsible for saying so.
    struct WatchStatus {
        let isSupported: Bool
        let authorization: WorkoutScheduler.AuthorizationState
        let scheduled: [ScheduledSummary]

        /// Queued appointments whose time has passed without completing.
        ///
        /// The number that matters most on the diagnostics screen: a healthy schedule trends toward
        /// zero, because entries either get done or get removed. A count that only grows means
        /// delivery is not happening and the queue is filling with workouts that never will.
        func overdueCount(now: Date = Date()) -> Int {
            scheduled.filter { $0.isOverdue(now: now) }.count
        }

        var authorizationDescription: String {
            switch authorization {
            case .authorized: return "authorized"
            case .denied: return "denied"
            case .restricted: return "restricted"
            case .notDetermined: return "not asked yet"
            @unknown default: return "unknown (\(authorization.rawValue))"
            }
        }
    }

    struct ScheduledSummary: Identifiable {
        let id: UUID
        let name: String
        let date: DateComponents
        let isComplete: Bool

        /// The scheduled moment, when the components describe one.
        var scheduledDate: Date? { Calendar.current.date(from: date) }

        /// An appointment whose time has passed without being completed.
        ///
        /// `date` is documented by Apple as "when the workout should begin", so once that moment is
        /// past and `complete` is still false, the workout did not happen — either it never reached
        /// the Watch, or it reached it and was ignored. Either way it will not happen now, and it
        /// keeps occupying one of the schedule's limited slots.
        ///
        /// Nothing surfaced this before. That is how an entry sat undelivered for 26 hours while the
        /// app displayed it next to fresh ones with no distinction, and every diagnosis this session
        /// was run on top of a queue nobody knew was stale.
        func isOverdue(now: Date = Date()) -> Bool {
            guard !isComplete, let scheduledDate else { return false }
            return scheduledDate < now
        }

        /// "overdue by 26h", "overdue by 4m" — how long this appointment has been missed.
        func overdueDescription(now: Date = Date()) -> String? {
            guard isOverdue(now: now), let scheduledDate else { return nil }
            let seconds = Int(now.timeIntervalSince(scheduledDate))
            if seconds < 3_600 { return "overdue by \(max(1, seconds / 60))m" }
            if seconds < 86_400 { return "overdue by \(seconds / 3_600)h" }
            return "overdue by \(seconds / 86_400)d"
        }
    }

    /// Reads this iPhone's WorkoutKit schedule without changing anything.
    ///
    /// Not the Watch's. `WorkoutScheduler.shared.scheduledWorkouts` is the list of workouts *this
    /// app* scheduled, and reading it back proves only that the phone recorded them.
    func status() async -> WatchStatus {
        guard WorkoutScheduler.isSupported else {
            return WatchStatus(isSupported: false, authorization: .notDetermined, scheduled: [])
        }

        let state = await WorkoutScheduler.shared.authorizationState
        let scheduled = await WorkoutScheduler.shared.scheduledWorkouts

        return WatchStatus(
            isSupported: true,
            authorization: state,
            scheduled: scheduled.map { entry in
                ScheduledSummary(id: entry.plan.id,
                                 name: Self.name(of: entry.plan),
                                 date: entry.date,
                                 isComplete: entry.complete)
            })
    }

    /// The user-visible name of a scheduled plan, whatever kind of workout it holds.
    private static func name(of plan: WorkoutPlan) -> String {
        switch plan.workout {
        case .custom(let custom):
            return custom.displayName ?? "Custom workout"
        case .goal, .pacer, .swimBikeRun:
            // Not produced by this app, but another app can schedule them.
            return "\(plan.workout.activity.self)"
        @unknown default:
            return "Unknown workout"
        }
    }

    /// Removes every workout this app has scheduled, and reports how many remain **on this iPhone**.
    ///
    /// A recovery path, not routine cleanup: a workout the Watch cannot parse stays in its
    /// schedule and can keep causing trouble every time the Watch tries to render it. A workout
    /// that did arrive is deleted on the Watch by hand — Outdoor Run, three-dot menu, custom
    /// workouts — which is what the app's own UI tells the user to do.
    ///
    /// The returned count is the phone's, read immediately after the removal, and a return of 0
    /// therefore means "this iPhone's schedule is empty" — **not** "the Watch is clear". The Watch
    /// has to receive the removal too, which takes as long as delivery does in the other direction.
    /// Two further limits worth knowing: `removeAllWorkouts` only removes what *this app*
    /// scheduled, so another app's entries survive it, and so does anything created natively on the
    /// Watch. A non-zero remainder is therefore not always something retrying can fix.
    @discardableResult
    func removeAllScheduledWorkouts() async -> Int {
        await WorkoutScheduler.shared.removeAllWorkouts()
        return await WorkoutScheduler.shared.scheduledWorkouts.count
    }

    /// Removes a previously scheduled plan, so re-sending does not consume this iPhone's limited
    /// scheduling slots. Returns whether the plan is gone afterwards.
    ///
    /// The limit is on the phone's queue, not on the Watch — the same distinction the queue-full
    /// error message draws.
    @discardableResult
    func remove(identifier: UUID) async -> Bool {
        let scheduled = await WorkoutScheduler.shared.scheduledWorkouts
        guard let match = scheduled.first(where: { $0.plan.id == identifier }) else {
            return true  // Already absent.
        }
        await WorkoutScheduler.shared.remove(match.plan, at: match.date)
        let remaining = await WorkoutScheduler.shared.scheduledWorkouts
        return !remaining.contains { $0.plan.id == identifier }
    }
}
