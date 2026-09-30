import SwiftUI

/// The watch's run screen — one screen, the owner's list (2026-09-29): phase, time left, heart rate,
/// leg pace, the current mile split, and total distance.
///
/// Time left comes from `PhaseClock`, re-read once a second, so the countdown runs on this watch's
/// clock between the phone's messages. Pace and distance come from `PaceTracker`, fed by this
/// watch's own distance readings.
struct WatchRunView: View {
    let controller: WatchWorkoutController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            // Frozen once the session has ended: an open cooldown's clock counting on after the save
            // read as a workout still going (the first real run, 2026-09-30).
            content(now: controller.endedAt ?? context.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let outcome = controller.outcome {
                    Text(Self.headline(outcome))
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(Self.color(outcome))
                        .fixedSize(horizontal: false, vertical: true)
                } else if let clock = controller.phaseClock {
                    Text(phaseTitle(clock.anchor))
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(phaseColor(clock.anchor.phase))
                    Text(timeText(clock, now: now))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(clock.isOverdue(at: now) ? .orange : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(timeCaption(clock, now: now))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                row("♥", heartRateText)
                row("leg", paceText(controller.pace.legPaceSecondsPerMile))
                row("mile", paceText(controller.pace.mileSplitSecondsPerMile))
                row("dist", distanceText)

                if let saveResult = controller.saveResult {
                    Text(saveResult)
                        .font(.system(size: 10))
                        .foregroundStyle(saveResult.contains("FAILED") ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !controller.routeStatus.hasPrefix("recording") {
                    // A run with no route should say so while it can still be fixed, not afterwards.
                    Text(controller.routeStatus)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Once the session has ended, only a failed save shows its error. A stale link error
                // from mid-run under "Workout saved" read as the save having failed (the owner, after
                // the 2026-09-30 run). Every error is still in the event log, which reaches the phone.
                if let error = controller.lastError,
                   controller.outcome == nil || controller.outcome == .notSaved {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Text

    private static func headline(_ outcome: WatchWorkoutController.Outcome) -> String {
        switch outcome {
        case .saving: return "Saving…"
        case .saved: return "Workout saved"
        case .savedWithoutRoute: return "Saved, no route"
        case .notSaved: return "Not saved"
        case .discarded: return "Discarded"
        }
    }

    private static func color(_ outcome: WatchWorkoutController.Outcome) -> Color {
        switch outcome {
        case .saving, .discarded: return .secondary
        case .saved: return .green
        case .savedWithoutRoute: return .orange
        case .notSaved: return .red
        }
    }

    private func phaseTitle(_ anchor: PhaseAnchor) -> String {
        var title = anchor.phase.rawValue.uppercased()
        if let leg = anchor.legNumber {
            title += anchor.legCount.map { " \(leg)/\($0)" } ?? " \(leg)"
        }
        if anchor.isPaused { title += " · PAUSED" }
        return title
    }

    /// Time left for a timed phase; elapsed for an open-ended one, which has nothing to count to.
    ///
    /// A countdown rounds **up**, exactly as the phone's `Display.countdown` does. The first build
    /// rounded down, so with 12.3 s left the phone read 0:13 and the watch 0:12 — measured on
    /// 2026-09-29 as "about a second" between the two screens.
    private func timeText(_ clock: PhaseClock, now: Date) -> String {
        if let remaining = clock.remaining(at: now) {
            return Self.clock(remaining.rounded(.up))
        }
        return Self.clock(clock.elapsed(at: now))
    }

    private func timeCaption(_ clock: PhaseClock, now: Date) -> String {
        if clock.remaining(at: now) == nil { return "elapsed" }
        return clock.isOverdue(at: now) ? "waiting for the phone" : "left"
    }

    private var heartRateText: String {
        controller.heartRate.map { "\(Int($0.rounded())) bpm" } ?? "—"
    }

    private var distanceText: String {
        String(format: "%.2f mi", controller.pace.totalMeters / PaceTracker.metersPerMile)
    }

    private func paceText(_ secondsPerMile: TimeInterval?) -> String {
        guard let secondsPerMile else { return "—" }
        return Self.clock(secondsPerMile) + " /mi"
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    private func phaseColor(_ phase: WatchPhase) -> Color {
        switch phase {
        case .run: return .green
        case .walk: return .blue
        case .warmup, .cooldown: return .orange
        case .countdown: return .yellow
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }
}
