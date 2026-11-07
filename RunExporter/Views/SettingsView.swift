import AVFAudio
import SwiftUI

/// Settings (spec §22). Export settings are untouched — they live on the export screen, as before.
struct SettingsView: View {
    @Environment(LoggerStore.self) private var store
    @Environment(LoggerDefaults.self) private var defaults
    @Environment(AudioCueEngine.self) private var audio

    var body: some View {
        @Bindable var defaults = defaults

        Form {
            if !defaults.configurationIssues.isEmpty {
                Section("Settings that could not be read") {
                    ForEach(defaults.configurationIssues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }

            cueSection($defaults)
            defaultsSection($defaults)
            loggingSection($defaults)
            aboutExportsSection

            Section {
                Text("Everything this app records stays on this device. There is no account, no "
                     + "analytics and no server. Data leaves only through the share sheet, when "
                     + "you send an export yourself.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // Shown so "am I actually running the new build?" is answerable from the phone.
            // iOS keeps a running app on its old bundle image after an install, which makes an
            // updated app look unchanged until it is force-quit.
            Section {
                LabeledContent("Version", value: Self.versionString)
            } footer: {
                Text("If this does not match the build you just installed, force-quit the app "
                     + "from the app switcher and reopen it.")
            }
        }
        .navigationTitle("Settings")
    }

    // MARK: - About exports

    /// The explanations that sat under each control on the export screen, moved here so Export is
    /// on screen without scrolling. Plain text: nothing here is a setting.
    private var aboutExportsSection: some View {
        Section("About exports") {
            ForEach(Self.exportExplanations, id: \.self) { line in
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let exportExplanations: [String] = [
        "Last workouts exports your most recent runs, from the first of them until now. Date "
            + "range exports whatever falls between two dates, and its End resets to now each "
            + "time you open the app.",
        "Every run is exported. A walk is exported only when this app recorded it from a "
            + "Walking plan, or when you marked it as really a run in History. The export says "
            + "how many walks it left out.",
        "Full date range includes every heart-rate and other Health record in the range. "
            + "Workout windows only keeps records within "
            + "\(ExportMode.workoutWindowBufferMinutes) minutes of each workout, for a smaller "
            + "export.",
        "Weather comes from each workout's own Health data. Nothing is looked up online.",
        "GPS routes show where you run, so treat an export that includes them as sensitive.",
        "If some data is missing, check this app's permissions in the Health app, under Sharing.",
    ]

    /// "1.1.4 (1)" — marketing version plus build, read from the running bundle.
    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    // MARK: - Cues

    @ViewBuilder
    private func cueSection(_ defaults: Bindable<LoggerDefaults>) -> some View {
        Section {
            Toggle("Play cues", isOn: defaults.playsCues)
            Picker("Cues", selection: defaults.cueMode) {
                ForEach(CueMode.allCases) { Text($0.displayName).tag($0) }
            }
            // Disabled only when cues are off, where nothing plays so the choice genuinely has no
            // effect.
            .disabled(!defaults.wrappedValue.playsCues)

            Stepper("Countdown: \(countdownLabel)",
                    value: defaults.countdownSeconds,
                    in: 0...10,
                    step: 1)
            Toggle("Announce final round", isOn: defaults.finalRoundAnnouncement)
            Toggle("Announce halfway", isOn: defaults.halfwayAnnouncement)

            // Set once and left: folded so the screen opens on what changes run to run.
            DisclosureGroup("Fine-tuning") {
                Toggle("Five-second warning", isOn: defaults.fiveSecondWarning)
                Toggle("Count down every transition", isOn: defaults.transitionCountdown)
                Toggle("Duck other audio", isOn: defaults.duckOtherAudio)

                VStack(alignment: .leading) {
                    Text("Cue volume")
                    // Floors at 10%, not 0 — silencing cues is "Play cues" off, which skips the
                    // work rather than doing it inaudibly. See `LoggerDefaults.minimumCueVolume`.
                    Slider(value: defaults.cueVolume, in: LoggerDefaults.minimumCueVolume...1)
                }

                Picker("Voice", selection: defaults.cueVoiceIdentifier) {
                    Text("System default").tag(String?.none)
                    ForEach(AudioCueEngine.availableVoices, id: \.identifier) { voice in
                        Text("\(voice.name) (\(voice.language))").tag(String?.some(voice.identifier))
                    }
                }
            }
        } header: {
            Text("Workout cues")
        } footer: {
            // Which mode is actually in effect, stated rather than left to be inferred.
            Text(cueSourceExplanation)
        }
    }

    private var countdownLabel: String {
        defaults.countdownSeconds == 0 ? "Off" : "\(defaults.countdownSeconds)s"
    }

    private var cueSourceExplanation: String { Self.cueSourceExplanation(for: defaults.cueSource) }

    /// What the user will actually hear under `source`.
    ///
    /// `static` and pure so `CueSourceExplanationTests` can assert it against
    /// `AudioCueEngine.shouldPlay` — the same reason `shouldPlay` and `sessionOptions` are
    /// `nonisolated static`. This text is a promise about audible behavior, and the engine is what
    /// keeps or breaks it; nothing but a test can keep the two in step.
    ///
    /// The Watch cue sources' footers once said "This app plays NO cues" while pause, resume, skip
    /// and end still played under them — a promise of silence the engine never kept, on the screen
    /// the engine's own comment cites as authoritative. Those sources were removed on 2026-09-29.
    static func cueSourceExplanation(for source: CueSource) -> String {
        switch source {
        case .iphoneAudioEngine:
            return "This iPhone plays the run, walk and cooldown cues through your current audio "
                + "route. The settings above apply."
        case .none:
            return "No cues will play from this app at all, including confirmations of taps. "
                + "The warning when a run starts without your Watch still sounds."
        }
    }

    // MARK: - Defaults

    @ViewBuilder
    private func defaultsSection(_ defaults: Bindable<LoggerDefaults>) -> some View {
        Section {
            DisclosureGroup("Defaults for new workouts") {
                defaultsRows(defaults)
            }
        }
    }

    @ViewBuilder
    private func defaultsRows(_ defaults: Bindable<LoggerDefaults>) -> some View {
            Picker("Activity", selection: defaults.activityType) {
                ForEach(PlannedActivityType.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Cooldown", selection: defaults.cooldownMode) {
                ForEach(CooldownMode.allCases) { Text($0.displayName).tag($0) }
            }
            if defaults.wrappedValue.cooldownMode == .timed {
                Stepper("Cooldown: \(PlannedWorkout.clockDuration(defaults.wrappedValue.defaultCooldownSeconds))",
                        value: defaults.defaultCooldownSeconds, in: 60...7200, step: 60)
            }
            Stepper("Run: \(PlannedWorkout.clockDuration(defaults.wrappedValue.defaultRunSeconds))",
                    value: defaults.defaultRunSeconds, in: 15...3600, step: 15)
            Stepper("Walk: \(PlannedWorkout.clockDuration(defaults.wrappedValue.defaultWalkSeconds))",
                    value: defaults.defaultWalkSeconds, in: 0...3600, step: 15)
            Stepper("Rounds: \(defaults.wrappedValue.defaultRepetitions)",
                    value: defaults.defaultRepetitions, in: 1...60)
    }

    // MARK: - Logging

    @ViewBuilder
    private func loggingSection(_ defaults: Bindable<LoggerDefaults>) -> some View {
        Section {
            DisclosureGroup("Logging") {
                Toggle("Show body signals", isOn: defaults.showBodySignals)
                Toggle("Show recovery prompt", isOn: defaults.showRecoveryPrompt)
                Toggle("Show scale explanations", isOn: defaults.showScaleExplanations)
                Stepper("Prompt for the last \(defaults.wrappedValue.unloggedPromptDays) days",
                        value: defaults.unloggedPromptDays, in: 1...90)
                Text("Older workouts are never deleted. They stop appearing in the \"needs a "
                     + "log\" list, and you can still log any of them from History.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
