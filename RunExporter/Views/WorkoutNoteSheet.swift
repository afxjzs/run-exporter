import SwiftUI

/// Captures one free-text note in the middle of a workout.
///
/// Built for a 60-second walk break with the phone at arm's length: the field is focused the moment
/// the sheet opens, so the first thumb press types rather than aims, and Save is the only decision.
/// Nothing here touches the interval engine or the audio session — the timer keeps running and the
/// cues keep sounding behind the sheet.
///
/// The text is written through to `LoggerDefaults` on every keystroke. That draft is not logged
/// data and never reaches the export; it exists so that text not yet committed survives the app
/// being killed mid-sentence, which is the one way a locked screen can actually lose it.
struct WorkoutNoteSheet: View {
    @Environment(LoggerDefaults.self) private var defaults
    @Environment(\.dismiss) private var dismiss

    let logger: RunLoggerModel
    let executionID: UUID
    let context: ActiveWorkoutModel.NoteContext
    /// Writes the note. Returns an error message, or nil on success.
    let save: (String) -> String?

    @State private var text = ""
    @State private var errorMessage: String?
    /// Whether the field was populated from an interrupted draft rather than typed in this sitting.
    /// Recorded at open: comparing the text to the stored draft would be true of anything typed
    /// since, because every keystroke is written through to it.
    @State private var restoredDraft = false
    @FocusState private var isTyping: Bool

    var body: some View {
        Form {
            Section {
                TextField("How does it feel right now?", text: $text, axis: .vertical)
                    .lineLimit(4...10)
                    .focused($isTyping)
                    .font(.title3)
                    .onChange(of: text) { _, updated in
                        defaults.setNoteDraft(updated, forExecution: executionID)
                    }
            } header: {
                Label(contextTitle, systemImage: "mappin.and.ellipse")
            } footer: {
                Text(contextFootnote)
            }

            previousNotesSection
        }
        .navigationTitle("Note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { commit() }
                    .disabled(isBlank)
                    .fontWeight(.semibold)
            }
        }
        .onAppear {
            // A draft only exists if a previous attempt was interrupted, so restoring it silently
            // would be the wrong kind of quiet — the footer below says where the text came from.
            text = defaults.noteDraft(forExecution: executionID)
            restoredDraft = !text.isEmpty
            isTyping = true
        }
        .alert("Could not save this note",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } }),
               actions: { Button("OK", role: .cancel) { errorMessage = nil } },
               message: { Text(errorMessage ?? "") })
    }

    // Strings are built in separate properties rather than inline. This project's SwiftUI
    // type-checker gives up on interpolation mixed with concatenation inside a view initialiser,
    // and it fails the Release build rather than warning.

    private var isBlank: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Where the workout was when this sheet opened — which is what the note will be filed under.
    private var contextTitle: String {
        let elapsed = Display.duration(context.secondsIntoWorkout)
        guard let repetition = context.repetition else {
            return "\(context.phase.displayName) · \(elapsed) elapsed"
        }
        return "\(context.phase.displayName) · round \(repetition) · \(elapsed) elapsed"
    }

    private var contextFootnote: String {
        if restoredDraft {
            return "This is text you had started and never saved, restored from before. It will "
                + "be filed under where the workout is now, not where it was when you began it."
        }
        return "Filed under where the workout was when you opened this note, so a thought about "
            + "this walk stays attached to this walk even if it ends while you type."
    }

    /// Notes already written in this workout.
    ///
    /// Shown for two reasons: so a thought is not written twice, and so a save is visibly a save.
    /// A capture surface that swallows the text and shows nothing back is indistinguishable from
    /// one that dropped it.
    @ViewBuilder
    private var previousNotesSection: some View {
        let existing = logger.notes(forExecution: executionID)
        if !existing.isEmpty {
            Section("Already noted this workout") {
                ForEach(existing) { note in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.text)
                        Text(note.contextSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func commit() {
        if let error = save(text) {
            errorMessage = error
            return
        }
        // Cleared only after the store has confirmed the write. Clearing first would turn a failed
        // save into a lost note.
        defaults.clearNoteDraft(forExecution: executionID)
        dismiss()
    }
}
