import SwiftUI

/// A plan's kind in its editor. Shared by both plan editors so they cannot come to ask it
/// differently.
///
/// It starts unchosen on a new plan, with no default, and the editors keep Save disabled until a
/// kind is picked. The owner asked for that: a default would let a run be filed under the wrong
/// kind without anyone deciding it.
struct RunKindSection: View {
    @Binding var kind: RunKind?

    var body: some View {
        Section {
            Picker("Kind", selection: $kind) {
                // Offered only while nothing is chosen, so it cannot be chosen back.
                if kind == nil {
                    Text("Choose").tag(RunKind?.none)
                }
                ForEach(RunKind.allCases) { option in
                    Text(option.displayName).tag(RunKind?.some(option))
                }
            }
        } header: {
            Text("Kind")
        } footer: {
            Text("Required. History compares runs of the same kind.")
        }
    }
}

/// Asks for a kind when a plan without one is started, saves it on the plan, then starts.
///
/// Plans made before kinds existed, and plans a preset made in one tap, have none. Asking here
/// means every new run has a kind, and each such plan is asked once.
struct RunKindQuestion: ViewModifier {
    /// The plan waiting for a kind. Set it to ask; it is cleared when the question closes.
    @Binding var plan: PlannedWorkout?
    /// Called with the plan once its kind is saved.
    let onChosen: (PlannedWorkout) -> Void

    @Environment(LoggerStore.self) private var store
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog("What kind of run is this?",
                                isPresented: Binding(get: { plan != nil },
                                                     set: { if !$0 { plan = nil } }),
                                titleVisibility: .visible,
                                presenting: plan) { waiting in
                ForEach(RunKind.allCases) { kind in
                    Button(kind.displayName) { choose(kind, for: waiting) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Saved on this plan, so you're only asked once.")
            }
            .alert("Something went wrong",
                   isPresented: Binding(get: { errorMessage != nil },
                                        set: { if !$0 { errorMessage = nil } }),
                   actions: { Button("OK", role: .cancel) { errorMessage = nil } },
                   message: { Text(errorMessage ?? "") })
    }

    /// The run does not start if the kind cannot be saved: it would start without one, which is
    /// what asking exists to prevent.
    private func choose(_ kind: RunKind, for waiting: PlannedWorkout) {
        waiting.runKind = kind.rawValue
        waiting.updatedAt = Date()
        if let error = store.save() {
            errorMessage = "The run's kind could not be saved, so it did not start. " + error
            return
        }
        onChosen(waiting)
    }
}

extension View {
    func askingForRunKind(_ plan: Binding<PlannedWorkout?>,
                          then onChosen: @escaping (PlannedWorkout) -> Void) -> some View {
        modifier(RunKindQuestion(plan: plan, onChosen: onChosen))
    }
}
