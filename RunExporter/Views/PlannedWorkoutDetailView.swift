import SwiftUI
import SwiftData

/// One plan, with every action the spec's workout card calls for (§5.2): start, send to Watch,
/// mark as next, edit, duplicate, delete.
///
/// This screen exists because sending used to be reachable **only** from Today, which sends
/// whatever it considers the next workout. That left no way to send any other plan — including no
/// way to replace a test workout already sitting on the Watch.
struct PlannedWorkoutDetailView: View {
    @Environment(LoggerStore.self) private var store
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var allPlans: [PlannedWorkout]

    let plan: PlannedWorkout
    let logger: RunLoggerModel

    /// Asked once and used by several actions, so they cannot disagree about which kind of plan
    /// this screen is showing.
    private var isOpenIntervals: Bool {
        if case .openIntervals = plan.shape { return true }
        return false
    }

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
                    Label("Start Audio Timer", systemImage: "play.circle.fill")
                        .font(.headline)
                }

                if isOpenIntervals {
                    // No send action, because there is nothing this plan could send. A watchOS 10
                    // CustomWorkout is a fixed list of blocks, and this plan is an unknown number of
                    // legs that end when you end them — the count is the measurement. A button
                    // that cannot deliver what it promises is a bug in this app, not a nit, so the
                    // space says what to do instead.
                    Label {
                        Text("Runs on this iPhone. Start a workout on your Watch and use Lap to "
                             + "keep its data lined up with these legs.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "applewatch.slash")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    NavigationLink {
                        SendToWatchView(plan: plan)
                    } label: {
                        Label("Send to Apple Watch", systemImage: "applewatch")
                    }
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
                    if isOpenIntervals {
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
            } footer: {
                Text(plan.workoutKitIdentifier == nil
                     ? "This plan has never been queued for the Watch."
                     : "Deleting also clears its entry from this iPhone's workout queue. It does "
                       + "not remove anything from the Watch — delete those on the Watch.")
            }
        }
        .navigationTitle(plan.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showingTimer) {
            ActiveWorkoutView(plan: plan, logger: logger)
        }
        // `role: .destructive` only colors the button; it prompts for nothing. This delete is
        // irreversible and also clears this iPhone's queue entry, so it gets a real confirmation —
        // the same treatment "End this workout?" already gets for a far more recoverable action.
        // It does not reach the Watch; `deleteConsequenceMessage` is what says so to the user.
        .alert("Delete this plan?", isPresented: $showDeleteConfirmation) {
            Button("Delete plan", role: .destructive) { Task { await delete() } }
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

    /// Deletes the plan, and first clears its entry from this iPhone's workout queue if it was
    /// ever sent.
    ///
    /// Order matters: clearing the entry needs `workoutKitIdentifier`, which disappears with the
    /// plan. Deleting locally first would strand the queue entry with nothing left able to name it.
    /// Nothing here touches the Watch — a workout already delivered there is deleted on the Watch.
    private func delete() async {
        guard !didDelete else { return }

        if let identifier = plan.workoutKitIdentifier, let uuid = UUID(uuidString: identifier) {
            let removed = await WorkoutKitService().remove(identifier: uuid)
            if !removed {
                errorMessage = PlannedWorkout.stuckQueueMessage
                return
            }
        }

        didDelete = true
        context.delete(plan)
        if let error = store.save() {
            errorMessage = error
            return
        }
        dismiss()
    }
}
