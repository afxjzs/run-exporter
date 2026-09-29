import ActivityKit
import SwiftUI

/// On-device harness for the cue acceptance tests (spec §26, Tests 1 and 2).
///
/// The spec requires these to be verified on real hardware with real AirPods, which no automated
/// check can do — a cue either is or is not audible to a person. This screen makes the two tests
/// fast to run and records exactly what the app attempted, so what was heard can be compared
/// against what was requested.
struct CueTestView: View {
    @Environment(LoggerStore.self) private var store
    @Environment(LoggerDefaults.self) private var defaults
    @Environment(AudioCueEngine.self) private var audio
    @Environment(\.modelContext) private var context

    @State private var isSessionOpen = false
    @State private var errorMessage: String?
    @State private var createdPlanName: String?
    @State private var liveActivityDiagnostic: String?
    @State private var liveActivity = LiveActivityController()

    private let cues: [AudioCue] = [.countdown(3), .countdown(2), .countdown(1),
                                    .run, .walk, .cooldown, .finalRound, .halfway,
                                    .nextPhase(.walk, seconds: 5), .complete,
                                    // Control confirmations — the ones that tell you a tap landed.
                                    .paused, .resumed(.run), .skipped, .ended]

    var body: some View {
        Form {
            Section {
                LabeledContent("Cue source", value: defaults.cueSource.displayName)
                LabeledContent("Output route",
                               value: audio.currentRouteDescription.isEmpty
                                   ? "not started" : audio.currentRouteDescription)
                LabeledContent("Session", value: isSessionOpen ? "active" : "inactive")
                backgroundCapableRow
                liveActivityRow
            } header: {
                Text("Now")
            } footer: {
                if !defaults.cueSource.usesAppOwnedEngine {
                    // Stated precisely, because the two cases genuinely differ: "No cues" is
                    // silent, while the Watch sources still confirm taps in this app.
                    Text("The cue source is \"\(defaults.cueSource.displayName)\", so this app "
                         + (defaults.cueSource == .none
                            ? "will play nothing at all. "
                            : "will play no transition cues — only confirmations of buttons you "
                              + "tap here. ")
                         + "Switch it to the iPhone audio engine in Settings to test the app's "
                         + "own cues.")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button {
                    startSession()
                } label: {
                    Label("Start audio session", systemImage: "play.circle")
                }
                .disabled(isSessionOpen)

                Button {
                    audio.endWorkoutAudio()
                    isSessionOpen = false
                } label: {
                    Label("Stop audio session", systemImage: "stop.circle")
                }
                .disabled(!isSessionOpen)
            } footer: {
                Text("Start the session, put your AirPods in, start music or a podcast, then play "
                     + "each cue below. The session must be running for background behaviour to "
                     + "match a real workout.")
            }

            Section("Play a cue") {
                ForEach(cues, id: \.identifier) { cue in
                    Button(cue.identifier.replacingOccurrences(of: "_", with: " ").capitalized) {
                        audio.play(cue)
                    }
                    .disabled(!isSessionOpen)
                }
            }

            Section {
                Button("Start a test Live Activity") {
                    liveActivityDiagnostic = liveActivity.runDiagnostic()
                }
                Button("End test Live Activity", role: .destructive) {
                    liveActivity.end(finalState: nil)
                    liveActivityDiagnostic = "Ended. Active count: \(liveActivity.activeCount)."
                }
                LabeledContent("Updates discarded by iOS", value: "\(liveActivity.droppedUpdates)")
                if let liveActivityDiagnostic {
                    Text(liveActivityDiagnostic)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Live Activity")
            } footer: {
                Text("Creates a Lock Screen card without running a workout. If this reports "
                     + "success but no card appears, the app is fine and the widget extension is "
                     + "the problem — which is otherwise impossible to tell apart.")
            }

            Section("Test 1 — native Apple Workout cues") {
                Text("Create the spec's 1 min run / 30 sec walk × 3 workout, send it to the Watch, "
                     + "start it in Apple's Workout app, and record what you actually hear at "
                     + "every transition.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Create the 1/0:30 × 3 test workout") { createTestWorkout() }
                if let createdPlanName {
                    Label("Created \"\(createdPlanName)\" — send it from Plans.",
                          systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.green)
                }
            }

            if !audio.playbackLog.isEmpty {
                Section {
                    ForEach(audio.playbackLog.reversed()) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(record.cue).font(.subheadline.weight(.medium))
                                Spacer()
                                Text(Display.timeFormatter.string(from: record.requestedAt))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text("\(record.spoke ? "spoke" : "no speech") · "
                                 + "\(record.played ? "tone" : "no tone") · \(record.route)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            // The number that shows whether beeps are landing on the second. The
                            // log used to stamp one time at the end of the work, so every row read
                            // as regular no matter how late the tone actually sounded.
                            if let latency = record.startLatency {
                                Text(Self.latencyDescription(latency))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(latency > 0.05 ? .orange : .secondary)
                            }
                        }
                    }
                    Button("Clear", role: .destructive) { audio.clearPlaybackLog() }
                } header: {
                    Text("What the app attempted")
                } footer: {
                    Text("This records what was requested, not what was audible. Confirm each one "
                         + "by ear — that is the part only you can do.")
                }
            }

            if let error = audio.lastError {
                Section("Audio problem") {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Clear") { audio.clearError() }
                }
            }
        }
        .navigationTitle("Cue Test")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            if isSessionOpen {
                audio.endWorkoutAudio()
                isSessionOpen = false
            }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } }),
               actions: { Button("OK", role: .cancel) { errorMessage = nil } },
               message: { Text(errorMessage ?? "") })
    }

    /// The distinction that matters: a session that failed to configure still makes noise in the
    /// foreground, so hearing a cue proves nothing about locked-screen playback. State which mode
    /// is actually in effect rather than letting it be inferred from "I can hear it".
    @ViewBuilder
    private var backgroundCapableRow: some View {
        // Three states, not two. Before the session is started nothing has been attempted, and
        // reporting "no — foreground only" then is a false alarm about a check that never ran.
        if !isSessionOpen {
            LabeledContent("Background capable", value: "not checked yet")
                .foregroundStyle(.secondary)
        } else if audio.isSessionConfigured {
            LabeledContent("Background capable", value: "yes")
        } else {
            LabeledContent("Background capable", value: "no — foreground only")
                .foregroundStyle(.orange)
        }
    }

    /// Whether the system will allow a Lock Screen card at all.
    ///
    /// Checked here rather than only at workout start, because "Live Activities are off" is a
    /// Settings state the user can fix before a run instead of discovering mid-run.
    @ViewBuilder
    private var liveActivityRow: some View {
        let enabled = ActivityAuthorizationInfo().areActivitiesEnabled
        LabeledContent("Live Activities",
                       value: enabled ? "allowed" : "off in iOS Settings")
            .foregroundStyle(enabled ? Color.primary : Color.orange)
    }

    private func startSession() {
        if let error = audio.prepare(settings: defaults) {
            errorMessage = error
            return
        }
        if let error = audio.beginWorkoutAudio() {
            errorMessage = error
            return
        }
        isSessionOpen = true
    }

    /// The exact workout spec §26 Test 1 calls for.
    private func createTestWorkout() {
        let plan = PlannedWorkout(name: "Cue test 1/0:30 × 3",
                                  runIntervalSeconds: 60,
                                  walkIntervalSeconds: 30,
                                  plannedRepetitions: 3,
                                  cooldownMode: .open,
                                  countdownSeconds: 3)
        context.insert(plan)
        if let error = store.save() {
            errorMessage = error
            return
        }
        createdPlanName = plan.name
    }

    /// How late a tone was, in words, with the threshold stated rather than left to the reader.
    ///
    /// 50 ms is the point where a beep stops feeling like it landed on the second. Anything at or
    /// under that reads as on time; above it is called out, because a cue that arrives late is the
    /// failure this whole screen exists to detect.
    static func latencyDescription(_ latency: TimeInterval) -> String {
        let milliseconds: Int = Int((latency * 1000).rounded())
        guard milliseconds > 50 else {
            return "on time (\(milliseconds) ms to sound)"
        }
        return "LATE by \(milliseconds) ms before the tone sounded"
    }
}
