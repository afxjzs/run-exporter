import SwiftUI
import SwiftData

/// Builds a plan whose running legs end when the runner ends them.
///
/// Its own screen rather than a mode inside `PlannedWorkoutEditorView`, deliberately. That editor
/// exists to assemble an ordered list of run/walk blocks, which is the most intricate screen in the
/// app; an open-interval plan has no blocks at all and four decisions. Putting a kind switch above
/// the block editor would mean every future change to either had to consider the other.
struct OpenIntervalPlanEditorView: View {

    @Environment(LoggerStore.self) private var store
    @Environment(LoggerDefaults.self) private var defaults
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var allPlans: [PlannedWorkout]

    /// Nil when creating. Editing an existing plan reuses this screen.
    let plan: PlannedWorkout?

    @State private var name = ""
    @State private var targetMinutes = 30
    @State private var targetSeconds = 0
    @State private var walkFloorMinutes = 3
    @State private var walkFloorSeconds = 0
    @State private var activityType: PlannedActivityType = .running
    @State private var warmupMode: WarmupMode = .none
    @State private var warmupMinutes = 5
    @State private var cooldownMode: CooldownMode = .open
    @State private var cooldownMinutes = 10
    @State private var isNextWorkout = false
    @State private var errorMessage: String?
    @State private var hasLoaded = false

    /// What the plan list will show. Built from the same function the saved plan will use, so the
    /// name proposed here is the name the list shows back.
    private var proposedName: String {
        PlannedWorkout.openIntervalSummary(target: targetTotalSeconds,
                                           walkFloor: walkFloorTotalSeconds)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var targetTotalSeconds: Int { targetMinutes * 60 + targetSeconds }
    private var walkFloorTotalSeconds: Int { walkFloorMinutes * 60 + walkFloorSeconds }

    /// Its own string, not interpolated inline: this project's Release build fails where Debug
    /// passes when interpolation and `+` mix inside a view initialiser. See LEARNINGS.md.
    private var footerText: String {
        let total = PlannedWorkout.clockDuration(targetTotalSeconds)
        return "You end each running leg yourself. Walks run at least as long as the floor and end "
            + "when you say so. The workout finishes once you have run \(total) in total, not "
            + "counting the walks."
    }

    var body: some View {
        Form {
            Section {
                TextField(proposedName, text: $name)
                Picker("Activity", selection: $activityType) {
                    ForEach(PlannedActivityType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
            } header: {
                Text("Workout")
            } footer: {
                Text("Leave the name blank to call it \"\(proposedName)\".")
            }

            Section {
                // Wheels, like the block editor's — setting a duration should not feel like two
                // different jobs depending on which kind of plan is being built. The target goes
                // to three hours; a floor beyond half an hour is not a recovery walk.
                DurationWheels(label: "Run in total",
                               minutes: $targetMinutes,
                               seconds: $targetSeconds,
                               minuteRange: 0...180)
                DurationWheels(label: "Walk at least",
                               minutes: $walkFloorMinutes,
                               seconds: $walkFloorSeconds)
            } header: {
                Text("Open intervals")
            } footer: {
                Text(footerText)
            }

            Section("Warmup") {
                Picker("Warmup", selection: $warmupMode) {
                    ForEach(WarmupMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                if warmupMode == .timed {
                    Stepper("\(warmupMinutes) min", value: $warmupMinutes, in: 1...60)
                }
            }

            Section("Cooldown") {
                Picker("Cooldown", selection: $cooldownMode) {
                    ForEach(CooldownMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                if cooldownMode == .timed {
                    Stepper("\(cooldownMinutes) min", value: $cooldownMinutes, in: 1...120)
                }
            }

            Section {
                Toggle("Make this my next workout", isOn: $isNextWorkout)
            }
        }
        .navigationTitle(plan == nil ? "New open intervals" : "Edit workout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
            }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } }),
               actions: { Button("OK", role: .cancel) { errorMessage = nil } },
               message: { Text(errorMessage ?? "") })
        .onAppear(perform: load)
    }

    /// Fills the fields from an existing plan, once.
    ///
    /// Guarded because `onAppear` fires again when the screen returns to the foreground, and
    /// reloading there would throw away edits the user had not saved yet.
    private func load() {
        guard !hasLoaded, let plan else { hasLoaded = true; return }
        hasLoaded = true

        name = plan.name
        activityType = plan.activityTypeValue ?? .running
        warmupMode = plan.warmupModeValue ?? .none
        warmupMinutes = max(1, (plan.warmupSeconds ?? 300) / 60)
        cooldownMode = plan.cooldownModeValue ?? .open
        cooldownMinutes = max(1, (plan.cooldownSeconds ?? 600) / 60)
        isNextWorkout = plan.isNextWorkout

        if let shape = plan.openIntervalShape {
            targetMinutes = shape.targetRunSeconds / 60
            targetSeconds = shape.targetRunSeconds % 60
            walkFloorMinutes = shape.walkFloorSeconds / 60
            walkFloorSeconds = shape.walkFloorSeconds % 60
        }
    }

    private func save() {
        let target: PlannedWorkout
        if let plan {
            target = plan
        } else {
            // The three interval fields stay at zero: this plan has no intervals, and zero is
            // already this app's way of saying "the shape is not described here". Nothing may read
            // them without going through `shape` first.
            target = PlannedWorkout(name: trimmedName.isEmpty ? proposedName : trimmedName,
                                    runIntervalSeconds: 0,
                                    walkIntervalSeconds: 0,
                                    plannedRepetitions: 0)
            context.insert(target)
        }

        target.name = trimmedName.isEmpty ? proposedName : trimmedName
        target.activityType = activityType.rawValue
        target.warmupMode = warmupMode.rawValue
        target.warmupSeconds = warmupMode == .timed ? warmupMinutes * 60 : nil
        target.cooldownMode = cooldownMode.rawValue
        target.cooldownSeconds = cooldownMode == .timed ? cooldownMinutes * 60 : nil
        target.updatedAt = Date()

        writeShape(to: target)

        if isNextWorkout {
            for other in allPlans where other.id != target.id { other.isNextWorkout = false }
        }
        target.isNextWorkout = isNextWorkout

        // Refuse to save a plan the timer could not run, rather than discovering it at the start
        // line. `makePhaseSource` is the same call the timer makes, so the two cannot disagree.
        do {
            _ = try target.makePhaseSource()
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        if let error = store.save() {
            errorMessage = error
            return
        }
        dismiss()
    }

    /// Writes the open-interval settings, replacing any previous ones.
    ///
    /// The old record is deleted explicitly rather than left to the relationship. A SwiftData
    /// cascade fires when the *parent* is deleted, not when a child is replaced — assigning a new
    /// one leaves the old row in the store with a nil inverse, invisible to every screen and every
    /// CSV. `PlannedWorkoutEditorView.writeShape` had to learn the same thing about blocks.
    private func writeShape(to target: PlannedWorkout) {
        if let existing = target.openIntervalShape {
            existing.targetRunSeconds = targetTotalSeconds
            existing.walkFloorSeconds = walkFloorTotalSeconds
            return
        }
        let shape = OpenIntervalShape(targetRunSeconds: targetTotalSeconds,
                                      walkFloorSeconds: walkFloorTotalSeconds)
        context.insert(shape)
        target.openIntervalShape = shape
    }
}
