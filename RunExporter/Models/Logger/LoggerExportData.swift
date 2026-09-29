import Foundation

/// Everything the run logger contributes to an export, already copied out of SwiftData.
///
/// This type is a plain value so it can cross into the export task safely. It also owns the
/// joins — shoe mileage and per-workout interval totals — so `ExportBuilder` stays a file writer
/// and the same arithmetic backs both the CSVs and the UI.
struct LoggerExportData {

    var shoes: [ShoeExportRow] = []
    var plannedWorkouts: [PlannedWorkoutExportRow] = []
    /// Every plan's segments, in order. One row for an ordinary plan, several for one that runs
    /// blocks of differing shape.
    var plannedWorkoutBlocks: [PlannedWorkoutBlockExportRow] = []
    var runLogs: [RunLogExportRow] = []
    var recoveryLogs: [RecoveryLogExportRow] = []
    var intervalLogs: [IntervalLogExportRow] = []
    var executions: [ExecutionExportRow] = []
    var bodySignalDetails: [BodySignalDetailExportRow] = []
    var notes: [WorkoutNoteExportRow] = []

    /// Problems found while snapshotting — unreadable store, unrecognized stored enum values.
    /// Written into `export_log.json` rather than dropped.
    var issues: [ExportLogEntry] = []

    /// True when the logger store could not be opened at all. The export still runs; every
    /// logger CSV is written with headers only, and the manifest says so.
    var storeUnavailable = false

    /// How many HealthKit workouts in this export have no run log. Filled in by `ExportBuilder`,
    /// which is the only place that knows the exported workout set.
    var unloggedWorkoutCount = 0

    // MARK: - Derived lookups

    private var runLogsByWorkoutUUID: [String: RunLogExportRow] = [:]
    private var recoveryByWorkoutUUID: [String: RecoveryLogExportRow] = [:]
    private var plannedNamesByID: [String: String] = [:]
    private var shoeNamesByID: [String: String] = [:]
    private var shoeStartingMileageByID: [String: Double] = [:]
    private var assignments: [ShoeMileage.Assignment] = []
    private var intervalsByWorkoutUUID: [String: [IntervalLogExportRow]] = [:]
    private var intervalsByExecutionID: [String: [IntervalLogExportRow]] = [:]

    /// Builds every lookup and fills in each shoe's assigned mileage.
    ///
    /// Call once after the raw rows are set. Doing it in one pass keeps the joins consistent:
    /// `shoes.csv` totals and each workout's `shoeMileageAtWorkoutMiles` come from the same
    /// assignment list, so they can never disagree.
    mutating func index() {
        plannedNamesByID = Dictionary(plannedWorkouts.map { ($0.plannedWorkoutID, $0.name) },
                                      uniquingKeysWith: { first, _ in first })
        shoeNamesByID = Dictionary(shoes.map { ($0.shoeID, $0.displayName) },
                                   uniquingKeysWith: { first, _ in first })
        shoeStartingMileageByID = Dictionary(shoes.map { ($0.shoeID, $0.startingMileage) },
                                             uniquingKeysWith: { first, _ in first })

        // Latest log wins if two logs somehow reference the same workout; the duplicate is
        // reported rather than silently discarded.
        //
        // Logs written mid-workout and not yet matched have no workout UUID. They are skipped
        // here — they cannot join to a workout — but still appear in run_logs.csv, identified by
        // their executionID. Indexing them under "" would make every one of them look like a
        // duplicate of the others.
        for log in runLogs.sorted(by: { $0.updatedAt < $1.updatedAt })
        where !log.healthKitWorkoutUUID.isEmpty {
            if let existing = runLogsByWorkoutUUID[log.healthKitWorkoutUUID] {
                issues.append(ExportLogEntry(
                    level: .warning, category: "run_logger",
                    workoutUUID: log.healthKitWorkoutUUID,
                    message: "Two run logs reference this workout (\(existing.runLogID) and "
                        + "\(log.runLogID)). workouts.csv joins the most recently updated one; "
                        + "both are still present in run_logs.csv."))
            }
            runLogsByWorkoutUUID[log.healthKitWorkoutUUID] = log
        }

        for log in recoveryLogs.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            recoveryByWorkoutUUID[log.healthKitWorkoutUUID] = log
        }

        assignments = runLogs.compactMap { log in
            guard let shoeID = log.shoeID, let uuid = UUID(uuidString: shoeID) else { return nil }
            return ShoeMileage.Assignment(shoeID: uuid,
                                          workoutStartDate: log.workoutStartDate,
                                          distanceMiles: log.workoutDistanceMiles)
        }

        let mileage = ShoeMileage.assignedMiles(from: assignments)
        for index in shoes.indices {
            guard let uuid = UUID(uuidString: shoes[index].shoeID) else { continue }
            shoes[index].assignedWorkoutMileage = mileage[uuid] ?? 0
        }

        intervalsByWorkoutUUID = Dictionary(grouping: intervalLogs.compactMap { row in
            row.healthKitWorkoutUUID.map { ($0, row) }
        }, by: { $0.0 }).mapValues { $0.map(\.1) }

        intervalsByExecutionID = Dictionary(grouping: intervalLogs, by: { $0.executionID })
    }

    // MARK: - workouts.csv join

    /// The subjective columns for one exported workout, or `nil` when it has no run log.
    func join(forWorkoutUUID uuid: String) -> WorkoutLoggerJoin? {
        guard let log = runLogsByWorkoutUUID[uuid] else { return nil }

        var join = WorkoutLoggerJoin()
        join.runLogID = log.runLogID
        join.plannedWorkoutID = log.plannedWorkoutID ?? ""
        join.plannedWorkoutName = log.plannedWorkoutID.flatMap { plannedNamesByID[$0] } ?? ""
        join.executionID = log.executionID ?? ""

        join.runIntervalSeconds = log.runIntervalSeconds
        join.walkIntervalSeconds = log.walkIntervalSeconds
        join.plannedRepetitions = log.plannedRepetitions
        join.completedRepetitions = log.completedRepetitions

        join.effortRPE = log.effortRPE
        join.personalHeatRating = log.personalHeatRating

        join.lowerBackSeverity = log.lowerBackSeverity
        join.leftAnkleSeverity = log.leftAnkleSeverity
        join.rightAnkleSeverity = log.rightAnkleSeverity
        join.leftKneeSeverity = log.leftKneeSeverity
        join.rightKneeSeverity = log.rightKneeSeverity

        join.shoeID = log.shoeID ?? ""
        join.shoeName = log.shoeID.flatMap { shoeNamesByID[$0] } ?? log.shoeName ?? ""
        if let shoeID = log.shoeID, let uuid = UUID(uuidString: shoeID) {
            join.shoeMileageAtWorkoutMiles = ShoeMileage.mileageAtWorkout(
                shoeID: uuid,
                startingMileage: shoeStartingMileageByID[shoeID] ?? 0,
                workoutStartDate: log.workoutStartDate,
                assignments: assignments)
        }

        join.userNotes = log.notes ?? ""
        join.nextDayRecovery = recoveryByWorkoutUUID[uuid]?.recoveryRating

        let intervals = intervals(forWorkoutUUID: uuid, executionID: log.executionID)
        if !intervals.isEmpty {
            join.mainSetDurationSeconds = duration(of: intervals) { $0.isMainSet }
            join.cooldownDurationSeconds = duration(of: intervals) { $0 == .cooldown }
            join.pausedDurationSeconds = duration(of: intervals) { $0 == .paused }
            join.loggedIntervalCount = intervals.count
        }
        return join
    }

    /// Intervals belonging to a workout: those already stamped with its UUID, plus — when none
    /// are — those recorded under the run log's execution before matching happened.
    private func intervals(forWorkoutUUID uuid: String, executionID: String?) -> [IntervalLogExportRow] {
        if let direct = intervalsByWorkoutUUID[uuid], !direct.isEmpty { return direct }
        guard let executionID else { return [] }
        return intervalsByExecutionID[executionID] ?? []
    }

    private func duration(of intervals: [IntervalLogExportRow],
                          matching predicate: (WorkoutPhase) -> Bool) -> Double {
        intervals.reduce(0) { total, row in
            guard let phase = WorkoutPhase(rawValue: row.phaseType), predicate(phase) else {
                return total
            }
            return total + row.actualDurationSeconds
        }
    }

    // MARK: - Manifest

    /// The `run_logger` block in manifest.json.
    var manifestCounts: [String: Any] {
        [
            "store_available": !storeUnavailable,
            "planned_workout_count": plannedWorkouts.count,
            "planned_workout_block_count": plannedWorkoutBlocks.count,
            "run_log_count": runLogs.count,
            "recovery_log_count": recoveryLogs.count,
            "shoe_count": shoes.count,
            "interval_log_count": intervalLogs.count,
            "unlogged_workout_count": unloggedWorkoutCount,
            "pending_execution_count": executions.count,
            "body_signal_detail_count": bodySignalDetails.count,
            "workout_note_count": notes.count,
        ]
    }
}
