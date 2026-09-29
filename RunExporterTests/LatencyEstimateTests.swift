import XCTest
@testable import RunExporter

/// The one-way message delay the watch's `PhaseClock` subtracts, estimated from ping round trips.
///
/// Measured 2026-09-29: the ping sent the instant the link connected took 1.71 s, against a 0.13 s
/// median once warm — the first message on a fresh link waits for the channel. A median over that
/// one sample made the watch subtract 0.86 s it should not have, and its countdown read low.
final class LatencyEstimateTests: XCTestCase {

    func testNoRoundTripsMeansNoCorrection() {
        XCTAssertEqual(LatencyEstimate.oneWay(fromRoundTrips: []), 0)
    }

    /// Warm-up and scheduling only ever add delay, so the smallest round trip is the truest one.
    func testTheWarmUpOutlierIsIgnored() {
        XCTAssertEqual(LatencyEstimate.oneWay(fromRoundTrips: [1.71, 0.14, 0.12]), 0.06, accuracy: 0.0001)
    }

    func testOneWayIsHalfTheRoundTrip() {
        XCTAssertEqual(LatencyEstimate.oneWay(fromRoundTrips: [0.2]), 0.1, accuracy: 0.0001)
    }

    /// A negative round trip cannot happen on one clock; if one appears it is a bug, not a speedup.
    func testNegativeRoundTripsAreIgnored() {
        XCTAssertEqual(LatencyEstimate.oneWay(fromRoundTrips: [-0.5, 0.3]), 0.15, accuracy: 0.0001)
    }
}
