import SwiftUI

/// Chooses between the phone-linked session and the stage 2 probe, and asks for Health access up
/// front.
///
/// The link screen appears as soon as a launch from the phone **arrives**, not once a session is
/// running — otherwise a launch that stalls before the session looks exactly like one that never
/// came. The probe stays reachable because it is still the instrument for background execution.
///
/// Swipe left for the saved event log. The build number sits at the bottom of the first page, so
/// every test starts by confirming which build is actually on the Watch.
struct RootView: View {
    private var controller = WatchWorkoutController.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            Group {
                if controller.origin != nil || controller.launchReceivedAt != nil {
                    WatchLinkView(controller: controller)
                } else {
                    ContentView()
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

/// Step 1's measuring screen: what started this session, whether the phone link is up, and what the
/// sensors are reporting. Not a run screen — that comes once the link is proven.
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

                if let error = controller.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if controller.isRunning {
                    Button("End", role: .destructive) { controller.end() }
                        .buttonStyle(.borderedProminent)
                }

                Text("Test session: not saved to Health.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }

    private var heartRateText: String {
        guard let bpm = controller.heartRate else { return "— bpm" }
        return String(format: "%.0f bpm", bpm)
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
