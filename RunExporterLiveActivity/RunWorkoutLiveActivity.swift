import ActivityKit
import SwiftUI
import WidgetKit

@main
struct RunExporterLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        RunWorkoutLiveActivity()
    }
}

/// Lock Screen and Dynamic Island presentation of a running workout (spec §12.1).
///
/// Tapping it opens the app, which is most of the value: it turns the Lock Screen into the way
/// back to the workout screen instead of hunting for the app.
struct RunWorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RunWorkoutAttributes.self) { context in
            LockScreenView(state: context.state,
                           workoutName: context.attributes.workoutName,
                           activityName: context.attributes.activityName)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            // Everything here is derived from fixed bounds for the same reason as the Lock Screen
            // card: iOS discards updates sent while the app is backgrounded, so a phase name or
            // round number would be wrong for most of a workout with nothing able to correct it.
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.activityName, systemImage: "figure.run")
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedText(state: context.state)
                        .font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    TimelineBar(state: context.state)
                }
            } compactLeading: {
                Image(systemName: "figure.run")
            } compactTrailing: {
                ElapsedText(state: context.state)
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "figure.run")
            }
        }
    }
}

/// The phase clock.
///
/// Uses `Text(timerInterval:)` so the system ticks the countdown itself — the app never pushes a
/// per-second update, which ActivityKit would throttle anyway. A paused workout shows a frozen
/// value instead, because a running clock would misrepresent a stopped one.
private struct TimeText: View {
    let state: RunWorkoutAttributes.ContentState

    var body: some View {
        if state.isPaused {
            Text(frozen).monospacedDigit()
        } else if let end = state.phaseEnd {
            Text(timerInterval: state.phaseStart...end, countsDown: true)
                .monospacedDigit()
        } else {
            // Open-ended phase: count up from its start.
            Text(state.phaseStart, style: .timer)
                .monospacedDigit()
        }
    }

    /// Remaining (or elapsed) time at the moment the pause began.
    private var frozen: String {
        let reference = state.pausedAt ?? Date()
        let seconds: TimeInterval
        if let end = state.phaseEnd {
            seconds = max(0, end.timeIntervalSince(reference))
        } else {
            seconds = max(0, reference.timeIntervalSince(state.phaseStart))
        }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The whole workout drawn as one self-animating bar per phase.
///
/// ## Why this exists
///
/// iOS applies `Activity.update` only while the app is in the foreground; from the background the
/// call returns cleanly and the content is discarded. A card whose correctness depends on
/// per-transition updates is therefore wrong for most of a locked workout — which is the entire
/// situation this app is built for.
///
/// A Live Activity's view is not re-rendered as time passes either, so this cannot be solved by
/// computing the current phase in `body`. But `ProgressView(timerInterval:)` is one of the few
/// views the system animates by itself, exactly like the `Text(timerInterval:)` clock. Giving each
/// phase its own progress view means the card advances on the system's clock: phases behind us read
/// full, the current one is visibly filling, and the ones ahead sit empty — **with no updates at
/// all** beyond the single push that starts the activity.
private struct TimelineBar: View {
    let state: RunWorkoutAttributes.ContentState

    /// Gap between segments.
    private static let spacing: CGFloat = 2
    /// Fixed width for an open-ended phase, which has no duration to be proportional to.
    private static let openWidth: CGFloat = 10

    var body: some View {
        let segments = state.timelineSegments

        // Nothing is drawn rather than something invented when the timeline is absent — an older
        // build's activity, or a plan that produced no schedule.
        if !segments.isEmpty {
            GeometryReader { geometry in
                // The gaps and the fixed-width open phase are taken out of the available space
                // *before* the timed phases are proportioned. Sharing out the full width and then
                // adding spacing on top overflows the card by exactly the total spacing, which is
                // what pushed the last segment past the rounded corner.
                let gaps = CGFloat(max(0, segments.count - 1)) * Self.spacing
                let openCount = segments.filter { $0.end == nil }.count
                let reserved = gaps + CGFloat(openCount) * Self.openWidth
                let usable = max(0, geometry.size.width - reserved)
                let totalSeconds = max(1, state.timelineTotalSeconds)

                HStack(spacing: Self.spacing) {
                    ForEach(segments) { segment in
                        segmentView(segment)
                            .frame(width: segment.end == nil
                                   ? Self.openWidth
                                   : usable * CGFloat(segment.seconds) / CGFloat(totalSeconds))
                    }
                }
                .frame(width: geometry.size.width, alignment: .leading)
            }
            .frame(height: 6)
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: RunWorkoutAttributes.ContentState.TimelineSegment) -> some View {
        if let end = segment.end {
            // `countsDown: false` fills as time passes rather than draining.
            ProgressView(timerInterval: segment.start...end, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .tint(timelineColor(segment.kind))
        } else {
            // An open-ended phase has no boundary to fill towards, so it is drawn as a plain track.
            Capsule().fill(timelineColor(segment.kind).opacity(0.55))
        }
    }

}

/// Kept keyed to the single-character phase codes carried in `phaseKinds`, since the widget cannot
/// import the app's `WorkoutPhase`.
private func timelineColor(_ kind: Character) -> Color {
    switch kind {
    case "r": return .green
    case "w": return .blue
    case "c": return .purple
    case "u", "d": return .orange
    default: return .gray
    }
}

private struct LockScreenView: View {
    let state: RunWorkoutAttributes.ContentState
    let workoutName: String
    let activityName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    // Headline comes from the *attributes*, which never change — so unlike the
                    // phase name it cannot drift out of date while the phone is locked.
                    Text(state.isPaused ? "PAUSED" : activityName.uppercased())
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(state.isPaused ? Color.gray : .primary)
                    Text(workoutName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 0) {
                    // `Text(_:style: .timer)` reserves a slot wide enough for the longest string it
                    // could ever show ("1:00:00") and centres the digits in it, so left to itself
                    // "1:54" floats in the middle of the card instead of sitting at the edge.
                    // An explicit frame plus trailing alignment pins it; the scale factor covers
                    // a workout that does run past an hour.
                    ElapsedText(state: state)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 104, alignment: .trailing)
                    Text("elapsed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            TimelineBar(state: state)

            // Deliberately *not* the phase name. Which phase is live is read off the bar, which
            // stays correct on the system's own clock; a word here would be wrong for most of a
            // locked workout with nothing able to correct it.
            //
            // It does, however, name run and walk in the bar's own colours, which is the only
            // legend the card has. Static text, so it cannot go stale.
            if let planSummary {
                Text(planSummary)
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
    }

    /// A one-line description of the plan — "3 rounds · run 1:00 · walk 0:30" — which doubles as the
    /// timeline bar's colour legend: "run" and "walk" carry the same tints as their segments.
    ///
    /// Static text derived from the timeline, so it is true for the whole workout and never needs an
    /// update. That matters here: `Activity.update` is discarded while the app is backgrounded, so
    /// anything on this card that is not derivable from immutable state is a lie waiting to happen.
    ///
    /// **Why an `AttributedString` and not `Text("a") + Text("b").foregroundColor(…)`.** Chained
    /// `Text` with interpolation has timed out the SwiftUI type-checker and failed the Release build
    /// three times in this project (README "Gotchas"). Building the string imperatively keeps type
    /// inference out of it. Every fragment is tinted explicitly, including the secondary ones, so
    /// the result does not depend on attribute-precedence rules against a view-level
    /// `foregroundStyle`.
    ///
    /// Returns `nil` rather than `""` so the caller omits the line entirely instead of reserving a
    /// blank one.
    ///
    /// The earlier form, `"1:00 / 0:30 × 3"`, was misread on a real Lock Screen as "1/0" and did not
    /// convey the round count — see `docs/CUE_FEASIBILITY_TEST.md`, Test 2.
    private var planSummary: AttributedString? {
        let segments = state.timelineSegments
        guard !segments.isEmpty else { return nil }
        let runs = segments.filter { $0.kind == "r" }
        let walks = segments.filter { $0.kind == "w" }
        guard let run = runs.first else { return nil }

        let roundWord = runs.count == 1 ? "round" : "rounds"
        var summary = tinted("\(runs.count) \(roundWord)", .secondary)
        summary.append(tinted(" · ", .secondary))
        summary.append(tinted("run \(clock(run.seconds))", timelineColor("r")))
        if let walk = walks.first {
            summary.append(tinted(" · ", .secondary))
            summary.append(tinted("walk \(clock(walk.seconds))", timelineColor("w")))
        }
        return summary
    }

    private func tinted(_ string: String, _ colour: Color) -> AttributedString {
        var piece = AttributedString(string)
        piece.foregroundColor = colour
        return piece
    }

    private func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Total time since the workout began, ticked by the system.
///
/// Anchored to `timelineStart`, which is fixed for the whole workout — that is exactly why this
/// stays correct while the phase countdown cannot. `Text(timerInterval:)` never needed updates; it
/// needed a target that does not move, and a phase boundary moves every interval.
private struct ElapsedText: View {
    let state: RunWorkoutAttributes.ContentState

    var body: some View {
        if state.isPaused, let pausedAt = state.pausedAt, let start = state.timelineStart {
            let total = Int(max(0, pausedAt.timeIntervalSince(start)))
            Text(String(format: "%d:%02d", total / 60, total % 60))
        } else if let start = state.timelineStart {
            Text(start, style: .timer)
        } else {
            // No timeline (an activity from an older build): fall back to the phase clock rather
            // than showing a blank where a number belongs.
            TimeText(state: state)
        }
    }
}

// `phaseSymbol` and `phaseColor` were removed from here: both were file-private with no call site
// anywhere in the widget, and Swift does not warn on an unused private function, so they read as
// live styling code to anyone opening this file. Note that `ActiveWorkoutView` has its own
// `phaseColor`, which IS used — the duplicate name is what made these two look load-bearing.
