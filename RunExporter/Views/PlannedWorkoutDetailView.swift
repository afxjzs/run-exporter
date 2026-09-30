import SwiftUI
import SwiftData

/// One plan, with the actions the spec's workout card calls for (§5.2): start, mark as next, edit,
/// duplicate, delete. The spec's "send to Watch" was removed in the 2026-09-29 clean-out — Start
/// launches the watch workout itself.
///
/// Start is here as well as on Today because Today only offers whatever it considers the next
/// workout, and this is where any other plan can be run.
struct PlannedWorkoutDetailView: View {
    @Environment(LoggerStore.self) private var store
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var allPlans: [PlannedWorkout]

    let plan: PlannedWorkout
    let logger: RunLoggerModel

    @State private var showingTimer = false
    @State private var errorMessage: String?
    @State private var didDelete = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        List {
            Section { PlannedWorkoutCard(plan: plan) }

            Section {
                Button {
                    showingTimer = true
                } label: {
                    Label("Start Workout", systemImage: "play.circle.fill")
                        .font(.headline)
                }
            }

            Section {
                if plan.isNextWorkout {
                    Label("This is your next workout", systemImage: "star.fill")
                        .foregroundStyle(.orange)
                } else {
                    Button {
                        markAsNext()
                    } label: {
                        Label("Make this the next workout", systemImage: "star")
                    }
                }

                // Routed by kind. Opening an open-interval plan in the block editor would be worse
                // than a wrong screen: that editor writes an ordered list of blocks on save, so it
                // would quietly turn this plan into an interval one while its open-interval record
                // sat there unread.
                NavigationLink {
                    if plan.isOpenIntervals {
                        OpenIntervalPlanEditorView(plan: plan)
                    } else {
                        PlannedWorkoutEditorView(plan: plan)
                    }
                } label: {
                    Label("Edit", systemImage: "pencil")
                }

                Button {
                    duplicate()
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
            }

            Section {
                // "Delete plan", not "Delete workout": this deletes the plan you built, and cannot
                // touch the HealthKit workout a run produced — only the Health app can do that.
                // The old label invited exactly that misreading.
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete plan", systemImage: "trash")
                }
            }
        }
        .navigationTitle(plan.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showingTimer) {
            ActiveWorkoutView(plan: plan, logger: logger)
        }
        // `role: .destructive` only colors the button; it prompts for nothing. This delete is
        // irreversible, so it gets a real confirmation — the same treatment "End this workout?"
        // already gets for a far more recoverable action.
        .alert("Delete this plan?", isPresented: $showDeleteConfirmation) {
            Button("Delete plan", role: .destructive) { delete() }
            Button("Keep it", role: .cancel) { }
        } message: {
            Text(plan.deleteConsequenceMessage)
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } }),
               actions: { Button("OK", role: .cancel) { errorMessage = nil } },
               message: { Text(errorMessage ?? "") })
    }

    // MARK: - Actions

    /// Exactly one plan is "next", so marking one clears the rest.
    private func markAsNext() {
        for other in allPlans where other.id != plan.id { other.isNextWorkout = false }
        plan.isNextWorkout = true
        plan.updatedAt = Date()
        if let error = store.save() { errorMessage = error }
    }

    private func duplicate() {
        context.insert(plan.duplicate())
        if let error = store.save() { errorMessage = error }
    }

    /// Deletes the plan. It no longer touches this iPhone's WorkoutKit queue: sending to the Watch
    /// through WorkoutKit was removed in the 2026-09-29 clean-out (docs/BACKLOG.md), and an entry
    /// a plan once queued stays in that queue, unreachable — accepted by the owner.
    private func delete() {
        guard !didDelete else { return }
        didDelete = true
        context.delete(plan)
        if let error = store.save() {
            errorMessage = error
            return
        }
        dismiss()
    }
}
