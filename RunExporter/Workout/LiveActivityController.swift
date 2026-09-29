import ActivityKit
import Foundation
import Observation

/// Owns the workout's Live Activity (spec §12.1).
///
/// Deliberately best-effort: a Live Activity is a convenience, and every failure here is reported
/// but never allowed to interfere with the timer or the cues, which are the parts that matter. If
/// the user has Live Activities switched off, the workout runs exactly as before.
@MainActor
@Observable
final class LiveActivityController {

    /// Non-nil when something went wrong. Shown on the workout screen alongside audio problems.
    private(set) var lastError: String?

    /// True when the system has discarded an update, so the Lock Screen card is now showing an
    /// **older phase than the workout is actually in**.
    ///
    /// This is not a hypothetical. iOS applies `Activity.update` only while the app is in the
    /// foreground; from the background the call returns normally and silently drops the content
    /// (confirmed on device across three instrumented runs — see `docs/CUE_FEASIBILITY_TEST.md`).
    /// Without this flag the card confidently displays "Run 1 of 3" during round 3 and nothing
    /// anywhere contradicts it.
    private(set) var isCardStale = false

    /// How many updates the system has thrown away this workout. Diagnostics only.
    private(set) var droppedUpdates = 0

    /// True while an activity is on screen.
    var isActive: Bool { activity != nil }

    private var activity: Activity<RunWorkoutAttributes>?

    /// Whether the user allows Live Activities at all.
    var areActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    // MARK: - Lifecycle

    func start(workoutName: String,
               activityName: String = "Running",
               state: RunWorkoutAttributes.ContentState) {
        guard activity == nil else { return }
        droppedUpdates = 0
        isCardStale = false
        guard areActivitiesEnabled else {
            // Not an error: a deliberate setting. Reported quietly so "why is there no Lock
            // Screen card?" has an answer, without implying something broke.
            lastError = "Live Activities are turned off for this app, so the workout will not "
                + "appear on the Lock Screen. Turn them on in Settings › Run Exporter."
            return
        }

        // Clearing stale activities and requesting the new one must happen **in that order**, in
        // one task. They used to be separate calls: the cleanup was a detached `Task` that had not
        // run yet when the new activity was created, so it then enumerated the activities — now
        // including the fresh one — and ended it immediately. The workout's card was destroyed by
        // its own cleanup, while a card started without cleanup worked fine.
        Task {
            for stale in Activity<RunWorkoutAttributes>.activities {
                await stale.end(nil, dismissalPolicy: .immediate)
            }

            do {
                activity = try Activity.request(
                    attributes: RunWorkoutAttributes(workoutName: workoutName,
                                                     activityName: activityName),
                    content: ActivityContent(state: state, staleDate: staleDate(for: state)),
                    pushType: nil)
            } catch {
                activity = nil
                lastError = "The Lock Screen activity could not start: "
                    + "\(error.localizedDescription). The workout and its cues are unaffected."
            }
        }
    }

    /// Compares what the system actually holds against what was just pushed, and reports a
    /// discarded update rather than letting the card go quietly wrong.
    ///
    /// Recovery is normal and expected: an update issued while the app happens to be in the
    /// foreground is applied, so the card corrects itself the moment the user opens the app. The
    /// warning therefore clears on success instead of latching.
    /// Internal rather than private so `LiveActivityStalenessTests` can exercise it directly: the
    /// OS behaviour that triggers it cannot be reproduced off-device, but this decision can.
    func recordOutcome(pushed: RunWorkoutAttributes.ContentState,
                       applied: RunWorkoutAttributes.ContentState) {
        guard applied != pushed else {
            isCardStale = false
            return
        }

        droppedUpdates += 1
        isCardStale = true
        // Counted, but deliberately **not** raised to the user any more. It was a real warning
        // while the card displayed a phase name that could contradict the workout. The card now
        // shows only values derived from fixed bounds, so a discarded update changes nothing the
        // user can see, and a banner on every locked workout would be noise reporting a
        // non-problem. The count stays for the Cue test screen.
    }

    /// A one-line description of why no card is showing, for the diagnostics screen.
    ///
    /// Exists because "nothing appeared" is the least actionable bug report possible, and the
    /// three causes — switched off, request failed, or working fine — are indistinguishable from
    /// the outside.
    var statusDescription: String {
        if isActive { return "running" }
        if !areActivitiesEnabled { return "turned off in Settings" }
        if lastError != nil { return "failed to start" }
        return "idle (starts with a workout)"
    }

    /// Pushes new state. Called at phase transitions and on pause/resume — never per second.
    func update(_ state: RunWorkoutAttributes.ContentState) {
        guard let activity else { return }
        Task {
            await activity.update(ActivityContent(state: state, staleDate: staleDate(for: state)))

            // `Activity.update` is non-throwing and reports nothing when the system declines to
            // apply the content, which it always does while the app is backgrounded. Reading the
            // content back is the only way to know it happened at all.
            recordOutcome(pushed: state, applied: activity.content.state)
        }
    }

    /// Removes the activity. `dismissalPolicy: .immediate` because a finished workout's card is
    /// clutter, not information.
    func end(finalState: RunWorkoutAttributes.ContentState?) {
        guard let activity else { return }
        self.activity = nil
        Task {
            let content = finalState.map {
                ActivityContent(state: $0, staleDate: nil)
            }
            await activity.end(content, dismissalPolicy: .immediate)
        }
    }

    /// Clears activities left behind by a previous launch — for instance if the app was killed
    /// mid-workout, which would otherwise strand a card on the Lock Screen with a running clock.
    ///
    /// Safe to call at launch. **Not** for use immediately before `start`, which does its own
    /// cleanup in the correct order; calling both races and kills the new activity.
    func endActivitiesFromPreviousLaunch() {
        guard activity == nil else { return }
        Task {
            for stale in Activity<RunWorkoutAttributes>.activities {
                await stale.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func clearError() { lastError = nil }

    // MARK: - Diagnostics

    /// Requests a standalone activity for testing, and reports exactly what happened.
    ///
    /// Separates the two failures that look identical from the outside: the app being unable to
    /// *create* an activity, and the widget extension being unable to *render* one. If this
    /// reports success and a live count but no card appears, the app side is fine and the problem
    /// is in the extension.
    func runDiagnostic() -> String {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return "Live Activities are disabled for this app in iOS Settings."
        }

        let now = Date()
        let state = RunWorkoutAttributes.ContentState(
            phaseName: "Run",
            phaseRawValue: "run",
            repetition: 1,
            totalRepetitions: 5,
            phaseStart: now,
            phaseEnd: now.addingTimeInterval(300),
            nextPhaseName: "Walk 1:00",
            isPaused: false,
            pausedAt: nil)

        do {
            let requested = try Activity.request(
                attributes: RunWorkoutAttributes(workoutName: "Diagnostic"),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil)
            activity = requested

            let live = Activity<RunWorkoutAttributes>.activities.count
            return "Request succeeded. id=\(requested.id.prefix(8))… "
                + "state=\(requested.activityState) activeCount=\(live).\n\n"
                + "If no card is visible now, the app created the activity correctly and the "
                + "widget extension is not rendering it."
        } catch {
            return "Activity.request failed: \(error)\n\n(\(type(of: error)))"
        }
    }

    /// How many activities this app currently has, whatever started them.
    var activeCount: Int { Activity<RunWorkoutAttributes>.activities.count }

    /// When the shown state stops being trustworthy.
    ///
    /// `nil` once the state carries a timeline, because then nothing on the card can go out of
    /// date: the bar and the elapsed clock are both derived from bounds that never move, and the
    /// card shows no phase name or round to be wrong about. Expiring at the phase boundary — which
    /// an earlier revision did — would now dim a *correct* card a minute into every workout.
    ///
    /// Without a timeline the old rule still applies: the content is a snapshot of one phase, so it
    /// stops being true when that phase ends.
    func staleDate(for state: RunWorkoutAttributes.ContentState) -> Date? {
        guard state.timelineSegments.isEmpty else { return nil }
        guard !state.isPaused, let end = state.phaseEnd else { return nil }
        return end
    }
}
