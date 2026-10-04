import Foundation
import SwiftData

/// Copies the logger's SwiftData contents into a plain `LoggerExportData` value.
///
/// Runs on the main actor because that is where the store's context lives; the resulting value is
/// then handed to the export task. Every failure — an unopenable store, an unreadable model, a
/// stored enum string this build does not recognize — becomes an `ExportLogEntry` that ends up in
/// `export_log.json`. Nothing is dropped quietly.
enum LoggerExportSnapshot {

    @MainActor
    static func make(store: LoggerStore) -> LoggerExportData {
        var data = LoggerExportData()

        guard store.container != nil else {
            data.storeUnavailable = true
            data.issues.append(ExportLogEntry(
                level: .error, category: "run_logger",
                message: (store.containerError ?? "The run logger database is unavailable.")
                    + " Logger CSV files were written with headers only."))
            return data
        }

        data.shoes = fetch(store, sortBy: [SortDescriptor(\Shoe.displayName)], into: &data.issues)
            .map(row(for:))

        let plans: [PlannedWorkout] = fetch(store,
                                            sortBy: [SortDescriptor(\PlannedWorkout.createdAt)],
                                            into: &data.issues)
        data.plannedWorkouts = plans.map { row(for: $0, issues: &data.issues) }
        data.plannedWorkoutBlocks = plans.flatMap(blockRows(for:))

        let runLogs: [RunLog] = fetch(store, sortBy: [SortDescriptor(\RunLog.workoutStartDate)],
                                      into: &data.issues)
        let shoeNames = Dictionary(data.shoes.map { ($0.shoeID, $0.displayName) },
                                   uniquingKeysWith: { first, _ in first })
        data.runLogs = runLogs.map { row(for: $0, shoeNames: shoeNames) }
        data.bodySignalDetails = runLogs.flatMap { log in
            log.bodySignalDetails.map { row(for: $0, log: log) }
        }

        data.recoveryLogs = fetch(store, sortBy: [SortDescriptor(\RecoveryLog.createdAt)],
                                  into: &data.issues)
            .map(row(for:))

        data.intervalLogs = fetch(store,
                                  sortBy: [SortDescriptor(\WorkoutIntervalLog.startDate),
                                           SortDescriptor(\WorkoutIntervalLog.sequenceIndex)],
                                  into: &data.issues)
            .map { row(for: $0, issues: &data.issues) }

        data.executions = fetch(store,
                                sortBy: [SortDescriptor(\PendingWorkoutExecution.createdAt)],
                                into: &data.issues)
            .map { row(for: $0, issues: &data.issues) }

        data.notes = fetch(store, sortBy: [SortDescriptor(\WorkoutNote.createdAt)],
                           into: &data.issues)
            .map { row(for: $0, issues: &data.issues) }

        data.index()
        return data
    }

    // MARK: - Fetching

    @MainActor
    private static func fetch<T: PersistentModel>(_ store: LoggerStore,
                                                  sortBy: [SortDescriptor<T>],
                                                  into issues: inout [ExportLogEntry]) -> [T] {
        var descriptor = FetchDescriptor<T>()
        descriptor.sortBy = sortBy
        switch store.fetch(descriptor) {
        case .success(let models):
            return models
        case .failure(let error):
            issues.append(ExportLogEntry(
                level: .error, category: "run_logger",
                message: "\(error.message) That file was written with headers only."))
            return []
        }
    }

    // MARK: - Row construction

    private static func row(for shoe: Shoe) -> ShoeExportRow {
        ShoeExportRow(shoeID: shoe.id.uuidString,
                      brand: shoe.brand,
                      model: shoe.model,
                      displayName: shoe.displayName,
                      firstUseDate: shoe.firstUseDate,
                      retiredDate: shoe.retiredDate,
                      startingMileage: shoe.startingMileage,
                      isDefault: shoe.isDefault,
                      notes: shoe.notes)
    }

    private static func row(for plan: PlannedWorkout,
                            issues: inout [ExportLogEntry]) -> PlannedWorkoutExportRow {
        check(plan.warmupModeValue, raw: plan.warmupMode,
              label: "warmup mode", subject: "planned workout \(plan.id)", issues: &issues)
        check(plan.cooldownModeValue, raw: plan.cooldownMode,
              label: "cooldown mode", subject: "planned workout \(plan.id)", issues: &issues)
        check(plan.activityTypeValue, raw: plan.activityType,
              label: "activity type", subject: "planned workout \(plan.id)", issues: &issues)

        // What the plan decided in advance, per kind. A plan of several segments has no single run
        // length, walk length or rounds — `planned_workout_blocks.csv` carries its segments. An
        // open-interval plan decides its walk (the floor, the shortest walk it allows) and nothing
        // else here; its legs and rounds are decided during the run and reported per run. A
        // damaged plan has nothing. Blank in each of those places, never a zero standing in for it.
        let decided: (run: Int?, walk: Int?, rounds: Int?)
        switch plan.shape {
        case .openIntervals(_, let walkFloor):
            decided = (nil, walkFloor, nil)
        case .intervals, .damaged:
            decided = plan.singleShape.map { ($0.runSeconds, $0.walkSeconds, $0.repetitions) }
                ?? (nil, nil, nil)
        }

        return PlannedWorkoutExportRow(
            plannedWorkoutID: plan.id.uuidString,
            name: plan.name,
            activityType: plan.activityType,
            warmupMode: plan.warmupMode,
            warmupSeconds: plan.warmupSeconds,
            runIntervalSeconds: decided.run,
            walkIntervalSeconds: decided.walk,
            plannedRepetitions: decided.rounds,
            includesFinalWalk: plan.includesFinalWalk,
            cooldownMode: plan.cooldownMode,
            cooldownSeconds: plan.cooldownSeconds,
            countdownSeconds: plan.countdownSeconds,
            totalRunSeconds: plan.totalRunSeconds,
            totalWalkSeconds: plan.totalWalkSeconds,
            mainSetSeconds: plan.mainSetSeconds,
            isNextWorkout: plan.isNextWorkout,
            workoutKitIdentifier: plan.workoutKitIdentifier,
            createdAt: plan.createdAt,
            updatedAt: plan.updatedAt,
            openIntervalTargetSeconds: plan.openIntervalShape?.targetRunSeconds,
            openIntervalWalkFloorSeconds: plan.openIntervalShape?.walkFloorSeconds)
    }

    /// A plan's segments, in the order it runs them.
    ///
    /// Built from `resolvedBlocks`, so a plan with no stored blocks contributes exactly one row
    /// describing its flat fields. Every plan with fixed segments appears, which is what lets this
    /// file be read as the complete answer to "what segments does this plan run". An open-interval
    /// plan has no segments, and a damaged plan has lost them, so neither has a row: the first is
    /// described by `planned_workouts.csv`'s open-interval columns, the second by its warning.
    private static func blockRows(for plan: PlannedWorkout) -> [PlannedWorkoutBlockExportRow] {
        // `position` is the enumeration index, not the stored `orderIndex`: `resolvedBlocks` has
        // already sorted by that field, and renumbering densely here means the exported sequence
        // describes the order the plan is performed in even if the stored indices have gaps.
        plan.resolvedBlocks.enumerated().map { index, block in
            PlannedWorkoutBlockExportRow(plannedWorkoutID: plan.id.uuidString,
                                         position: index,
                                         runIntervalSeconds: block.runSeconds,
                                         walkIntervalSeconds: block.walkSeconds,
                                         repetitions: block.repetitions)
        }
    }

    /// Captures written mid-workout that have not yet been joined to a HealthKit workout.
    ///
    /// Counts notes as well as logs. This gated the export's pre-flight reconciliation on orphaned
    /// `RunLog`s alone, which made it blind to the case `LEARNINGS.md` calls ordinary: a run with
    /// three notes and no run log, because a note asks for no RPE. That run scored zero, the sweep
    /// never ran, and its notes exported unjoined with no line in `export_log.json` — the same
    /// "reconcile logs, not captures" mistake the sweep itself was reshaped to fix, reintroduced in
    /// front of it.
    ///
    /// A record with no `executionID` is not waiting for anything: it belongs to no timer session
    /// and never will. Notes always carry one.
    @MainActor
    static func pendingCaptureCounts(store: LoggerStore) -> (logs: Int, notes: Int, total: Int) {
        let logDescriptor = FetchDescriptor<RunLog>(
            predicate: #Predicate { $0.healthKitWorkoutUUID == nil && $0.executionID != nil })
        let noteDescriptor = FetchDescriptor<WorkoutNote>(
            predicate: #Predicate { $0.healthKitWorkoutUUID == nil })

        var logs = 0
        var notes = 0
        if case .success(let rows) = store.fetch(logDescriptor) { logs = rows.count }
        if case .success(let rows) = store.fetch(noteDescriptor) { notes = rows.count }
        return (logs: logs, notes: notes, total: logs + notes)
    }

    /// Interval rows that will export with no workout UUID.
    ///
    /// `pendingCaptureCounts` above deliberately does not count these — it gates the reconcile
    /// sweep, and legs are joined as a side effect of joining their execution, not on their own. But
    /// nothing else counted them either, so a run whose legs never reached a workout exported with
    /// a blank column and not one word anywhere. `row(for: WorkoutIntervalLog)` checks only the
    /// phase type, so the silence was total.
    @MainActor
    static func unjoinedIntervalLegCount(store: LoggerStore) -> Int {
        let descriptor = FetchDescriptor<WorkoutIntervalLog>(
            predicate: #Predicate { $0.healthKitWorkoutUUID == nil })
        guard case .success(let rows) = store.fetch(descriptor) else { return 0 }
        return rows.count
    }

    private static func row(for log: RunLog, shoeNames: [String: String]) -> RunLogExportRow {
        let shoeID = log.shoeID?.uuidString
        var row = RunLogExportRow(
            runLogID: log.id.uuidString,
            // Blank while a mid-workout log is still waiting to be matched to a HealthKit
            // workout. `executionID` identifies it until then.
            healthKitWorkoutUUID: log.healthKitWorkoutUUID?.uuidString ?? "",
            plannedWorkoutID: log.plannedWorkoutID?.uuidString,
            executionID: log.executionID?.uuidString,
            createdAt: log.createdAt,
            updatedAt: log.updatedAt,
            runIntervalSeconds: log.runIntervalSeconds,
            walkIntervalSeconds: log.walkIntervalSeconds,
            plannedRepetitions: log.plannedRepetitions,
            completedRepetitions: log.completedRepetitions,
            effortRPE: log.effortRPE,
            personalHeatRating: log.personalHeatRating,
            lowerBackSeverity: log.lowerBackSeverity,
            leftAnkleSeverity: log.leftAnkleSeverity,
            rightAnkleSeverity: log.rightAnkleSeverity,
            leftKneeSeverity: log.leftKneeSeverity,
            rightKneeSeverity: log.rightKneeSeverity,
            shoeID: shoeID,
            shoeName: shoeID.flatMap { shoeNames[$0] },
            notes: log.notes,
            workoutStartDate: log.workoutStartDate,
            workoutDistanceMiles: log.workoutDistanceMiles,
            workoutActivityType: log.workoutActivityType)
        // Raw, like every stored enum here: a value this build does not know is exported as it is.
        row.intensityMode = log.intensityMode
        row.targetRPEMin = log.targetRPEMin
        row.targetRPEMax = log.targetRPEMax
        row.targetHeartRateMin = log.targetHeartRateMin
        row.targetHeartRateMax = log.targetHeartRateMax
        row.talkTest = log.talkTest
        return row
    }

    private static func row(for detail: BodySignalDetail, log: RunLog) -> BodySignalDetailExportRow {
        BodySignalDetailExportRow(
            detailID: detail.id.uuidString,
            runLogID: log.id.uuidString,
            // Blank until the parent log is matched; runLogID always identifies it.
            healthKitWorkoutUUID: log.healthKitWorkoutUUID?.uuidString ?? "",
            area: detail.area,
            timing: detail.timing,
            character: detail.character,
            note: detail.note,
            createdAt: detail.createdAt)
    }

    private static func row(for log: RecoveryLog) -> RecoveryLogExportRow {
        RecoveryLogExportRow(
            recoveryLogID: log.id.uuidString,
            healthKitWorkoutUUID: log.healthKitWorkoutUUID.uuidString,
            runLogID: log.runLogID?.uuidString,
            recoveryRating: log.recoveryRating,
            lowerBackSeverity: log.lowerBackSeverity,
            leftAnkleSeverity: log.leftAnkleSeverity,
            rightAnkleSeverity: log.rightAnkleSeverity,
            leftKneeSeverity: log.leftKneeSeverity,
            rightKneeSeverity: log.rightKneeSeverity,
            notes: log.notes,
            createdAt: log.createdAt,
            updatedAt: log.updatedAt)
    }

    private static func row(for log: WorkoutIntervalLog,
                            issues: inout [ExportLogEntry]) -> IntervalLogExportRow {
        check(log.phaseTypeValue, raw: log.phaseType,
              label: "phase type", subject: "interval log \(log.id)", issues: &issues)

        return IntervalLogExportRow(
            intervalLogID: log.id.uuidString,
            healthKitWorkoutUUID: log.healthKitWorkoutUUID?.uuidString,
            executionID: log.executionID.uuidString,
            sequenceIndex: log.sequenceIndex,
            phaseType: log.phaseType,
            repetitionNumber: log.repetitionNumber,
            plannedDurationSeconds: log.plannedDurationSeconds,
            actualDurationSeconds: log.actualDurationSeconds,
            startDate: log.startDate,
            endDate: log.endDate,
            wasSkipped: log.wasSkipped,
            wasInterrupted: log.wasInterrupted,
            endReason: log.endReason,
            lowerBackSeverity: log.lowerBackSeverity,
            leftAnkleSeverity: log.leftAnkleSeverity,
            rightAnkleSeverity: log.rightAnkleSeverity,
            leftKneeSeverity: log.leftKneeSeverity,
            rightKneeSeverity: log.rightKneeSeverity,
            baselineReachedAt: log.baselineReachedAt)
    }

    private static func row(for note: WorkoutNote,
                            issues: inout [ExportLogEntry]) -> WorkoutNoteExportRow {
        check(note.phaseTypeValue, raw: note.phaseType,
              label: "phase type", subject: "workout note \(note.id)", issues: &issues)

        return WorkoutNoteExportRow(
            noteID: note.id.uuidString,
            // Blank while the note is still waiting for the Watch's workout. `executionID`
            // identifies it until then, exactly as it does for a mid-workout run log.
            healthKitWorkoutUUID: note.healthKitWorkoutUUID?.uuidString ?? "",
            executionID: note.executionID.uuidString,
            createdAt: note.createdAt,
            phaseType: note.phaseType,
            repetitionNumber: note.repetitionNumber,
            secondsIntoWorkout: note.secondsIntoWorkout,
            text: note.text)
    }

    private static func row(for execution: PendingWorkoutExecution,
                            issues: inout [ExportLogEntry]) -> ExecutionExportRow {
        check(execution.statusValue, raw: execution.status,
              label: "status", subject: "execution \(execution.id)", issues: &issues)

        return ExecutionExportRow(
            executionID: execution.id.uuidString,
            plannedWorkoutID: execution.plannedWorkoutID.uuidString,
            plannedWorkoutName: execution.plannedWorkoutName,
            expectedActivityType: execution.expectedActivityType,
            expectedDurationSeconds: execution.expectedDurationSeconds,
            // Not set wherever the run had no single shape or fixed rounds — stored that way, or
            // cleared by `ShapeZeroRepair` — so nothing here needs to know which kinds to blank.
            runIntervalSeconds: execution.runIntervalSeconds,
            walkIntervalSeconds: execution.walkIntervalSeconds,
            plannedRepetitions: execution.plannedRepetitions,
            completedRepetitions: execution.completedRepetitions,
            blockShape: execution.blockShape,
            status: execution.status,
            matchedHealthKitWorkoutUUID: execution.matchedHealthKitWorkoutUUID?.uuidString,
            timerStartedAt: execution.timerStartedAt,
            timerEndedAt: execution.timerEndedAt,
            createdAt: execution.createdAt,
            updatedAt: execution.updatedAt)
    }

    /// Reports a stored string this build cannot interpret. The raw value is still exported
    /// verbatim — a value that is not understood is never rewritten into one that is.
    private static func check<T>(_ parsed: T?, raw: String, label: String, subject: String,
                                 issues: inout [ExportLogEntry]) {
        guard parsed == nil else { return }
        issues.append(ExportLogEntry(
            level: .warning, category: "run_logger",
            message: "The \(label) of \(subject) is stored as \"\(raw)\", which this version does "
                + "not recognize. The raw value is exported unchanged."))
    }
}
