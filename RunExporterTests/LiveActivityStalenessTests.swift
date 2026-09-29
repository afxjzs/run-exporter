import XCTest
@testable import RunExporter

/// Regression tests for the Live Activity going silently stale (spec §12.1).
///
/// ## The bug these lock down
///
/// `Activity.update(_:)` applies its content **only while the app is in the foreground**. Called
/// from a backgrounded app it returns normally, throws nothing, reports nothing — and discards the
/// update. Confirmed on device across three instrumented runs on 2026-08-07: during a locked
/// workout the Lock Screen card kept reading "RUN · Round 1 of 3 · 0:00" while the app itself was
/// correctly in cooldown at round 3. Full evidence in `docs/CUE_FEASIBILITY_TEST.md`, Test 3.
///
/// That is the worst failure shape available: no crash, no error, and a confident wrong answer on
/// the Lock Screen — the one surface the user looks at while running.
///
/// ## What can and cannot be tested here
///
/// The OS behaviour itself **cannot** be reproduced off-device; nothing in the simulator declines
/// an update. What is testable is the app's response to it, which is where the defect actually lay:
/// the outcome was never inspected. These tests pin that the app notices a discarded update and
/// says so, and that the stale date expires at the phase boundary so the system dims a card that
/// has stopped being true.
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

    // MARK: - Detecting a discarded update

    /// The core regression: content the system did not apply must be reported, not shrugged off.
    func testDiscardedUpdateIsRecorded() {
        let controller = LiveActivityController()

        controller.recordOutcome(pushed: state(phase: "walk", name: "Walk", repetition: 2),
                                 applied: state())

        XCTAssertTrue(controller.isCardStale,
                      "A dropped update must mark the card stale — this is exactly the silent "
                      + "failure the whole bug consisted of")
        XCTAssertEqual(controller.droppedUpdates, 1)
    }

    /// A discarded update must not raise a user-facing error any more.
    ///
    /// It did while the card displayed a phase name that could contradict the workout. The card now
    /// shows only values derived from fixed bounds, so a dropped update changes nothing visible —
    /// and a warning on every locked workout would be a banner reporting a non-problem.
    func testDiscardedUpdateNoLongerRaisesAUserFacingError() {
        let controller = LiveActivityController()

        controller.recordOutcome(pushed: state(phase: "cooldown", name: "Cooldown", repetition: 3),
                                 applied: state(name: "Run", repetition: 1))

        XCTAssertNil(controller.lastError)
        XCTAssertEqual(controller.droppedUpdates, 1, "Still counted, for the diagnostics screen")
    }

    /// An update that *was* applied must not raise a warning.
    func testAppliedUpdateIsNotFlagged() {
        let controller = LiveActivityController()
        let pushed = state(phase: "walk", name: "Walk", repetition: 2)

        controller.recordOutcome(pushed: pushed, applied: pushed)

        XCTAssertFalse(controller.isCardStale)
        XCTAssertEqual(controller.droppedUpdates, 0)
    }

    /// Staleness must clear when the card catches up, not latch for the rest of the workout.
    ///
    /// Recovery is the normal case: returning to the foreground gets an update applied, which is
    /// precisely why `refreshFromClock` now pushes one unconditionally.
    func testStalenessClearsOnceAnUpdateLands() {
        let controller = LiveActivityController()
        let current = state(phase: "cooldown", name: "Cooldown", repetition: 3)

        controller.recordOutcome(pushed: current, applied: state())
        XCTAssertTrue(controller.isCardStale)

        controller.recordOutcome(pushed: current, applied: current)

        XCTAssertFalse(controller.isCardStale, "The card caught up; the warning must clear")
        XCTAssertEqual(controller.droppedUpdates, 1, "The count is cumulative for diagnostics")
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
