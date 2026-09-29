import SwiftUI
import WorkoutKit

/// Sends a plan to the Apple Watch (spec §8.1).
///
/// Success is only reported after the scheduled list has been read back and the plan is actually
/// in it. Apple's own preview sheet is offered alongside, clearly labelled as a separate action —
/// it gives no callback, so the app cannot tell whether the user added the workout from it and
/// deliberately does not claim to know.
struct SendToWatchView: View {
    @Environment(LoggerStore.self) private var store

    let plan: PlannedWorkout

    @State private var isSending = false
    @State private var result: WorkoutKitService.SendResult?
    @State private var errorMessage: String?
    @State private var showPreview = false
    @State private var isClearing = false
    @State private var clearResult: String?
    @State private var status: WorkoutKitService.WatchStatus?
    @State private var isRefreshing = false
    @State private var lastChecked: Date?

    private let service = WorkoutKitService()

    var body: some View {
        Form {
            Section { PlannedWorkoutCard(plan: plan) }

            if !service.isSupported {
                Section {
                    Label("Sending workouts to Apple Watch is not supported on this device.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            watchStatusSection

            // Apple's sheet is the primary action because it is the one that demonstrably delivers.
            // Measured 2026-08-13: `90/60 × 8` scheduled through `WorkoutScheduler` never reached
            // the Watch, and the same workout added through this sheet arrived. Three other
            // scheduled workouts also never arrived, and `removeAllWorkouts()` could not clear any
            // of them — a store that accepts writes and neither delivers nor forgets them.
            //
            // The cost is real and is stated in the footer rather than hidden: Apple's sheet reports
            // nothing back, so the app cannot confirm the outcome. An unverifiable action that works
            // beats a verified one that does not.
            Section {
                Button {
                    showPreview = true
                } label: {
                    Label("Add to Apple Watch", systemImage: "applewatch")
                }
                .disabled(convertedPlan == nil)

                // KEPT ON PURPOSE, NOT BECAUSE IT WORKS. `WorkoutScheduler` delivered nothing on
                // the owner's hardware over four attempts (LEARNINGS.md), but it demonstrably
                // worked in early August and may work on other pairings or a later watchOS. So it
                // stays, labelled with what is actually known rather than quietly presented as an
                // equal option. The label is driven by live state — an overdue queue is proof that
                // delivery is failing right now — rather than by a hardcoded claim that could
                // itself go stale.
                Button {
                    Task { await send() }
                } label: {
                    HStack {
                        if isSending { ProgressView().padding(.trailing, 6) }
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Schedule for a time", systemImage: "calendar.badge.clock")
                            Text(schedulingCaveat)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .disabled(isSending || !service.isSupported)
            } footer: {
                Text("Add opens Apple's own sheet and puts the workout on the Watch directly. It "
                     + "reports nothing back, so this app cannot confirm it worked — check the "
                     + "Workout app on your wrist, under Outdoor Run. Scheduling instead books the "
                     + "workout for a time; it is queued on this iPhone and delivered separately, "
                     + "and on this setup that delivery has not been happening. Use Add.")
            }

            if let conversionError {
                Section {
                    Label(conversionError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            if let result {
                Section("Scheduled") {
                    // Not a success tick. This confirms only that the iPhone recorded the
                    // schedule; delivery is a separate step that has not been working here, so a
                    // green checkmark and "open the Workout app and select it" would send the user
                    // looking for something that is very likely not there.
                    Label("Queued on this iPhone.", systemImage: "tray.and.arrow.down.fill")
                        .foregroundStyle(.secondary)
                    Text("This does not mean it reached the Watch. If it arrives, it will be in "
                         + "the Workout app under Outdoor Run, named:")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(result.displayName).font(.headline)

                    // Shown so the scheduled time can be compared against what the Watch displays.
                    // Sends now aim a few minutes ahead rather than at the minute already in
                    // progress; without showing it, that choice would be invisible to the user.
                    if let when = result.scheduledDate {
                        LabeledContent("Scheduled for", value: Display.dayAndTime(when))
                    }

                    if result.previousInstanceRemoved == false {
                        Label("This plan's previous entry could not be removed from the queue, so "
                              + "it is now listed twice above.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let errorMessage {
                Section("Not sent") {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                Button(role: .destructive) {
                    Task { await clearWatch() }
                } label: {
                    HStack {
                        if isClearing { ProgressView().padding(.trailing, 6) }
                        // Named for what it actually does. It was "Remove all workouts from
                        // Watch", which it cannot do: `removeAllWorkouts()` only reaches this app's
                        // *scheduled* entries, and nothing that has ever reached the wrist arrived
                        // that way — workouts added through Apple's sheet go into the Watch's own
                        // library, out of WorkoutKit's reach entirely. A button promising a
                        // capability that does not exist is a silent failure with a tap target.
                        Label("Clear this iPhone's queue", systemImage: "trash")
                    }
                }
                .disabled(isClearing || !service.isSupported)

                if let clearResult {
                    Text(clearResult)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                // Deliberately no markdown emphasis: this is a concatenated `String`, so `Text`
                // takes the non-localized overload and would render the asterisks literally.
                Text("Clears the scheduled workouts listed above, which live on this iPhone. "
                     + "It cannot delete anything from your Watch: workouts added with Apple's "
                     + "sheet, created on the Watch, or scheduled by another app are all outside "
                     + "WorkoutKit's reach. Delete those on the Watch itself.")
            }
        }
        .navigationTitle("Send to Watch")
        .navigationBarTitleDisplayMode(.inline)
        .task { if status == nil { await refreshStatus() } }
        .workoutPreview(convertedPlan ?? WorkoutPlan(.custom(CustomWorkout(activity: .running))),
                        isPresented: previewBinding)
    }

    /// The WorkoutKit form of this plan, or nil when the plan cannot be converted.
    private var convertedPlan: WorkoutPlan? {
        guard let custom = try? WorkoutKitService.makeCustomWorkout(from: plan) else { return nil }
        return WorkoutPlan(.custom(custom))
    }

    /// Why the plan could not be converted, if it could not be.
    private var conversionError: String? {
        do {
            _ = try WorkoutKitService.makeCustomWorkout(from: plan)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Refuses to present the preview when there is nothing real to preview.
    ///
    /// `.workoutPreview` needs a non-optional plan, so an unconvertible plan would otherwise show
    /// Apple's sheet describing an empty placeholder workout — a sheet that looks like it worked
    /// while showing something the user never created.
    private var previewBinding: Binding<Bool> {
        Binding(get: { showPreview && convertedPlan != nil },
                set: { showPreview = $0 })
    }

    /// What the phone actually knows about the Watch, rather than what the last send appeared to do.
    @ViewBuilder
    private var watchStatusSection: some View {
        Section {
            if let status {
                LabeledContent("Permission", value: status.authorizationDescription)
                LabeledContent("Queued on this iPhone", value: "\(status.scheduled.count)")

                let overdue = status.overdueCount()
                if overdue > 0 {
                    Label(overdueSummary(overdue), systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                ForEach(status.scheduled) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.subheadline.weight(.medium))
                        Text(entry.scheduledDate.map { Display.dayAndTime($0) }
                             ?? "no scheduled date")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // Read from WorkoutKit and previously discarded, which left "1 queued but
                        // nothing on my wrist" with no readable explanation.
                        if entry.isComplete {
                            Text("marked complete")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if let overdueText = entry.overdueDescription() {
                            Text(overdueText)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if status.scheduled.isEmpty {
                    Text("This iPhone has nothing queued from this app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack { ProgressView(); Text("Checking…").foregroundStyle(.secondary) }
            }

            // Refreshing re-reads a list that is usually unchanged, so without a visible result the
            // button is indistinguishable from a dead control — which is how it read to the user.
            // The timestamp is the feedback: it proves the read happened even when the data did not
            // move.
            Button {
                Task { await refreshStatus() }
            } label: {
                HStack {
                    if isRefreshing { ProgressView().padding(.trailing, 6) }
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isRefreshing)

            if let lastChecked {
                Text("Checked at \(Display.timeWithSeconds(lastChecked))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Schedule on this iPhone")
        } footer: {
            // This footer used to read the count as proof about the Watch. It is the phone's
            // schedule, and delivery to the wrist was measured at minutes on 2026-08-07 — so the
            // old wording sent the user hunting for a failure that had not happened.
            Text("Read straight from WorkoutKit on this iPhone. Delivery to the Watch is separate "
                 + "and can lag by minutes, in both directions — so a count of 0 just after a send "
                 + "does not mean the send failed, and a workout listed here may not be on the "
                 + "wrist yet. Nothing on this screen can see the Watch itself.")
        }
    }

    /// What is currently known about whether scheduling delivers, read from live state.
    ///
    /// An overdue entry is a workout whose appointment passed without being done, which on this
    /// setup means it never arrived. Saying so beside the button is the difference between offering
    /// a choice and offering a trap.
    private var schedulingCaveat: String {
        guard let status, status.overdueCount() > 0 else {
            return "Queues on this iPhone. Delivery to the Watch cannot be confirmed."
        }
        return "Not currently delivering — \(status.overdueCount()) queued workouts never arrived."
    }

    /// Built as a plain `String` rather than inline in the `Label`: this project's type-checker has
    /// given up three times on interpolation mixed with concatenation inside a view initialiser, and
    /// it fails the Release build rather than warning.
    private func overdueSummary(_ count: Int) -> String {
        let subject = count == 1 ? "1 workout has" : "\(count) workouts have"
        return subject + " passed their scheduled time without being done. "
            + "They are almost certainly not reaching the Watch."
    }

    private func refreshStatus() async {
        isRefreshing = true
        defer { isRefreshing = false }
        status = await service.status()
        lastChecked = Date()
    }

    /// Clears the Watch's scheduled workouts and reports what is actually left afterwards, rather
    /// than assuming the removal worked.
    private func clearWatch() async {
        isClearing = true
        clearResult = nil
        defer { isClearing = false }

        // `remaining` is this iPhone's count, read immediately after the removal. It used to be
        // reported as "No workouts are scheduled on the Watch", which is a claim about hardware
        // this screen cannot see — and it was wrong in exactly the case that prompted the user to
        // press the button, with the stale workout still sitting on the wrist.
        let remaining = await service.removeAllScheduledWorkouts()
        if remaining == 0 {
            clearResult = "This iPhone's queue is now empty. Workouts already on your Watch are "
                + "unaffected — delete those on the Watch."
            result = nil
        } else {
            // Says nothing about the Watch, and does not promise that retrying helps. Measured
            // 2026-08-13: `removeAllWorkouts()` left a queue of 4 untouched across repeated taps,
            // so "try again with the Watch nearby" would have been advice for a fix that does not
            // exist. See LEARNINGS.md.
            clearResult = "\(remaining) still queued on this iPhone — WorkoutKit did not remove "
                + "them. Restarting the iPhone is the only known way to clear a queue stuck like "
                + "this. These entries do not affect what is on your Watch."
        }
        await refreshStatus()
    }

    private func send() async {
        isSending = true
        errorMessage = nil
        result = nil
        defer { isSending = false }

        do {
            let sent = try await service.send(plan: plan)
            result = sent
            plan.workoutKitIdentifier = sent.workoutKitIdentifier.uuidString
            plan.updatedAt = Date()
            if let error = store.save() {
                errorMessage = "The workout was queued, but this app could not record that it "
                    + "was: \(error)"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshStatus()
    }
}
