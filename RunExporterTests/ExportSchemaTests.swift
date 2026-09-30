import XCTest
@testable import RunExporter

/// Guards the export's contract with whatever already reads it.
///
/// The v1.0 columns must keep their exact names and positions, and a workout with no run log must
/// export blanks rather than zeros — the two mean different things and must stay distinguishable.
final class ExportSchemaTests: XCTestCase {

    // MARK: - Backwards compatibility

    /// The v1.0 `workouts.csv` header, verbatim. If this changes, an existing consumer breaks.
    private let v1WorkoutColumns = [
        "uuid", "workoutActivityType", "workoutActivityTypeName",
        "startDate", "endDate", "duration",
        "totalDistance", "totalDistanceUnit", "totalDistanceMeters",
        "totalEnergyBurned", "totalEnergyBurnedUnit", "totalEnergyKilocalories",
        "sourceName", "sourceBundleIdentifier", "sourceVersion",
        "deviceName", "deviceJSON",
        "metadataJSON", "workoutEventsJSON", "workoutStatisticsJSON",
    ]

    func testV1WorkoutColumnsAreUnchangedAndStillLeading() {
        XCTAssertEqual(Array(WorkoutExportRow.columns.prefix(v1WorkoutColumns.count)),
                       v1WorkoutColumns,
                       "v1.0 columns must keep their names and leading positions")
    }

    /// Column groups are only ever appended, never reordered, so existing readers keep working.
    /// Order: v1.0 base, weather, route, run-logger join, classification.
    func testColumnGroupsAreAppendedInOrder() {
        let expected = v1WorkoutColumns
            + WorkoutWeather.columns
            + RouteSummaryRow.workoutColumns
            + WorkoutLoggerJoin.columns
            + WorkoutExportRow.classificationColumns

        XCTAssertEqual(WorkoutExportRow.columns, expected)
    }

    /// Every column list must have exactly as many entries as its row emits values.
    func testAllRowsAreRectangular() {
        let row = WorkoutExportRow(
            uuid: "u", workoutActivityType: "a", workoutActivityTypeName: "running",
            startDate: "s", endDate: "e", duration: "1",
            totalDistance: "1", totalDistanceUnit: "mi", totalDistanceMeters: "1609",
            totalEnergyBurned: "1", totalEnergyBurnedUnit: "kcal", totalEnergyKilocalories: "1",
            sourceName: "n", sourceBundleIdentifier: "b", sourceVersion: "v",
            deviceName: "d", deviceJSON: "{}",
            metadataJSON: "{}", workoutEventsJSON: "[]", workoutStatisticsJSON: "[]")

        XCTAssertEqual(row.values.count, WorkoutExportRow.columns.count)

        XCTAssertEqual(WorkoutLoggerJoin.blankValues.count, WorkoutLoggerJoin.columns.count)
        XCTAssertEqual(WorkoutLoggerJoin().values.count, WorkoutLoggerJoin.columns.count)

        let shoe = ShoeExportRow(shoeID: "s", brand: "On", model: "Cloudmonster 2",
                                 displayName: "On Cloudmonster 2", firstUseDate: nil,
                                 retiredDate: nil, startingMileage: 0, isDefault: true, notes: nil)
        XCTAssertEqual(shoe.values.count, ShoeExportRow.columns.count)

        let note = WorkoutNoteExportRow(noteID: "n", healthKitWorkoutUUID: "", executionID: "e",
                                        createdAt: Date(), phaseType: "walk", repetitionNumber: 3,
                                        secondsIntoWorkout: 742, text: "calf tight")
        XCTAssertEqual(note.values.count, WorkoutNoteExportRow.columns.count)

        let block = PlannedWorkoutBlockExportRow(plannedWorkoutID: "p", position: 0,
                                                 runIntervalSeconds: 300,
                                                 walkIntervalSeconds: 60, repetitions: 1)
        XCTAssertEqual(block.values.count, PlannedWorkoutBlockExportRow.columns.count)

        let plan = PlannedWorkoutExportRow(
            plannedWorkoutID: "p", name: "4/1 × 5", activityType: "running",
            warmupMode: "none", warmupSeconds: nil,
            runIntervalSeconds: 240, walkIntervalSeconds: 60, plannedRepetitions: 5,
            includesFinalWalk: false, cooldownMode: "open", cooldownSeconds: nil,
            countdownSeconds: 0, totalRunSeconds: 1_200, totalWalkSeconds: 240,
            mainSetSeconds: 1_440, isNextWorkout: true, workoutKitIdentifier: nil,
            createdAt: Date(), updatedAt: Date())
        XCTAssertEqual(plan.values.count, PlannedWorkoutExportRow.columns.count)

        // Blanked columns must still occupy their position, or every column after them shifts left
        // and the file silently reports one field's value under another's name.
        let blockPlan = PlannedWorkoutExportRow(
            plannedWorkoutID: "p", name: "blocks", activityType: "running",
            warmupMode: "none", warmupSeconds: nil,
            runIntervalSeconds: nil, walkIntervalSeconds: nil, plannedRepetitions: nil,
            includesFinalWalk: false, cooldownMode: "open", cooldownSeconds: nil,
            countdownSeconds: 0, totalRunSeconds: 1_560, totalWalkSeconds: 180,
            mainSetSeconds: 1_740, isNextWorkout: true, workoutKitIdentifier: nil,
            createdAt: Date(), updatedAt: Date())
        XCTAssertEqual(blockPlan.values.count, PlannedWorkoutExportRow.columns.count)

        let execution = ExecutionExportRow(
            executionID: "e", plannedWorkoutID: "p", plannedWorkoutName: "blocks",
            expectedActivityType: "running", expectedDurationSeconds: 1_740,
            runIntervalSeconds: nil, walkIntervalSeconds: nil, plannedRepetitions: 4,
            completedRepetitions: nil, blockShape: "300/60x1|480/60x2|300/60x1",
            status: "started", matchedHealthKitWorkoutUUID: nil,
            timerStartedAt: nil, timerEndedAt: nil, createdAt: Date(), updatedAt: Date())
        XCTAssertEqual(execution.values.count, ExecutionExportRow.columns.count)
    }

    // MARK: - Blank never means zero

    func testUnloggedWorkoutExportsBlanksNotZeros() {
        let row = WorkoutLoggerJoin.blankValues
        XCTAssertEqual(row.count, WorkoutLoggerJoin.columns.count)
        XCTAssertTrue(row.allSatisfy { $0.isEmpty },
                      "An unlogged workout must export empty strings, never 0")
    }

    /// A body-signal severity of 0 is a real answer and must survive as "0".
    func testLoggedZeroSeverityIsNotBlank() {
        var join = WorkoutLoggerJoin()
        join.effortRPE = 6.5
        join.personalHeatRating = 7
        join.lowerBackSeverity = 0

        let index = try! XCTUnwrap(WorkoutLoggerJoin.columns.firstIndex(of: "lowerBackSeverity"))
        XCTAssertEqual(join.values[index], "0",
                       "A reported zero must not be indistinguishable from 'not logged'")
    }

    func testHalfPointRatingsSurviveFormatting() {
        var join = WorkoutLoggerJoin()
        join.effortRPE = 6.5
        join.personalHeatRating = 7.5

        let rpeIndex = try! XCTUnwrap(WorkoutLoggerJoin.columns.firstIndex(of: "effortRPE"))
        let heatIndex = try! XCTUnwrap(
            WorkoutLoggerJoin.columns.firstIndex(of: "personalHeatRating"))

        XCTAssertEqual(join.values[rpeIndex], "6.5")
        XCTAssertEqual(join.values[heatIndex], "7.5")
    }

    /// Spec §20.1's list, in order, must all be present.
    func testSpecMandatedJoinColumnsArePresentInOrder() {
        let required = ["plannedWorkoutID", "plannedWorkoutName",
                        "runIntervalSeconds", "walkIntervalSeconds",
                        "plannedRepetitions", "completedRepetitions",
                        "effortRPE", "personalHeatRating",
                        "lowerBackSeverity", "leftAnkleSeverity", "rightAnkleSeverity",
                        "leftKneeSeverity", "rightKneeSeverity",
                        "shoeID", "shoeName", "shoeMileageAtWorkoutMiles",
                        "userNotes", "nextDayRecovery"]

        XCTAssertEqual(Array(WorkoutLoggerJoin.columns.prefix(required.count)), required)
    }

    /// Spec §20.2 and §20.3 column lists.
    func testRunLogAndIntervalColumnsMatchSpec() {
        let runLogRequired = ["runLogID", "healthKitWorkoutUUID", "plannedWorkoutID", "executionID",
                              "createdAt", "updatedAt",
                              "runIntervalSeconds", "walkIntervalSeconds",
                              "plannedRepetitions", "completedRepetitions",
                              "effortRPE", "personalHeatRating",
                              "lowerBackSeverity", "leftAnkleSeverity", "rightAnkleSeverity",
                              "leftKneeSeverity", "rightKneeSeverity",
                              "shoeID", "shoeName", "notes"]
        XCTAssertEqual(Array(RunLogExportRow.columns.prefix(runLogRequired.count)), runLogRequired)

        let intervalRequired = ["intervalLogID", "healthKitWorkoutUUID", "executionID",
                                "sequenceIndex", "phaseType", "repetitionNumber",
                                "plannedDurationSeconds", "actualDurationSeconds",
                                "startDate", "endDate", "wasSkipped", "wasInterrupted"]
        // Leading, not exhaustive — the same rule as §20.2 above and as every other column group
        // in this file: append, never reorder. The full fifteen-column list is pinned exactly by
        // `testBackThresholdIntervalColumnsAreAppendedAfterTheExistingOnes`, so nothing is given up
        // by loosening this one to match its siblings.
        XCTAssertEqual(Array(IntervalLogExportRow.columns.prefix(intervalRequired.count)),
                       intervalRequired)

        let shoeRequired = ["shoeID", "brand", "model", "displayName",
                            "firstUseDate", "retiredDate",
                            "startingMileage", "assignedWorkoutMileage", "totalMileage",
                            "isDefault", "notes"]
        XCTAssertEqual(ShoeExportRow.columns, shoeRequired)
    }

    // MARK: - CSV escaping

    /// A note containing a comma, a quote or a newline must not break the file.
    func testNotesWithCommasAndQuotesStayInOneField() {
        let note = "Full sun, no shade. \"Ouch\""
        let multiline = "line1\nline2"

        var writer = CSVWriter(columns: ["a", "b"])
        writer.addRow([note, multiline])

        // Assert on the escaping rules rather than on one exact byte sequence: a field with a
        // comma or quote is wrapped, and interior quotes are doubled.
        XCTAssertEqual(CSVWriter.escape(note), "\"Full sun, no shade. \"\"Ouch\"\"\"")
        XCTAssertEqual(CSVWriter.escape(multiline), "\"line1\nline2\"")
        XCTAssertEqual(CSVWriter.escape("plain"), "plain", "Fields needing no quoting stay bare")

        let text = writer.text
        XCTAssertTrue(text.hasPrefix("a,b\r\n"))
        XCTAssertTrue(text.contains(CSVWriter.escape(note)))
        XCTAssertTrue(text.contains(CSVWriter.escape(multiline)))
    }

    // MARK: - Open-interval columns

    /// The twelve existing columns keep their names and positions; the three that describe a
    /// open-interval leg are appended after them. Same rule as every other column group here —
    /// anything already parsing `workout_intervals.csv` keeps working.
    func testBackThresholdIntervalColumnsAreAppendedAfterTheExistingOnes() {
        let existing = [
            "intervalLogID", "healthKitWorkoutUUID", "executionID",
            "sequenceIndex", "phaseType", "repetitionNumber",
            "plannedDurationSeconds", "actualDurationSeconds",
            "startDate", "endDate", "wasSkipped", "wasInterrupted",
        ]

        XCTAssertEqual(IntervalLogExportRow.columns,
                       existing + ["endReason", "baselineReachedAt",
                                   "lowerBackSeverity", "leftAnkleSeverity", "rightAnkleSeverity",
                                   "leftKneeSeverity", "rightKneeSeverity"])
    }

    /// An ordinary interval run measures none of these, and exports them blank.
    ///
    /// A reading of `0` is a real answer meaning that area was fine; a blank means the question
    /// was never asked. Writing zero here would put a measurement into every row of every interval
    /// run ever exported.
    func testAnIntervalRunExportsBlanksForTheOpenIntervalColumns() {
        let row = IntervalLogExportRow(intervalLogID: "A",
                                       healthKitWorkoutUUID: nil,
                                       executionID: "B",
                                       sequenceIndex: 0,
                                       phaseType: "run",
                                       repetitionNumber: 1,
                                       plannedDurationSeconds: 240,
                                       actualDurationSeconds: 240,
                                       startDate: Date(timeIntervalSince1970: 0),
                                       endDate: Date(timeIntervalSince1970: 240),
                                       wasSkipped: false,
                                       wasInterrupted: false,
                                       endReason: nil,
                                       lowerBackSeverity: nil,
                                       leftAnkleSeverity: nil,
                                       rightAnkleSeverity: nil,
                                       leftKneeSeverity: nil,
                                       rightKneeSeverity: nil,
                                       baselineReachedAt: nil)

        XCTAssertEqual(Array(row.values.suffix(6)), ["", "", "", "", "", ""])
    }

    /// A plan row has to be able to say it is an open-interval plan and what it decided in advance.
    ///
    /// Without these, such a plan exports as one with no intervals and no rounds — indistinguishable
    /// from a damaged one, in a file whose whole job is describing what was planned. Appended, like
    /// every other group here.
    func testOpenIntervalPlanColumnsAreAppendedAfterTheExistingOnes() {
        let existing = [
            "plannedWorkoutID", "name", "activityType",
            "warmupMode", "warmupSeconds",
            "runIntervalSeconds", "walkIntervalSeconds", "plannedRepetitions", "includesFinalWalk",
            "cooldownMode", "cooldownSeconds", "countdownSeconds",
            "totalRunSeconds", "totalWalkSeconds", "mainSetSeconds",
            "isNextWorkout", "workoutKitIdentifier",
            "createdAt", "updatedAt",
        ]

        XCTAssertEqual(PlannedWorkoutExportRow.columns,
                       existing + ["openIntervalTargetSeconds",
                                   "openIntervalWalkFloorSeconds"])
    }
}
