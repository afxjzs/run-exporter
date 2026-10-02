import SwiftUI

/// Chooses between the run screen, the link screen and the idle screen, and asks for Health access
/// up front.
///
/// The link screen appears as soon as a launch from the phone **arrives**, not once a session is
/// running — otherwise a launch that stalls before the session looks exactly like one that never
/// came. With nothing arrived, the idle screen says where a workout starts. (Until the 2026-09-29
/// clean-out that slot held the stage 2 background-execution probe, which had passed.)
///
/// The Health requests below must stay: a launch from the phone may arrive in the background, where
/// no permission sheet can appear, so access is asked for whenever this app is on screen.
///
/// Swipe left for the saved event log. The build number sits at the bottom of the first page, so
/// every test starts by confirming which build is actually on the Watch.
struct RootView: View {
    private var controller = WatchWorkoutController.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            Group {
                if controller.phaseClock != nil {
                    // A run the phone is driving: the run screen, not the diagnostics.
                    WatchRunView(controller: controller)
                } else if controller.origin != nil || controller.launchReceivedAt != nil {
                    WatchLinkView(controller: controller)
                } else {
                    WatchIdleView(controller: controller)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("build \(WatchBuildInfo.label)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            WatchEventLogView()
        }
        .task { await controller.prepareHealthAccess() }
        .onChange(of: scenePhase) { _, phase in
            WatchEventLog.shared.record("screen: \(Self.name(for: phase))")
            // Every time the app comes on screen, not once per process. A Watch reinstall resets
            // Health access, and a process the phone started in the background has already spent
            // its `.task` ask where no sheet could appear.
            if phase == .active {
                Task { await controller.prepareHealthAccess() }
            }
        }
    }

    private static func name(for phase: ScenePhase) -> String {
        switch phase {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}

/// Opening the app by hand with no run from the phone: where a workout starts, and whether Health
/// access is in place — without it, a phone launch stops with an error.
struct WatchIdleView: View {
    let controller: WatchWorkoutController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Start a workout from your iPhone.")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Health access: \(controller.healthAccess)")
                    .font(.caption2)
                    .foregroundStyle(controller.healthAccess == "failed" ? .red : .secondary)
                WatchErrorText(error: controller.lastError)
            }
            .padding(.horizontal, 4)
        }
    }
}

/// The controller's last error, in red and wrapped, or nothing. One view so the idle and link
/// screens cannot drift in how they show a failure.
struct WatchErrorText: View {
    let error: String?

    var body: some View {
        if let error {
            Text(error)
                .font(.caption2)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The saved event log, newest first, with the build it was read on.
struct WatchEventLogView: View {
    private var log = WatchEventLog.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("EVENT LOG")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if log.lines.isEmpty {
                    Text("Nothing recorded.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(log.lines.reversed().enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(line.contains("ERROR") ? .red : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Clear log", role: .destructive) { log.clear() }
                    .padding(.top, 6)
            }
            .padding(.horizontal, 4)
        }
    }
}

/// What the watch shows between a phone launch arriving and the first phase — and when a start
/// fails, the only place the watch says why: the step it reached and the error. End discards a
/// session the phone has lost track of. (Its "Test session: not saved to Health." footer was false
/// for a real run and went in the 2026-09-29 clean-out.)
struct WatchLinkView: View {
    let controller: WatchWorkoutController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(heartRateText)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                row("launch from phone", Self.time(controller.launchReceivedAt))
                row("step", controller.step)
                row("Health access", controller.healthAccess)
                row("started by", controller.origin?.rawValue ?? "—")
                row("at", Self.time(controller.startedAt))
                row("session", controller.sessionState)
                row("iPhone", controller.mirroring)
                row("pings answered", "\(controller.pingsAnswered)")
                row("statuses sent", "\(controller.statusesSent)")

                WatchErrorText(error: controller.lastError)

                if controller.isRunning {
                    Button("End", role: .destructive) { controller.end() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var heartRateText: String {
        guard let bpm = controller.heartRate else { return "— bpm" }
        // `Int(rounded())`, not `String(format: "%.0f")`: printf rounds half to even and Swift's
        // `rounded()` rounds half away from zero, so 72.5 printed as 72 here and 73 on the run
        // screen and in the phone's `Display.heartRate`. One app, one value, two answers.
        return "\(Int(bpm.rounded())) bpm"
    }

    /// Tenths of a second, so it can be compared with the phone's log by eye.
    private static func time(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(1)))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.caption)
                .monospacedDigit()
        }
    }
}
