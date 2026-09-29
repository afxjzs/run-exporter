import SwiftUI

/// The post-run log (spec §15).
///
/// Ordered for speed, not for completeness: the two required ratings are first, everything else is
/// already filled in or optional. The objective section is read-only — it is Apple's data, and
/// mixing it with the fields the user types would blur exactly the line the export keeps sharp.
struct RunLogFormView: View {
    @Environment(LoggerDefaults.self) private var defaults
    @Environment(\.dismiss) private var dismiss

    let workout: HealthKitManager.WorkoutSummary
    let logger: RunLoggerModel
    /// Pre-fill from the timer session that produced this workout, when there was one.
    var context: (plannedWorkoutID: UUID?, executionID: UUID?,
                  run: Int?, walk: Int?, planned: Int?, completed: Int?)?

    @State private var draft: RunLogDraft?
    @State private var errorMessage: String?
    @State private var isEditingExisting = false

    var body: some View {
        Form {
            objectiveSection

            if let binding = draftBinding {
                requiredSection(binding)
                if defaults.showBodySignals { bodySignalSection(binding) }
                shoeSection(binding)
                notesSection(binding)
            }
        }
        .navigationTitle(isEditingExisting ? "Edit Run Log" : "Log Run")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(draft?.isComplete != true)
                    .fontWeight(.semibold)
            }
        }
        .onAppear(perform: loadDraft)
        .alert("Could not save",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } }),
               actions: { Button("OK", role: .cancel) { errorMessage = nil } },
               message: { Text(errorMessage ?? "") })
    }

    private var draftBinding: Binding<RunLogDraft>? {
        guard draft != nil else { return nil }
        return Binding(get: { draft ?? RunLogDraft(shoeID: nil) },
                       set: { draft = $0 })
    }

    // MARK: - Objective (read-only)

    private var objectiveSection: some View {
        Section {
            LabeledContent("Date", value: Display.dayAndTime(workout.startDate))
            LabeledContent("Activity", value: workout.activityType.displayName)
            LabeledContent("Distance", value: Display.miles(workout.distanceMiles))
            LabeledContent("Duration", value: Display.duration(workout.duration))
            LabeledContent("Pace", value: Display.pace(workout.paceSecondsPerMile))
            LabeledContent("Avg HR", value: Display.heartRate(workout.averageHeartRate))
            LabeledContent("Peak HR", value: Display.heartRate(workout.peakHeartRate))
            LabeledContent("Weather", value: weatherSummary)
            if let plan = plannedSummary {
                LabeledContent("Plan", value: plan)
            }
        } header: {
            Text("From Apple Health")
        } footer: {
            Text("Recorded by \(workout.sourceName). These values are not editable here.")
        }
    }

    /// Apple's recorded weather, or a plain statement that there is none — never a bare dash,
    /// which reads as a fault. The heat rating below is asked for either way; it is the user's
    /// own perception and does not depend on this.
    private var weatherSummary: String {
        guard workout.hasWeatherMetadata else { return "Not recorded" }
        return "\(Display.temperature(workout.temperatureFahrenheit)) · "
            + Display.humidity(workout.humidityPercent)
    }

    private var plannedSummary: String? {
        guard let context, let run = context.run else { return nil }
        let walk = context.walk ?? 0
        let reps = context.planned ?? 0
        let completed = context.completed ?? 0
        let shape = walk > 0
            ? "\(PlannedWorkout.compactDuration(run))/\(PlannedWorkout.compactDuration(walk)) × \(reps)"
            : "\(PlannedWorkout.compactDuration(run)) continuous"
        return "\(shape) · \(completed) completed"
    }

    // MARK: - Required

    private func requiredSection(_ draft: Binding<RunLogDraft>) -> some View {
        Section {
            HalfPointRatingPicker(title: "Effort (RPE)",
                                  lowLabel: "1 · extremely easy",
                                  highLabel: "10 · maximum effort",
                                  value: draft.effortRPE)

            HalfPointRatingPicker(title: "How hot did it feel to you?",
                                  lowLabel: "1 · felt cold",
                                  highLabel: "10 · severely overheated",
                                  value: draft.personalHeatRating)
        } header: {
            Text("Required")
        } footer: {
            if defaults.showScaleExplanations {
                Text("Heat rating is your own perception — 5 is thermally neutral. It is stored "
                     + "separately from the recorded weather above, and the two are expected to "
                     + "disagree.")
            }
        }
    }

    // MARK: - Body signals

    private func bodySignalSection(_ draft: Binding<RunLogDraft>) -> some View {
        Section {
            ForEach(BodyArea.allCases) { area in
                BodySignalRow(area: area,
                              value: Binding(
                                get: { draft.wrappedValue.severity(for: area) },
                                set: { draft.wrappedValue.severities[area] = $0 }))
            }
        } header: {
            Text("Body signals")
        } footer: {
            Text("0 means nothing felt wrong. Leave them at 0 if there is nothing to report.")
        }
    }

    // MARK: - Shoe

    private func shoeSection(_ draft: Binding<RunLogDraft>) -> some View {
        Section("Shoes") {
            let shoes = logger.shoes()
            if shoes.isEmpty {
                Text("No shoes yet. Add one from Today › Shoes.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Shoe", selection: draft.shoeID) {
                    Text("None").tag(UUID?.none)
                    ForEach(shoes) { shoe in
                        Text(shoe.displayName).tag(UUID?.some(shoe.id))
                    }
                }
            }
        }
    }

    private func notesSection(_ draft: Binding<RunLogDraft>) -> some View {
        Section("Notes") {
            TextField("Anything worth remembering", text: draft.notes, axis: .vertical)
                .lineLimit(3...8)
        }
    }

    // MARK: - Loading and saving

    private func loadDraft() {
        guard draft == nil else { return }

        if let existing = logger.runLog(forWorkout: workout.uuid) {
            draft = RunLogDraft(log: existing)
            isEditingExisting = true
            return
        }

        // A log written during the workout has no `healthKitWorkoutUUID`, so the lookup above cannot
        // see it however complete it is. Without this the form opened blank over the user's own
        // cooldown notes, and saving it wrote those notes back as nil — silently, since `save` reuses
        // the very log the empty draft is about to overwrite. `RunLogDraft(log:)` carries the
        // `executionID` across, so saving continues to update that log rather than adding a second.
        if let pending = logger.pendingLog(forWorkout: workout) {
            draft = RunLogDraft(log: pending)
            isEditingExisting = true
            return
        }

        var fresh = RunLogDraft(shoeID: logger.defaultShoe()?.id)
        if let context {
            fresh.plannedWorkoutID = context.plannedWorkoutID
            fresh.executionID = context.executionID
            fresh.runIntervalSeconds = context.run
            fresh.walkIntervalSeconds = context.walk
            fresh.plannedRepetitions = context.planned
            fresh.completedRepetitions = context.completed
        }
        draft = fresh
    }

    private func save() {
        guard let draft else { return }
        if let error = logger.save(draft: draft, for: workout) {
            errorMessage = error
            return
        }
        dismiss()
    }
}

/// The next-day recovery prompt (spec §17). Deliberately tiny and entirely optional.
struct RecoveryLogView: View {
    @Environment(\.dismiss) private var dismiss

    let workout: HealthKitManager.WorkoutSummary
    let logger: RunLoggerModel

    @State private var rating: Double?
    @State private var severities: [BodyArea: Double] = [:]
    @State private var notes = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                HalfPointRatingPicker(title: "Recovery today",
                                      lowLabel: "1 · severely affected",
                                      highLabel: "10 · completely recovered",
                                      value: $rating)
            } footer: {
                Text("10 means today is indistinguishable from a day you did not run.")
            }

            Section("Lingering signals") {
                ForEach(BodyArea.allCases) { area in
                    BodySignalRow(area: area,
                                  value: Binding(get: { severities[area] ?? 0 },
                                                 set: { severities[area] = $0 }))
                }
            }

            Section("Notes") {
                TextField("Optional", text: $notes, axis: .vertical).lineLimit(2...6)
            }
        }
        .navigationTitle("Recovery")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(rating == nil)
            }
        }
        .onAppear {
            guard severities.isEmpty else { return }
            if let existing = logger.recoveryLog(forWorkout: workout.uuid) {
                rating = existing.recoveryRating
                for area in BodyArea.allCases { severities[area] = existing.severity(for: area) }
                notes = existing.notes ?? ""
            } else {
                for area in BodyArea.allCases { severities[area] = 0 }
            }
        }
        .alert("Could not save",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } }),
               actions: { Button("OK", role: .cancel) { errorMessage = nil } },
               message: { Text(errorMessage ?? "") })
    }

    private func save() {
        guard let rating else { return }
        if let error = logger.saveRecovery(rating: rating,
                                           severities: severities,
                                           notes: notes,
                                           for: workout.uuid) {
            errorMessage = error
            return
        }
        dismiss()
    }
}
