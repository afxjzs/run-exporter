import XCTest
@testable import RunExporter

/// The cue-timing measurement, asserted so it cannot quietly become inert.
///
/// This exists because the playback log previously could not detect the bug it was built to detect:
/// it stamped a single time *after* all of a cue's work had finished, so every row read as regular
/// no matter how late the tone actually sounded. A timing log that cannot show drift is worse than
/// none, because it reads as evidence.
@MainActor
final class CueLatencyTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_775_000_000)

    private func record(latency: TimeInterval?) -> AudioCueEngine.PlaybackRecord {
        AudioCueEngine.PlaybackRecord(cue: "run",
                                      requestedAt: base,
                                      soundedAt: latency.map { base.addingTimeInterval($0) },
                                      route: "AirPods",
                                      spoke: true,
                                      played: latency != nil)
    }

    // MARK: - The measurement itself

    func testStartLatencyIsTheGapBetweenRequestAndSound() {
        XCTAssertEqual(record(latency: 0.25).startLatency ?? -1, 0.25, accuracy: 0.0001)
    }

    func testStartLatencyIsNilForACueWithNoTone() {
        // A voice-only cue has no tone whose start could be late, and reporting 0 would claim a
        // measurement that was never taken.
        XCTAssertNil(record(latency: nil).startLatency)
    }

    func testAZeroLatencyIsStillAMeasurementNotAnAbsence() {
        XCTAssertEqual(record(latency: 0).startLatency, 0)
    }

    // MARK: - The verdict it reports

    func testComfortablyOnTimeReadsAsOnTime() {
        let text = CueTestView.latencyDescription(0.004)
        XCTAssertTrue(text.contains("on time"), text)
        XCTAssertFalse(text.contains("LATE"), text)
    }

    func testClearlyLateReadsAsLateAndNamesTheDelay() {
        let text = CueTestView.latencyDescription(0.42)
        XCTAssertTrue(text.contains("LATE"), text)
        XCTAssertTrue(text.contains("420"), text)
    }

    /// The threshold is a claim about perception, so it is pinned on both sides rather than left to
    /// whoever next edits the comparison.
    func testFiftyMillisecondsIsTheBoundaryAndCountsAsOnTime() {
        XCTAssertTrue(CueTestView.latencyDescription(0.050).contains("on time"))
    }

    func testJustOverFiftyMillisecondsIsCalledOut() {
        XCTAssertTrue(CueTestView.latencyDescription(0.051).contains("LATE"))
    }

    func testLatencyIsReportedInWholeMillisecondsNotSeconds() {
        // Guards against a formatting change that would print "0 ms" for every sub-second delay and
        // make every row look fine.
        XCTAssertTrue(CueTestView.latencyDescription(0.137).contains("137"),
                      CueTestView.latencyDescription(0.137))
    }
}
