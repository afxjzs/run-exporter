import XCTest
@testable import RunExporter

/// How long a Live Activity's content stays valid (spec §12.1).
///
/// ## Why this matters
///
/// `Activity.update(_:)` applies its content **only while the app is in the foreground**. Called
/// from a backgrounded app it returns normally, throws nothing, reports nothing — and discards the
/// update. Confirmed on device across three instrumented runs on 2026-08-07: during a locked
/// workout the Lock Screen card kept reading "RUN · Round 1 of 3 · 0:00" while the app itself was
/// correctly in cooldown at round 3. Full evidence in `docs/CUE_FEASIBILITY_TEST.md`, Test 3.
///
/// The card was redesigned so it needs no updates. What remains testable, and pinned here, is the
/// stale date: the system dims a card that has stopped being true, and must not dim one that is
/// still true. (Tests that a discarded update was *detected* and counted were removed in the
/// 2026-09-29 clean-out, with the count they pinned; it was shown only on the cue test screen.)
@MainActor
final class LiveActivityStalenessTests: XCTestCase {

    private func state(phase: String = "run",
                       name: String = "Run",
                       repetition: Int = 1,
                       end: Date? = Date(timeIntervalSince1970: 1_000_060),
                       paused: Bool = false) -> RunWorkoutAttributes.ContentState {
        RunWorkoutAttributes.ContentState(
            phaseName: name,
            phaseRawValue: phase,
            repetition: repetition,
            totalRepetitions: 3,
            phaseStart: Date(timeIntervalSince1970: 1_000_000),
            phaseEnd: end,
            nextPhaseName: "Walk 0:30",
            isPaused: paused,
            pausedAt: nil)
    }

    // MARK: - Stale date

    /// Without a timeline the content is a snapshot of one phase, so it expires when that phase
    /// ends. It used to be `phaseEnd + 30`, which assumed the only way to be wrong was the app
    /// dying — those 30 seconds were 30 seconds of a bright, confident, incorrect card.
    func testStaleDateIsThePhaseBoundaryWhenThereIsNoTimeline() throws {
        let controller = LiveActivityController()
        let end = Date(timeIntervalSince1970: 1_000_060)

        let stale = try XCTUnwrap(controller.staleDate(for: state(end: end)))

        XCTAssertEqual(stale, end,
                       "Stale date must not extend past the boundary: after it, the card is wrong")
    }

    /// With a timeline the card never goes stale — every value on it is derived from bounds that
    /// do not move, and it shows no phase name to be wrong about. Expiring at the phase boundary
    /// here would dim a *correct* card one minute into every workout.
    func testTimelineCardNeverGoesStale() {
        let controller = LiveActivityController()
        var withTimeline = state(end: Date(timeIntervalSince1970: 1_000_060))
        withTimeline.timelineStart = Date(timeIntervalSince1970: 1_000_000)
        withTimeline.phaseKinds = "rw"
        withTimeline.phaseDurations = [60, 30]

        XCTAssertNil(controller.staleDate(for: withTimeline))
    }

    /// A paused workout is not going stale — its clock is legitimately frozen.
    func testPausedStateNeverGoesStale() {
        let controller = LiveActivityController()
        XCTAssertNil(controller.staleDate(for: state(paused: true)))
    }

    /// An open-ended phase (open cooldown) has no boundary to expire at.
    func testOpenEndedPhaseHasNoStaleDate() {
        let controller = LiveActivityController()
        XCTAssertNil(controller.staleDate(for: state(end: nil)))
    }
}
