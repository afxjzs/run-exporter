import SwiftUI

/// Logs how the run felt **during** the workout, before the HealthKit workout exists.
///
/// The objective section is deliberately absent: distance, pace and heart rate are not known
/// until the Watch finishes and HealthKit receives the workout. Only the subjective fields are
/// asked for here, and they are attached to the workout automatically once it arrives.
struct EarlyRunLogView: View {
    @Environment(LoggerDefaults.self) private var defaults
    @Environment(\.dismiss) private var dismiss

    let logger: RunLoggerModel
    let executionID: UUID
    let startedAt: Date
    let activityType: PlannedActivityType
    /// True when the workout has already finished and no HealthKit workout was found — the copy
    /// must not talk about a cooldown that is over, or promise data that may never arrive.
    var isAfterWorkout = false
    var context: (plannedWorkoutID: UUID?, executionID: UUID?,
                  run: Int?, walk: Int?, planned: Int?, completed: Int?)?

    @State private var draft: RunLogDraft?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Label(headerTitle, systemImage: headerSymbol)
                    .font(.subheadline)
                if let summary = plannedSummary {
                    LabeledContent("Workout", value: summary)
                }
            } footer: {
                Text(headerFootnote)
            }

            if let binding = draftBinding {
                Section {
                    HalfPointRatingPicker(title: "Effort (RPE)",
                                          lowLabel: "1 · extremely easy",
                                          highLabel: "10 · maximum effort",
                                          value: binding.effortRPE)
                    HalfPointRatingPicker(title: "How hot did it feel to you?",
                                          lowLabel: "1 · felt cold",
                                          highLabel: "10 · severely overheated",
                                          value: binding.personalHeatRating)
                } header: {
                    Text("Required")
                }

                if defaults.showBodySignals {
                    Section("Body signals") {
                        ForEach(BodyArea.allCases) { area in
                            BodySignalRow(area: area,
                                          value: Binding(
                                            get: { binding.wrappedValue.severity(for: area) },
                                            set: { binding.wrappedValue.severities[area] = $0 }))
                        }
                    }
                }

                Section("Shoes") {
                    let shoes = logger.shoes()
                    if shoes.isEmpty {
                        Text("No shoes yet.").foregroundStyle(.secondary)
                    } else {
                        Picker("Shoe", selection: binding.shoeID) {
                            Text("None").tag(UUID?.none)
                            ForEach(shoes) { shoe in
                                Text(shoe.displayName).tag(UUID?.some(shoe.id))
                            }
                        }
                    }
                }

                Section("Notes") {
                    TextField("Anything worth remembering", text: binding.notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
        }
        .navigationTitle("Log Run")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
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

    // Broken out of the view body: inline ternaries here pushed the SwiftUI type-checker past its
    // time limit, which fails the build outright rather than degrading.

    private var headerTitle: String {
        isAfterWorkout ? "No Apple Watch workout" : "Logging during your cooldown"
    }

    private var headerSymbol: String {
        isAfterWorkout ? "applewatch.slash" : "clock.badge.checkmark"
    }

    private var headerFootnote: String {
        if isAfterWorkout {
            return "Nothing was found in Apple Health to attach this to, so it will be saved with "
                + "your intervals but without distance, pace or heart rate. If a Watch workout "
                + "turns up later you can log that one too."
        }
        return "Distance, pace and heart rate are added automatically when the workout arrives "
            + "from your Watch. Log how it felt now, while it is fresh."
    }

    private var draftBinding: Binding<RunLogDraft>? {
        guard draft != nil else { return nil }
        return Binding(get: { draft ?? RunLogDraft(shoeID: nil) }, set: { draft = $0 })
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

    private func loadDraft() {
        guard draft == nil else { return }

        // Re-opening during the same cooldown must edit the existing log, not start a second one.
        if let existing = logger.pendingLog(forExecution: executionID) {
            draft = RunLogDraft(log: existing)
            return
        }

        var fresh = RunLogDraft(shoeID: logger.defaultShoe()?.id)
        fresh.executionID = executionID
        if let context {
            fresh.plannedWorkoutID = context.plannedWorkoutID
            fresh.runIntervalSeconds = context.run
            fresh.walkIntervalSeconds = context.walk
            fresh.plannedRepetitions = context.planned
            fresh.completedRepetitions = context.completed
        }
        draft = fresh
    }

    private func save() {
        guard let draft else { return }
        if let error = logger.saveDuringWorkout(draft: draft,
                                                executionID: executionID,
                                                startedAt: startedAt,
                                                activityType: activityType) {
            errorMessage = error
            return
        }
        dismiss()
    }
}
