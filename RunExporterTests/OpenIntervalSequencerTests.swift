import XCTest
@testable import RunExporter

/// The sequencing rules of an open-interval run, with no clock and no store.
///
/// A open-interval plan has no fixed phase list: the number of legs is the measurement, so it
/// cannot be built up front the way `WorkoutPhaseSchedule` builds an interval plan. This type
/// answers what comes next from the running time accumulated so far, which is the only thing that
/// decides it.
final class OpenIntervalSequencerTests: XCTestCase {

    private func sequencer(target: Int = 1800, walkFloor: Int = 180) -> OpenIntervalSequencer {
        OpenIntervalSequencer(targetRunSeconds: target, walkFloorSeconds: walkFloor)
    }

    /// A leg ends when the runner ends it or at the target, whichever comes first — so a leg started
    /// with 2:40 of running left to the target may last 2:40 and no longer.
    ///
    /// Without the cap the workout runs past the number the whole plan is defined by, and the last
    /// row of the dataset records a leg length that was never a threshold measurement.
    func testALegIsCappedByTheRunningLeftToTheTarget() {
        XCTAssertEqual(sequencer().legCapSeconds(accumulatedRunSeconds: 1640), 160)
    }

    /// Reaching the target ends the workout rather than starting another recovery walk.
    ///
    /// The interval plans have the same rule in a different dress — spec §11.1's "no walk after the
    /// final run". A recovery walk exists to prepare the next leg, so once there is no next leg
    /// it is three minutes of walking the owner did not ask for, recorded as though it were part of
    /// the protocol.
    func testReachingTheTargetEndsTheWorkoutRatherThanStartingAnotherWalk() {
        XCTAssertEqual(sequencer().next(afterLegEndingAt: 1800), .finished)
    }

    /// Short of the target, the leg is followed by a recovery walk carrying the plan's floor.
    func testShortOfTheTargetALegIsFollowedByARecoveryWalk() {
        XCTAssertEqual(sequencer().next(afterLegEndingAt: 1640),
                       .recoveryWalk(floorSeconds: 180))
    }
}
