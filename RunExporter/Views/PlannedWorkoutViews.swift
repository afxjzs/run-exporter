import SwiftUI
import SwiftData

/// The list of interval plans, with the presets from spec §7 one tap away.
struct PlannedWorkoutListView: View {
    @Environment(LoggerStore.self) private var store
    @Environment(LoggerDefaults.self) private var defaults
    @Environment(\.modelContext) private var context

    @Query(sort: \PlannedWorkout.updatedAt, order: .reverse) private var plans: [PlannedWorkout]

    let logger: RunLoggerModel

    @State private var isCreating = false
    @State private var isCreatingOpenIntervals = false
    @State private var errorMessage: String?
    @State private var planPendingDeletion: PlannedWorkout?

    var body: some View {
        List {
            if plans.isEmpty {
                Section {
                    Text("No workouts yet. Tap + to build your own, or start from a preset below "
                         + "and edit anything you like.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Your Workouts") {
                    ForEach(plans) { plan in
                        NavigationLink {
                            PlannedWorkoutDetailView(plan: plan, logger: logger)
                        } label: {
                            planRow(plan)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                planPendingDeletion = plan
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { duplicate(plan) } label: {
                                Label("Duplicate", systemImage: "plus.square.on.square")
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .leading) {
                            Button { markAsNext(plan); saveChanges() } label: {
                                Label("Next", systemImage: "star")
                            }
                            .tint(.orange)
                        }
                    }
                }
            }

            Section("Presets") {
                ForEach(PlannedWorkoutPreset.all) { preset in
                    Button {
                        create(from: preset)
                    } label: {
                        HStack {
                            Text(preset.name)
                            Spacer()
                            Image(systemName: "plus.circle")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
        .navigationTitle("Plans")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Interval workout") { isCreating = true }
                    Button("Open intervals") { isCreatingOpenIntervals = true }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .navigationDestination(isPresented: $isCreating) {
            PlannedWorkoutEditorView(plan: nil)
        }
        .navigationDestination(isPresented: $isCreatingOpenIntervals) {
            OpenIntervalPlanEditorView(plan: nil)
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } }),
               actions: { Button("OK", role: .cancel) { errorMessage = nil } },
               message: { Text(errorMessage ?? "") })
        // A swipe is a deliberate gesture, but this delete is irreversible. So it confirms, matching
        // the detail screen rather than differing from it by which gesture happened to start it.
        .alert("Delete this plan?",
               isPresented: Binding(get: { planPendingDeletion != nil },
                                    set: { if !$0 { planPendingDeletion = nil } })) {
            Button("Delete plan", role: .destructive) {
                if let plan = planPendingDeletion {
                    delete(plan)
                }
                planPendingDeletion = nil
            }
            Button("Keep it", role: .cancel) { planPendingDeletion = nil }
        } message: {
            Text(planPendingDeletion?.deleteConsequenceMessage ?? "")
        }
    }

    private func planRow(_ plan: PlannedWorkout) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(plan.name).font(.headline)
                if plan.isNextWorkout {
                    Text("NEXT")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2), in: Capsule())
                }
            }
            // An open-interval plan's summary already states its target, and `mainSetSeconds` there
            // counts only the running — the walks have no planned length. Appending "main set
            // 30:00" would read as the whole workout and be short by every walk in it.
            Text(planSubtitle(plan))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The caption under a plan's name.
    ///
    /// Built as its own `String` rather than inline in the view: this project's Release build fails
    /// where Debug passes when interpolation and `+` mix inside a view initialiser, and it is a
    /// Release-only error. See LEARNINGS.md.
    private func planSubtitle(_ plan: PlannedWorkout) -> String {
        switch plan.shape {
        case .openIntervals:
            return plan.intervalSummary
        case .intervals, .damaged:
            let mainSet = PlannedWorkout.clockDuration(plan.mainSetSeconds)
            return "\(plan.intervalSummary) · main set \(mainSet)"
        }
    }

    private func create(from preset: PlannedWorkoutPreset) {
        let plan = preset.makeWorkout(defaults: defaults)

        // Same guard the editor applies: never save a plan the timer would refuse to run. Without
        // this a bad default produces a workout that saves cleanly and only fails at the start
        // line, long after the mistake was made.
        do {
            _ = try WorkoutPhaseSchedule.build(from: plan)
        } catch {
            errorMessage = "\"\(preset.name)\" could not be created from your current defaults: "
                + "\(error.localizedDescription)"
            return
        }

        context.insert(plan)
        markAsNext(plan)
        saveChanges()
    }

    private func duplicate(_ plan: PlannedWorkout) {
        context.insert(plan.duplicate())
        saveChanges()
    }

    /// Deletes a plan. Like the detail screen's delete, it no longer touches this iPhone's
    /// WorkoutKit queue, which the 2026-09-29 clean-out removed (docs/BACKLOG.md).
    private func delete(_ plan: PlannedWorkout) {
        context.delete(plan)
        saveChanges()
    }

    /// Exactly one plan is "next", so marking one clears the rest.
    private func markAsNext(_ plan: PlannedWorkout) {
        for other in plans where other.id != plan.id { other.isNextWorkout = false }
        plan.isNextWorkout = true
        plan.updatedAt = Date()
    }

    private func saveChanges() {
        if let error = store.save() { errorMessage = error }
    }
}

// MARK: - Editor

/// Create or edit a plan (spec §7). Everything is on one screen so the 30-second target is met
/// without any navigation.
struct PlannedWorkoutEditorView: View {
    @Environment(LoggerStore.self) private var store
    @Environment(LoggerDefaults.self) private var defaults
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var allPlans: [PlannedWorkout]

    /// Nil when creating.
    let plan: PlannedWorkout?

    /// One segment being edited.
    ///
    /// Carries its own identity so the list survives reordering and deletion — a `ForEach` keyed by
    /// array position loses track of which row the user is typing in the moment one moves.
    private struct BlockDraft: Identifiable, Equatable {
        let id = UUID()
        var runMinutes: Int
        var runSeconds: Int
        var walkMinutes: Int
        var walkSeconds: Int
        var repetitions: Int

        var totalRunSeconds: Int { runMinutes * 60 + runSeconds }
        var totalWalkSeconds: Int { walkMinutes * 60 + walkSeconds }

        /// The value type the rest of the app reasons about a plan's shape with.
        var block: PlannedWorkout.Block {
            PlannedWorkout.Block(runSeconds: totalRunSeconds,
                                 walkSeconds: totalWalkSeconds,
                                 repetitions: repetitions)
        }

        init(runSeconds seconds: Int, walkSeconds walk: Int, repetitions: Int) {
            runMinutes = seconds / 60
            runSeconds = seconds % 60
            walkMinutes = walk / 60
            walkSeconds = walk % 60
            self.repetitions = repetitions
        }
    }

    @State private var name = ""
    @State private var activityType: PlannedActivityType = .running
    @State private var blocks: [BlockDraft] = []
    @State private var includesFinalWalk = false
    @State private var warmupMode: WarmupMode = .none
    @State private var warmupMinutes = 5
    @State private var cooldownMode: CooldownMode = .open
    @State private var cooldownMinutes = 5
    @State private var countdownSeconds = 0
    @State private var isNextWorkout = true
    @State private var errorMessage: String?
    @State private var didLoad = false

    /// Whether the name is still following the workout's shape.
    ///
    /// True until the user types a name of their own, after which the shape stops touching it —
    /// renaming someone's "Tuesday hills" to "5/1×1 · 8/1×2" because they adjusted a block would
    /// be the app overwriting an intention it was not asked about.
    @State private var nameFollowsShape = true

    /// Every segment as the rest of the app sees it.
    private var shape: [PlannedWorkout.Block] { blocks.map(\.block) }

    /// The name this workout's shape would give it — the same string the plan list will show.
    private var generatedName: String {
        PlannedWorkout.summary(blocks: shape, includesFinalWalk: includesFinalWalk)
    }

    /// True when any walk length is set, which is the only case where the final-walk toggle means
    /// anything.
    private var hasAnyWalk: Bool { blocks.contains { $0.totalWalkSeconds > 0 } }

    /// The plan's own arithmetic, not a copy of it — see `PlannedWorkout.mainSetSeconds(blocks:…)`.
    /// A preview that disagreed with what gets saved would be the screen stating one number while
    /// the timer ran another.
    private var mainSetSeconds: Int {
        PlannedWorkout.mainSetSeconds(blocks: shape, includesFinalWalk: includesFinalWalk)
    }

    private var totalRepetitions: Int { PlannedWorkout.totalRepetitions(blocks: shape) }

    var body: some View {
        Form {
            Section {
                TextField("Workout name", text: $name)
                    // Fires for the shape-driven refresh below as well as for typing. The refresh
                    // sets exactly the generated name, so only a value that differs from it can
                    // have come from the user.
                    .onChange(of: name) { _, newValue in
                        if newValue != generatedName { nameFollowsShape = false }
                    }
                Picker("Activity", selection: $activityType) {
                    ForEach(PlannedActivityType.allCases) { Text($0.displayName).tag($0) }
                }
            } header: {
                Text("Name")
            } footer: {
                if nameFollowsShape {
                    Text("Named after its shape until you type your own.")
                }
            }

            Section {
                ForEach($blocks) { $draft in
                    blockRow($draft)
                }
                // Both are passed nil for a one-block plan, which is how SwiftUI is told not to
                // offer the affordance at all. Handing it a closure that declines to act would
                // give the user a swipe that silently does nothing and never says why.
                .onMove(perform: blocks.count > 1 ? moveBlocks : nil)
                .onDelete(perform: blocks.count > 1 ? deleteBlocks : nil)

                Button {
                    addBlock()
                } label: {
                    Label("Add block", systemImage: "plus.circle.fill")
                }

                if hasAnyWalk {
                    Toggle("Walk after the final run", isOn: $includesFinalWalk)
                    Text(finalWalkExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Main set", value: PlannedWorkout.clockDuration(mainSetSeconds))
            } header: {
                Text("Intervals")
            } footer: {
                Text(blocksExplanation)
            }

            Section("Warmup") {
                Picker("Warmup", selection: $warmupMode) {
                    ForEach(WarmupMode.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                if warmupMode == .timed {
                    Stepper("\(warmupMinutes) min", value: $warmupMinutes, in: 1...60)
                }
            }

            Section("Cooldown") {
                Picker("Cooldown", selection: $cooldownMode) {
                    ForEach(CooldownMode.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                if cooldownMode == .timed {
                    Stepper("\(cooldownMinutes) min", value: $cooldownMinutes, in: 1...120)
                }
                if cooldownMode == .open {
                    Text("An open cooldown runs until you tap Finish, and is recorded separately "
                         + "from the main set.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Countdown") {
                Picker("Countdown", selection: $countdownSeconds) {
                    ForEach(LoggerDefaults.allowedCountdownSeconds, id: \.self) { value in
                        Text(value == 0 ? "Off" : "\(value)s").tag(value)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("Make this the next workout", isOn: $isNextWorkout)
            }
        }
        .navigationTitle(plan == nil ? "New Workout" : "Edit Workout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Reordering needs edit mode, and edit mode needs this button. Shown only once there
            // is more than one block, because there is nothing to reorder before that.
            if blocks.count > 1 {
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!isValid)
            }
        }
        .onChange(of: blocks) { _, _ in
            // The name tracks the workout as it is built, so the plan list does not end up full of
            // rows called "4/1 × 5" that run something else entirely.
            if nameFollowsShape { name = generatedName }
        }
        .onAppear(perform: loadOnce)
        .alert("Something went wrong",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } }),
               actions: { Button("OK", role: .cancel) { errorMessage = nil } },
               message: { Text(errorMessage ?? "") })
    }

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !blocks.isEmpty else { return false }
        // Every segment has to be runnable, not just the first — the same rule
        // `WorkoutPhaseSchedule.build` applies, checked here so Save is disabled rather than
        // failing with an alert after the fact.
        return blocks.allSatisfy { $0.totalRunSeconds > 0 && $0.repetitions > 0 }
    }

    /// Built as strings in their own properties. This project's SwiftUI type-checker gives up on
    /// interpolation mixed with concatenation inside a view initialiser, and fails the **Release**
    /// build rather than warning about it.
    private var finalWalkExplanation: String {
        includesFinalWalk
            ? "The last run is followed by a walk, then cooldown."
            : "The last run goes straight into cooldown."
    }

    private var blocksExplanation: String {
        guard blocks.count > 1 else {
            return "Add a block to run rounds of different lengths — 5/1 once, then 8/1 twice, "
                + "then 5/1 again."
        }
        let rounds = "\(totalRepetitions) rounds"
        return "Runs top to bottom: " + rounds + " in all. Swipe a block to delete it, or use Edit "
            + "to reorder."
    }

    @ViewBuilder
    private func blockRow(_ draft: Binding<BlockDraft>) -> some View {
        let index = blocks.firstIndex { $0.id == draft.wrappedValue.id } ?? 0

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(PlannedWorkout.blockLabel(at: index))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(PlannedWorkout.blockSummary(draft.wrappedValue.block))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            durationPicker(label: "Run",
                           minutes: draft.runMinutes,
                           seconds: draft.runSeconds)
            durationPicker(label: "Walk",
                           minutes: draft.walkMinutes,
                           seconds: draft.walkSeconds)
            Stepper("Rounds: \(draft.wrappedValue.repetitions)",
                    value: draft.repetitions,
                    in: 1...60)
        }
    }

    /// Writes the edited segments onto the plan.
    ///
    /// A plan of one shape is stored in the flat fields with an empty `blocks` relationship —
    /// which is exactly what every plan created before blocks existed looks like. One stored form
    /// per kind of plan, one code path in `resolvedBlocks`, and nothing to migrate.
    private func writeShape(_ shapes: [PlannedWorkout.Block], to target: PlannedWorkout) {
        // Replace rather than accumulate. Reassigning the relationship would leave the previous
        // block records in the store with no plan pointing at them: rows nothing reads, nothing
        // exports and nothing deletes. The cascade rule only fires when the plan itself goes.
        for existing in target.blocks { context.delete(existing) }
        target.blocks = []

        guard shapes.count > 1 else {
            guard let only = shapes.first else { return }
            target.runIntervalSeconds = only.runSeconds
            target.walkIntervalSeconds = only.walkSeconds
            target.plannedRepetitions = only.repetitions
            return
        }

        target.blocks = shapes.enumerated().map { index, block in
            PlannedWorkoutBlock(orderIndex: index,
                                runIntervalSeconds: block.runSeconds,
                                walkIntervalSeconds: block.walkSeconds,
                                repetitions: block.repetitions)
        }

        // Zeroed rather than left holding the first block's numbers. Nothing reads these for a
        // plan that carries blocks — every reader goes through `resolvedBlocks` — and if something
        // ever does, a zero is a value no runnable plan can have, so it fails loudly instead of
        // quietly running one third of the workout.
        target.runIntervalSeconds = 0
        target.walkIntervalSeconds = 0
        target.plannedRepetitions = 0
    }

    private func moveBlocks(from source: IndexSet, to destination: Int) {
        blocks.move(fromOffsets: source, toOffset: destination)
    }

    /// A plan is at least one segment: deleting the last would leave a workout that runs nothing,
    /// which `WorkoutPhaseSchedule.build` refuses outright. The affordance is withheld rather than
    /// offered and then ignored — see where this is attached.
    private func deleteBlocks(at offsets: IndexSet) {
        guard blocks.count > offsets.count else { return }
        blocks.remove(atOffsets: offsets)
    }

    private func addBlock() {
        // A new block starts as a copy of the last one, which is the shape the user was just
        // looking at. Starting from the app defaults instead would drop them back to 4/1 in the
        // middle of building something deliberately different.
        let previous = blocks.last
        blocks.append(BlockDraft(runSeconds: previous?.totalRunSeconds ?? defaults.defaultRunSeconds,
                                 walkSeconds: previous?.totalWalkSeconds ?? defaults.defaultWalkSeconds,
                                 repetitions: 1))
    }

    private func durationPicker(label: String, minutes: Binding<Int>, seconds: Binding<Int>) -> some View {
        DurationWheels(label: label, minutes: minutes, seconds: seconds)
    }

    /// Fills the fields from the plan being edited, or from the user's defaults when creating.
    private func loadOnce() {
        guard !didLoad else { return }
        didLoad = true

        guard let plan else {
            blocks = [BlockDraft(runSeconds: defaults.defaultRunSeconds,
                                 walkSeconds: defaults.defaultWalkSeconds,
                                 repetitions: defaults.defaultRepetitions)]
            cooldownMode = defaults.cooldownMode
            cooldownMinutes = max(1, defaults.defaultCooldownSeconds / 60)
            activityType = defaults.activityType
            countdownSeconds = defaults.countdownSeconds
            nameFollowsShape = true
            name = generatedName
            return
        }

        name = plan.name
        // A plan still called what its shape says keeps following it; one the user named
        // themselves — "Tuesday hills", or a preset's "20 min continuous" — does not.
        nameFollowsShape = plan.name == plan.intervalSummary
        activityType = plan.activityTypeValue ?? .running
        // `resolvedBlocks` reads either shape, so a plan stored as flat fields and one stored as
        // blocks both arrive here as the same list — the editor has no notion of an "old" plan.
        blocks = plan.resolvedBlocks.map {
            BlockDraft(runSeconds: $0.runSeconds,
                       walkSeconds: $0.walkSeconds,
                       repetitions: $0.repetitions)
        }
        includesFinalWalk = plan.includesFinalWalk
        warmupMode = plan.warmupModeValue ?? .none
        warmupMinutes = max(1, (plan.warmupSeconds ?? 300) / 60)
        cooldownMode = plan.cooldownModeValue ?? .open
        cooldownMinutes = max(1, (plan.cooldownSeconds ?? 300) / 60)
        countdownSeconds = plan.countdownSeconds
        isNextWorkout = plan.isNextWorkout
    }

    private func save() {
        let shapes = shape
        guard !shapes.isEmpty else {
            errorMessage = "A workout needs at least one block."
            return
        }

        let target: PlannedWorkout
        if let plan {
            target = plan
        } else {
            // Created with the three interval fields zeroed, because `writeShape` below is the
            // only thing that should ever set them. Seeding them from the first segment here made
            // a multi-block plan hold that segment's numbers for a few statements — briefly the
            // exact "plausible and wrong" state `writeShape` zeroes them to prevent.
            target = PlannedWorkout(name: name,
                                    runIntervalSeconds: 0,
                                    walkIntervalSeconds: 0,
                                    plannedRepetitions: 0)
            context.insert(target)
        }

        target.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        target.activityType = activityType.rawValue
        writeShape(shapes, to: target)
        target.includesFinalWalk = includesFinalWalk
        target.warmupMode = warmupMode.rawValue
        target.warmupSeconds = warmupMode == .timed ? warmupMinutes * 60 : nil
        target.cooldownMode = cooldownMode.rawValue
        target.cooldownSeconds = cooldownMode == .timed ? cooldownMinutes * 60 : nil
        target.countdownSeconds = countdownSeconds
        target.updatedAt = Date()

        if isNextWorkout {
            for other in allPlans where other.id != target.id { other.isNextWorkout = false }
        }
        target.isNextWorkout = isNextWorkout

        // Refuse to save a plan the timer could not actually run, rather than discovering it at
        // the start line.
        do {
            _ = try WorkoutPhaseSchedule.build(from: target)
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
}
