import XCTest
@testable import RunExporter

/// The whole-workout timeline carried in the Live Activity's `ContentState`.
///
/// ## Why the card carries a timeline at all
///
/// iOS applies `Activity.update` only while the app is in the foreground; from the background the
/// call returns cleanly and the content is discarded (confirmed on device — see
/// `docs/CUE_FEASIBILITY_TEST.md`, Test 3). A Live Activity view is also never re-rendered as time
/// passes, so the widget cannot work out the current phase in its `body` either.
///
/// The way out is to send every phase's bounds in the one push that is guaranteed to be applied,
/// and draw each with `ProgressView(timerInterval:)`, which the system animates on its own. These
/// tests pin the arithmetic that makes that card truthful — if the bounds are wrong, the card is
/// confidently wrong for a whole workout with nothing to correct it.
@MainActor
final class LiveActivityTimelineTests: XCTestCase {

    private var suiteName = ""
    private var settings: LoggerDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "LiveActivityTimelineTests.\(UUID().uuidString)"
        settings = LoggerDefaults(defaults: UserDefaults(suiteName: suiteName)!)
        settings.cueSource = .iphoneAudioEngine
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        settings = nil
        super.tearDown()
    }

    private func plan(run: Int = 60, walk: Int = 30, reps: Int = 3,
                      countdown: Int = 3,
                      cooldown: CooldownMode = .open) -> PlannedWorkout {
        PlannedWorkout(name: "test",
                       runIntervalSeconds: run,
                       walkIntervalSeconds: walk,
                       plannedRepetitions: reps,
                       cooldownMode: cooldown,
                       countdownSeconds: countdown)
    }

    private func state(start: Date?, kinds: String,
                       durations: [Int]) -> RunWorkoutAttributes.ContentState {
        RunWorkoutAttributes.ContentState(
            phaseName: "Run", phaseRawValue: "run",
            repetition: 1, totalRepetitions: 3,
            phaseStart: start ?? Date(), phaseEnd: nil,
            nextPhaseName: nil, isPaused: false, pausedAt: nil,
            timelineStart: start, phaseKinds: kinds, phaseDurations: durations)
    }

    // MARK: - Rebuilding absolute bounds

    /// Each segment must begin exactly where the previous one ended — the property the whole
    /// design rests on, since nothing corrects it later.
    func testSegmentsAccumulateFromTheAnchor() {
        let anchor = Date(timeIntervalSinceReferenceDate: 0)
        let segments = state(start: anchor, kinds: "drwr", durations: [3, 60, 30, 60])
            .timelineSegments

        XCTAssertEqual(segments.count, 4)
        XCTAssertEqual(segments[0].start, anchor)
        XCTAssertEqual(segments[0].end, anchor.addingTimeInterval(3))
        XCTAssertEqual(segments[1].start, anchor.addingTimeInterval(3))
        XCTAssertEqual(segments[1].end, anchor.addingTimeInterval(63))
        XCTAssertEqual(segments[2].start, anchor.addingTimeInterval(63))
        XCTAssertEqual(segments[3].end, anchor.addingTimeInterval(153))
        XCTAssertEqual(segments.map(\.kind), ["d", "r", "w", "r"])
    }

    /// An open-ended phase (`0` seconds) has no end and terminates the timeline.
    func testOpenEndedPhaseHasNoEndAndEndsTheTimeline() {
        let anchor = Date(timeIntervalSinceReferenceDate: 0)
        let segments = state(start: anchor, kinds: "rc", durations: [60, 0]).timelineSegments

        XCTAssertEqual(segments.count, 2)
        XCTAssertNotNil(segments[0].end)
        XCTAssertNil(segments[1].end, "An open cooldown has no boundary to fill towards")
    }

    /// A malformed timeline must draw nothing rather than a partial one that looks complete.
    func testMismatchedArraysProduceNoTimeline() {
        let anchor = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertTrue(state(start: anchor, kinds: "rw", durations: [60]).timelineSegments.isEmpty)
        XCTAssertTrue(state(start: nil, kinds: "rw", durations: [60, 30]).timelineSegments.isEmpty)
        XCTAssertTrue(state(start: anchor, kinds: "", durations: []).timelineSegments.isEmpty)
    }

    // MARK: - What the engine hands over

    /// At the very first phase the anchor is simply that phase's start.
    func testTimelineAnchorAtWorkoutStart() throws {
        let engine = IntervalTimerEngine()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        try engine.start(plan: plan(), settings: settings, now: start)

        let timeline = try XCTUnwrap(engine.liveActivityTimeline)

        XCTAssertEqual(timeline.start, start)
        XCTAssertEqual(timeline.kinds, "drwrwrc",
                       "3 runs, 2 walks (no walk after the final run), countdown and cooldown")
        XCTAssertEqual(timeline.durations, [3, 60, 30, 60, 30, 60, 0])
    }

    /// Mid-workout the anchor is walked back from the current phase, so the timeline still places
    /// the phase the runner is actually in exactly where it belongs.
    func testTimelineAnchorIsDerivedFromTheCurrentPhase() throws {
        let engine = IntervalTimerEngine()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        try engine.start(plan: plan(), settings: settings, now: start)

        // Into run 2: countdown 3 + run 60 + walk 30 = 93 seconds in.
        engine.tick(now: start.addingTimeInterval(95))
        XCTAssertEqual(engine.phase, .run)
        XCTAssertEqual(engine.currentRepetition, 2)

        let timeline = try XCTUnwrap(engine.liveActivityTimeline)

        XCTAssertEqual(timeline.start, start,
                       "With no pauses the derived anchor must equal the real workout start")
    }

    /// A pause shifts the wall clock, and the anchor has to move with it — otherwise every segment
    /// on the card drifts by the length of the pause for the rest of the workout.
    func testPauseShiftsTheAnchor() throws {
        let engine = IntervalTimerEngine()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        try engine.start(plan: plan(), settings: settings, now: start)

        engine.tick(now: start.addingTimeInterval(10))
        engine.pause(now: start.addingTimeInterval(10))
        engine.resume(now: start.addingTimeInterval(70))   // a 60-second pause
        engine.tick(now: start.addingTimeInterval(71))

        let timeline = try XCTUnwrap(engine.liveActivityTimeline)
        let segments = state(start: timeline.start,
                             kinds: timeline.kinds,
                             durations: timeline.durations).timelineSegments
        let currentIndex = try XCTUnwrap(segments.firstIndex { segment in
            guard let end = segment.end else { return false }
            return segment.start <= engine.phaseStartDate && engine.phaseStartDate < end
                || segment.start == engine.phaseStartDate
        })

        XCTAssertEqual(segments[currentIndex].start, engine.phaseStartDate,
                       "The segment for the live phase must start where the engine says it did")
    }
}
