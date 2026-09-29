import XCTest
@testable import RunExporter

/// The phone's interval engine state, turned into the anchor the watch is sent.
///
/// The engine keeps absolute dates on the phone's clock; the anchor carries only durations. This is
/// the one place that conversion happens, so it is tested for every shape a phase can take —
/// including the ones the watch must never be sent.
final class WatchPhaseMappingTests: XCTestCase {

    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func snapshot(phase: WorkoutPhase = .run,
                          underlying: WorkoutPhase? = .run,
                          paused: Bool = false,
                          repetition: Int = 3,
                          total: Int = 5,
                          length: TimeInterval? = 180,
                          frozenElapsed: TimeInterval = 0,
                          frozenRemaining: TimeInterval? = nil) -> WatchPhaseMapping.EngineSnapshot {
        WatchPhaseMapping.EngineSnapshot(
            phase: phase,
            plannedPhase: underlying,
            isPaused: paused,
            repetition: repetition,
            totalRepetitions: total,
            phaseStart: start,
            phaseEnd: length.map { start.addingTimeInterval($0) },
            frozenElapsed: frozenElapsed,
            frozenRemaining: frozenRemaining)
    }

    func testATimedPhaseSendsElapsedAndRemaining() throws {
        let anchor = try XCTUnwrap(WatchPhaseMapping.anchor(from: snapshot(),
                                                            now: start + 30, oneWayLatency: 0.05))
        XCTAssertEqual(anchor.phase, .run)
        XCTAssertEqual(anchor.elapsedAtSend, 30, accuracy: 0.001)
        XCTAssertEqual(anchor.remainingAtSend!, 150, accuracy: 0.001)
        XCTAssertEqual(anchor.legNumber, 3)
        XCTAssertEqual(anchor.legCount, 5)
        XCTAssertFalse(anchor.isPaused)
        XCTAssertEqual(anchor.oneWayLatency, 0.05, accuracy: 0.0001)
    }

    func testAnOpenPhaseSendsNoRemaining() throws {
        let anchor = try XCTUnwrap(WatchPhaseMapping.anchor(from: snapshot(length: nil),
                                                            now: start + 42, oneWayLatency: 0))
        XCTAssertNil(anchor.remainingAtSend)
        XCTAssertEqual(anchor.elapsedAtSend, 42, accuracy: 0.001)
    }

    /// While paused the engine reports `.paused` and its clock is stopped. The watch is told which
    /// phase is paused, and the frozen values — not ones recomputed from `now`, which keep moving.
    func testAPausedPhaseSendsTheUnderlyingPhaseFrozen() throws {
        let paused = snapshot(phase: .paused, underlying: .walk, paused: true,
                              frozenElapsed: 20, frozenRemaining: 40)
        let anchor = try XCTUnwrap(WatchPhaseMapping.anchor(from: paused, now: start + 500, oneWayLatency: 0))
        XCTAssertEqual(anchor.phase, .walk)
        XCTAssertTrue(anchor.isPaused)
        XCTAssertEqual(anchor.elapsedAtSend, 20, accuracy: 0.001)
        XCTAssertEqual(anchor.remainingAtSend!, 40, accuracy: 0.001)
    }

    /// `idle` and `completed` are the phone's UI states, not phases the watch shows.
    func testIdleAndCompletedAreNeverSent() {
        XCTAssertNil(WatchPhaseMapping.anchor(from: snapshot(phase: .idle, underlying: nil),
                                              now: start, oneWayLatency: 0))
        XCTAssertNil(WatchPhaseMapping.anchor(from: snapshot(phase: .completed, underlying: nil),
                                              now: start, oneWayLatency: 0))
    }

    /// The countdown before the first leg has no leg, and an open-interval plan has no total.
    func testNoLegOrTotalIsSentAsAbsentNotZero() throws {
        let anchor = try XCTUnwrap(WatchPhaseMapping.anchor(
            from: snapshot(phase: .countdown, underlying: .countdown, repetition: 0, total: 0, length: 3),
            now: start + 1, oneWayLatency: 0))
        XCTAssertEqual(anchor.phase, .countdown)
        XCTAssertNil(anchor.legNumber)
        XCTAssertNil(anchor.legCount)
    }

    /// A snapshot taken a hair before the phase's recorded start must not produce a negative elapsed,
    /// which the watch would rightly refuse as a corrupt anchor.
    func testElapsedIsNeverNegative() throws {
        let anchor = try XCTUnwrap(WatchPhaseMapping.anchor(from: snapshot(),
                                                            now: start - 0.01, oneWayLatency: 0))
        XCTAssertEqual(anchor.elapsedAtSend, 0, accuracy: 0.0001)
        XCTAssertNotNil(anchor.remainingAtSend)
        XCTAssertNil(anchor.validationError)
    }

    /// Paused with no known phase underneath is not a state the engine should reach. Sending nothing
    /// beats sending a guess; the caller reports it.
    func testPausedWithNoUnderlyingPhaseSendsNothing() {
        XCTAssertNil(WatchPhaseMapping.anchor(from: snapshot(phase: .paused, underlying: nil, paused: true),
                                              now: start, oneWayLatency: 0))
    }
}
