import XCTest
@testable import RunExporter

/// The aerobic analysis as the export reports it: aerobic spec §9–§17 and its §24 scenarios A–J,
/// under the formulas and thresholds in that document's Decisions (D1–D19).
///
/// Each test builds one run — its legs as the app records them, and the heart-rate and distance
/// samples HealthKit would hand back for its workout — runs the real export file writer, and reads
/// cells out of the CSVs it wrote. Only HealthKit is faked. Nothing here names the analysis code, so
/// that code can be rewritten freely; what these pin is what the owner reads.
///
/// Every value is invented. Samples sit on a regular grid so each expected number can be worked out
/// by hand, and the working is in the comments.
final class AerobicExportTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)
    private let workoutUUID = "AE000000-0000-0000-0000-000000000001"
    private let executionID = "exec-aerobic"

    override func tearDown() {
        try? FileManager.default.removeItem(at: exportFolder)
        super.tearDown()
    }

    // MARK: - A. Continuous 30-minute run, stable heart rate

    /// 30 minutes at 3 m/s; 140 bpm for the first 15, 141 for the last 15.
    func testAStableContinuousRunShowsLowDrift() throws {
        try export(legs: [Leg("run", 0, 1_800)],
                   heartRate: grid(0, 1_800) { $0 < 900 ? 140 : 141 },
                   distance: steps(0, 1_800) { _ in 3 })

        let row = try summary()
        try assertNumber(row, "totalRunningDurationSeconds", 1_800)
        try assertNumber(row, "totalRunningDistanceMeters", 5_400)
        try assertNumber(row, "runningHRSampleCount", 360)
        try assertNumber(row, "runningAverageHR", 140.5)
        try assertNumber(row, "runningMedianHR", 140.5)
        try assertNumber(row, "runningMinimumHR", 140)
        try assertNumber(row, "runningMaximumHR", 141)
        try assertNumber(row, "firstHalfAverageHR", 140)
        try assertNumber(row, "secondHalfAverageHR", 141)
        try assertNumber(row, "heartRateDriftBPM", 1)
        // A sample every 5 s covers every moment (D5, D6). The longest stretch without one is the
        // 5 s between two samples (D7).
        try assertNumber(row, "runningHRCoveragePercent", 100)
        try assertNumber(row, "largestHRSampleGapSeconds", 5)
        XCTAssertEqual(try cell(row, "insufficientHRData"), "false")
    }

    // MARK: - B. Clear drift

    /// 135 bpm at 3 m/s for the first half; 150 bpm at 2.7 m/s for the second.
    func testBClearDriftFollowsTheDocumentedFormulas() throws {
        try export(legs: [Leg("run", 0, 1_800)],
                   heartRate: grid(0, 1_800) { $0 < 900 ? 135 : 150 },
                   distance: steps(0, 1_800) { $0 < 900 ? 3 : 2.7 })

        let row = try summary()
        // D17: second − first, and (second − first) ÷ first × 100.
        try assertNumber(row, "heartRateDriftBPM", 15)
        try assertNumber(row, "heartRateDriftPercent", 15.0 / 135 * 100)
        // D15: (2700 m + 2430 m) ÷ 1800 s; pace = 1609.344 ÷ speed.
        try assertNumber(row, "runningAverageSpeedMetersPerSecond", 2.85)
        try assertNumber(row, "runningAveragePaceSecondsPerMile", 1_609.344 / 2.85)
        try assertNumber(row, "firstHalfAverageSpeed", 3)
        try assertNumber(row, "secondHalfAverageSpeed", 2.7)
        // On speed, so slower is negative.
        try assertNumber(row, "paceOrSpeedDriftPercent", -10)
        // D16: meters per beat = speed ÷ (bpm ÷ 60). 3 ÷ 2.25 and 2.7 ÷ 2.5.
        try assertNumber(row, "firstHalfEfficiency", 3 / 2.25)
        try assertNumber(row, "secondHalfEfficiency", 1.08)
        try assertNumber(row, "efficiencyChangePercent", (1.08 - 3 / 2.25) / (3 / 2.25) * 100)
    }

    // MARK: - C. Intervals

    /// 5 min run / 3 min walk × 6. Runs 1–3 at 140 bpm, runs 4–6 at 150, every walk at 100.
    func testCIntervalsUseOnlyRunningTimeAndSplitAtRunningMinuteFifteen() throws {
        var legs: [Leg] = []
        for i in 0..<6 {
            let start = Double(i * 480)
            legs.append(Leg("run", start, start + 300, repetition: i + 1))
            legs.append(Leg("walk", start + 300, start + 480, repetition: i + 1))
        }
        func inRun(_ t: Double) -> Int? {
            let i = Int(t / 480)
            return t - Double(i * 480) < 300 ? i : nil
        }
        try export(legs: legs,
                   heartRate: grid(0, 2_880) { t in inRun(t).map { $0 < 3 ? 140 : 150 } ?? 100 },
                   distance: steps(0, 2_880) { t in inRun(t) == nil ? 1.5 : 3 })

        let row = try summary()
        try assertNumber(row, "totalRunningDurationSeconds", 1_800)
        try assertNumber(row, "totalRunningDistanceMeters", 5_400)
        try assertNumber(row, "runningHRSampleCount", 360)
        try assertNumber(row, "runningAverageHR", 145)
        try assertNumber(row, "runningMinimumHR", 140, "a walk's 100 bpm reached the running metrics")
        // Running minute 15 is the end of run 3, though the clock reads 23 minutes there.
        try assertNumber(row, "firstHalfAverageHR", 140)
        try assertNumber(row, "secondHalfAverageHR", 150)

        // Each leg is sliced on its own.
        let walk = try interval(phase: "walk", repetition: 2)
        try assertNumber(walk, "averageHR", 100)
        let run = try interval(phase: "run", repetition: 5)
        try assertNumber(run, "averageHR", 150)
        try assertNumber(run, "hrSampleCount", 60)
    }

    // MARK: - D. The split inside an interval

    /// Three 10-minute runs with 2-minute walks. Running minute 15 falls halfway through run 2, where
    /// heart rate steps from 140 to 150 and speed from 3 to 2 m/s. Giving run 2 to either half whole
    /// would put 142.5 or 147.5 bpm in a half.
    func testDTheSplitCutsTheIntervalItFallsIn() throws {
        let legs = [Leg("run", 0, 600, repetition: 1), Leg("walk", 600, 720, repetition: 1),
                    Leg("run", 720, 1_320, repetition: 2), Leg("walk", 1_320, 1_440, repetition: 2),
                    Leg("run", 1_440, 2_040, repetition: 3)]
        func walking(_ t: Double) -> Bool { (600..<720).contains(t) || (1_320..<1_440).contains(t) }
        try export(legs: legs,
                   heartRate: grid(0, 2_040) { t in walking(t) ? 110 : (t < 1_020 ? 140 : 150) },
                   distance: steps(0, 2_040) { t in walking(t) ? 1.2 : (t < 1_020 ? 3 : 2) })

        let row = try summary()
        try assertNumber(row, "firstHalfAverageHR", 140)
        try assertNumber(row, "secondHalfAverageHR", 150)
        try assertNumber(row, "firstHalfAverageSpeed", 3)
        try assertNumber(row, "secondHalfAverageSpeed", 2)
    }

    // MARK: - E. Pauses

    /// A 10-minute run paused from 3:30 to 5:30. Heart rate reads 90 while paused, 140 otherwise.
    /// The engine shifts the run's recorded start forward by the pause, so its recorded window
    /// covers the pause and misses its first two minutes (LEARNINGS.md); the analysis must not use it.
    func testEPausedTimeDoesNotReachTheRunningMetrics() throws {
        let paused = 210.0..<330.0
        try export(legs: [Leg("run", 0, 720, pauses: [(210, 330)])],
                   heartRate: grid(0, 720) { paused.contains($0) ? 90 : 140 },
                   distance: steps(0, 720) { paused.contains($0) ? nil : 3 })

        let row = try summary()
        try assertNumber(row, "totalRunningDurationSeconds", 600)
        try assertNumber(row, "totalRunningDistanceMeters", 1_800)
        // 42 samples before the pause, 78 after it.
        try assertNumber(row, "runningHRSampleCount", 120)
        try assertNumber(row, "runningAverageHR", 140)
        try assertNumber(row, "runningMinimumHR", 140, "paused heart rate reached the running metrics")
        // The pause is not running time, so it is neither a gap nor a hole in coverage (D7).
        try assertNumber(row, "runningHRCoveragePercent", 100)
        try assertNumber(row, "largestHRSampleGapSeconds", 5)
    }

    // MARK: - F. No heart rate

    func testFNoHeartRateLeavesHeartRateMetricsBlankAndFlagged() throws {
        try export(legs: [Leg("run", 0, 1_800)],
                   heartRate: [],
                   distance: steps(0, 1_800) { _ in 3 })

        let row = try summary()
        try assertNumber(row, "runningHRSampleCount", 0, "a count of none is a count (D9)")
        try assertNumber(row, "runningHRCoveragePercent", 0)
        try assertNumber(row, "largestHRSampleGapSeconds", 1_800)
        XCTAssertEqual(try cell(row, "insufficientHRData"), "true")
        for column in ["runningAverageHR", "runningMedianHR", "runningMinimumHR", "runningMaximumHR",
                       "firstHalfAverageHR", "secondHalfAverageHR",
                       "heartRateDriftBPM", "heartRateDriftPercent",
                       "firstHalfEfficiency", "secondHalfEfficiency", "efficiencyChangePercent"] {
            XCTAssertEqual(try cell(row, column), "", "\(column) must be blank, never 0")
        }
        // Distance does not depend on heart rate.
        try assertNumber(row, "runningAverageSpeedMetersPerSecond", 3)
    }

    // MARK: - G. A large gap

    /// 140 bpm throughout, except no sample at all between 10:00 and 15:00. The last sample before the
    /// hole is at 597.5 s and the first after it at 902.5 s.
    func testGALargeGapLowersCoverageAndWithholdsDrift() throws {
        try export(legs: [Leg("run", 0, 1_800)],
                   heartRate: grid(0, 1_800) { (600..<900).contains($0) ? nil : 140 },
                   distance: steps(0, 1_800) { _ in 3 })

        let row = try summary()
        try assertNumber(row, "largestHRSampleGapSeconds", 305)
        // Uncovered: more than 5 s from any sample, 602.5 s to 897.5 s (D6).
        try assertNumber(row, "runningHRCoveragePercent", (1_800 - 295) / 1_800.0 * 100)
        // 84% overall passes, but the first half is only 67% covered, so drift is withheld (D8).
        XCTAssertEqual(try cell(row, "insufficientHRData"), "true")
        XCTAssertEqual(try cell(row, "heartRateDriftBPM"), "")
        XCTAssertEqual(try cell(row, "firstHalfAverageHR"), "")
        XCTAssertEqual(try cell(row, "firstHalfEfficiency"), "")
        // The whole-run figures stay, beside the coverage that qualifies them.
        try assertNumber(row, "runningAverageHR", 140)
    }

    // MARK: - H. Recovery

    /// A run, a 3-minute walk, a second run, then a 90-second cooldown. 160 bpm while running, falling
    /// 0.2 bpm a second after each run ends. Samples on whole 5-second marks, so one sits exactly at
    /// each moment the drops are read.
    func testHRecoveryDropsAfterARunIncludingIntoCooldown() throws {
        let legs = [Leg("run", 0, 300, repetition: 1), Leg("walk", 300, 480, repetition: 1),
                    Leg("run", 480, 780, repetition: 2), Leg("cooldown", 780, 870)]
        func bpm(_ t: Double) -> Double {
            if t > 300 && t < 480 { return 160 - 0.2 * (t - 300) }
            if t > 780 { return 160 - 0.2 * (t - 780) }
            return 160
        }
        try export(legs: legs,
                   heartRate: grid(0, 870, offset: 0, through: true, bpm),
                   distance: steps(0, 870) { _ in 3 })

        // D11: the run's endHR (160) minus the sample 30, 60 and 120 s after the run ended.
        let walk = try interval(phase: "walk", repetition: 1)
        try assertNumber(walk, "heartRateDrop30s", 6)
        try assertNumber(walk, "heartRateDrop60s", 12)
        try assertNumber(walk, "heartRateDrop120s", 24)

        let cooldown = try interval(phase: "cooldown", repetition: nil)
        try assertNumber(cooldown, "heartRateDrop30s", 6)
        try assertNumber(cooldown, "heartRateDrop60s", 12)
        XCTAssertEqual(try cell(cooldown, "heartRateDrop120s"), "",
                       "120 s after the run is past the end of a 90 s cooldown")

        let run = try interval(phase: "run", repetition: 2)
        XCTAssertEqual(try cell(run, "heartRateDrop30s"), "", "a run is not a recovery")
    }

    // MARK: - I. No distance

    func testIMissingDistanceKeepsHeartRateAndBlanksPace() throws {
        try export(legs: [Leg("run", 0, 1_800)],
                   heartRate: grid(0, 1_800) { _ in 140 },
                   distance: [])

        let row = try summary()
        try assertNumber(row, "runningAverageHR", 140)
        try assertNumber(row, "heartRateDriftBPM", 0)
        XCTAssertEqual(try cell(row, "insufficientHRData"), "false")
        for column in ["totalRunningDistanceMeters", "runningAverageSpeedMetersPerSecond",
                       "runningAveragePaceSecondsPerMile",
                       "firstHalfAverageSpeed", "secondHalfAverageSpeed", "paceOrSpeedDriftPercent",
                       "firstHalfEfficiency", "secondHalfEfficiency", "efficiencyChangePercent"] {
            XCTAssertEqual(try cell(row, column), "", "\(column) must be blank, never 0 (D14)")
        }
    }

    // MARK: - J. A workout from before this feature

    /// Logged before aerobic fields existed. Every test above already has no run log, which is §26's
    /// unlogged case; this one has a log that predates the feature.
    func testJARunLoggedBeforeTheFeatureStillExportsAndIsAnalyzed() throws {
        let log = RunLogExportRow(runLogID: "log-old", healthKitWorkoutUUID: workoutUUID,
                                  plannedWorkoutID: nil, executionID: executionID,
                                  createdAt: t0, updatedAt: t0,
                                  effortRPE: 4, personalHeatRating: 5,
                                  lowerBackSeverity: 0, leftAnkleSeverity: 0, rightAnkleSeverity: 0,
                                  leftKneeSeverity: 0, rightKneeSeverity: 0,
                                  workoutStartDate: t0, workoutDistanceMiles: 3,
                                  workoutActivityType: "running")
        try export(legs: [Leg("run", 0, 1_800)],
                   heartRate: grid(0, 1_800) { _ in 140 },
                   distance: steps(0, 1_800) { _ in 3 },
                   runLog: log)

        // D18: blank means "not recorded".
        let logged = try XCTUnwrap(try table("run_logs.csv").first { $0["runLogID"] == "log-old" })
        for column in ["intensityMode", "targetRPEMin", "targetRPEMax",
                       "targetHeartRateMin", "targetHeartRateMax", "talkTest"] {
            XCTAssertEqual(try cell(logged, column), "", "\(column) was never recorded for this run")
        }

        let row = try summary()
        XCTAssertEqual(try cell(row, "runLogID"), "log-old")
        XCTAssertEqual(try cell(row, "intensityMode"), "")
        try assertNumber(row, "effortRPE", 4)
        try assertNumber(row, "runningAverageHR", 140)
    }

    // MARK: - Building a run

    /// One leg as the app records it. `pauses` are absolute times inside the leg; they become pause
    /// rows written ahead of it, with the leg's recorded start shifted forward by their total — what
    /// `IntervalTimerEngine` does on resume.
    private struct Leg {
        let phase: String
        let start: Double
        let end: Double
        let repetition: Int?
        let pauses: [(Double, Double)]

        init(_ phase: String, _ start: Double, _ end: Double,
             repetition: Int? = nil, pauses: [(Double, Double)] = []) {
            self.phase = phase
            self.start = start
            self.end = end
            self.repetition = repetition
            self.pauses = pauses
        }
    }

    private func rows(for legs: [Leg]) -> [IntervalLogExportRow] {
        var rows: [IntervalLogExportRow] = []
        func row(_ phase: String, _ start: Double, _ end: Double, repetition: Int?,
                 duration: Double) -> IntervalLogExportRow {
            IntervalLogExportRow(intervalLogID: "leg-\(rows.count)",
                                 healthKitWorkoutUUID: workoutUUID,
                                 executionID: executionID,
                                 sequenceIndex: rows.count,
                                 phaseType: phase,
                                 repetitionNumber: repetition,
                                 plannedDurationSeconds: nil,
                                 actualDurationSeconds: duration,
                                 startDate: t0.addingTimeInterval(start),
                                 endDate: t0.addingTimeInterval(end),
                                 wasSkipped: false,
                                 wasInterrupted: false)
        }
        for leg in legs {
            var paused = 0.0
            for (start, end) in leg.pauses {
                rows.append(row("paused", start, end, repetition: leg.repetition, duration: end - start))
                paused += end - start
            }
            rows.append(row(leg.phase, leg.start + paused, leg.end, repetition: leg.repetition,
                            duration: leg.end - leg.start - paused))
        }
        return rows
    }

    /// Heart-rate samples every 5 s from `start` to `end`, at `offset` past each 5 s mark. The
    /// default 2.5 s offset gives each sample sole claim to the 5 s around it. `bpm` returns nil
    /// where no sample should exist.
    private func grid(_ start: Double, _ end: Double, offset: Double = 2.5, through: Bool = false,
                      _ bpm: (Double) -> Double?) -> [WorkoutSample] {
        var samples: [WorkoutSample] = []
        var t = start + offset
        while through ? t <= end : t < end {
            if let value = bpm(t) {
                let at = t0.addingTimeInterval(t)
                samples.append(WorkoutSample(start: at, end: at, value: value))
            }
            t += 5
        }
        return samples
    }

    /// Distance samples spanning 3 s each, as the Watch writes them (LEARNINGS.md), at the speed
    /// `speed` gives for the start of each span. Nil writes no sample.
    private func steps(_ start: Double, _ end: Double,
                       _ speed: (Double) -> Double?) -> [WorkoutSample] {
        var samples: [WorkoutSample] = []
        var t = start
        while t < end {
            if let metersPerSecond = speed(t) {
                samples.append(WorkoutSample(start: t0.addingTimeInterval(t),
                                             end: t0.addingTimeInterval(t + 3),
                                             value: metersPerSecond * 3))
            }
            t += 3
        }
        return samples
    }

    // MARK: - Running the export

    private var exportFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("aerobic_export_test",
                                                                      isDirectory: true)
    }

    /// Writes a complete export of one workout with the real `ExportBuilder.writeFiles`.
    private func export(legs: [Leg], heartRate: [WorkoutSample], distance: [WorkoutSample],
                        runLog: RunLogExportRow? = nil) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: exportFolder)
        try fm.createDirectory(at: exportFolder, withIntermediateDirectories: true)

        let end = (legs.map(\.end).max() ?? 0)
        var logger = LoggerExportData()
        logger.intervalLogs = rows(for: legs)
        logger.executions = [
            ExecutionExportRow(executionID: executionID, plannedWorkoutID: UUID().uuidString,
                               plannedWorkoutName: "invented", expectedActivityType: "running",
                               expectedDurationSeconds: nil,
                               runIntervalSeconds: nil, walkIntervalSeconds: nil,
                               plannedRepetitions: nil, completedRepetitions: nil,
                               blockShape: nil, status: "matched",
                               matchedHealthKitWorkoutUUID: workoutUUID,
                               timerStartedAt: t0, timerEndedAt: t0.addingTimeInterval(end),
                               createdAt: t0, updatedAt: t0),
        ]
        logger.runLogs = runLog.map { [$0] } ?? []
        logger.index()

        var dataset = ExportDataset()
        dataset.workouts = [workoutRow(duration: end)]
        dataset.logger = logger
        dataset.workoutSamples = [workoutUUID: WorkoutSamples(heartRate: heartRate, distance: distance)]

        let builder = ExportBuilder(health: HealthKitManager(), appVersion: "aerobic-test")
        try builder.writeFiles(dataset: dataset,
                               into: exportFolder,
                               programStart: t0,
                               queryStart: t0,
                               queryEnd: t0.addingTimeInterval(86_400),
                               mode: .fullDateRange,
                               options: ExportOptions(includeWeather: false, includeRoutes: false,
                                                      includeWalking: false,
                                                      reclassifiedAsRunning: []),
                               intervalAudio: IntervalAudioSettings(
                                   cueSource: CueSource.iphoneAudioEngine.rawValue,
                                   cueMode: CueMode.voiceAndBeeps.rawValue,
                                   countdownSeconds: 3, fiveSecondWarning: false,
                                   finalRoundAnnouncement: false, halfwayAnnouncement: false,
                                   transitionCountdown: false, duckOtherAudio: true),
                               createdAt: t0)
    }

    private func workoutRow(duration: Double) -> WorkoutExportRow {
        WorkoutExportRow(uuid: workoutUUID,
                         workoutActivityType: "HKWorkoutActivityTypeRunning",
                         workoutActivityTypeName: "running",
                         startDate: Fmt.isoString(t0),
                         endDate: Fmt.isoString(t0.addingTimeInterval(duration)),
                         duration: String(duration),
                         totalDistance: "", totalDistanceUnit: "mi", totalDistanceMeters: "",
                         totalEnergyBurned: "", totalEnergyBurnedUnit: "kcal",
                         totalEnergyKilocalories: "",
                         sourceName: "invented", sourceBundleIdentifier: "invented",
                         sourceVersion: "1", deviceName: "invented", deviceJSON: "{}",
                         metadataJSON: "{}", workoutEventsJSON: "[]", workoutStatisticsJSON: "[]")
    }

    // MARK: - Reading the export

    /// A CSV file as rows keyed by its header. A small RFC 4180 reader, so the file is checked by
    /// parsing it rather than by trusting the writer that produced it.
    private func table(_ name: String) throws -> [[String: String]] {
        let text = try String(contentsOf: exportFolder.appendingPathComponent(name), encoding: .utf8)
        var records: [[String]] = []
        var field = ""
        var record: [String] = []
        var quoted = false
        var chars = Array(text)[...]
        while let c = chars.popFirst() {
            if quoted {
                if c == "\"" {
                    if chars.first == "\"" { field.append("\""); chars.removeFirst() } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                quoted = true
            } else if c == "," {
                record.append(field); field = ""
            } else if c == "\r\n" || c == "\n" {
                record.append(field); field = ""
                records.append(record); record = []
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !record.isEmpty { record.append(field); records.append(record) }
        let header = try XCTUnwrap(records.first, "\(name) is empty")
        return records.dropFirst().map { Dictionary(uniqueKeysWithValues: zip(header, $0)) }
    }

    private func summary() throws -> [String: String] {
        let rows = try table("aerobic_workout_summary.csv")
        return try XCTUnwrap(rows.first { $0["healthKitWorkoutUUID"] == workoutUUID },
                             "no aerobic_workout_summary.csv row for the workout")
    }

    private func interval(phase: String, repetition: Int?) throws -> [String: String] {
        let rows = try table("workout_intervals.csv")
        let wanted = repetition.map(String.init) ?? ""
        return try XCTUnwrap(rows.first { $0["phaseType"] == phase && $0["repetitionNumber"] == wanted },
                             "no \(phase) \(wanted) row in workout_intervals.csv")
    }

    /// A cell's text. A column the file does not have is a failure, never a blank.
    private func cell(_ row: [String: String], _ column: String) throws -> String {
        try XCTUnwrap(row[column], "the file has no \(column) column")
    }

    private func assertNumber(_ row: [String: String], _ column: String, _ expected: Double,
                              _ message: String = "",
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let text = try cell(row, column)
        let value = try XCTUnwrap(Double(text), "\(column) is \"\(text)\", not a number. \(message)",
                                  file: file, line: line)
        XCTAssertEqual(value, expected, accuracy: 0.001, "\(column). \(message)", file: file, line: line)
    }
}
