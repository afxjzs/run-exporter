import ActivityKit
import Foundation

/// State shared between the app and its Live Activity widget (spec §12.1).
///
/// Compiled into **both** targets, which is why it lives outside the app's source folder and
/// depends on nothing but ActivityKit and Foundation.
///
/// ## Why the countdown is dates rather than a number
///
/// ActivityKit rate-limits updates, so an activity cannot be pushed a new "seconds remaining"
/// every second. Instead the phase's absolute start and end travel in the state and the widget
/// renders them with `Text(timerInterval:)`, which the system ticks on its own. The app then only
/// has to update at phase transitions — a handful of times per workout instead of hundreds.
struct RunWorkoutAttributes: ActivityAttributes {

    /// Everything that changes as the workout progresses.
    struct ContentState: Codable, Hashable {
        /// Display name of the current phase, e.g. "Run".
        var phaseName: String
        /// Raw `WorkoutPhase` value, so the widget can style without importing the app's enum.
        var phaseRawValue: String
        var repetition: Int
        var totalRepetitions: Int

        /// Absolute bounds of the current phase. `phaseEnd` is nil for an open-ended phase
        /// (open cooldown or warmup), where elapsed time is shown counting up instead.
        var phaseStart: Date
        var phaseEnd: Date?

        /// What follows this phase, if anything.
        var nextPhaseName: String?
        var isPaused: Bool

        /// When paused, the instant the pause began — the widget freezes the clock there rather
        /// than letting it keep running down.
        var pausedAt: Date?

        // MARK: - Whole-workout timeline

        /// The instant the first phase began, from which every phase's bounds are derived.
        ///
        /// ## Why the entire schedule travels in the state
        ///
        /// iOS applies `Activity.update` only while the app is in the foreground; from the
        /// background the call returns normally and silently discards the content (confirmed on
        /// device — see `docs/CUE_FEASIBILITY_TEST.md`, Test 3). A card that depends on per-phase
        /// updates is therefore wrong for most of a locked workout.
        ///
        /// Live Activity views are not re-rendered as time passes either, so the widget cannot
        /// simply work out the current phase in its `body`. What it *can* do is use the handful of
        /// views the system ticks on its own — `Text(timerInterval:)`, `Text(_:style:)` and
        /// `ProgressView(timerInterval:)`. Carrying every phase's bounds and drawing one
        /// self-filling progress view per phase gives a card that stays correct for the whole
        /// workout from the single push that `Activity.request` is guaranteed to apply.
        ///
        /// Stored as an anchor plus durations rather than a date per phase because a
        /// 20-repetition plan is 41 phases and `ContentState` has a 4 KB budget.
        var timelineStart: Date?

        /// One character per phase, in order: `r` run, `w` walk, `c` cooldown, `u` warmup,
        /// `d` countdown, `?` anything this version does not recognise.
        var phaseKinds: String = ""

        /// Planned seconds per phase — same order and count as `phaseKinds`. `0` marks an
        /// open-ended phase, which can only ever be the last one.
        var phaseDurations: [Int] = []
    }

    /// Fixed for the life of the activity.
    var workoutName: String

    /// "Running" or "Walking" — the headline, and safe to put there precisely because an
    /// `ActivityAttributes` value never changes, so it cannot go stale the way `ContentState` does.
    var activityName: String = "Running"
}

extension RunWorkoutAttributes.ContentState {

    /// One phase with absolute bounds, ready to hand to `ProgressView(timerInterval:)`.
    struct TimelineSegment: Identifiable, Equatable {
        let id: Int
        /// `r`, `w`, `c`, `u`, `d`, or `?` — see `phaseKinds`.
        let kind: Character
        let start: Date
        /// `nil` for an open-ended phase, which has no boundary to fill towards.
        let end: Date?

        var seconds: Int {
            guard let end else { return 0 }
            return max(0, Int(end.timeIntervalSince(start)))
        }
    }

    /// Rebuilds absolute phase bounds by accumulating `phaseDurations` from `timelineStart`.
    ///
    /// Returns empty rather than guessing if the two arrays disagree — a partial timeline drawn as
    /// though it were whole is precisely the kind of confidently-wrong display this design exists
    /// to remove.
    var timelineSegments: [TimelineSegment] {
        guard let timelineStart,
              phaseKinds.count == phaseDurations.count,
              !phaseDurations.isEmpty else { return [] }

        var cursor = timelineStart
        var segments: [TimelineSegment] = []
        for (index, kind) in phaseKinds.enumerated() {
            let seconds = phaseDurations[index]
            let end = seconds > 0 ? cursor.addingTimeInterval(TimeInterval(seconds)) : nil
            segments.append(TimelineSegment(id: index, kind: kind, start: cursor, end: end))
            guard let end else { break }   // an open phase ends the timeline
            cursor = end
        }
        return segments
    }

    /// Total planned seconds of the timed portion — the denominator for segment widths.
    var timelineTotalSeconds: Int { phaseDurations.reduce(0, +) }
}
