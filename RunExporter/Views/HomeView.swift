import SwiftUI
import SwiftData

/// The Today screen (spec §5.1): next planned workout, anything waiting to be logged, a glance at
/// recent workouts, and the export.
struct HomeView: View {
    @Environment(LoggerStore.self) private var store
    @Environment(LoggerDefaults.self) private var defaults
    @Environment(AudioCueEngine.self) private var audio

    @Query(filter: #Predicate<PlannedWorkout> { $0.isNextWorkout },
           sort: \PlannedWorkout.updatedAt, order: .reverse)
    private var nextWorkouts: [PlannedWorkout]

    @Query(sort: \PlannedWorkout.updatedAt, order: .reverse)
    private var allPlans: [PlannedWorkout]

    let logger: RunLoggerModel

    @State private var workoutToLog: HealthKitManager.WorkoutSummary?
    @State private var activePlan: PlannedWorkout?

    private var nextWorkout: PlannedWorkout? { nextWorkouts.first ?? allPlans.first }

    var body: some View {
        List {
            maintenanceSection
            nextWorkoutSection
            exportSection
            unloggedSection
            recentSection
            shoesSection
        }
        .navigationTitle("Running")
        .refreshable { await logger.refresh() }
        .task { await logger.refresh() }
        .fullScreenCover(item: $activePlan) { plan in
            ActiveWorkoutView(plan: plan, logger: logger)
        }
        .sheet(item: $workoutToLog) { workout in
            NavigationStack {
                RunLogFormView(workout: workout, logger: logger)
            }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { logger.errorMessage != nil },
                                    set: { if !$0 { logger.errorMessage = nil } }),
               actions: { Button("OK", role: .cancel) { logger.errorMessage = nil } },
               message: { Text(logger.errorMessage ?? "") })
    }

    // MARK: - Housekeeping

    /// Housekeeping the app performed on its own initiative.
    ///
    /// Inline and dismissible rather than an alert: retiring an abandoned timer is not a failure, so
    /// "Something went wrong" would be the wrong frame and an alert on launch would be noise. It
    /// still has to appear, because it changes which runs the app can link — and a change in
    /// behavior the user cannot see is the thing this project treats as worse than a crash.
    @ViewBuilder
    private var maintenanceSection: some View {
        if let notice = logger.maintenanceNotice {
            Section {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Got it") { logger.maintenanceNotice = nil }
            }
        }
    }

    // MARK: - Next workout

    @ViewBuilder
    private var nextWorkoutSection: some View {
        Section("Next Workout") {
            if let plan = nextWorkout {
                PlannedWorkoutCard(plan: plan)

                Button {
                    activePlan = plan
                } label: {
                    Label("Start Workout", systemImage: "play.circle.fill")
                        .font(.headline)
                }
            } else {
                Text("No workouts yet.")
                    .foregroundStyle(.secondary)
                NavigationLink {
                    PlannedWorkoutEditorView(plan: nil)
                } label: {
                    Label("Create a workout", systemImage: "plus.circle")
                }
            }
        }
    }

    // MARK: - Unlogged

    @ViewBuilder
    private var unloggedSection: some View {
        if !logger.unloggedWorkouts.isEmpty {
            Section("Needs a log") {
                ForEach(logger.unloggedWorkouts) { workout in
                    Button {
                        workoutToLog = workout
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(Display.dayAndTime(workout.startDate))
                                .font(.headline)
                            Text("\(workout.activityType.displayName) · \(Display.miles(workout.distanceMiles)) · \(Display.duration(workout.duration))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Label("Log incomplete", systemImage: "square.and.pencil")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Recent

    @ViewBuilder
    private var recentSection: some View {
        Section("Recent Workouts") {
            if logger.isLoading && logger.recentWorkouts.isEmpty {
                HStack { ProgressView(); Text("Reading Health…").foregroundStyle(.secondary) }
            } else if logger.recentWorkouts.isEmpty {
                Text("No running or walking workouts found yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(logger.recentWorkouts.prefix(5)) { workout in
                    NavigationLink {
                        WorkoutDetailView(workout: workout, logger: logger)
                    } label: {
                        WorkoutRow(workout: workout, log: logger.runLog(forWorkout: workout.uuid))
                    }
                }
            }
        }
    }

    // MARK: - Export and shoes

    /// Directly under Next Workout, styled like Start: running and exporting are what this app is
    /// for (owner, 2026-09-29 clean-out). Its only entry point — Settings no longer has one.
    private var exportSection: some View {
        Section {
            NavigationLink {
                ExportView()
            } label: {
                Label("Export Data", systemImage: "square.and.arrow.up")
                    .font(.headline)
            }
        }
    }

    private var shoesSection: some View {
        Section {
            NavigationLink {
                ShoesView(logger: logger)
            } label: {
                Label("Shoes", systemImage: "shoe")
            }
        }
    }
}

/// One line of the recent-workouts list (spec §19).
struct WorkoutRow: View {
    let workout: HealthKitManager.WorkoutSummary
    let log: RunLog?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(Display.relativeDay(workout.startDate))
                    .font(.headline)
                Spacer()
                Text(Display.miles(workout.distanceMiles))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let log {
                Text("RPE \(Display.rating(log.effortRPE)) · Heat \(Display.rating(log.personalHeatRating))")
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

/// The planned-workout summary card (spec §5.2).
struct PlannedWorkoutCard: View {
    let plan: PlannedWorkout

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(plan.name)
                .font(.title3.weight(.semibold))
            Text(plan.intervalSummary)
                .font(.headline)
                .foregroundStyle(.tint)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                // A plan of several segments has no one run or walk length, so it lists them
                // instead of picking one. Reading the flat fields here showed a 5/1×1 → 8/1×2 →
                // 5/1×1 plan as a flat "Run 5:00", which is a workout it never runs.
                if plan.hasDamagedShape {
                    // Nothing here is a number, deliberately. A plan in this state runs for no
                    // time, and printing "Run 0:00" would look like a measurement of that.
                    GridRow {
                        Text("Shape").foregroundStyle(.secondary)
                        Text(PlannedWorkout.damagedShapeSummary)
                            .foregroundStyle(.red)
                    }
                } else if plan.hasMultipleBlocks {
                    ForEach(Array(plan.resolvedBlocks.enumerated()), id: \.offset) { index, block in
                        GridRow {
                            Text(PlannedWorkout.blockLabel(at: index)).foregroundStyle(.secondary)
                            Text(PlannedWorkout.blockSummary(block)).monospacedDigit()
                        }
                    }
                } else if case .openIntervals(let target, let walkFloor) = plan.shape {
                    // No run length and no round count, because this plan fixes neither. What it
                    // does fix is the total and the floor, so those are what it shows.
                    GridRow {
                        Text("Run to").foregroundStyle(.secondary)
                        Text(PlannedWorkout.clockDuration(target)).monospacedDigit()
                    }
                    if walkFloor > 0 {
                        GridRow {
                            Text("Walk at least").foregroundStyle(.secondary)
                            Text(PlannedWorkout.clockDuration(walkFloor)).monospacedDigit()
                        }
                    }
                } else if let only = plan.singleShape {
                    // `singleShape`, not the flat fields. Reading those directly was right only
                    // while no one-segment plan is ever stored as a block row — an invariant this
                    // card cannot see and nothing enforces.
                    GridRow {
                        Text("Run").foregroundStyle(.secondary)
                        Text(PlannedWorkout.clockDuration(only.runSeconds)).monospacedDigit()
                    }
                    if only.walkSeconds > 0 {
                        GridRow {
                            Text("Walk").foregroundStyle(.secondary)
                            Text(PlannedWorkout.clockDuration(only.walkSeconds)).monospacedDigit()
                        }
                    }
                }
                // Both omitted for an open-interval plan. Its round count is the measurement and is
                // not knowable in advance, so "Rounds 0" would state something false; and its main
                // set counts only the running, because those walks have no planned length, so the
                // figure would read as the whole workout and be short by every walk in it.
                if !plan.isOpenIntervals {
                    GridRow {
                        Text("Rounds").foregroundStyle(.secondary)
                        Text("\(plan.totalRepetitions)").monospacedDigit()
                    }
                    GridRow {
                        Text("Main set").foregroundStyle(.secondary)
                        Text(PlannedWorkout.clockDuration(plan.mainSetSeconds)).monospacedDigit()
                    }
                }
                GridRow {
                    Text("Warmup").foregroundStyle(.secondary)
                    Text(warmupText)
                }
                GridRow {
                    Text("Cooldown").foregroundStyle(.secondary)
                    Text(cooldownText)
                }
                // Shown because it decides whether Apple Watch will even attempt a weather
                // reading. Outdoor is required for weather; it does not guarantee it.
                GridRow {
                    Text("Location").foregroundStyle(.secondary)
                    Text("Outdoor")
                }
            }
            .font(.subheadline)
        }
        .padding(.vertical, 4)
    }

    /// An unrecognized stored mode is shown as-is rather than displayed as "None", which would
    /// misreport the plan.
    private var warmupText: String {
        guard let mode = plan.warmupModeValue else { return "⚠︎ \(plan.warmupMode)" }
        switch mode {
        case .none: return "None"
        case .open: return "Open"
        case .timed: return PlannedWorkout.clockDuration(plan.warmupSeconds ?? 0)
        }
    }

    private var cooldownText: String {
        guard let mode = plan.cooldownModeValue else { return "⚠︎ \(plan.cooldownMode)" }
        switch mode {
        case .none: return "None"
        case .open: return "Open"
        case .timed: return PlannedWorkout.clockDuration(plan.cooldownSeconds ?? 0)
        }
    }
}
