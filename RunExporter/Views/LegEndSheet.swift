import SwiftUI

/// Annotates the running leg that has **just ended**, in an open-interval workout.
///
/// The leg is already over before this appears: the tap ended it, the walk cue has sounded and the
/// walk's clock is running. That ordering is the point. The runner starts walking when they press
/// the button, so the leg's recorded length has to stop there too — ending it on this sheet's Done
/// button instead added however long the rating took onto the leg, which is the one number the
/// workout exists to measure.
///
/// Everything here is therefore optional. Dismissing records nothing and costs nothing.
///
/// Every body area is offered rather than one the plan nominated. A leg that ended because of one
/// area is as much a measurement as one that ended because of another, and asking about all five
/// costs nothing when four of them stay at zero.
struct LegEndSheet: View {

    @Environment(\.dismiss) private var dismiss

    let context: ActiveWorkoutModel.LegEndContext
    let logger: RunLoggerModel
    let model: ActiveWorkoutModel

    /// Every area starts at zero, exactly as the post-run log's rows do, where zero is a real answer
    /// meaning nothing felt wrong. `canSave` still requires *something* before writing, so tapping
    /// Done without looking cannot file five measurements the runner never made.
    @State private var readings: [BodyArea: Double] = Dictionary(
        uniqueKeysWithValues: BodyArea.allCases.map { ($0, 0) })
    @State private var note = ""
    @State private var errorMessage: String?

    private var hasReading: Bool { readings.values.contains { $0 > 0 } }

    /// A note counts. A leg can end for a reason that is not pain — needing the bathroom, a
    /// traffic light, a shoelace — and in that case the note *is* the data. Requiring a non-zero
    /// severity would have forced the runner to invent one or record nothing.
    private var canSave: Bool {
        hasReading || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var legLabel: String {
        let elapsed = Display.duration(context.legSeconds)
        guard let number = context.legNumber else { return "Leg · \(elapsed)" }
        return "Leg \(number) · \(elapsed)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(legLabel)
                        .font(.headline)
                        .monospacedDigit()
                }

                Section {
                    ForEach(BodyArea.allCases) { area in
                        BodySignalRow(area: area, value: binding(for: area))
                    }
                } header: {
                    Text("How does it feel?")
                } footer: {
                    Text(hasReading
                         ? "Everything you leave at zero is recorded as nothing, which is an answer."
                         : "Set one above zero, or write a note. Saving five zeros nobody looked "
                           + "at would put five measurements in your data that you never made.")
                }

                Section("Note") {
                    TextField("Why you stopped, or anything else", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                }
            }
            .navigationTitle("Leg recorded")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Not "Cancel": the leg is recorded either way, and nothing here is undone by
                    // leaving. Only the annotation is skipped.
                    Button("Nothing to add") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .alert("Something went wrong",
                   isPresented: Binding(get: { errorMessage != nil },
                                        set: { if !$0 { errorMessage = nil } }),
                   actions: { Button("OK", role: .cancel) { dismiss() } },
                   message: { Text(errorMessage ?? "") })
        }
    }

    private func binding(for area: BodyArea) -> Binding<Double> {
        Binding(get: { readings[area] ?? 0 },
                set: { readings[area] = $0 })
    }

    /// Attaches the readings to the leg already recorded, then files the note.
    ///
    /// Readings only when one is above zero: otherwise five zeros nobody set would be written as
    /// measurements. A note-only save leaves them blank, which is the honest reading of "the runner
    /// told us why, and it was not pain".
    private func save() {
        if hasReading {
            var signals = BodySignalReadings()
            for area in BodyArea.allCases { signals[area] = readings[area] ?? 0 }
            if let error = model.recordLegReadings(signals) {
                errorMessage = error
                return
            }
        }

        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            dismiss()
            return
        }

        let noteContext = ActiveWorkoutModel.NoteContext(phase: .run,
                                                        repetition: context.legNumber,
                                                        secondsIntoWorkout: model.engine
                                                            .elapsedWorkoutSeconds,
                                                        takenAt: context.endedAt)
        if let error = model.saveNote(text, context: noteContext, logger: logger) {
            errorMessage = error
            return
        }
        dismiss()
    }
}
