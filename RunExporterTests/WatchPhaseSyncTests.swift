import XCTest
@testable import RunExporter

/// Watch plan step 2: the phone decides the phases, the watch displays and records them.
///
/// Timing rule (docs/WATCHOS_RECORDER_PLAN.md): the phone never sends a clock time for the watch to
/// act on. It sends **durations** — how far into the phase it is, how long remains — and the watch
/// anchors them to its own clock when the message arrives. The two devices' clocks are never
/// compared, so their offset cannot matter; the only error is the one-way message delay, measured at
/// a 0.13 s median round trip on 2026-09-29.
final class WatchPhaseSyncTests: XCTestCase {

    private let arrival = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func anchor(phase: WatchPhase = .run,
                        elapsed: TimeInterval = 12,
                        remaining: TimeInterval? = 168,
                        paused: Bool = false,
                        latency: TimeInterval = 0) -> PhaseAnchor {
        PhaseAnchor(phase: phase, legNumber: 3, legCount: 5,
                    elapsedAtSend: elapsed, remainingAtSend: remaining,
                    isPaused: paused, oneWayLatency: latency,
                    sentAt: Date(timeIntervalSinceReferenceDate: 1))
    }

    // MARK: - Messages

    func testPhaseMessagesSurviveARoundTrip() throws {
        let messages: [WatchLinkMessage] = [
            .phaseBegan(anchor()),
            .phaseBegan(anchor(phase: .walk, remaining: nil)),            // open-ended
            .phaseBegan(anchor(phase: .cooldown, paused: true, latency: 0.065)),
            .finishWorkout(executionID: UUID()),
        ]
        for message in messages {
            XCTAssertEqual(try WatchLinkCodec.decode(WatchLinkCodec.encode(message)), message)
        }
    }

    func testAnUnknownPhaseThrows() {
        let body = #"{"phase":"sprint","elapsedAtSend":1,"isPaused":false,"oneWayLatency":0,"sentAt":0}"#
        XCTAssertThrowsError(try WatchLinkCodec.decode(envelope(kind: "phaseBegan", body: body)))
    }

    /// A negative duration is a corrupt anchor. Displaying it as a countdown would be the silent kind
    /// of wrong; refusing it is the loud kind.
    func testNegativeDurationsAreRejected() {
        for (field, body) in [
            ("elapsed", #"{"phase":"run","elapsedAtSend":-1,"isPaused":false,"oneWayLatency":0,"sentAt":0}"#),
            ("remaining", #"{"phase":"run","elapsedAtSend":1,"remainingAtSend":-5,"isPaused":false,"oneWayLatency":0,"sentAt":0}"#),
            ("latency", #"{"phase":"run","elapsedAtSend":1,"isPaused":false,"oneWayLatency":-0.1,"sentAt":0}"#),
        ] {
            XCTAssertThrowsError(try WatchLinkCodec.decode(envelope(kind: "phaseBegan", body: body)),
                                 "negative \(field) must not decode")
        }
    }

    /// The watch app installs minutes after the phone's, so an older sender is normal.
    func testAVersionOneMessageStillDecodes() throws {
        let data = envelope(version: 1, kind: "endWorkout", body: "{}")
        XCTAssertEqual(try WatchLinkCodec.decode(data), .endWorkout)
    }

    // MARK: - The watch's clock for a phase

    func testTheCountdownFollowsTheWatchClock() {
        let clock = PhaseClock(anchor: anchor(elapsed: 12, remaining: 168), receivedAt: arrival)
        XCTAssertEqual(clock.remaining(at: arrival)!, 168, accuracy: 0.001)
        XCTAssertEqual(clock.remaining(at: arrival + 60)!, 108, accuracy: 0.001)
        XCTAssertEqual(clock.elapsed(at: arrival + 60), 72, accuracy: 0.001)
    }

    func testTheLatencyEstimateIsSubtracted() {
        let clock = PhaseClock(anchor: anchor(elapsed: 12, remaining: 168, latency: 0.5), receivedAt: arrival)
        XCTAssertEqual(clock.remaining(at: arrival)!, 167.5, accuracy: 0.001)
        XCTAssertEqual(clock.elapsed(at: arrival), 12.5, accuracy: 0.001)
    }

    func testAnOpenEndedPhaseHasNoCountdown() {
        let clock = PhaseClock(anchor: anchor(elapsed: 30, remaining: nil), receivedAt: arrival)
        XCTAssertNil(clock.remaining(at: arrival + 10))
        XCTAssertEqual(clock.elapsed(at: arrival + 10), 40, accuracy: 0.001)
        XCTAssertFalse(clock.isOverdue(at: arrival + 10_000))
    }

    func testPausedFreezesBothValues() {
        let clock = PhaseClock(anchor: anchor(elapsed: 12, remaining: 168, paused: true), receivedAt: arrival)
        XCTAssertEqual(clock.remaining(at: arrival + 300)!, 168, accuracy: 0.001)
        XCTAssertEqual(clock.elapsed(at: arrival + 300), 12, accuracy: 0.001)
        XCTAssertFalse(clock.isOverdue(at: arrival + 300))
    }

    /// Past the deadline the phone's next phase is late. Show 0 — and say it is late, rather than
    /// letting a clamped 0 pass for "on time".
    func testPastTheDeadlineShowsZeroAndIsOverdue() {
        let clock = PhaseClock(anchor: anchor(elapsed: 0, remaining: 10), receivedAt: arrival)
        XCTAssertFalse(clock.isOverdue(at: arrival + 9))
        XCTAssertEqual(clock.remaining(at: arrival + 15)!, 0, accuracy: 0.001)
        XCTAssertTrue(clock.isOverdue(at: arrival + 15))
    }

    /// The date the workout event is written with, on the watch's clock.
    func testThePhaseStartIsDatedOnTheWatchClock() {
        let clock = PhaseClock(anchor: anchor(elapsed: 2, remaining: 100, latency: 0.25), receivedAt: arrival)
        XCTAssertEqual(clock.phaseStartedAt.timeIntervalSince(arrival), -2.25, accuracy: 0.001)
    }

    // MARK: - Helpers

    private func envelope(version: Int = WatchLinkCodec.protocolVersion, kind: String, body: String) -> Data {
        Data(#"{"version":\#(version),"kind":"\#(kind)","body":\#(body)}"#.utf8)
    }
}
