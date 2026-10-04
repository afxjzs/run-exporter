import Foundation

/// The aerobic analysis as the export writes it (aerobic spec §17): `aerobic_workout_summary.csv`,
/// and a group of per-leg columns after every shipped column of `workout_intervals.csv`.
///
/// Runs inside `ExportBuilder.writeFiles`, from the dataset, so the file layer that tests drive is
/// the one that produces these numbers.
enum AerobicExport {

    static let summaryFileName = "aerobic_workout_summary.csv"

    /// §17's list, in its order (Decisions D4).
    static let summaryColumns = [
        "healthKitWorkoutUUID", "runLogID", "executionID", "plannedWorkoutID", "startDate",
        "intensityMode", "targetRPEMin", "targetRPEMax", "targetHeartRateMin", "targetHeartRateMax",
        "effortRPE", "personalHeatRating", "talkTest",
        "totalRunningDurationSeconds", "totalRunningDistanceMeters",
        "runningHRSampleCount", "runningHRCoveragePercent", "largestHRSampleGapSeconds",
        "runningAverageHR", "runningMedianHR", "runningMinimumHR", "runningMaximumHR",
        "runningAverageSpeedMetersPerSecond", "runningAveragePaceSecondsPerMile",
        "firstHalfAverageHR", "secondHalfAverageHR", "heartRateDriftBPM", "heartRateDriftPercent",
        "firstHalfAverageSpeed", "secondHalfAverageSpeed", "paceOrSpeedDriftPercent",
        "firstHalfEfficiency", "secondHalfEfficiency", "efficiencyChangePercent",
        "insufficientHRData", "analysisVersion",
    ]

    /// §17's `workout_intervals.csv` additions — a group of their own, after every shipped column.
    static let intervalColumns = [
        "hrSampleCount", "averageHR", "medianHR", "minimumHR", "maximumHR", "startHR", "endHR",
        "heartRateDrop30s", "heartRateDrop60s", "heartRateDrop120s",
    ]

    static let blankIntervalValues = Array(repeating: "", count: intervalColumns.count)

    struct Output {
        var summaryRows: [[String]] = []
        /// Each analyzed leg's values for `intervalColumns`, by `intervalLogID`. A leg with no entry
        /// writes blanks.
        var intervalValues: [String: [String]] = [:]
        var issues: [ExportLogEntry] = []
    }

    static func make(workouts: [WorkoutExportRow],
                     logger: LoggerExportData,
                     samples: [String: WorkoutSamples]) -> Output {
        var output = Output()
        var withoutLegs = 0

        for workout in workouts {
            let executionID: String
            let execution: ExecutionExportRow?
            switch logger.execution(forWorkoutUUID: workout.uuid) {
            case .none:
                withoutLegs += 1
                continue
            case .ambiguous(let ids):
                output.issues.append(ExportLogEntry(
                    level: .warning, category: "aerobic", workoutUUID: workout.uuid,
                    message: "Executions \(ids.joined(separator: ", ")) all claim this workout, so "
                        + "which legs it ran cannot be told. It has no \(summaryFileName) row."))
                continue
            case .one(let id, let row):
                executionID = id
                execution = row
            }
            // Nil when the execution recorded no legs, or they could not be read — the latter
            // already in the export log, from `LoggerExportData.index()`.
            guard let run = logger.recordedRun(forExecutionID: executionID) else {
                withoutLegs += 1
                continue
            }

            var result: AerobicAnalysis.Workout?
            if let workoutSamples = samples[workout.uuid] {
                let analysis = AerobicAnalysis.analyze(run, samples: workoutSamples)
                result = analysis.workout
                for (id, leg) in analysis.legs { output.intervalValues[id] = values(for: leg) }
            } else {
                output.issues.append(ExportLogEntry(
                    level: .warning, category: "aerobic", workoutUUID: workout.uuid,
                    message: "This workout's heart rate and distance were not read, so its "
                        + "\(summaryFileName) row and its legs' heart-rate columns are blank."))
            }
            output.summaryRows.append(summaryValues(
                workout: workout, executionID: executionID, execution: execution,
                log: logger.runLog(forWorkoutUUID: workout.uuid),
                runningSeconds: run.totalRunSeconds, result: result))
        }

        // D19: said, not silent.
        if withoutLegs > 0 {
            output.issues.append(ExportLogEntry(
                level: .info, category: "aerobic",
                message: "\(withoutLegs) workout(s) join no recorded legs — another app's, or from "
                    + "before the app recorded legs — so they have no running phases to analyze "
                    + "and no \(summaryFileName) row."))
        }
        return output
    }

    // MARK: - Rows

    private static func summaryValues(workout: WorkoutExportRow,
                                      executionID: String,
                                      execution: ExecutionExportRow?,
                                      log: RunLogExportRow?,
                                      runningSeconds: Double,
                                      result r: AerobicAnalysis.Workout?) -> [String] {
        let identity: [String] = [
            workout.uuid, log?.runLogID ?? "", executionID, execution?.plannedWorkoutID ?? "",
            workout.startDate,
        ]
        // Only a log written after the feature carries these; blank otherwise (D18).
        let intent: [String] = [
            log?.intensityMode ?? "",
            Fmt.fixed(log?.targetRPEMin, places: 1), Fmt.fixed(log?.targetRPEMax, places: 1),
            log?.targetHeartRateMin.map(String.init) ?? "",
            log?.targetHeartRateMax.map(String.init) ?? "",
        ]
        let subjective: [String] = [
            log.map { Fmt.fixed($0.effortRPE, places: 1) } ?? "",
            log.map { Fmt.fixed($0.personalHeatRating, places: 1) } ?? "",
            log?.talkTest ?? "",
        ]
        let running: [String] = [
            Fmt.fixed(runningSeconds, places: 3),
            Fmt.fixed(r?.runningDistance, places: 3),
            r.map { String($0.running.sampleCount) } ?? "",
            Fmt.fixed(r?.running.coverage.map { $0 * 100 }, places: 3),
            Fmt.fixed(r?.running.largestGap, places: 3),
            Fmt.fixed(r?.running.average, places: 3),
            Fmt.fixed(r?.running.median, places: 3),
            Fmt.fixed(r?.running.minimum, places: 3),
            Fmt.fixed(r?.running.maximum, places: 3),
            Fmt.fixed(r?.runningSpeed, places: 4),
            Fmt.fixed(r?.runningPaceSecondsPerMile, places: 3),
        ]
        let halves: [String] = [
            Fmt.fixed(r?.firstHalfHeartRate, places: 3),
            Fmt.fixed(r?.secondHalfHeartRate, places: 3),
            Fmt.fixed(r?.heartRateDriftBPM, places: 3),
            Fmt.fixed(r?.heartRateDriftPercent, places: 3),
            Fmt.fixed(r?.firstHalfSpeed, places: 4),
            Fmt.fixed(r?.secondHalfSpeed, places: 4),
            Fmt.fixed(r?.speedDriftPercent, places: 3),
            Fmt.fixed(r?.firstHalfEfficiency, places: 4),
            Fmt.fixed(r?.secondHalfEfficiency, places: 4),
            Fmt.fixed(r?.efficiencyChangePercent, places: 3),
        ]
        let quality: [String] = [Fmt.bool(r?.insufficientHeartRate), AerobicAnalysis.analysisVersion]
        return identity + intent + subjective + running + halves + quality
    }

    private static func values(for leg: AerobicAnalysis.Leg) -> [String] {
        let heartRate: [String] = [
            String(leg.sampleCount),
            Fmt.fixed(leg.average, places: 3),
            Fmt.fixed(leg.median, places: 3),
            Fmt.fixed(leg.minimum, places: 3),
            Fmt.fixed(leg.maximum, places: 3),
            Fmt.fixed(leg.startHeartRate, places: 3),
            Fmt.fixed(leg.endHeartRate, places: 3),
        ]
        let drops = AerobicAnalysis.recoveryOffsets.map { Fmt.fixed(leg.recoveryDrops[$0], places: 3) }
        return heartRate + drops
    }
}
