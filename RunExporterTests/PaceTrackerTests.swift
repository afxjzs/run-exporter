import XCTest
@testable import RunExporter

/// The pace figures the watch shows: leg pace, the current mile split, and total distance.
///
/// Computed on the watch from its own cumulative distance readings and its own clock (watch plan
/// step 2), so no clock sync is involved. Pure, so every edge is tested here rather than on a run.
final class PaceTrackerTests: XCTestCase {

    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let mile = PaceTracker.metersPerMile

    func testTotalDistanceFollowsTheReadings() {
        var tracker = PaceTracker(start: start)
        tracker.record(totalMeters: 100, at: start + 30)
        tracker.record(totalMeters: 450, at: start + 120)
        XCTAssertEqual(tracker.totalMeters, 450, accuracy: 0.001)
    }

    /// Seconds per mile over the leg: time to the latest reading ÷ distance since the leg began.
    func testLegPaceIsTimeOverDistanceSinceTheLegBegan() throws {
        var tracker = PaceTracker(start: start)
        tracker.record(totalMeters: 1_000, at: start + 400)
        tracker.beginLeg(at: start + 400)
        tracker.record(totalMeters: 1_000 + mile / 4, at: start + 400 + 120)   // a quarter mile in 2:00
        XCTAssertEqual(try XCTUnwrap(tracker.legPaceSecondsPerMile), 480, accuracy: 0.01)
    }

    /// The first few meters of a leg give absurd paces. Say nothing until there is enough distance.
    func testLegPaceIsAbsentUntilEnoughDistance() {
        var tracker = PaceTracker(start: start)
        tracker.beginLeg(at: start)
        tracker.record(totalMeters: 5, at: start + 2)
        XCTAssertNil(tracker.legPaceSecondsPerMile)
    }

    func testANewLegResetsTheLegBaseline() throws {
        var tracker = PaceTracker(start: start)
        tracker.beginLeg(at: start)
        tracker.record(totalMeters: mile / 2, at: start + 300)          // slow first leg: 10:00/mi
        tracker.beginLeg(at: start + 300)
        tracker.record(totalMeters: mile / 2 + mile / 4, at: start + 420) // quarter mile in 2:00
        XCTAssertEqual(try XCTUnwrap(tracker.legPaceSecondsPerMile), 480, accuracy: 0.01)
    }

    func testTheSplitBeforeTheFirstMileRunsFromTheStart() throws {
        var tracker = PaceTracker(start: start)
        tracker.record(totalMeters: mile / 2, at: start + 270)            // half mile in 4:30
        XCTAssertEqual(try XCTUnwrap(tracker.mileSplitSecondsPerMile), 540, accuracy: 0.01)
    }

    /// The mile is crossed between two readings. The split restarts at the interpolated crossing,
    /// not at the reading that happened to come after it.
    func testCrossingAMileInterpolatesTheCrossingTime() throws {
        var tracker = PaceTracker(start: start)
        tracker.record(totalMeters: mile - 100, at: start + 500)
        tracker.record(totalMeters: mile + 100, at: start + 540)          // crossing at start + 520
        XCTAssertEqual(tracker.currentMileStartedAt.timeIntervalSince(start), 520, accuracy: 0.01)
        tracker.record(totalMeters: mile + mile / 4, at: start + 520 + 120)
        XCTAssertEqual(try XCTUnwrap(tracker.mileSplitSecondsPerMile), 480, accuracy: 0.01)
    }

    /// A gap in readings can cross two miles at once. The split restarts at the last one crossed.
    func testAGapAcrossTwoMilesMarksTheLastOne() {
        var tracker = PaceTracker(start: start)
        tracker.record(totalMeters: mile * 0.5, at: start + 300)
        tracker.record(totalMeters: mile * 2.5, at: start + 1_500)       // 2 miles over 1,200 s
        // Linear between the readings: mile 2 is 1.5 miles past the first reading, at 600 s/mile.
        XCTAssertEqual(tracker.currentMileStartedAt.timeIntervalSince(start), 300 + 900, accuracy: 0.01)
        XCTAssertEqual(tracker.completedMiles, 2)
    }

    /// Cumulative distance never truly goes backwards. A reading that does is a bad sample: ignored
    /// and counted, never allowed to shrink the total or pull a mile back.
    func testABackwardReadingIsIgnoredAndCounted() {
        var tracker = PaceTracker(start: start)
        tracker.record(totalMeters: 800, at: start + 200)
        tracker.record(totalMeters: 700, at: start + 210)
        XCTAssertEqual(tracker.totalMeters, 800, accuracy: 0.001)
        XCTAssertEqual(tracker.rejectedReadings, 1)
    }

    /// Distance arrives in batches. Pace is measured to the latest reading, so it does not drift
    /// slower in the seconds between batches.
    func testPaceIsMeasuredToTheLatestReadingNotToNow() throws {
        var tracker = PaceTracker(start: start)
        tracker.beginLeg(at: start)
        tracker.record(totalMeters: mile / 4, at: start + 120)
        // No `now` goes in, so waiting cannot change the answer.
        XCTAssertEqual(try XCTUnwrap(tracker.legPaceSecondsPerMile), 480, accuracy: 0.01)
    }
}
