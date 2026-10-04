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
    /// Only executions with at least one leg: `Dictionary(grouping:)` makes no empty groups, so a
    /// timer that never started has no entry here and its actual* columns stay blank, never zero.
    private var recordedRunsByExecutionID: [String: RecordedRun] = [:]

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

        // What each run actually ran, derived once from its legs. Both the execution rows and the
        // workouts.csv join read this one result, so the two files cannot disagree about a run.
        recordedRunsByExecutionID = [:]
        for (executionID, rows) in intervalsByExecutionID {
            do {
                recordedRunsByExecutionID[executionID] = try RecordedRun(rows: rows)
            } catch RecordedRun.Failure.unrecognizedPhase(let phase) {
                issues.append(ExportLogEntry(
                    level: .warning, category: "run_logger",
                    message: "Execution \(executionID) has a leg with phase \"\(phase)\", which this "
                        + "version does not recognize, so what that run actually ran cannot be "
                        + "derived. Its actual* columns are blank; its legs are in workout_intervals.csv."))
            } catch {
                issues.append(ExportLogEntry(
                    level: .warning, category: "run_logger",
                    message: "Could not derive what execution \(executionID) ran: \(error). "
                        + "Its actual* columns are blank."))
            }
        }
        for index in executions.indices {
            guard let run = recordedRunsByExecutionID[executions[index].executionID] else { continue }
            executions[index].actualShape = run.shapeDescriptor
            executions[index].actualRunLegCount = run.runLegCount
            executions[index].actualRunSeconds = run.totalRunSeconds
            executions[index].actualWalkSeconds = run.totalWalkSeconds
        }
    }

    /// What an execution actually ran, or nil when it recorded no legs or they could not be read
    /// (the latter reported in `issues`). The seam the aerobic analysis reads legs from.
    func recordedRun(forExecutionID id: String) -> RecordedRun? {
        recordedRunsByExecutionID[id]
    }

    /// The run log joined to a workout — the one `join(forWorkoutUUID:)` reads.
    func runLog(forWorkoutUUID uuid: String) -> RunLogExportRow? {
        runLogsByWorkoutUUID[uuid]
    }

    /// Which execution's legs belong to a workout: the one matched to it, or the one whose legs
    /// were stamped with it. A run log is not needed — the aerobic analysis covers unlogged runs
    /// too (aerobic spec §26).
    enum ExecutionMatch {
        case none
        /// `row` is nil when legs name an execution whose record is gone; the legs are still the
        /// run, and the columns only the record could fill stay blank.
        case one(executionID: String, row: ExecutionExportRow?)
        /// More than one execution claims the workout. Picking one would put a guess in the
        /// export, so the caller reports it instead.
        case ambiguous([String])
    }

    func execution(forWorkoutUUID uuid: String) -> ExecutionMatch {
        var ids = Set(executions.filter { $0.matchedHealthKitWorkoutUUID == uuid }.map(\.executionID))
        ids.formUnion((intervalsByWorkoutUUID[uuid] ?? []).map(\.executionID))
        guard ids.count <= 1 else { return .ambiguous(ids.sorted()) }
        guard let id = ids.first else { return .none }
        return .one(executionID: id, row: executions.first { $0.executionID == id })
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
        if let executionID = log.executionID, let run = recordedRunsByExecutionID[executionID] {
            join.actualShape = run.shapeDescriptor
            join.actualRunLegCount = run.runLegCount
            join.actualRunSeconds = run.totalRunSeconds
            join.actualWalkSeconds = run.totalWalkSeconds
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
