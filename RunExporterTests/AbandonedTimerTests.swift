import XCTest
import SwiftData
@testable import RunExporter

/// Retiring abandoned timers, and the two rules that keep the retirement narrow.
///
/// The state these cover was unreachable before: `ExecutionStatus.expired` existed and `matchable`
/// excluded it, but nothing ever assigned it — a designed retirement path no code could reach. These
/// assert both that it now happens and, more importantly, that it does not happen to anything else.
final class AbandonedTimerTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_775_000_000)
    private let threshold = RunLoggerModel.abandonedTimerThreshold

    private func execution(status: ExecutionStatus,
                           createdMinutesAgo: Double,
                           timerEnded: Bool) -> PendingWorkoutExecution {
        let createdAt = base.addingTimeInterval(-createdMinutesAgo * 60)
        let execution = PendingWorkoutExecution(
            plannedWorkoutID: UUID(),
            plannedWorkoutName: "4/1 × 5",
            expectedActivityType: .running,
            expectedDurationSeconds: 1_500,
            runIntervalSeconds: 240,
            walkIntervalSeconds: 60,
            plannedRepetitions: 5,
            status: status,
            createdAt: createdAt)
        execution.timerStartedAt = createdAt
        if timerEnded {
            execution.timerEndedAt = createdAt.addingTimeInterval(1_500)
        }
        return execution
    }

    // MARK: - What counts as abandoned

    func testStartedTimerWithNoEndIsAbandonedOnceThresholdPasses() {
        let stale = execution(status: .started, createdMinutesAgo: 13 * 60, timerEnded: false)
        XCTAssertTrue(stale.isAbandoned(now: base, after: threshold))
    }

    func testStartedTimerWithNoEndIsNotAbandonedWithinTheThreshold() {
        // A timer that is still running looks exactly like one that was abandoned, so the only
        // honest discriminator is age. Twenty minutes in, the run may genuinely be in progress.
        let running = execution(status: .started, createdMinutesAgo: 20, timerEnded: false)
        XCTAssertFalse(running.isAbandoned(now: base, after: threshold))
    }

    func testStartedTimerThatWasStoppedIsNotAbandoned() {
        let finished = execution(status: .started, createdMinutesAgo: 13 * 60, timerEnded: true)
        XCTAssertFalse(finished.isAbandoned(now: base, after: threshold))
    }

    /// The rule that protects the feature this whole area exists for.
    ///
    /// A completed execution must stay matchable however old it is: the reverse matcher anchors on
    /// the workout's own start date precisely so a run logged days later still resolves. One of the
    /// owner's runs was logged three days after the fact, and expiring completed executions on age
    /// would have silently broken exactly that.
    func testCompletedExecutionIsNeverAbandonedHoweverOld() {
        let ancient = execution(status: .completed, createdMinutesAgo: 60 * 24 * 90, timerEnded: true)
        XCTAssertFalse(ancient.isAbandoned(now: base, after: threshold))
    }

    func testPreparedExecutionIsLeftAloneDeliberately() {
        // Not an oversight: harmless under a two-minute match window, and no real data has ever
        // contained one. Pinned so that widening the rule is a decision rather than a drift.
        let prepared = execution(status: .prepared, createdMinutesAgo: 60 * 24, timerEnded: false)
        XCTAssertFalse(prepared.isAbandoned(now: base, after: threshold))
    }

    // MARK: - The retired state the matcher already honoured

    func testExpiredIsNotMatchable() {
        XCTAssertFalse(ExecutionStatus.matchable.contains(.expired))
    }

    func testStartedIsStillMatchableSoRetirementIsWhatRemovesIt() {
        // If `.started` were simply excluded from `matchable`, a genuinely running timer could never
        // match. Retirement, not status, is what takes an abandoned timer out of contention.
        XCTAssertTrue(ExecutionStatus.matchable.contains(.started))
    }

    func testAnExpiredExecutionIsNoLongerAMatchCandidate() {
        let retired = execution(status: .expired, createdMinutesAgo: 0, timerEnded: false)
        XCTAssertFalse(retired.isMatchCandidate(
            now: base, window: RecentWorkoutMatcher.startToleranceSeconds))
    }

    // MARK: - The guard that used to guard nothing

    /// `isMatchCandidate` compared a *signed* interval, so every execution created after `now`
    /// passed however far after — only the caller's own `abs()` bounded it.
    func testMatchCandidateWindowIsBoundedInBothDirections() {
        let future = execution(status: .started, createdMinutesAgo: -30, timerEnded: false)
        XCTAssertFalse(future.isMatchCandidate(
            now: base, window: RecentWorkoutMatcher.startToleranceSeconds))

        let near = execution(status: .started, createdMinutesAgo: -1, timerEnded: false)
        XCTAssertTrue(near.isMatchCandidate(
            now: base, window: RecentWorkoutMatcher.startToleranceSeconds))
    }

    // MARK: - The single candidate factory

    /// Two hand-written copies of this mapping disagreed about which timestamp to pass as
    /// `createdAt`, which is the field `score()` keys on.
    func testMatchCandidateAnchorsOnTheTimerStart() {
        let stale = execution(status: .started, createdMinutesAgo: 30, timerEnded: false)
        let timerStart = base.addingTimeInterval(-5 * 60)
        stale.timerStartedAt = timerStart

        XCTAssertEqual(stale.matchCandidate?.createdAt, timerStart)
    }

    func testMatchCandidateFallsBackToCreatedAtWhenNoTimerRan() {
        let sentOnly = execution(status: .sentToWatch, createdMinutesAgo: 10, timerEnded: false)
        sentOnly.timerStartedAt = nil

        XCTAssertEqual(sentOnly.matchCandidate?.createdAt, sentOnly.createdAt)
    }

    // MARK: - Saying so rather than doing it quietly

    func testNoticeNamesTheCountAndSaysNothingWasDeleted() {
        let notice = RunLoggerModel.abandonedTimerNotice(count: 6)
        XCTAssertTrue(notice.contains("6 timers"), notice)
        XCTAssertTrue(notice.contains("Nothing was deleted"), notice)
    }

    func testNoticeIsSingularForOne() {
        let notice = RunLoggerModel.abandonedTimerNotice(count: 1)
        XCTAssertTrue(notice.contains("1 timer that"), notice)
        XCTAssertFalse(notice.contains("1 timers"), notice)
    }
}
