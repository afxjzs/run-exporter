import SwiftUI

/// On-device harness for plan of record step 1 (`docs/WATCHOS_RECORDER_PLAN.md`): launch the watch
/// app from here, watch its session arrive, and measure the link.
///
/// A measuring screen, like `CueTestView` — not the run screen. The real Start button is step 2,
/// once this proves the mechanism works on this phone and this watch.
struct WatchLinkTestView: View {
    @Environment(WatchLink.self) private var link

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await link.launchWatchWorkout() }
                } label: {
                    Label(link.isLaunching ? "Starting…" : "Start watch workout", systemImage: "applewatch")
                }
                .disabled(link.isLaunching || link.isConnected)

                Button("Ping the watch") { link.ping() }
                    .disabled(!link.isConnected)
                Button("End watch workout", role: .destructive) { link.endWatchWorkout() }
                    .disabled(!link.isConnected)
                Button("Reset this screen") { link.reset() }
            } footer: {
                Text("Starts a test session on the watch. It is not saved to Health. Reset frees "
                     + "the buttons if a test gets stuck; it does not end a session on the watch.")
            }

            Section {
                LabeledContent("Watch log lines received", value: "\(link.watchLogLinesReceived)")
                if let fileError = link.fileError {
                    Text(fileError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Saved for diagnosis")
            } footer: {
                Text("The watch's event log and this screen's log are saved to files on this phone.")
            }

            Section("Watch") {
                LabeledContent("Session", value: link.sessionState ?? "not connected")
                LabeledContent("Heart rate", value: heartRateText)
                LabeledContent("Started by", value: link.latestStatus?.origin.rawValue ?? "—")
                LabeledContent("Statuses received", value: "\(link.statusesReceived)")
                LabeledContent("Last status", value: lastStatusText)
                LabeledContent("Round trips", value: roundTripText)
            }

            Section {
                if link.events.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                }
                ForEach(link.events.reversed()) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.time(event.at))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(event.text)
                            .font(.footnote)
                            .foregroundStyle(event.isError ? .red : .primary)
                    }
                }
            } header: {
                Text("Log, newest first")
            } footer: {
                Button("Clear log") { link.clearLog() }
            }
        }
        .navigationTitle("Watch link test")
    }

    private var heartRateText: String {
        guard let status = link.latestStatus else { return "—" }
        guard let bpm = status.heartRate else { return "no reading yet" }
        return String(format: "%.0f bpm", bpm)
    }

    /// Received time on this phone's clock, so its age is honest.
    private var lastStatusText: String {
        guard let receivedAt = link.latestStatusReceivedAt else { return "—" }
        return Self.time(receivedAt)
    }

    private var roundTripText: String {
        guard let last = link.roundTrips.last else { return "—" }
        let sorted = link.roundTrips.sorted()
        let median = sorted[sorted.count / 2]
        let summary = "last \(WatchLink.seconds(last))"
        return link.roundTrips.count > 1
            ? summary + ", median \(WatchLink.seconds(median)) of \(link.roundTrips.count)"
            : summary
    }

    private static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(2)))
    }
}
