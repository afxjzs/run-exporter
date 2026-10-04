import Foundation
import Observation
import SwiftData

/// Shared state for the logging side of the app: recent HealthKit workouts, which of them already
/// have a run log, and the writes that create or update one.
///
/// Sits between the SwiftData store and the screens so the views stay declarative and the store is
/// touched in one place. Every failure lands in `errorMessage` rather than being swallowed.
@MainActor
@Observable
final class RunLoggerModel {

    private(set) var recentWorkouts: [HealthKitManager.WorkoutSummary] = []
    private(set) var unloggedWorkouts: [HealthKitManager.WorkoutSummary] = []
    private(set) var isLoading = false
    var errorMessage: String?

    /// Housekeeping the app did on its own, stated rather than performed quietly.
    ///
    /// Separate from `errorMessage` because retiring an abandoned timer is not a failure and does
    /// not belong under "Something went wrong" — but it does change which runs the app is able to
    /// link, so doing it silently would leave the user with a wrong belief about why a link
    /// happened or did not.
    var maintenanceNotice: String?

    /// HealthKit UUIDs that already have a run log.
    private(set) var loggedWorkoutUUIDs: Set<UUID> = []

    /// Bumped after every successful write, so views built from a store *fetch* re-render.
    ///
    /// `@Observable` can only track properties on this object. A view whose content comes from
    /// `runLog(forWorkout:)` or `recoveryLog(forWorkout:)` — direct SwiftData fetches — registers no
    /// dependency at all, so it keeps displaying whatever it rendered first. That is how a run log
    /// could save correctly and the screen still read "Not logged yet." with a "Log this run"
    /// button, reporting nothing wrong. Views that show fetched objects must read this.
    private(set) var storeRevision = 0

    private let health: HealthKitManager
    private let store: LoggerStore
    private let defaults: LoggerDefaults

    /// How far back the recent-workout list reads. Wider than the prompt window so the History
    /// screen can show older workouts the Home prompt intentionally hides.
    private static let historyHours = 24 * 120

    init(health: HealthKitManager = HealthKitManager(),
         store: LoggerStore,
         defaults: LoggerDefaults) {
        self.health = health
        self.store = store
        self.defaults = defaults
    }

    // MARK: - Loading

    func refresh() async {
        // Before the HealthKit guard on purpose: retiring abandoned timers is a store operation and
        // should still happen on a device where HealthKit is unavailable, so the backlog does not
        // grow silently while the app cannot read workouts.
        expireAbandonedExecutions()

        guard health.isAvailable else {
            errorMessage = "HealthKit is not available on this device, so workouts cannot be read."
            return
        }
        // The UI smoke test, Debug builds only: no request, so nothing to read. See `UITesting`.
        guard !UITesting.skipsHealthAuthorization else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            try await health.requestAuthorization()
        } catch {
            errorMessage = "Health access failed: \(error.localizedDescription)"
            return
        }

        do {
            // Same activity-type rule as the export, so the queue never offers a workout the
            // export would drop, and never hides one it would keep.
            recentWorkouts = try await health.fetchRecentWorkouts(
                hours: Self.historyHours,
                includeWalking: defaults.includeWalkingWorkouts,
                reclassifiedAsRunning: defaults.reclassifiedAsRunning)
        } catch {
            errorMessage = "Could not read recent workouts: \(error.localizedDescription)"
            return
        }

        reloadLoggedUUIDs()
        recomputeUnlogged()
        reconcilePendingCaptures(among: unloggedWorkouts)
    }

    /// Joins everything captured during a workout — notes and any log written mid-run — to the
    /// HealthKit workouts that have since arrived.
    ///
    /// The join used to be attempted **exactly once**: from `ActiveWorkoutView.findWorkoutToLog()`,
    /// at the moment the timer finished, and only on its `.matched` branch. HealthKit routinely does
    /// not have the Watch's workout yet at that instant — the cue feasibility test measured Watch
    /// sync in minutes — so the match returned `.noCandidates`, nothing attached, and the log stayed
    /// orphaned permanently: invisible to `runLog(forWorkout:)`, counted as unlogged forever, and
    /// liable to be overwritten by a blank form. One missed instant lost the user's writing.
    ///
    /// Running it on every refresh makes the join *eventually* consistent rather than one-shot, and
    /// repairs records already orphaned by the old behavior.
    ///
    /// **Captures, not logs.** This swept for orphaned `RunLog`s only, and returned early when there
    /// were none — so a workout that was noted but never logged had nothing to trigger it, and its
    /// notes waited for a code path the user never took. What makes something eligible is having
    /// *anything* unjoined, which is what `pendingCaptureExecutions()` answers. The run log was
    /// never the subject; it was one of the things being joined.
    ///
    /// **Joining to nothing is not treated as an error, deliberately.** The ordinary reason is that
    /// there is no HealthKit workout yet — either it has not synced, or the timer was run on the
    /// phone with no Watch at all, which is a supported way to use the app. Reporting that would
    /// fire on every refresh during a normal cooldown and would be wrong about a phone-only run.
    /// Real faults still surface: an unreadable store and a failed write both report.
    ///
    /// Internal rather than private, and takes the workouts to consider, so the sweep can be
    /// asserted against a real in-memory store instead of only reasoned about — the same reason
    /// `expireAbandonedExecutions(now:)` is shaped that way. `refresh()` is the only production
    /// caller. Returns how many executions it joined.
    @discardableResult
    func reconcilePendingCaptures(among workouts: [HealthKitManager.WorkoutSummary]) -> Int {
        guard let waiting = pendingCaptureExecutions(), !waiting.isEmpty else { return 0 }

        var joined = 0
        // `workouts` is a value-typed snapshot: `attach` recomputes `unloggedWorkouts` as it goes.
        for workout in workouts {
            guard let executionID = resolvedExecution(for: workout, reportProblems: false),
                  waiting.contains(executionID) else { continue }

            if let error = attach(workout: workout, toPendingLogFor: executionID) {
                errorMessage = "What you captured during your workout could not be joined to the "
                    + "run it belongs to: \(error)"
                return joined
            }
            joined += 1
        }
        return joined
    }

    /// Executions with something still waiting to be joined to a workout.
    ///
    /// Nil — distinct from empty — when the store could not be read, so the caller stops rather
    /// than treating an unreadable store as "nothing to do".
    ///
    /// Interval records are deliberately **not** counted as something waiting. Every run produces
    /// them, so they would make every unlogged workout eligible, and `attach` marks an execution
    /// matched and stamps its intervals — the sweep would silently link runs the user never asked
    /// to link. Notes and logs are things the user typed; their presence is the signal that this
    /// execution is worth joining, and the intervals then come along with them.
    private func pendingCaptureExecutions() -> Set<UUID>? {
        var waiting: Set<UUID> = []

        switch store.fetch(FetchDescriptor<RunLog>(
            predicate: #Predicate { $0.healthKitWorkoutUUID == nil })) {
        case .success(let orphans):
            waiting.formUnion(orphans.compactMap(\.executionID))
        case .failure(let error):
            errorMessage = error.message
            return nil
        }

        switch store.fetch(FetchDescriptor<WorkoutNote>(
            predicate: #Predicate { $0.healthKitWorkoutUUID == nil })) {
        case .success(let orphans):
            waiting.formUnion(orphans.map(\.executionID))
        case .failure(let error):
            errorMessage = error.message
            return nil
        }

        return waiting
    }

    private func reloadLoggedUUIDs() {
        switch store.fetch(FetchDescriptor<RunLog>()) {
        case .success(let logs):
            // Logs still awaiting a match have no workout UUID and so mark nothing as logged —
            // the workout they will attach to must stay in the unlogged queue until it does.
            loggedWorkoutUUIDs = Set(logs.compactMap(\.healthKitWorkoutUUID))
        case .failure(let error):
            errorMessage = error.message
        }
    }

    // MARK: - Retiring abandoned timers

    /// How long a started-but-never-stopped timer is given before it counts as abandoned.
    ///
    /// Generous on purpose. A timer that is still running is indistinguishable from one that was
    /// abandoned — both are `.started` with no end recorded — so this has to exceed the longest run
    /// anyone might plausibly be part-way through when the app is reopened. Twelve hours clears an
    /// ultramarathon while still retiring the same evening's test timers by morning.
    ///
    /// `nonisolated` because it is a compile-time constant of a Sendable type: isolating it to the
    /// main actor bought nothing and made every reader pay for the hop. Reading it from a
    /// nonisolated context is an error in the Swift 6 language mode, which `AbandonedTimerTests`
    /// hit; see the Swift 6 entry in `docs/BACKLOG.md`.
    nonisolated static let abandonedTimerThreshold: TimeInterval = 12 * 60 * 60

    /// Retires timers that were started and never stopped, and says so afterwards.
    ///
    /// `ExecutionStatus.expired` has existed since the model was written, and `matchable` has always
    /// excluded it, so the matcher already honours the retired state. Nothing ever *assigned* it,
    /// though — the retirement path was designed, respected, and unreachable. This is what makes it
    /// reachable.
    ///
    /// Retires rather than deletes. `WorkoutIntervalLog` refers to its execution by a plain
    /// `executionID` with no SwiftData relationship, so there is no cascade: deleting an execution
    /// would strand its interval records with an ID pointing at nothing, and they would keep
    /// exporting as though intact.
    /// Internal rather than private, and takes `now`, so the sweep can be asserted against a real
    /// in-memory store instead of only reasoned about. `refresh()` is the only production caller.
    func expireAbandonedExecutions(now: Date = Date()) {
        let executions: [PendingWorkoutExecution]
        switch store.fetch(FetchDescriptor<PendingWorkoutExecution>()) {
        case .success(let fetched):
            executions = fetched
        case .failure(let error):
            errorMessage = error.message
            return
        }

        let abandoned = executions.filter {
            $0.isAbandoned(now: now, after: Self.abandonedTimerThreshold)
        }
        guard !abandoned.isEmpty else { return }

        for execution in abandoned { execution.setStatus(.expired, at: now) }

        if let error = saveAndRecord() {
            errorMessage = "Could not retire \(abandoned.count) abandoned "
                + (abandoned.count == 1 ? "timer" : "timers") + ": \(error)"
            return
        }

        maintenanceNotice = Self.abandonedTimerNotice(count: abandoned.count)
    }

    /// The retirement wording, kept separate so it can be asserted without a store or a main actor.
    nonisolated static func abandonedTimerNotice(count: Int) -> String {
        let subject = count == 1
            ? "1 timer that was started and never stopped"
            : "\(count) timers that were started and never stopped"
        return "Retired \(subject). They were still being treated as possible matches for your "
            + "runs, which can stop a run from being linked to the intervals it recorded. Nothing "
            + "was deleted: those intervals are still in your export."
    }

    private func recomputeUnlogged() {
        // The prompt only reaches back `unloggedPromptDays`, so a long history of never-logged
        // workouts does not turn into a permanent to-do list (spec §21).
        let promptStart = Calendar.current.date(byAdding: .day,
                                                value: -defaults.unloggedPromptDays,
                                                to: Date())
        let hideBefore = [promptStart, defaults.hideUnloggedBefore].compactMap { $0 }.max()

        unloggedWorkouts = RecentWorkoutMatcher.unloggedWorkouts(
            from: recentWorkouts,
            loggedUUIDs: loggedWorkoutUUIDs,
            hideBefore: hideBefore)
    }

    // MARK: - Reclassifying a mislabelled walk

    /// Walking workouts available to browse, regardless of the walking filter.
    private(set) var walkingWorkouts: [HealthKitManager.WorkoutSummary] = []

    /// Loads walks so a run the Watch recorded as "Outdoor Walk" can be found and corrected.
    func loadWalkingWorkouts() async {
        guard health.isAvailable else { return }
        do {
            walkingWorkouts = try await health.fetchWalkingWorkouts(
                hours: Self.historyHours,
                reclassifiedAsRunning: defaults.reclassifiedAsRunning)
        } catch {
            errorMessage = "Could not read walking workouts: \(error.localizedDescription)"
        }
    }

    func isReclassifiedAsRunning(_ uuid: UUID) -> Bool {
        defaults.reclassifiedAsRunning.contains(uuid)
    }

    /// Marks a walk as really having been a run, or undoes that.
    ///
    /// Changes nothing in Apple Health — `HKWorkout` cannot be edited, and this app never writes
    /// to HealthKit. The annotation lives on this device and is applied when workouts are read.
    func setReclassifiedAsRunning(_ reclassified: Bool, for uuid: UUID) async {
        if reclassified {
            defaults.reclassifiedAsRunning.insert(uuid)
        } else {
            defaults.reclassifiedAsRunning.remove(uuid)
        }
        await refresh()
        await loadWalkingWorkouts()
    }

    // MARK: - Lookups

    func workout(withUUID uuid: UUID) -> HealthKitManager.WorkoutSummary? {
        recentWorkouts.first { $0.uuid == uuid }
    }

    func runLog(forWorkout uuid: UUID) -> RunLog? {
        var descriptor = FetchDescriptor<RunLog>(
            predicate: #Predicate { $0.healthKitWorkoutUUID == uuid })
        descriptor.fetchLimit = 1
        switch store.fetch(descriptor) {
        case .success(let logs):
            return logs.first
        case .failure(let error):
            errorMessage = error.message
            return nil
        }
    }

    func recoveryLog(forWorkout uuid: UUID) -> RecoveryLog? {
        var descriptor = FetchDescriptor<RecoveryLog>(
            predicate: #Predicate { $0.healthKitWorkoutUUID == uuid })
        descriptor.fetchLimit = 1
        switch store.fetch(descriptor) {
        case .success(let logs):
            return logs.first
        case .failure(let error):
            errorMessage = error.message
            return nil
        }
    }

    func intervalLogs(forWorkout uuid: UUID, executionID: UUID?) -> [WorkoutIntervalLog] {
        var descriptor = FetchDescriptor<WorkoutIntervalLog>(
            predicate: #Predicate { $0.healthKitWorkoutUUID == uuid })
        descriptor.sortBy = [SortDescriptor(\.sequenceIndex)]
        switch store.fetch(descriptor) {
        case .success(let logs) where !logs.isEmpty:
            return logs
        case .success:
            // Not yet stamped with the workout UUID — fall back to the execution that recorded
            // them, which is how intervals survive between finishing and matching.
            guard let executionID else { return [] }
            var byExecution = FetchDescriptor<WorkoutIntervalLog>(
                predicate: #Predicate { $0.executionID == executionID })
            byExecution.sortBy = [SortDescriptor(\.sequenceIndex)]
            switch store.fetch(byExecution) {
            case .success(let logs): return logs
            case .failure(let error):
                errorMessage = error.message
                return []
            }
        case .failure(let error):
            errorMessage = error.message
            return []
        }
    }

    // MARK: - Shoes

    func shoes(includeRetired: Bool = false) -> [Shoe] {
        var descriptor = FetchDescriptor<Shoe>()
        descriptor.sortBy = [SortDescriptor(\.displayName)]
        switch store.fetch(descriptor) {
        case .success(let shoes):
            return includeRetired ? shoes : shoes.filter { !$0.isRetired }
        case .failure(let error):
            errorMessage = error.message
            return []
        }
    }

    func shoe(withID id: UUID) -> Shoe? {
        var descriptor = FetchDescriptor<Shoe>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        switch store.fetch(descriptor) {
        case .success(let shoes): return shoes.first
        case .failure(let error):
            errorMessage = error.message
            return nil
        }
    }

    /// The shoe a new log should start with: the one used most recently, then the marked default.
    ///
    /// "Most recently used" is by workout date, not by when the log was typed, so logging an old
    /// workout does not change what the next run defaults to.
    func defaultShoe() -> Shoe? {
        var descriptor = FetchDescriptor<RunLog>()
        descriptor.sortBy = [SortDescriptor(\.workoutStartDate, order: .reverse)]
        descriptor.fetchLimit = 20
        if case .success(let logs) = store.fetch(descriptor) {
            for log in logs {
                if let shoeID = log.shoeID, let shoe = shoe(withID: shoeID), !shoe.isRetired {
                    return shoe
                }
            }
        }
        if let defaultID = defaults.defaultShoeID, let shoe = shoe(withID: defaultID),
           !shoe.isRetired {
            return shoe
        }
        return shoes().first { $0.isDefault } ?? shoes().first
    }

    /// Total miles on a shoe: its starting mileage plus every run log assigned to it.
    func totalMileage(for shoe: Shoe) -> Double {
        shoe.startingMileage + assignedMileage(for: shoe.id)
    }

    func assignedMileage(for shoeID: UUID) -> Double {
        ShoeMileage.assignedMiles(from: allAssignments())[shoeID] ?? 0
    }

    private func allAssignments() -> [ShoeMileage.Assignment] {
        switch store.fetch(FetchDescriptor<RunLog>()) {
        case .success(let logs):
            return logs.compactMap { log in
                guard let shoeID = log.shoeID else { return nil }
                return ShoeMileage.Assignment(shoeID: shoeID,
                                              workoutStartDate: log.workoutStartDate,
                                              distanceMiles: log.workoutDistanceMiles)
            }
        case .failure(let error):
            errorMessage = error.message
            return []
        }
    }

    // MARK: - Writing

    /// Saves, and on success records that the store changed. Returns the error message, if any.
    ///
    /// Every write goes through here rather than calling `store.save()` directly, so no future
    /// write can forget to bump `storeRevision` and leave a screen showing stale data.
    private func saveAndRecord() -> String? {
        if let error = store.save() { return error }
        storeRevision += 1
        return nil
    }

    /// The log written mid-workout for this execution, if there is one.
    func pendingLog(forExecution executionID: UUID) -> RunLog? {
        var descriptor = FetchDescriptor<RunLog>(
            predicate: #Predicate { $0.executionID == executionID && $0.healthKitWorkoutUUID == nil })
        descriptor.fetchLimit = 1
        switch store.fetch(descriptor) {
        case .success(let logs): return logs.first
        case .failure(let error):
            errorMessage = error.message
            return nil
        }
    }

    /// Any log already written for this execution, joined to a workout or not.
    ///
    /// Answers "have I logged this run?" without going through HealthKit, the matcher, or the
    /// unlogged queue — none of which can answer it at the moment the timer stops. A log written
    /// during cooldown has no workout UUID yet and the Watch's workout may not even exist, so every
    /// other signal reads as "nothing here" for a run that has in fact been logged.
    ///
    /// Deliberately not filtered on `healthKitWorkoutUUID`: both the pending and the joined states
    /// mean the same thing to the user, which is that they already did this.
    func existingLog(forExecution executionID: UUID) -> RunLog? {
        var descriptor = FetchDescriptor<RunLog>(
            predicate: #Predicate { $0.executionID == executionID })
        descriptor.fetchLimit = 1
        switch store.fetch(descriptor) {
        case .success(let logs): return logs.first
        case .failure(let error):
            errorMessage = error.message
            return nil
        }
    }

    /// The log written mid-workout for `workout`, when one exists but was never joined to it.
    ///
    /// A log written during cooldown carries no `healthKitWorkoutUUID` — the workout did not exist
    /// yet — so `runLog(forWorkout:)` cannot see it, however complete it is. Any screen offering to
    /// log a workout **must** consult this as well, or it presents a blank form over writing the
    /// user has already done, and saving that blank form overwrites it with nothing. That is not
    /// hypothetical: it is how a real cooldown log lost its notes.
    func pendingLog(forWorkout workout: HealthKitManager.WorkoutSummary) -> RunLog? {
        guard let executionID = resolvedExecution(for: workout, reportProblems: false) else {
            return nil
        }
        return pendingLog(forExecution: executionID)
    }

    /// Saves a log during the workout, before the HealthKit workout exists.
    ///
    /// Written against the execution rather than a workout UUID, and attached to the workout once
    /// the Watch's recording reaches HealthKit. The point is capturing how the run felt while it
    /// is still fresh, rather than after the walk home.
    @discardableResult
    func saveDuringWorkout(draft: RunLogDraft,
                           executionID: UUID,
                           startedAt: Date,
                           activityType: PlannedActivityType) -> String? {
        guard let context = store.context else {
            return "The run logger database is unavailable, so nothing was saved."
        }
        guard let rpe = draft.effortRPE else { return "Choose an effort RPE before saving." }
        guard let heat = draft.personalHeatRating else {
            return "Choose a personal heat rating before saving."
        }

        let log: RunLog
        if let existing = pendingLog(forExecution: executionID) {
            log = existing
        } else {
            log = RunLog(healthKitWorkoutUUID: nil,
                         workoutStartDate: startedAt,
                         // Distance is unknown until the Watch's workout arrives; it is filled in
                         // at match time rather than guessed at now.
                         workoutDistanceMiles: nil,
                         workoutActivityType: activityType.rawValue,
                         effortRPE: rpe,
                         personalHeatRating: heat)
            context.insert(log)
        }

        apply(draft, to: log, rpe: rpe, heat: heat)
        log.executionID = executionID
        // Applied on this path too, so "a save never blanks the plan shape" holds for every write
        // rather than only the one where the loss was observed.
        backfillPlanShape(on: log, fromExecution: executionID)
        copyIntent(on: log, fromExecution: executionID)
        log.updatedAt = Date()

        if let error = saveAndRecord() { return error }
        if let shoeID = draft.shoeID { defaults.defaultShoeID = shoeID }
        return nil
    }

    // MARK: - Notes captured during the workout

    /// Saves one mid-workout note, immediately.
    ///
    /// Called the moment the user taps Save on the note sheet, not at the end of the interval or
    /// the end of the run: the thought is on disk before anything else can go wrong.
    @discardableResult
    func saveNote(_ text: String,
                  executionID: UUID,
                  phase: WorkoutPhase,
                  repetition: Int?,
                  secondsIntoWorkout: Double,
                  at date: Date = Date()) -> String? {
        guard let context = store.context else {
            return "The run logger database is unavailable, so this note was not saved."
        }
        // Trimmed at the ends only. The interior is the user's own writing — a note thumbed into a
        // 60-second walk break is often two half-sentences on separate lines, and reflowing it
        // would be editing what they said.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "This note is empty, so nothing was saved. Type something first."
        }

        let note = WorkoutNote(executionID: executionID,
                               createdAt: date,
                               phaseType: phase,
                               repetitionNumber: repetition,
                               secondsIntoWorkout: secondsIntoWorkout,
                               text: trimmed)
        context.insert(note)
        return saveAndRecord()
    }

    /// Every note belonging to a finished workout, oldest first.
    ///
    /// Shaped exactly like `intervalLogs(forWorkout:executionID:)`, and for the same reason: a note
    /// written mid-run is not stamped with the workout until the Watch's recording reaches
    /// HealthKit, which on this hardware takes minutes. Reading only by UUID would show an empty
    /// list during that window, which is indistinguishable from having lost the note.
    func notes(forWorkout uuid: UUID, executionID: UUID?) -> [WorkoutNote] {
        // Read first so a screen built from this fetch re-renders after a note is saved.
        // Observation cannot see a SwiftData fetch; `storeRevision` is the only signal it can.
        _ = storeRevision

        var descriptor = FetchDescriptor<WorkoutNote>(
            predicate: #Predicate { $0.healthKitWorkoutUUID == uuid })
        descriptor.sortBy = [SortDescriptor(\.createdAt)]
        switch store.fetch(descriptor) {
        case .success(let notes) where !notes.isEmpty:
            return notes
        case .success:
            guard let executionID else { return [] }
            return self.notes(forExecution: executionID)
        case .failure(let error):
            errorMessage = error.message
            return []
        }
    }

    /// The timer session that produced this workout, for screens that need it without a run log.
    ///
    /// Notes are stamped with the workout inside `attach(workoutUUID:toExecution:)`, which only
    /// runs when a run log is saved or reconciled. A run that was noted but never logged therefore
    /// keeps notes that name only their execution — perfectly safe, present in the export, and
    /// invisible to any screen that has just a workout in hand. This is how such a screen finds
    /// them.
    ///
    /// Delegates to the same resolution the save path uses, rather than matching again here: a
    /// second implementation could disagree with the first, and this project has already been bitten
    /// by two hand-written copies of a mapping drifting apart. `reportProblems` is off because this
    /// is a read — the messages there are phrased for a save and would claim something was written.
    func execution(forWorkout workout: HealthKitManager.WorkoutSummary) -> UUID? {
        resolvedExecution(for: workout, reportProblems: false)
    }

    /// Every note written during one timer session, oldest first.
    func notes(forExecution executionID: UUID) -> [WorkoutNote] {
        _ = storeRevision

        var descriptor = FetchDescriptor<WorkoutNote>(
            predicate: #Predicate { $0.executionID == executionID })
        descriptor.sortBy = [SortDescriptor(\.createdAt)]
        switch store.fetch(descriptor) {
        case .success(let notes): return notes
        case .failure(let error):
            errorMessage = error.message
            return []
        }
    }

    /// Links a finished workout to the execution that produced it, and to the mid-workout log if
    /// one was written.
    ///
    /// **The interval stamping is deliberately not conditional on a mid-workout log existing.** It
    /// used to be: an early `return nil` for "there is no pending log" skipped it, and returned the
    /// value that means *no error*, which the caller reads as success. So a user who logged the run
    /// afterwards rather than during it got interval records naming no workout, with nothing
    /// reported anywhere. Whether the subjective half was written early has no bearing on which
    /// workout the intervals belong to.
    @discardableResult
    func attach(workout: HealthKitManager.WorkoutSummary, toPendingLogFor executionID: UUID) -> String? {
        if let log = pendingLog(forExecution: executionID) {
            log.healthKitWorkoutUUID = workout.uuid
            log.workoutStartDate = workout.startDate
            log.workoutDistanceMiles = workout.distanceMiles
            log.workoutActivityType = workout.activityType.rawValue
            log.updatedAt = Date()

            if let error = saveAndRecord() { return error }

            // Only a mid-workout log makes the workout *logged*. Without one it still needs the
            // user's ratings, so it has to stay in the queue.
            loggedWorkoutUUIDs.insert(workout.uuid)
            recomputeUnlogged()
        }

        attach(workoutUUID: workout.uuid, toExecution: executionID)
        return nil
    }

    /// Copies the editable fields of a draft onto a log.
    private func apply(_ draft: RunLogDraft, to log: RunLog, rpe: Double, heat: Double) {
        log.effortRPE = rpe
        log.personalHeatRating = heat
        for area in BodyArea.allCases {
            log.setSeverity(draft.severity(for: area), for: area)
        }
        log.shoeID = draft.shoeID
        log.notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : draft.notes
        log.plannedWorkoutID = draft.plannedWorkoutID
        log.runIntervalSeconds = draft.runIntervalSeconds
        log.walkIntervalSeconds = draft.walkIntervalSeconds
        log.plannedRepetitions = draft.plannedRepetitions
        log.completedRepetitions = draft.completedRepetitions
        applyTalkTest(draft, to: log)
    }

    /// Writes the talk test when the form asked it. A draft that never offered it carries nil, and
    /// nil never overwrites an answer already saved — the blank-form loss this file guards against
    /// elsewhere.
    private func applyTalkTest(_ draft: RunLogDraft, to log: RunLog) {
        if let talkTest = draft.talkTest { log.talkTest = talkTest.rawValue }
    }

    /// Copies the run's intent from its timer session (aerobic spec §1). The form does not edit
    /// intent, so the session — which copied it from the plan as the run began — is the authority,
    /// and a later edit to the plan cannot reach it. With no session nothing is written: a log of
    /// a run never planned in this app has no intent to report.
    private func copyIntent(on log: RunLog, fromExecution executionID: UUID?) {
        guard let executionID, let execution = executionRecord(id: executionID) else { return }
        log.intensityMode = execution.intensityMode
        log.targetRPEMin = execution.targetRPEMin
        log.targetRPEMax = execution.targetRPEMax
        log.targetHeartRateMin = execution.targetHeartRateMin
        log.targetHeartRateMax = execution.targetHeartRateMax
    }

    /// The intent of the run a timer session recorded, for the forms: they offer the talk test for
    /// an aerobic run only (§7). Nil when the session is unknown or predates intent.
    func intensity(forExecution executionID: UUID?) -> WorkoutIntensityMode? {
        guard let executionID, let execution = executionRecord(id: executionID) else { return nil }
        return execution.intensityMode.flatMap(WorkoutIntensityMode.init(rawValue:))
    }

    /// Fills the plan shape from the timer session when the draft does not carry it.
    ///
    /// A draft built from a blank form has no `plannedWorkoutID` and no interval shape, and writing
    /// those nils straight through is how a run logged a second time lost its plan linkage. The
    /// execution that produced the run still held every one of those values the
    /// whole time. Two such rows are still in the owner's data; re-saving either one repairs it,
    /// which is the only recovery route — there is deliberately no migration.
    ///
    /// **Fills gaps only.** A draft that states a value keeps it, including where it disagrees with
    /// the execution: someone editing the form is a better authority on what they did than a match
    /// is. With no execution nothing is filled at all — inventing a shape from a nearby run would be
    /// worse than a blank column, because a blank is visibly unknown and a wrong number is not.
    private func backfillPlanShape(on log: RunLog, fromExecution executionID: UUID?) {
        guard log.plannedWorkoutID == nil
                || log.runIntervalSeconds == nil
                || log.walkIntervalSeconds == nil
                || log.plannedRepetitions == nil
                || log.completedRepetitions == nil else { return }
        guard let executionID, let execution = executionRecord(id: executionID) else { return }

        if log.plannedWorkoutID == nil { log.plannedWorkoutID = execution.plannedWorkoutID }

        // A run of several segments has no single interval shape, and the session records zero to
        // say so. Copying that zero here would write "ran for no time" into a column meant to
        // describe the run — the same class of wrong number this backfill exists to prevent. The
        // shape of such a run is in the session's `blockShape` and in the export.
        if !execution.hasMultipleBlocks {
            if log.runIntervalSeconds == nil {
                log.runIntervalSeconds = execution.runIntervalSeconds
            }
            if log.walkIntervalSeconds == nil {
                log.walkIntervalSeconds = execution.walkIntervalSeconds
            }
        }
        if log.plannedRepetitions == nil { log.plannedRepetitions = execution.plannedRepetitions }
        if log.completedRepetitions == nil {
            log.completedRepetitions = execution.completedRepetitions
        }
    }

    /// One timer session by id. Reports an unreadable store rather than reading as "not found".
    private func executionRecord(id: UUID) -> PendingWorkoutExecution? {
        var descriptor = FetchDescriptor<PendingWorkoutExecution>(
            predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        switch store.fetch(descriptor) {
        case .success(let executions): return executions.first
        case .failure(let error):
            errorMessage = error.message
            return nil
        }
    }

    /// Creates or updates the run log for a workout. Returns an error message on failure.
    @discardableResult
    func save(draft: RunLogDraft, for workout: HealthKitManager.WorkoutSummary) -> String? {
        guard let context = store.context else {
            return "The run logger database is unavailable, so nothing was saved."
        }

        // Resolved before anything else because it serves both jobs below: reusing a log written
        // during the run, and stamping this workout onto the run's interval records. A draft built
        // from the workout carries no execution — the ordinary case when logging a run after it
        // finished — and that used to mean the intervals were linked to nothing at all.
        let executionID = draft.executionID ?? resolvedExecution(for: workout)

        let log: RunLog
        if let existing = runLog(forWorkout: workout.uuid) {
            log = existing
        } else if let executionID,
                  let pending = pendingLog(forExecution: executionID) {
            // A log written during the workout: attach it rather than creating a second one.
            log = pending
            log.healthKitWorkoutUUID = workout.uuid
        } else {
            log = RunLog(healthKitWorkoutUUID: workout.uuid,
                         workoutStartDate: workout.startDate,
                         workoutDistanceMiles: workout.distanceMiles,
                         workoutActivityType: workout.activityType.rawValue,
                         effortRPE: draft.effortRPE ?? 0,
                         personalHeatRating: draft.personalHeatRating ?? 0)
            context.insert(log)
        }

        guard let rpe = draft.effortRPE else {
            return "Choose an effort RPE before saving."
        }
        guard let heat = draft.personalHeatRating else {
            return "Choose a personal heat rating before saving."
        }

        // Refresh the workout snapshot too: distance can change if the workout was edited in
        // Health after it was first logged.
        log.workoutStartDate = workout.startDate
        log.workoutDistanceMiles = workout.distanceMiles
        log.workoutActivityType = workout.activityType.rawValue

        log.effortRPE = rpe
        log.personalHeatRating = heat
        for area in BodyArea.allCases {
            log.setSeverity(draft.severity(for: area), for: area)
        }
        log.shoeID = draft.shoeID
        log.notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : draft.notes
        log.plannedWorkoutID = draft.plannedWorkoutID
        log.executionID = executionID
        log.runIntervalSeconds = draft.runIntervalSeconds
        log.walkIntervalSeconds = draft.walkIntervalSeconds
        log.plannedRepetitions = draft.plannedRepetitions
        log.completedRepetitions = draft.completedRepetitions
        applyTalkTest(draft, to: log)
        backfillPlanShape(on: log, fromExecution: executionID)
        copyIntent(on: log, fromExecution: executionID)
        log.updatedAt = Date()

        if let error = saveAndRecord() { return error }

        // Stamp this workout's intervals and close out its execution, so the interval data is
        // reachable from the HealthKit UUID from now on.
        if let executionID {
            attach(workoutUUID: workout.uuid, toExecution: executionID)
        }
        if let shoeID = draft.shoeID {
            defaults.defaultShoeID = shoeID
        }

        loggedWorkoutUUIDs.insert(workout.uuid)
        recomputeUnlogged()
        return nil
    }

    /// The execution that produced `workout`, for a run being logged after it finished.
    ///
    /// `nil` is the ordinary answer for a workout that was never planned in this app. It is *not*
    /// the answer for a store that could not be read: that returns nil too, but reports first.
    /// Conflating the two is what let the original linking bug hide — an unreadable store and "no
    /// plan for this run" produced identical, silent behavior.
    ///
    /// More than one plausible execution is reported rather than resolved by a tiebreak: interval
    /// records stamped onto the wrong run would be wrong permanently, with no way to spot it.
    ///
    /// `reportProblems` exists because this mapping is now needed on read paths too — opening a log
    /// form, and the reconciliation sweep — where the messages below would be actively wrong. They
    /// are phrased for the save path ("Your run log was saved, but…"), and firing one while merely
    /// *loading* a form would tell the user something was written when nothing was. A store failure
    /// still reports either way: that is a real fault, not a diagnosis of the user's data.
    private func resolvedExecution(for workout: HealthKitManager.WorkoutSummary,
                                   reportProblems: Bool = true) -> UUID? {
        let executions: [PendingWorkoutExecution]
        switch store.fetch(FetchDescriptor<PendingWorkoutExecution>()) {
        case .success(let fetched):
            executions = fetched
        case .failure(let error):
            errorMessage = error.message
            return nil
        }

        // The workout's own start is the reference point, not "now" — a run logged days later must
        // still resolve against the executions that were live when it happened. The run a workout
        // is tagged with is exempt from the window: the tag is proof, and a Watch that joined late
        // (Try again, minutes in) saves a workout that starts well outside it. It must still be
        // unmatched and in a matchable state, like any other candidate.
        let eligible = executions.filter {
            let window = $0.id == workout.executionID
                ? TimeInterval.infinity
                : RecentWorkoutMatcher.startToleranceSeconds
            return $0.isMatchCandidate(now: workout.startDate, window: window)
        }
        let candidates = eligible.compactMap(\.matchCandidate)
        let unrecognized = eligible.count - candidates.count

        switch RecentWorkoutMatcher.execution(forWorkout: workout, candidates: candidates) {
        case .matched(let executionID):
            return executionID

        case .none:
            // Ordinarily there is simply no plan for this run, and that needs no comment. But if a
            // timer session was dropped because its stored activity type is not one this build
            // recognizes, that is a reason for the miss and must not vanish into a `compactMap`.
            if unrecognized > 0, reportProblems {
                let sessions = unrecognized == 1 ? "session" : "sessions"
                errorMessage = "\(unrecognized) timer \(sessions) could not be considered for this "
                    + "run, because the activity recorded against "
                    + (unrecognized == 1 ? "it is" : "them is")
                    + " not one this version of the app recognizes."
            }
            return nil

        case .ambiguous(let executionIDs):
            // Refusing to guess is right — intervals stamped onto the wrong run are wrong forever.
            // Refusing to guess and then saying nothing was not: the choice is now offered on the
            // workout's own History screen, so this points there rather than dead-ending.
            guard reportProblems else { return nil }
            errorMessage = "Your run log was saved, but its recorded intervals were left "
                + "unattached: \(executionIDs.count) timer sessions overlap this run closely "
                + "enough that picking one could attach them to the wrong run. Open this run in "
                + "History to choose which timer session was this one."
            return nil
        }
    }

    // MARK: - Choosing a timer session by hand

    /// One timer session the user could attach a workout's interval records to.
    struct ExecutionChoice: Identifiable, Equatable {
        let id: UUID
        let startedAt: Date
        let endedAt: Date?
        let planName: String
        let intervalCount: Int
    }

    /// The timer sessions that could plausibly have produced `workout`, for the case where the app
    /// could not tell which one did.
    ///
    /// Refusing to guess is right: intervals stamped onto the wrong run are wrong permanently and
    /// invisibly. Refusing to guess *and then offering nothing* was the actual defect — the user
    /// knows which run they did, and had no way to say so, which made an ambiguous run permanently
    /// unlinkable (spec §14 priority 6, built for the forward direction and never this one).
    ///
    /// Empty when the matcher is confident, and empty when nothing is plausible. An empty list must
    /// render as no picker at all: offering a choice that does not exist is its own lie.
    func executionChoices(for workout: HealthKitManager.WorkoutSummary) -> [ExecutionChoice] {
        // Read first so a screen built from these fetches re-renders after a link is made. Same
        // reason `HistoryView` reads it — Observation cannot see a SwiftData fetch.
        _ = storeRevision

        let executions: [PendingWorkoutExecution]
        switch store.fetch(FetchDescriptor<PendingWorkoutExecution>()) {
        case .success(let fetched):
            executions = fetched
        case .failure(let error):
            errorMessage = error.message
            return []
        }

        let eligible = executions.filter {
            $0.isMatchCandidate(now: workout.startDate,
                                window: RecentWorkoutMatcher.startToleranceSeconds)
        }
        guard case .ambiguous(let executionIDs) = RecentWorkoutMatcher.execution(
                forWorkout: workout,
                candidates: eligible.compactMap(\.matchCandidate)) else { return [] }

        let offered = Set(executionIDs)
        return eligible
            .filter { offered.contains($0.id) }
            .map { execution in
                ExecutionChoice(id: execution.id,
                                startedAt: execution.timerStartedAt ?? execution.createdAt,
                                endedAt: execution.timerEndedAt,
                                planName: execution.plannedWorkoutName,
                                intervalCount: intervalCount(forExecution: execution.id))
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Attaches `workout` to the timer session the user chose, and stamps that session's intervals.
    ///
    /// The same `attach` the automatic path uses, so a hand-made link is indistinguishable from an
    /// automatic one afterwards — including in the export.
    func linkIntervals(ofExecution executionID: UUID,
                       to workout: HealthKitManager.WorkoutSummary) {
        attach(workoutUUID: workout.uuid, toExecution: executionID)
    }

    private func intervalCount(forExecution executionID: UUID) -> Int {
        let descriptor = FetchDescriptor<WorkoutIntervalLog>(
            predicate: #Predicate { $0.executionID == executionID })
        switch store.fetch(descriptor) {
        case .success(let logs):
            return logs.count
        case .failure(let error):
            errorMessage = error.message
            return 0
        }
    }

    /// Links a finished workout to the execution that produced it and stamps its intervals.
    ///
    /// Every step here can fail independently, and each failure leaves the log saved but the
    /// intervals unlinked — which is invisible on screen and indistinguishable from a run that was
    /// never planned. So problems accumulate and are reported together: assigning `errorMessage`
    /// per step would let a later failure quietly overwrite an earlier one.
    private func attach(workoutUUID: UUID, toExecution executionID: UUID) {
        var problems: [String] = []

        var descriptor = FetchDescriptor<PendingWorkoutExecution>(
            predicate: #Predicate { $0.id == executionID })
        descriptor.fetchLimit = 1
        switch store.fetch(descriptor) {
        case .success(let executions):
            if let execution = executions.first {
                execution.matchedHealthKitWorkoutUUID = workoutUUID
                execution.setStatus(.matched)
            } else {
                // `executionID` came from an execution read moments ago, so its absence now is a
                // real anomaly rather than an ordinary miss. Stamping the intervals is still worth
                // attempting: they key on `executionID`, not on this object.
                problems.append("the timer session it came from could no longer be found, so it "
                                + "was not marked as matched.")
            }
        case .failure(let error):
            problems.append("reading the timer session failed: \(error.message)")
        }

        let intervals = FetchDescriptor<WorkoutIntervalLog>(
            predicate: #Predicate { $0.executionID == executionID })
        switch store.fetch(intervals) {
        case .success(let logs):
            for log in logs { log.healthKitWorkoutUUID = workoutUUID }
        case .failure(let error):
            problems.append("reading its recorded intervals failed, so they were left "
                            + "unattached: \(error.message)")
        }

        // Notes written mid-workout are stamped here for the same reason the intervals are, and
        // deliberately in the same place: every route that links a workout to an execution — the
        // automatic match, the reconciliation sweep, and the user resolving an ambiguity by hand —
        // goes through this method. Stamping them anywhere else would leave one of those routes
        // attaching the intervals and quietly abandoning the notes.
        let notes = FetchDescriptor<WorkoutNote>(
            predicate: #Predicate { $0.executionID == executionID })
        switch store.fetch(notes) {
        case .success(let notes):
            for note in notes { note.healthKitWorkoutUUID = workoutUUID }
        case .failure(let error):
            problems.append("reading the notes written during it failed, so they were left "
                            + "unattached: \(error.message)")
        }

        if let error = saveAndRecord() {
            problems.append("linking it to the workout's intervals failed: \(error)")
        }

        if !problems.isEmpty {
            errorMessage = "Your run log was saved, but " + problems.joined(separator: " Also, ")
        }
    }

    /// Creates or updates the next-day recovery log.
    @discardableResult
    func saveRecovery(rating: Double,
                      severities: [BodyArea: Double],
                      notes: String?,
                      for workoutUUID: UUID) -> String? {
        guard let context = store.context else {
            return "The run logger database is unavailable, so nothing was saved."
        }

        let log: RecoveryLog
        if let existing = recoveryLog(forWorkout: workoutUUID) {
            log = existing
        } else {
            log = RecoveryLog(healthKitWorkoutUUID: workoutUUID, recoveryRating: rating)
            log.runLogID = runLog(forWorkout: workoutUUID)?.id
            context.insert(log)
        }

        log.recoveryRating = rating
        for area in BodyArea.allCases {
            log.setSeverity(severities[area] ?? 0, for: area)
        }
        log.notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? notes : nil
        log.updatedAt = Date()
        return saveAndRecord()
    }

    /// Marks a workout as intentionally never being logged, by hiding everything before it
    /// (spec §21).
    func hideUnloggedWorkouts(before date: Date) {
        defaults.hideUnloggedBefore = date
        recomputeUnlogged()
    }
}

/// The in-progress contents of the post-run form.
///
/// RPE and heat rating are optional here and required at save: the form must be able to show
/// "not chosen yet" rather than pre-selecting a value the user never picked (spec §26, Test 6).
struct RunLogDraft {
    var effortRPE: Double?
    var personalHeatRating: Double?
    var severities: [BodyArea: Double] = [:]
    var shoeID: UUID?
    var notes: String = ""

    var plannedWorkoutID: UUID?
    var executionID: UUID?
    var runIntervalSeconds: Int?
    var walkIntervalSeconds: Int?
    var plannedRepetitions: Int?
    var completedRepetitions: Int?

    /// Nil until the form offers the talk test, which it does for an aerobic run only (§7).
    var talkTest: TalkTest?

    func severity(for area: BodyArea) -> Double { severities[area] ?? 0 }

    var isComplete: Bool { effortRPE != nil && personalHeatRating != nil }

    /// Rebuilds a draft from a saved log, for editing.
    init(log: RunLog) {
        effortRPE = log.effortRPE
        personalHeatRating = log.personalHeatRating
        for area in BodyArea.allCases { severities[area] = log.severity(for: area) }
        shoeID = log.shoeID
        notes = log.notes ?? ""
        plannedWorkoutID = log.plannedWorkoutID
        executionID = log.executionID
        runIntervalSeconds = log.runIntervalSeconds
        walkIntervalSeconds = log.walkIntervalSeconds
        plannedRepetitions = log.plannedRepetitions
        completedRepetitions = log.completedRepetitions
        talkTest = log.talkTest.flatMap(TalkTest.init(rawValue:))
    }

    /// A fresh draft. Body signals start at zero (spec §15.3); the two ratings start unset.
    init(shoeID: UUID?) {
        self.shoeID = shoeID
        for area in BodyArea.allCases { severities[area] = 0 }
    }
}
