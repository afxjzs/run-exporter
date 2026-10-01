import SwiftUI

/// Recent workouts with filters (spec §19).
struct HistoryView: View {
    @Environment(LoggerDefaults.self) private var defaults

    let logger: RunLoggerModel

    @State private var filter: Filter = .all

    /// The activity filters worth offering. "Walking" is hidden when walking workouts are not
    /// read at all — a filter that can only ever return nothing is worse than no filter.
    private var availableFilters: [Filter] {
        defaults.includeWalkingWorkouts
            ? Filter.allCases.filter { $0 != .walks }
            : Filter.allCases.filter { $0 != .walking && $0 != .running }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all, logged, unlogged, running, walking
        /// Browses walking workouts even when they are excluded, so a run the Watch mislabelled
        /// as a walk can still be found and corrected.
        case walks
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .all: return "All"
            case .logged: return "Logged"
            case .unlogged: return "Unlogged"
            case .running: return "Running"
            case .walking: return "Walking"
            case .walks: return "Walks"
            }
        }
    }

    private var filtered: [HealthKitManager.WorkoutSummary] {
        // "Walks" reads a different list entirely: walking workouts the main list excludes.
        if filter == .walks { return logger.walkingWorkouts }

        return logger.recentWorkouts.filter { workout in
            switch filter {
            case .all: return true
            case .logged: return logger.loggedWorkoutUUIDs.contains(workout.uuid)
            case .unlogged: return !logger.loggedWorkoutUUIDs.contains(workout.uuid)
            case .running: return workout.activityType == .running
            case .walking: return workout.activityType == .walking
            case .walks: return false   // handled above
            }
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Filter", selection: $filter) {
                    ForEach(availableFilters) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: defaults.includeWalkingWorkouts) { _, _ in
                    // A hidden filter must not stay selected, or the list silently shows nothing.
                    if !availableFilters.contains(filter) { filter = .all }
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))

            if filter == .walks {
                Section {
                    Text("Walking workouts are excluded from the app and the export. If one of "
                         + "these was really a run/walk session the Watch recorded as "
                         + "\"Outdoor Walk\", open it and tap \"This was really a run\".")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if filtered.isEmpty {
                Section {
                    Text(logger.isLoading ? "Reading Health…" : "Nothing matches this filter.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(filtered) { workout in
                    NavigationLink {
                        WorkoutDetailView(workout: workout, logger: logger)
                    } label: {
                        HistoryRow(workout: workout, log: logger.runLog(forWorkout: workout.uuid),
                                   logger: logger)
                    }
                }
            }
        }
        .navigationTitle("History")
        .refreshable { await logger.refresh() }
        .task { if logger.recentWorkouts.isEmpty { await logger.refresh() } }
        .task(id: filter) {
            if filter == .walks { await logger.loadWalkingWorkouts() }
        }
    }
}

private struct HistoryRow: View {
    let workout: HealthKitManager.WorkoutSummary
    let log: RunLog?
    let logger: RunLoggerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(Display.dayFormatter.string(from: workout.startDate))
                    .font(.headline)
                Spacer()
                Text(Display.miles(workout.distanceMiles))
                    .font(.subheadline.monospacedDigit())
            }

            if let log {
                if let run = log.runIntervalSeconds, let walk = log.walkIntervalSeconds,
                   let reps = log.plannedRepetitions {
                    Text("\(PlannedWorkout.compactDuration(run))/\(PlannedWorkout.compactDuration(walk)) × \(reps)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Text("RPE \(Display.rating(log.effortRPE))")
                    Text("Heat \(Display.rating(log.personalHeatRating))")
                    // No shoe: hidden 2026-10-01 with the rest of the shoe UI (docs/BACKLOG.md,
                    // "Hide shoes for now"). New logs still record one, so leaving this would show
                    // shoes here and nowhere else.
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Not logged")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// Everything known about one workout, objective and subjective kept visually separate.
struct WorkoutDetailView: View {
    let workout: HealthKitManager.WorkoutSummary
    let logger: RunLoggerModel

    @Environment(LoggerDefaults.self) private var defaults
    @State private var showLogSheet = false
    @State private var showRecoverySheet = false

    // Both read `logger.storeRevision` first, and that read is the only reason this screen updates
    // after a save. The fetches below are invisible to Observation, so without it a log saved from
    // the sheet left this screen still showing "Not logged yet." and a "Log this run" button —
    // with nothing to indicate the save had in fact worked.
    private var log: RunLog? {
        _ = logger.storeRevision
        return logger.runLog(forWorkout: workout.uuid)
    }
    private var recovery: RecoveryLog? {
        _ = logger.storeRevision
        return logger.recoveryLog(forWorkout: workout.uuid)
    }

    var body: some View {
        List {
            classificationSection

            Section("Apple Health") {
                LabeledContent("Start", value: Display.dayAndTime(workout.startDate))
                LabeledContent("Activity",
                               value: workout.recordedActivityType.displayName)
                LabeledContent("Distance", value: Display.miles(workout.distanceMiles))
                LabeledContent("Total duration", value: Display.duration(workout.duration))
                LabeledContent("Pace", value: Display.pace(workout.paceSecondsPerMile))
                LabeledContent("Avg HR", value: Display.heartRate(workout.averageHeartRate))
                LabeledContent("Peak HR", value: Display.heartRate(workout.peakHeartRate))
                weatherRows
                LabeledContent("Source", value: workout.sourceName)
            }

            intervalSection
            notesSection
            linkIntervalsSection
            logSection
            recoverySection
        }
        .navigationTitle(Display.relativeDay(workout.startDate))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLogSheet) {
            NavigationStack { RunLogFormView(workout: workout, logger: logger) }
        }
        // This screen had no alert at all, so anything written to `logger.errorMessage` from here —
        // including the notice that a run's intervals were left unattached — was displayed only by
        // HomeView, and saving from History reported nothing whatsoever.
        .alert("Something went wrong",
               isPresented: Binding(get: { logger.errorMessage != nil },
                                    set: { if !$0 { logger.errorMessage = nil } }),
               actions: { Button("OK", role: .cancel) { logger.errorMessage = nil } },
               message: { Text(logger.errorMessage ?? "") })
        .sheet(isPresented: $showRecoverySheet) {
            NavigationStack { RecoveryLogView(workout: workout, logger: logger) }
        }
    }

    /// Weather, or an explanation of why there is none.
    ///
    /// A bare "—" is ambiguous: it reads as a bug whether or not one exists. Apple only records
    /// weather for some outdoor workouts, so absence is usually normal — but the user should be
    /// able to tell that apart from a failure to read it.
    @ViewBuilder
    private var weatherRows: some View {
        if workout.hasWeatherMetadata {
            LabeledContent("Temperature", value: Display.temperature(workout.temperatureFahrenheit))
            LabeledContent("Humidity", value: Display.humidity(workout.humidityPercent))
        } else {
            LabeledContent("Weather", value: "Not recorded")
                .foregroundStyle(.secondary)
            Text(weatherAbsenceExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var weatherAbsenceExplanation: String {
        if workout.isIndoor == true {
            return "This workout is marked as indoor, so Apple recorded no weather for it."
        }
        if workout.metadataKeys.isEmpty {
            return "Apple stored no metadata at all with this workout, so there is no weather to "
                + "read. This is common for workouts not recorded by an Apple Watch."
        }
        return "Apple Watch records weather only for some outdoor workouts — it needs a weather "
            + "fetch at the time. This workout has \(workout.metadataKeys.count) other metadata "
            + "field(s) but no weather ones. Nothing was lost in reading it."
    }

    /// Lets a run the Watch recorded as a walk be treated as a run everywhere in this app.
    @ViewBuilder
    private var classificationSection: some View {
        if workout.recordedActivityType == .walking {
            Section {
                if isReclassified {
                    Label("Treated as a run", systemImage: "figure.run")
                        .foregroundStyle(.green)
                    Button("Treat as a walk again") {
                        Task { await setReclassified(false) }
                    }
                } else {
                    Button {
                        Task { await setReclassified(true) }
                    } label: {
                        Label("This was really a run", systemImage: "figure.run")
                    }
                }
            } header: {
                Text("Activity type")
            } footer: {
                Text("Apple Health recorded this as a walk, and that cannot be changed — a "
                     + "workout is immutable and this app never writes to Health. Marking it here "
                     + "makes this app treat it as a run: it appears in your logs and exports, "
                     + "with the original type preserved and a reclassifiedAsRunning column "
                     + "recording the change.")
            }
        }
    }

    private var isReclassified: Bool { logger.isReclassifiedAsRunning(workout.uuid) }

    private func setReclassified(_ value: Bool) async {
        await logger.setReclassifiedAsRunning(value, for: workout.uuid)
    }

    /// Notes typed while the run was happening.
    ///
    /// Kept separate from the run log's own notes field on purpose: one describes a moment, the
    /// other describes the run. Flattening them together would throw away the timing, which is
    /// most of what makes a mid-run observation worth having.
    ///
    /// The execution is resolved from the workout when there is no run log to name it.
    ///
    /// `reconcilePendingCaptures` stamps notes with their workout on every refresh, so this is not
    /// the normal path — it covers the case the sweep structurally cannot reach. That sweep only
    /// considers `unloggedWorkouts`, which `recomputeUnlogged()` filters to the last
    /// `unloggedPromptDays` (7 by default), so a run that was noted, never logged, and left for a
    /// week drops out of the candidate list for good. Its notes stay keyed to the execution, and
    /// without this they would be invisible here while sitting safely in the store.
    ///
    /// It also covers the window between finishing a run and the first refresh that sees the
    /// Watch's workout, when nothing carries the workout UUID yet.
    @ViewBuilder
    private var notesSection: some View {
        let executionID = log?.executionID ?? logger.execution(forWorkout: workout)
        let notes = logger.notes(forWorkout: workout.uuid, executionID: executionID)
        if !notes.isEmpty {
            Section {
                ForEach(notes) { note in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.text)
                        Text(note.contextSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Notes taken during this workout")
            } footer: {
                Text("Each one is filed under the phase it was written in. These are separate from "
                     + "the notes on the run log below, which describe the run as a whole.")
            }
        }
    }

    @ViewBuilder
    private var intervalSection: some View {
        let intervals = logger.intervalLogs(forWorkout: workout.uuid, executionID: log?.executionID)
        if !intervals.isEmpty {
            Section {
                ForEach(intervals) { interval in
                    HStack {
                        Text(interval.phaseTypeValue?.displayName ?? "⚠︎ \(interval.phaseType)")
                        if let repetition = interval.repetitionNumber {
                            Text("#\(repetition)").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Display.duration(interval.actualDurationSeconds))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if interval.wasSkipped {
                            Image(systemName: "forward.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if interval.wasInterrupted {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.subheadline)
                }
            } header: {
                Text("Intervals recorded by this app")
            } footer: {
                Text(intervalFooter(intervals))
            }
        }
    }

    /// Offered only when the app genuinely could not tell which timer session produced this run.
    ///
    /// The matcher is right to refuse a tiebreak — intervals stamped onto the wrong run are wrong
    /// permanently and nothing on screen would ever say so. But refusing and then offering no way
    /// forward made an ambiguous run unlinkable for good. The user knows which run they did; this is
    /// where they say it. Spec §14 priority 6, which existed for the forward direction only.
    ///
    /// Renders nothing when `executionChoices` is empty, which covers both "the app is confident"
    /// and "nothing is plausible". An empty picker would imply a choice that isn't there.
    @ViewBuilder
    private var linkIntervalsSection: some View {
        let choices = logger.executionChoices(for: workout)
        if !choices.isEmpty {
            Section {
                ForEach(choices) { choice in
                    Button {
                        logger.linkIntervals(ofExecution: choice.id, to: workout)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Display.dayAndTime(choice.startedAt))
                                .font(.headline)
                            Text(choiceDetail(choice))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Which timer session was this run?")
            } footer: {
                Text("More than one timer session overlaps this run closely enough that the app "
                     + "will not choose for you — attaching these intervals to the wrong run could "
                     + "not be undone. Pick the session you actually ran.")
            }
        }
    }

    private func choiceDetail(_ choice: RunLoggerModel.ExecutionChoice) -> String {
        let plan: String = choice.planName
        let intervals: String = choice.intervalCount == 1
            ? "1 interval"
            : "\(choice.intervalCount) intervals"
        guard let ended = choice.endedAt else {
            // Worth saying plainly: a session with no end is one that was never stopped, which is
            // exactly why it is still in contention.
            return plan + " · " + intervals + " · never stopped"
        }
        let ran: String = Display.duration(ended.timeIntervalSince(choice.startedAt))
        return plan + " · " + intervals + " · ran " + ran
    }

    private func intervalFooter(_ intervals: [WorkoutIntervalLog]) -> String {
        let mainSet = intervals
            .filter { $0.phaseTypeValue?.isMainSet == true }
            .reduce(0) { $0 + $1.actualDurationSeconds }
        let cooldown = intervals
            .filter { $0.phaseTypeValue == .cooldown }
            .reduce(0) { $0 + $1.actualDurationSeconds }
        return "Main set \(Display.duration(mainSet)) · cooldown \(Display.duration(cooldown)). "
            + "Cooldown is never counted in the main set."
    }

    @ViewBuilder
    private var logSection: some View {
        Section {
            if let log {
                LabeledContent("Effort RPE", value: Display.rating(log.effortRPE))
                LabeledContent("Personal heat", value: Display.rating(log.personalHeatRating))
                ForEach(BodyArea.allCases) { area in
                    LabeledContent(area.displayName, value: Display.rating(log.severity(for: area)))
                }
                // No Shoe row: hidden 2026-10-01 (docs/BACKLOG.md, "Hide shoes for now"). The value
                // is still recorded and still in the export; only the display is gone.
                if let notes = log.notes, !notes.isEmpty {
                    Text(notes).font(.callout)
                }
                Button("Edit log") { showLogSheet = true }
            } else {
                Text("Not logged yet.").foregroundStyle(.secondary)
                Button("Log this run") { showLogSheet = true }
            }
        } header: {
            Text("Your log")
        } footer: {
            Text("Subjective values you entered. Kept separate from the Health data above.")
        }
    }

    @ViewBuilder
    private var recoverySection: some View {
        if defaults.showRecoveryPrompt {
            Section("Next-day recovery") {
                if let recovery {
                    LabeledContent("Recovery", value: Display.rating(recovery.recoveryRating))
                    Button("Edit recovery") { showRecoverySheet = true }
                } else {
                    Button("Add recovery note") { showRecoverySheet = true }
                }
            }
        }
    }
}
