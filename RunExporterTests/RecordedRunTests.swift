import XCTest
@testable import RunExporter

/// What an execution actually ran, derived from its recorded legs.
///
/// Every summary row used to describe a run by its plan's shape, so an open-interval run — whose
/// legs the runner ends — was summarized as zeros although every leg was recorded. And the
/// aerobic analysis slices heart rate by these legs' times, so a leg's window must be the time
/// actually spent in it.
final class RecordedRunTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    /// A row as `IntervalTimerEngine` writes it: `start`/`end` are offsets from `t0` in seconds,
    /// and `duration` defaults to the window's length.
    private func row(_ sequence: Int, _ phase: String, rep: Int? = nil,
                     _ start: Double, _ end: Double, duration: Double? = nil,
                     endReason: LegEndReason? = nil) -> IntervalLogExportRow {
        var row = IntervalLogExportRow(intervalLogID: UUID().uuidString,
                                       healthKitWorkoutUUID: nil,
                                       executionID: "exec",
                                       sequenceIndex: sequence,
                                       phaseType: phase,
                                       repetitionNumber: rep,
                                       plannedDurationSeconds: nil,
                                       actualDurationSeconds: duration ?? (end - start),
                                       startDate: t0.addingTimeInterval(start),
                                       endDate: t0.addingTimeInterval(end),
                                       wasSkipped: false,
                                       wasInterrupted: false)
        row.endReason = endReason?.rawValue
        return row
    }

    /// Countdown, a timed warmup and an open cooldown are recorded too. Counting any of them as
    /// running would inflate exactly the totals the aerobic analysis is built on.
    func testOnlyRunAndWalkLegsCountTowardRunAndWalkTotals() throws {
        let run = try RecordedRun(rows: [
            row(0, "countdown", 0, 3),
            row(1, "warmup", 3, 303),
            row(2, "run", rep: 1, 303, 543),
            row(3, "walk", rep: 1, 543, 603),
            row(4, "run", rep: 2, 603, 843),
            row(5, "cooldown", 843, 1_443),
        ])

        XCTAssertEqual(run.runLegCount, 2)
        XCTAssertEqual(run.totalRunSeconds, 480, accuracy: 0.001)
        XCTAssertEqual(run.totalWalkSeconds, 60, accuracy: 0.001)
    }

    /// The engine shifts an interrupted leg's start forward by the pause, so its recorded window
    /// overlaps the pause and misses its own first seconds. Measured on a real run: a leg stored
    /// as starting a second before the pause that interrupted it ended.
    ///
    /// Here run 2 really starts at 300, pauses 360–420, and ends at 600: 240 s of running. It is
    /// recorded as 360–600, after the pause row.
    func testAPausedLegsActiveWindowsAreItsRealRunningTime() throws {
        let run = try RecordedRun(rows: [
            row(0, "run", rep: 1, 0, 240),
            row(1, "walk", rep: 1, 240, 300),
            row(2, "paused", 360, 420),
            row(3, "run", rep: 2, 360, 600, duration: 240),
        ])

        let leg = try XCTUnwrap(run.legs.last)
        XCTAssertEqual(leg.activeWindows, [
            DateInterval(start: t0.addingTimeInterval(300), end: t0.addingTimeInterval(360)),
            DateInterval(start: t0.addingTimeInterval(420), end: t0.addingTimeInterval(600)),
        ])
        XCTAssertEqual(leg.activeSeconds, 240, accuracy: 0.001)
    }

    func testPausedTimeIsNeitherRunningNorWalking() throws {
        let run = try RecordedRun(rows: [
            row(0, "run", rep: 1, 0, 240),
            row(1, "paused", 240, 300),
            row(2, "walk", rep: 1, 300, 360, duration: 60),
        ])

        XCTAssertEqual(run.totalRunSeconds, 240, accuracy: 0.001)
        XCTAssertEqual(run.totalWalkSeconds, 60, accuracy: 0.001)
        XCTAssertEqual(run.pausedSeconds, 60, accuracy: 0.001)
    }

    /// The point of the cleanup: an open run is described by what was run. Each round is a run
    /// and the walk after it, in whole seconds; a last run with no walk after it walked nothing.
    func testAnOpenRunIsDescribedByTheLegsTheRunnerEnded() throws {
        let run = try RecordedRun(rows: [
            row(0, "run", rep: 1, 0, 752, endReason: .runnerEnded),
            row(1, "walk", rep: 1, 752, 933),
            row(2, "run", rep: 2, 933, 1_142, endReason: .targetReached),
            row(3, "cooldown", 1_142, 1_500),
        ])

        XCTAssertEqual(run.runLegCount, 2)
        XCTAssertEqual(run.shapeDescriptor, "752/181|209/0")
        XCTAssertEqual(run.legs.map(\.endReason), [.runnerEnded, nil, .targetReached, nil])
    }

    /// An unknown phase cannot be sorted into run, walk or pause without guessing, and a guess
    /// would move a total. Fail, naming it.
    func testAnUnrecognizedPhaseFailsInsteadOfBeingGuessed() {
        XCTAssertThrowsError(try RecordedRun(rows: [row(0, "sprint", 0, 60)])) { error in
            XCTAssertEqual(error as? RecordedRun.Failure, .unrecognizedPhase("sprint"))
        }
    }

    /// The export groups rows by execution in a dictionary, which keeps no order.
    func testRowsAreReadInRecordedOrderWhateverOrderTheyArrive() throws {
        let run = try RecordedRun(rows: [
            row(2, "run", rep: 2, 300, 540),
            row(0, "run", rep: 1, 0, 240),
            row(1, "walk", rep: 1, 240, 300),
        ])

        XCTAssertEqual(run.shapeDescriptor, "240/60|240/0")
    }
}
