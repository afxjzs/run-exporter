import Foundation

// MARK: - Snapshot rows
//
// Plain, immutable values copied out of SwiftData on the main actor before an export starts.
// SwiftData models are not `Sendable` and must not cross into the export task, so the export
// never touches the store — it works entirely from this snapshot.

struct ShoeExportRow {
    var shoeID: String
    var brand: String
    var model: String
    var displayName: String
    var firstUseDate: Date?
    var retiredDate: Date?
    var startingMileage: Double
    var isDefault: Bool
    var notes: String?

    /// Miles from assigned run logs, filled in by `LoggerExportData`.
    var assignedWorkoutMileage: Double = 0

    var totalMileage: Double { startingMileage + assignedWorkoutMileage }

    static let columns = [
        "shoeID", "brand", "model", "displayName",
        "firstUseDate", "retiredDate",
        "startingMileage", "assignedWorkoutMileage", "totalMileage",
        "isDefault", "notes",
    ]

    var values: [String] {
        [
            shoeID, brand, model, displayName,
            Fmt.isoString(firstUseDate), Fmt.isoString(retiredDate),
            Fmt.fixed(startingMileage, places: 3),
            Fmt.fixed(assignedWorkoutMileage, places: 3),
            Fmt.fixed(totalMileage, places: 3),
            isDefault ? "true" : "false",
            notes ?? "",
        ]
    }
}

struct PlannedWorkoutExportRow {
    var plannedWorkoutID: String
    var name: String
    var activityType: String
    var warmupMode: String
    var warmupSeconds: Int?
    /// Blank for a plan whose intervals are not all the same shape.
    ///
    /// One run length, one walk length and one repetition count describe a plan of one shape and
    /// nothing else. For `5/1×1 → 8/1×2 → 5/1×1` there is no honest value, and reporting the first
    /// block's numbers would state something false about the whole run. The shape of every plan is
    /// in `planned_workout_blocks.csv` instead. Blank here never means zero.
    ///
    /// An open-interval plan decides only its walk in advance, so it has a walk and nothing else:
    /// `walkIntervalSeconds` is its walk floor, the shortest walk it allows.
    var runIntervalSeconds: Int?
    var walkIntervalSeconds: Int?
    var plannedRepetitions: Int?
    var includesFinalWalk: Bool
    var cooldownMode: String
    var cooldownSeconds: Int?
    var countdownSeconds: Int
    /// Blank where the plan does not fix the number in advance — an open-interval plan's walks and
    /// main set — or nothing describes the plan. Blank never means zero.
    var totalRunSeconds: Int?
    var totalWalkSeconds: Int?
    var mainSetSeconds: Int?
    var isNextWorkout: Bool
    var workoutKitIdentifier: String?
    var createdAt: Date
    var updatedAt: Date

    /// Set only on an open-interval plan — one whose running legs end when the runner ends them.
    ///
    /// Blank on every ordinary interval plan. Without these an open-interval plan would export as
    /// one with no intervals and no rounds, which is indistinguishable from a damaged plan in the
    /// one file whose job is saying what was planned.
    var openIntervalTargetSeconds: Int?
    var openIntervalWalkFloorSeconds: Int?

    static let columns = [
        "plannedWorkoutID", "name", "activityType",
        "warmupMode", "warmupSeconds",
        "runIntervalSeconds", "walkIntervalSeconds", "plannedRepetitions", "includesFinalWalk",
        "cooldownMode", "cooldownSeconds", "countdownSeconds",
        "totalRunSeconds", "totalWalkSeconds", "mainSetSeconds",
        "isNextWorkout", "workoutKitIdentifier",
        "createdAt", "updatedAt",
        "openIntervalTargetSeconds", "openIntervalWalkFloorSeconds",
    ]

    var values: [String] {
        [
            plannedWorkoutID, name, activityType,
            warmupMode, warmupSeconds.map(String.init) ?? "",
            runIntervalSeconds.map(String.init) ?? "",
            walkIntervalSeconds.map(String.init) ?? "",
            plannedRepetitions.map(String.init) ?? "",
            includesFinalWalk ? "true" : "false",
            cooldownMode, cooldownSeconds.map(String.init) ?? "", String(countdownSeconds),
            totalRunSeconds.map(String.init) ?? "",
            totalWalkSeconds.map(String.init) ?? "",
            mainSetSeconds.map(String.init) ?? "",
            isNextWorkout ? "true" : "false", workoutKitIdentifier ?? "",
            Fmt.isoString(createdAt), Fmt.isoString(updatedAt),
            openIntervalTargetSeconds.map(String.init) ?? "",
            openIntervalWalkFloorSeconds.map(String.init) ?? "",

        ]
    }
}

/// One segment of a plan: a run length, a walk length and a repetition count that apply together.
///
/// Every plan contributes rows here, including an ordinary `4/1 × 5`, which is a plan of exactly
/// one segment. That uniformity is the point — a plan's shape is always readable from this one
/// file, with no rule about when to look somewhere else instead.
///
/// Keyed by `plannedWorkoutID` + `orderIndex`. Segments have no identity of their own that anything
/// else refers to, and a plan created before blocks existed has no stored segment record to take an
/// id from, so inventing one would only add a column that means nothing.
struct PlannedWorkoutBlockExportRow {
    var plannedWorkoutID: String
    /// Run order within the plan: a dense sequence from 0, in the order the segments are performed.
    ///
    /// Deliberately **not** named `orderIndex` after the stored `PlannedWorkoutBlock.orderIndex`.
    /// Segments are sorted by that field and then renumbered here, so the two agree in order but
    /// not necessarily in value — a column sharing a model property's name while holding a
    /// different number is a trap for anyone joining this file back to the app's own data.
    var position: Int
    var runIntervalSeconds: Int
    /// Zero for a segment that runs straight through with no recovery walk.
    var walkIntervalSeconds: Int
    var repetitions: Int

    static let columns = [
        "plannedWorkoutID", "position",
        "runIntervalSeconds", "walkIntervalSeconds", "repetitions",
    ]

    var values: [String] {
        [
            plannedWorkoutID, String(position),
            String(runIntervalSeconds), String(walkIntervalSeconds), String(repetitions),
        ]
    }
}

struct RunLogExportRow {
    var runLogID: String
    var healthKitWorkoutUUID: String
    var plannedWorkoutID: String?
    var executionID: String?
    var createdAt: Date
    var updatedAt: Date

    var runIntervalSeconds: Int?
    var walkIntervalSeconds: Int?
    var plannedRepetitions: Int?
    var completedRepetitions: Int?

    var effortRPE: Double
    var personalHeatRating: Double

    var lowerBackSeverity: Double
    var leftAnkleSeverity: Double
    var rightAnkleSeverity: Double
    var leftKneeSeverity: Double
    var rightKneeSeverity: Double

    var shoeID: String?
    var shoeName: String?
    var notes: String?

    /// Snapshot of the matched workout, kept so shoe mileage is derivable from the export alone.
    var workoutStartDate: Date
    var workoutDistanceMiles: Double?
    var workoutActivityType: String

    static let columns = [
        "runLogID", "healthKitWorkoutUUID", "plannedWorkoutID", "executionID",
        "createdAt", "updatedAt",
        "runIntervalSeconds", "walkIntervalSeconds", "plannedRepetitions", "completedRepetitions",
        "effortRPE", "personalHeatRating",
        "lowerBackSeverity", "leftAnkleSeverity", "rightAnkleSeverity",
        "leftKneeSeverity", "rightKneeSeverity",
        "shoeID", "shoeName", "notes",
        // Beyond the spec's column list, appended so the file is self-contained.
        "workoutStartDate", "workoutDistanceMiles", "workoutActivityType",
    ]

    var values: [String] {
        [
            runLogID, healthKitWorkoutUUID, plannedWorkoutID ?? "", executionID ?? "",
            Fmt.isoString(createdAt), Fmt.isoString(updatedAt),
            runIntervalSeconds.map(String.init) ?? "",
            walkIntervalSeconds.map(String.init) ?? "",
            plannedRepetitions.map(String.init) ?? "",
            completedRepetitions.map(String.init) ?? "",
            Fmt.fixed(effortRPE, places: 1), Fmt.fixed(personalHeatRating, places: 1),
            Fmt.fixed(lowerBackSeverity, places: 1),
            Fmt.fixed(leftAnkleSeverity, places: 1),
            Fmt.fixed(rightAnkleSeverity, places: 1),
            Fmt.fixed(leftKneeSeverity, places: 1),
            Fmt.fixed(rightKneeSeverity, places: 1),
            shoeID ?? "", shoeName ?? "", notes ?? "",
            Fmt.isoString(workoutStartDate),
            Fmt.fixed(workoutDistanceMiles, places: 4),
            workoutActivityType,
        ]
    }
}

struct RecoveryLogExportRow {
    var recoveryLogID: String
    var healthKitWorkoutUUID: String
    var runLogID: String?
    var recoveryRating: Double
    var lowerBackSeverity: Double
    var leftAnkleSeverity: Double
    var rightAnkleSeverity: Double
    var leftKneeSeverity: Double
    var rightKneeSeverity: Double
    var notes: String?
    var createdAt: Date
    var updatedAt: Date

    static let columns = [
        "recoveryLogID", "healthKitWorkoutUUID", "runLogID",
        "recoveryRating",
        "lowerBackSeverity", "leftAnkleSeverity", "rightAnkleSeverity",
        "leftKneeSeverity", "rightKneeSeverity",
        "notes", "createdAt", "updatedAt",
    ]

    var values: [String] {
        [
            recoveryLogID, healthKitWorkoutUUID, runLogID ?? "",
            Fmt.fixed(recoveryRating, places: 1),
            Fmt.fixed(lowerBackSeverity, places: 1),
            Fmt.fixed(leftAnkleSeverity, places: 1),
            Fmt.fixed(rightAnkleSeverity, places: 1),
            Fmt.fixed(leftKneeSeverity, places: 1),
            Fmt.fixed(rightKneeSeverity, places: 1),
            notes ?? "", Fmt.isoString(createdAt), Fmt.isoString(updatedAt),
        ]
    }
}

struct IntervalLogExportRow {
    var intervalLogID: String
    var healthKitWorkoutUUID: String?
    var executionID: String
    var sequenceIndex: Int
    var phaseType: String
    var repetitionNumber: Int?
    var plannedDurationSeconds: Int?
    var actualDurationSeconds: Double
    var startDate: Date
    var endDate: Date
    var wasSkipped: Bool
    var wasInterrupted: Bool
    /// Why an open-interval leg stopped — `LegEndReason`. Blank on every interval run, which
    /// measures nothing of the kind.
    var endReason: String?
    /// The 0–10 signal reading taken at the end of a leg. Blank means the question was never asked;
    /// `0` means it was asked and the area was fine.
    /// The 0–10 readings taken as a leg ended, named as `run_logs.csv` names them so the two files
    /// join without translation. Blank means the question was never asked; `0` means it was.
    var lowerBackSeverity: Double?
    var leftAnkleSeverity: Double?
    var rightAnkleSeverity: Double?
    var leftKneeSeverity: Double?
    var rightKneeSeverity: Double?
    /// When, during a recovery walk, the runner reported that signal gone. Blank when it had not by the
    /// time the walk ended.
    var baselineReachedAt: Date?

    static let columns = [
        "intervalLogID", "healthKitWorkoutUUID", "executionID",
        "sequenceIndex", "phaseType", "repetitionNumber",
        "plannedDurationSeconds", "actualDurationSeconds",
        "startDate", "endDate", "wasSkipped", "wasInterrupted",
        "endReason", "baselineReachedAt",
        "lowerBackSeverity", "leftAnkleSeverity", "rightAnkleSeverity",
        "leftKneeSeverity", "rightKneeSeverity",
    ]

    var values: [String] {
        [
            intervalLogID, healthKitWorkoutUUID ?? "", executionID,
            String(sequenceIndex), phaseType, repetitionNumber.map(String.init) ?? "",
            plannedDurationSeconds.map(String.init) ?? "",
            Fmt.fixed(actualDurationSeconds, places: 3),
            Fmt.isoString(startDate), Fmt.isoString(endDate),
            wasSkipped ? "true" : "false", wasInterrupted ? "true" : "false",
            endReason ?? "",
            Fmt.isoString(baselineReachedAt),
            Fmt.fixed(lowerBackSeverity, places: 1),
            Fmt.fixed(leftAnkleSeverity, places: 1),
            Fmt.fixed(rightAnkleSeverity, places: 1),
            Fmt.fixed(leftKneeSeverity, places: 1),
            Fmt.fixed(rightKneeSeverity, places: 1),
        ]
    }
}

struct ExecutionExportRow {
    var executionID: String
    var plannedWorkoutID: String
    var plannedWorkoutName: String
    var expectedActivityType: String
    /// Blank for an open-interval run, whose length is not known in advance.
    var expectedDurationSeconds: Int?
    /// Blank when this run had segments of differing shape, or was open-interval — `blockShape`
    /// describes it instead. Blank never means zero.
    var runIntervalSeconds: Int?
    var walkIntervalSeconds: Int?
    /// Rounds are well defined however many segments there were; blank for an open-interval run,
    /// whose rounds were decided during it (see actualRunLegCount).
    var plannedRepetitions: Int?
    var completedRepetitions: Int?
    /// The shape that was run, as "300/60x1|480/60x2|300/60x1". Blank for a session recorded
    /// before this column existed, whose own interval columns are the truth about it.
    var blockShape: String?
    var status: String
    var matchedHealthKitWorkoutUUID: String?
    var timerStartedAt: Date?
    var timerEndedAt: Date?
    var createdAt: Date
    var updatedAt: Date

    /// What was actually run, from this execution's legs — `RecordedRun`. The columns above are the
    /// plan as it stood when the run began; these are what happened. Blank when no leg was recorded
    /// or the legs could not be read (the second is reported in export_log.json). Filled in by
    /// `LoggerExportData.index()`, which holds the legs.
    var actualShape: String?
    var actualRunLegCount: Int?
    var actualRunSeconds: Double?
    var actualWalkSeconds: Double?

    static let columns = [
        "executionID", "plannedWorkoutID", "plannedWorkoutName",
        "expectedActivityType", "expectedDurationSeconds",
        "runIntervalSeconds", "walkIntervalSeconds",
        "plannedRepetitions", "completedRepetitions", "blockShape",
        "status", "matchedHealthKitWorkoutUUID",
        "timerStartedAt", "timerEndedAt", "createdAt", "updatedAt",
        // Appended: what was run, beside what was planned.
        "actualShape", "actualRunLegCount", "actualRunSeconds", "actualWalkSeconds",
    ]

    var values: [String] {
        [
            executionID, plannedWorkoutID, plannedWorkoutName,
            expectedActivityType, expectedDurationSeconds.map(String.init) ?? "",
            runIntervalSeconds.map(String.init) ?? "",
            walkIntervalSeconds.map(String.init) ?? "",
            plannedRepetitions.map(String.init) ?? "", completedRepetitions.map(String.init) ?? "",
            blockShape ?? "",
            status, matchedHealthKitWorkoutUUID ?? "",
            Fmt.isoString(timerStartedAt), Fmt.isoString(timerEndedAt),
            Fmt.isoString(createdAt), Fmt.isoString(updatedAt),
            actualShape ?? "", actualRunLegCount.map(String.init) ?? "",
            Fmt.fixed(actualRunSeconds, places: 3), Fmt.fixed(actualWalkSeconds, places: 3),
        ]
    }
}

/// One note captured during a workout.
///
/// `healthKitWorkoutUUID` is blank while the note is still waiting for the Watch's workout, exactly
/// as it is for a mid-workout run log. `executionID` identifies it until then, and `createdAt`
/// places it inside a row of `workout_intervals.csv` — the two files join on the note's timestamp
/// falling between an interval's `startDate` and `endDate`.
struct WorkoutNoteExportRow {
    var noteID: String
    var healthKitWorkoutUUID: String
    var executionID: String
    var createdAt: Date
    var phaseType: String
    var repetitionNumber: Int?
    var secondsIntoWorkout: Double
    var text: String

    static let columns = [
        "noteID", "healthKitWorkoutUUID", "executionID",
        "createdAt", "phaseType", "repetitionNumber", "secondsIntoWorkout", "text",
    ]

    var values: [String] {
        [
            noteID, healthKitWorkoutUUID, executionID,
            Fmt.isoString(createdAt), phaseType,
            repetitionNumber.map(String.init) ?? "",
            Fmt.fixed(secondsIntoWorkout, places: 1),
            text,
        ]
    }
}

struct BodySignalDetailExportRow {
    var detailID: String
    var runLogID: String
    var healthKitWorkoutUUID: String
    var area: String
    var timing: String?
    var character: String?
    var note: String?
    var createdAt: Date

    static let columns = [
        "detailID", "runLogID", "healthKitWorkoutUUID",
        "area", "timing", "character", "note", "createdAt",
    ]

    var values: [String] {
        [
            detailID, runLogID, healthKitWorkoutUUID,
            area, timing ?? "", character ?? "", note ?? "", Fmt.isoString(createdAt),
        ]
    }
}

// MARK: - workouts.csv join

/// The subjective columns appended to each `workouts.csv` row (spec §20.1).
///
/// These are a *join*, not a second source of truth: every value here also appears in its own CSV.
/// They exist so ordinary analysis does not require joining five files by hand. A workout with no
/// run log gets `blankValues` — blank always means "not logged", never zero.
struct WorkoutLoggerJoin {

    var runLogID: String = ""
    var plannedWorkoutID: String = ""
    var plannedWorkoutName: String = ""
    var executionID: String = ""

    var runIntervalSeconds: Int?
    var walkIntervalSeconds: Int?
    var plannedRepetitions: Int?
    var completedRepetitions: Int?

    var effortRPE: Double?
    var personalHeatRating: Double?

    var lowerBackSeverity: Double?
    var leftAnkleSeverity: Double?
    var rightAnkleSeverity: Double?
    var leftKneeSeverity: Double?
    var rightKneeSeverity: Double?

    var shoeID: String = ""
    var shoeName: String = ""
    var shoeMileageAtWorkoutMiles: Double?

    var userNotes: String = ""
    var nextDayRecovery: Double?

    /// Derived from this workout's own interval logs, so main-set numbers stay separable from a
    /// long or open-ended cooldown (spec §25).
    var mainSetDurationSeconds: Double?
    var cooldownDurationSeconds: Double?
    var pausedDurationSeconds: Double?
    var loggedIntervalCount: Int?

    /// The run's execution's `actual*` columns, copied — one derivation, not a second one here.
    var actualShape: String?
    var actualRunLegCount: Int?
    var actualRunSeconds: Double?
    var actualWalkSeconds: Double?

    /// Spec §20.1's list first, then the derived interval columns.
    static let columns = [
        "plannedWorkoutID", "plannedWorkoutName",
        "runIntervalSeconds", "walkIntervalSeconds",
        "plannedRepetitions", "completedRepetitions",
        "effortRPE", "personalHeatRating",
        "lowerBackSeverity", "leftAnkleSeverity", "rightAnkleSeverity",
        "leftKneeSeverity", "rightKneeSeverity",
        "shoeID", "shoeName", "shoeMileageAtWorkoutMiles",
        "userNotes", "nextDayRecovery",
        // Appended beyond the spec so the main set stays analysable without joining
        // workout_intervals.csv.
        "runLogID", "executionID",
        "mainSetDurationSeconds", "cooldownDurationSeconds", "pausedDurationSeconds",
        "loggedIntervalCount",
    ]

    /// What the run actually ran — a group of its own, because workouts.csv places it **after** the
    /// classification column. Appended to `columns` instead, it pushed `reclassifiedAsRunning` out of
    /// the position it shipped in. See `ExportSchemaTests.shippedWorkoutColumns`.
    static let actualColumns = [
        "actualShape", "actualRunLegCount", "actualRunSeconds", "actualWalkSeconds",
    ]

    var actualValues: [String] {
        [
            actualShape ?? "", actualRunLegCount.map(String.init) ?? "",
            Fmt.fixed(actualRunSeconds, places: 3), Fmt.fixed(actualWalkSeconds, places: 3),
        ]
    }

    static let blankActualValues: [String] = Array(repeating: "", count: actualColumns.count)

    var values: [String] {
        [
            plannedWorkoutID, plannedWorkoutName,
            runIntervalSeconds.map(String.init) ?? "",
            walkIntervalSeconds.map(String.init) ?? "",
            plannedRepetitions.map(String.init) ?? "",
            completedRepetitions.map(String.init) ?? "",
            Fmt.fixed(effortRPE, places: 1), Fmt.fixed(personalHeatRating, places: 1),
            Fmt.fixed(lowerBackSeverity, places: 1),
            Fmt.fixed(leftAnkleSeverity, places: 1),
            Fmt.fixed(rightAnkleSeverity, places: 1),
            Fmt.fixed(leftKneeSeverity, places: 1),
            Fmt.fixed(rightKneeSeverity, places: 1),
            shoeID, shoeName, Fmt.fixed(shoeMileageAtWorkoutMiles, places: 3),
            userNotes, Fmt.fixed(nextDayRecovery, places: 1),
            runLogID, executionID,
            Fmt.fixed(mainSetDurationSeconds, places: 3),
            Fmt.fixed(cooldownDurationSeconds, places: 3),
            Fmt.fixed(pausedDurationSeconds, places: 3),
            loggedIntervalCount.map(String.init) ?? "",
        ]
    }

    /// Every column blank — an unlogged workout. Never zeros: zero is a real RPE-adjacent value
    /// and would be indistinguishable from "the user reported no pain".
    static let blankValues: [String] = Array(repeating: "", count: columns.count)
}
