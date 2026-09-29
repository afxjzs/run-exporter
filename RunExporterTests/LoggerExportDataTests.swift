import XCTest
@testable import RunExporter

/// The joins that let `workouts.csv` carry subjective data without a manual join, and the shoe
/// mileage arithmetic behind them.
final class LoggerExportDataTests: XCTestCase {

    private let shoeID = UUID()
    private let otherShoeID = UUID()
    private let base = Date(timeIntervalSinceReferenceDate: 0)

    private func runLog(workoutUUID: String,
                        shoe: UUID?,
                        dayOffset: Double,
                        distance: Double?,
                        executionID: String? = nil,
                        rpe: Double = 6.5,
                        heat: Double = 7.5) -> RunLogExportRow {
        RunLogExportRow(runLogID: UUID().uuidString,
                        healthKitWorkoutUUID: workoutUUID,
                        plannedWorkoutID: nil,
                        executionID: executionID,
                        createdAt: base,
                        updatedAt: base.addingTimeInterval(dayOffset * 86_400),
                        runIntervalSeconds: 240,
                        walkIntervalSeconds: 60,
                        plannedRepetitions: 5,
                        completedRepetitions: 5,
                        effortRPE: rpe,
                        personalHeatRating: heat,
                        lowerBackSeverity: 0,
                        leftAnkleSeverity: 1,
                        rightAnkleSeverity: 0,
                        leftKneeSeverity: 0,
                        rightKneeSeverity: 0,
                        shoeID: shoe?.uuidString,
                        shoeName: nil,
                        notes: "note",
                        workoutStartDate: base.addingTimeInterval(dayOffset * 86_400),
                        workoutDistanceMiles: distance,
                        workoutActivityType: "running")
    }

    private func shoe(_ id: UUID, name: String, starting: Double) -> ShoeExportRow {
        ShoeExportRow(shoeID: id.uuidString, brand: "On", model: name, displayName: name,
                      firstUseDate: base, retiredDate: nil,
                      startingMileage: starting, isDefault: true, notes: nil)
    }

    // MARK: - Shoe mileage

    func testAssignedMileageSumsOnlyThatShoesRuns() {
        var data = LoggerExportData()
        data.shoes = [shoe(shoeID, name: "Cloudmonster 2", starting: 10),
                      shoe(otherShoeID, name: "Other", starting: 0)]
        data.runLogs = [runLog(workoutUUID: "w1", shoe: shoeID, dayOffset: 0, distance: 2.0),
                        runLog(workoutUUID: "w2", shoe: shoeID, dayOffset: 1, distance: 3.0),
                        runLog(workoutUUID: "w3", shoe: otherShoeID, dayOffset: 2, distance: 5.0)]
        data.index()

        let cloudmonster = try! XCTUnwrap(data.shoes.first { $0.shoeID == shoeID.uuidString })
        XCTAssertEqual(cloudmonster.assignedWorkoutMileage, 5.0, accuracy: 0.0001)
        XCTAssertEqual(cloudmonster.totalMileage, 15.0, accuracy: 0.0001,
                       "Total is starting mileage plus assigned runs")
    }

    /// The odometer reading after a given workout, not the shoe's lifetime total.
    func testMileageAtWorkoutIsCumulativeUpToThatWorkout() {
        var data = LoggerExportData()
        data.shoes = [shoe(shoeID, name: "Cloudmonster 2", starting: 10)]
        data.runLogs = [runLog(workoutUUID: "w1", shoe: shoeID, dayOffset: 0, distance: 2.0),
                        runLog(workoutUUID: "w2", shoe: shoeID, dayOffset: 1, distance: 3.0),
                        runLog(workoutUUID: "w3", shoe: shoeID, dayOffset: 2, distance: 4.0)]
        data.index()

        let second = try! XCTUnwrap(data.join(forWorkoutUUID: "w2"))
        XCTAssertEqual(try! XCTUnwrap(second.shoeMileageAtWorkoutMiles), 15.0, accuracy: 0.0001,
                       "10 starting + 2 + 3, not including the later 4-mile run")
    }

    /// A workout with no recorded distance contributes nothing rather than a guess.
    func testMissingDistanceContributesZeroMiles() {
        var data = LoggerExportData()
        data.shoes = [shoe(shoeID, name: "Cloudmonster 2", starting: 0)]
        data.runLogs = [runLog(workoutUUID: "w1", shoe: shoeID, dayOffset: 0, distance: nil),
                        runLog(workoutUUID: "w2", shoe: shoeID, dayOffset: 1, distance: 2.0)]
        data.index()

        XCTAssertEqual(data.shoes[0].assignedWorkoutMileage, 2.0, accuracy: 0.0001)
    }

    // MARK: - Joins

    func testUnloggedWorkoutHasNoJoin() {
        var data = LoggerExportData()
        data.index()
        XCTAssertNil(data.join(forWorkoutUUID: "never-logged"))
    }

    func testJoinCarriesSubjectiveValues() {
        var data = LoggerExportData()
        data.shoes = [shoe(shoeID, name: "Cloudmonster 2", starting: 0)]
        data.runLogs = [runLog(workoutUUID: "w1", shoe: shoeID, dayOffset: 0, distance: 2.0)]
        data.index()

        let join = try! XCTUnwrap(data.join(forWorkoutUUID: "w1"))
        XCTAssertEqual(join.effortRPE, 6.5)
        XCTAssertEqual(join.personalHeatRating, 7.5)
        XCTAssertEqual(join.leftAnkleSeverity, 1)
        XCTAssertEqual(join.shoeName, "Cloudmonster 2")
        XCTAssertEqual(join.userNotes, "note")
    }

    func testRecoveryRatingJoinsToItsWorkout() {
        var data = LoggerExportData()
        data.runLogs = [runLog(workoutUUID: "w1", shoe: nil, dayOffset: 0, distance: 2.0)]
        data.recoveryLogs = [RecoveryLogExportRow(recoveryLogID: UUID().uuidString,
                                                  healthKitWorkoutUUID: "w1",
                                                  runLogID: nil,
                                                  recoveryRating: 9,
                                                  lowerBackSeverity: 0,
                                                  leftAnkleSeverity: 0,
                                                  rightAnkleSeverity: 0,
                                                  leftKneeSeverity: 0,
                                                  rightKneeSeverity: 0,
                                                  notes: nil,
                                                  createdAt: base,
                                                  updatedAt: base)]
        data.index()

        XCTAssertEqual(try! XCTUnwrap(data.join(forWorkoutUUID: "w1")).nextDayRecovery, 9)
    }

    // MARK: - Main set vs cooldown

    private func interval(_ phase: WorkoutPhase, seconds: Double,
                          workoutUUID: String?) -> IntervalLogExportRow {
        IntervalLogExportRow(intervalLogID: UUID().uuidString,
                             healthKitWorkoutUUID: workoutUUID,
                             executionID: "exec-1",
                             sequenceIndex: 0,
                             phaseType: phase.rawValue,
                             repetitionNumber: nil,
                             plannedDurationSeconds: nil,
                             actualDurationSeconds: seconds,
                             startDate: base,
                             endDate: base.addingTimeInterval(seconds),
                             wasSkipped: false,
                             wasInterrupted: false)
    }

    /// Spec §25: a long cooldown must never reach the main-set number.
    func testCooldownAndPauseAreExcludedFromMainSet() {
        var data = LoggerExportData()
        data.runLogs = [runLog(workoutUUID: "w1", shoe: nil, dayOffset: 0,
                               distance: 2.0, executionID: "exec-1")]
        data.intervalLogs = [interval(.run, seconds: 240, workoutUUID: "w1"),
                             interval(.walk, seconds: 60, workoutUUID: "w1"),
                             interval(.run, seconds: 240, workoutUUID: "w1"),
                             interval(.cooldown, seconds: 1_500, workoutUUID: "w1"),
                             interval(.paused, seconds: 300, workoutUUID: "w1")]
        data.index()

        let join = try! XCTUnwrap(data.join(forWorkoutUUID: "w1"))
        XCTAssertEqual(try! XCTUnwrap(join.mainSetDurationSeconds), 540, accuracy: 0.0001)
        XCTAssertEqual(try! XCTUnwrap(join.cooldownDurationSeconds), 1_500, accuracy: 0.0001)
        XCTAssertEqual(try! XCTUnwrap(join.pausedDurationSeconds), 300, accuracy: 0.0001)
    }

    /// Intervals recorded before matching are still found, via the execution.
    func testIntervalsFallBackToExecutionWhenNotYetStamped() {
        var data = LoggerExportData()
        data.runLogs = [runLog(workoutUUID: "w1", shoe: nil, dayOffset: 0,
                               distance: 2.0, executionID: "exec-1")]
        data.intervalLogs = [interval(.run, seconds: 240, workoutUUID: nil),
                             interval(.cooldown, seconds: 600, workoutUUID: nil)]
        data.index()

        let join = try! XCTUnwrap(data.join(forWorkoutUUID: "w1"))
        XCTAssertEqual(try! XCTUnwrap(join.mainSetDurationSeconds), 240, accuracy: 0.0001)
    }

    // MARK: - Diagnostics

    func testDuplicateRunLogsAreReportedNotDropped() {
        var data = LoggerExportData()
        data.runLogs = [runLog(workoutUUID: "w1", shoe: nil, dayOffset: 0, distance: 2.0),
                        runLog(workoutUUID: "w1", shoe: nil, dayOffset: 1, distance: 2.0)]
        data.index()

        XCTAssertTrue(data.issues.contains { $0.level == .warning },
                      "Two logs on one workout must be reported")
        XCTAssertEqual(data.runLogs.count, 2, "Both logs still reach run_logs.csv")
    }

    func testManifestCountsReflectContents() {
        var data = LoggerExportData()
        data.shoes = [shoe(shoeID, name: "Cloudmonster 2", starting: 0)]
        data.runLogs = [runLog(workoutUUID: "w1", shoe: shoeID, dayOffset: 0, distance: 2.0)]
        data.intervalLogs = [interval(.run, seconds: 60, workoutUUID: "w1")]
        data.unloggedWorkoutCount = 3
        data.index()

        let counts = data.manifestCounts
        XCTAssertEqual(counts["shoe_count"] as? Int, 1)
        XCTAssertEqual(counts["run_log_count"] as? Int, 1)
        XCTAssertEqual(counts["interval_log_count"] as? Int, 1)
        XCTAssertEqual(counts["unlogged_workout_count"] as? Int, 3)
        XCTAssertEqual(counts["store_available"] as? Bool, true)
    }

    func testUnavailableStoreIsReportedInManifest() {
        var data = LoggerExportData()
        data.storeUnavailable = true
        data.index()

        XCTAssertEqual(data.manifestCounts["store_available"] as? Bool, false,
                       "An unreadable store must not look like an empty one")
    }
}
