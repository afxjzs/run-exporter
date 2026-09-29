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
            voiceSection($defaults)
            defaultsSection($defaults)
            loggingSection($defaults)

            Section {
                NavigationLink { CueTestView() } label: {
                    Label("Cue test", systemImage: "waveform")
                }
                NavigationLink { WatchLinkTestView() } label: {
                    Label("Watch link test", systemImage: "applewatch")
                }
                NavigationLink { ExportView() } label: {
                    Label("Export Data", systemImage: "square.and.arrow.up")
                }
            }

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
            Picker("Cue source", selection: defaults.cueSource) {
                ForEach(CueSource.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Cues", selection: defaults.cueMode) {
                ForEach(CueMode.allCases) { Text($0.displayName).tag($0) }
            }
            // Disabled only for "No cues", where nothing plays so the choice genuinely has no
            // effect. It used to be disabled for the Watch sources too, via `usesAppOwnedEngine`,
            // which is false for those — but `cueMode` decides whether the pause/resume/skip/end
            // confirmations are spoken or beeped, and those do play under the Watch sources. A
            // setting that demonstrably changes what you hear was unreachable from the one screen
            // meant to control it.
            .disabled(defaults.wrappedValue.cueSource == .none)

            Stepper("Countdown: \(countdownLabel)",
                    value: defaults.countdownSeconds,
                    in: 0...10,
                    step: 1)
            Toggle("Five-second warning", isOn: defaults.fiveSecondWarning)
            Toggle("Announce final round", isOn: defaults.finalRoundAnnouncement)
            Toggle("Announce halfway", isOn: defaults.halfwayAnnouncement)
            Toggle("Count down every transition", isOn: defaults.transitionCountdown)
            Toggle("Duck other audio", isOn: defaults.duckOtherAudio)

            VStack(alignment: .leading) {
                Text("Cue volume")
                // Floors at 10%, not 0 — silencing cues is "Cue source: No cues", which skips the
                // work rather than doing it inaudibly. See `LoggerDefaults.minimumCueVolume`.
                Slider(value: defaults.cueVolume, in: LoggerDefaults.minimumCueVolume...1)
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
    /// Two of these used to say "This app plays NO cues" for the Watch sources, which was false.
    /// `shouldPlay` returns `source.usesAppOwnedEngine || cue.isControlConfirmation`, so pause,
    /// resume, skip and end have always played under those sources — deliberately, because a tap in
    /// *this* app is this app's to acknowledge. The footer promised silence the engine never
    /// delivered, and Settings is the screen the engine's own comment cites as authoritative.
    static func cueSourceExplanation(for source: CueSource) -> String {
        switch source {
        case .iphoneAudioEngine:
            return "This iPhone plays the run, walk and cooldown cues through your current audio "
                + "route. The settings above apply."
        case .appleWorkout:
            return "Apple's Workout app on the Watch provides the run, walk and cooldown cues, and "
                + "this app stays quiet for those so the two never talk over each other. It does "
                + "still confirm taps you make here — pause, resume, skip and end — and the Cues, "
                + "voice and volume settings above apply to those confirmations. Choose \"No cues\" "
                + "for complete silence from this app."
        case .watchCompanion:
            return "A Watch companion app is not part of this version, so nothing will announce the "
                + "run and walk transitions. This app does still confirm taps you make here — "
                + "pause, resume, skip and end — and the Cues, voice and volume settings above "
                + "apply to those confirmations. Choose \"No cues\" for complete silence from this "
                + "app."
        case .none:
            return "No cues will play from this app at all, including confirmations of taps."
        }
    }

    // MARK: - Voice

    @ViewBuilder
    private func voiceSection(_ defaults: Bindable<LoggerDefaults>) -> some View {
        Section("Voice") {
            Picker("Voice", selection: defaults.cueVoiceIdentifier) {
                Text("System default").tag(String?.none)
                ForEach(AudioCueEngine.availableVoices, id: \.identifier) { voice in
                    Text("\(voice.name) (\(voice.language))").tag(String?.some(voice.identifier))
                }
            }
        }
    }

    // MARK: - Defaults

    @ViewBuilder
    private func defaultsSection(_ defaults: Bindable<LoggerDefaults>) -> some View {
        Section("Defaults for new workouts") {
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
    }

    // MARK: - Logging

    @ViewBuilder
    private func loggingSection(_ defaults: Bindable<LoggerDefaults>) -> some View {
        Section {
            Toggle("Show body signals", isOn: defaults.showBodySignals)
            Toggle("Show recovery prompt", isOn: defaults.showRecoveryPrompt)
            Toggle("Show scale explanations", isOn: defaults.showScaleExplanations)
            Stepper("Prompt for the last \(defaults.wrappedValue.unloggedPromptDays) days",
                    value: defaults.unloggedPromptDays, in: 1...90)
        } header: {
            Text("Logging")
        } footer: {
            Text("Older workouts are never deleted — they just stop appearing in the "
                 + "\"needs a log\" list. You can still log any of them from History.")
        }
    }
}
