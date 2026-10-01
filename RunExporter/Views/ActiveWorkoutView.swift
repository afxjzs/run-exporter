import SwiftUI

/// The running workout screen (spec §12): large, high-contrast, few controls.
///
/// Everything is sized to be read at arm's length in sunlight while moving, and the destructive
/// action (End) is separated from the ones used mid-run so it cannot be hit by accident.
struct ActiveWorkoutView: View {
    @Environment(LoggerStore.self) private var store
    @Environment(LoggerDefaults.self) private var defaults
    @Environment(AudioCueEngine.self) private var audio
    @Environment(WatchLink.self) private var watchLink
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let plan: PlannedWorkout
    let logger: RunLoggerModel

    @State private var model: ActiveWorkoutModel?
    @State private var showEndConfirmation = false
    @State private var showLogPrompt = false
    @State private var workoutToLog: HealthKitManager.WorkoutSummary?
    @State private var candidateWorkouts: CandidateList?
    @State private var showEarlyLog = false
    @State private var showNoWorkoutOptions = false
    @State private var showAlreadyLogged = false
    /// Non-nil while the note sheet is up. Holds the phase the workout was in at the tap.
    @State private var noteContext: ActiveWorkoutModel.NoteContext?
    @State private var legEndContext: ActiveWorkoutModel.LegEndContext?
    @State private var showEarlyLegConfirmation = false
    /// Non-nil when a workout of the right kind exists but started outside the matching window.
    @State private var nearMiss: NearMiss?

    /// Identifiable wrapper so the picker can be driven by `.sheet(item:)`.
    struct CandidateList: Identifiable {
        let id = UUID()
        let workouts: [HealthKitManager.WorkoutSummary]
    }

    /// The nearest workout that missed the two-minute window, and by how much.
    ///
    /// Carries the offset rather than recomputing it in the view, so the number the user is shown
    /// is the number the matcher actually rejected on.
    struct NearMiss: Identifiable {
        let id = UUID()
        let workout: HealthKitManager.WorkoutSummary
        let offsetSeconds: TimeInterval
    }

    var body: some View {
        ZStack {
            phaseColor.ignoresSafeArea()

            if let model {
                if model.hasStarted {
                    content(model: model)
                } else {
                    armed(model: model)
                }
            } else {
                ProgressView().tint(.white)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            guard model == nil else { return }
            // Created, deliberately not started. The timer session, the audio session and the Live
            // Activity all begin at the Start button, so their clock agrees with the Watch's rather
            // than with whenever this screen happened to appear.
            model = ActiveWorkoutModel(store: store, defaults: defaults, audio: audio, watchLink: watchLink)
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from the lock screen: re-derive from the clock immediately rather than
            // showing a stale value until the next tick.
            if phase == .active { model?.refreshFromClock() }
        }
        .onDisappear {
            // Never leave the audio session active behind a dismissed screen.
            model?.cancel()
        }
        .alert("End this workout?", isPresented: $showEndConfirmation) {
            Button("End workout", role: .destructive) {
                model?.endEarly()
                promptToLog()
            }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("Intervals completed so far are kept.")
        }
        .alert("No Apple Watch workout found", isPresented: $showNoWorkoutOptions) {
            Button("Log it anyway") { showEarlyLog = true }
            Button("Wait for the Watch", role: .cancel) { dismiss() }
        } message: {
            Text("If you ran this on the phone only, there is nothing to match — log it now and "
                 + "it will be saved without distance or heart rate.\n\nIf you did record on your "
                 + "Watch, end the workout there and log it from Today in a minute or two.")
        }
        // The case that used to arrive disguised as "No Apple Watch workout found". Waiting cannot
        // fix it — the reverse matching direction applies the same two-minute gate — so the only
        // honest options are to use the workout or not. Confirming by hand is what this app already
        // does for an ambiguous match, and `linkIntervals` makes the result indistinguishable from
        // an automatic link, including in the export.
        .alert("Started too far apart to link",
               isPresented: Binding(get: { nearMiss != nil },
                                    set: { if !$0 { nearMiss = nil } }),
               presenting: nearMiss) { miss in
            Button("Use it anyway") { link(miss) }
            Button("Not this one", role: .cancel) {
                nearMiss = nil
                dismiss()
            }
        } message: { miss in
            Text(nearMissMessage(miss))
        }
        .alert("Workout complete", isPresented: $showLogPrompt) {
            Button("Log it now") { Task { await findWorkoutToLog() } }
            Button("Later", role: .cancel) { dismiss() }
        } message: {
            Text(completionMessage)
        }
        .alert("You already logged this run", isPresented: $showAlreadyLogged) {
            Button("Edit log") { Task { await editExistingLog() } }
            Button("OK", role: .cancel) { dismiss() }
        } message: {
            Text("Your notes and ratings from during the workout are saved. Distance, pace and "
                 + "heart rate attach automatically once the Watch's workout reaches Apple Health.")
        }
        .sheet(item: $workoutToLog, onDismiss: { dismiss() }) { workout in
            NavigationStack {
                RunLogFormView(workout: workout,
                               logger: logger,
                               context: model?.logDraftContext)
            }
        }
        .sheet(isPresented: $showEarlyLog, onDismiss: {
            // Ask the store whether a log was actually written. This runs for a cancel as well as a
            // save, and only the store can tell the two apart — which is why the button's label is
            // no longer driven by a flag someone has to remember to set.
            model?.refreshPendingLog(using: logger)
            // Reached from the "no Watch workout" path, the workout is already over — close the
            // screen behind it. During cooldown it is still running, so stay put.
            if showNoWorkoutOptions || model?.engine.isRunning != true { dismiss() }
        }) {
            if let model, let executionID = model.executionID {
                NavigationStack {
                    EarlyRunLogView(logger: logger,
                                    executionID: executionID,
                                    startedAt: model.startedAt,
                                    activityType: model.activityType,
                                    isAfterWorkout: !model.engine.isRunning,
                                    context: model.logDraftContext)
                }
            } else {
                // Without this the sheet still presented, containing nothing at all — which reads as
                // the app having ignored the tap. If there is no timer session to attach a log to,
                // the honest response is to say which precondition failed and what still works.
                NavigationStack {
                    ContentUnavailableView {
                        Label("This run cannot be logged here",
                              systemImage: "exclamationmark.triangle.fill")
                    } description: {
                        Text("No timer session was recorded for this workout, so there is nothing "
                             + "to attach a log to yet. You can still log the run from History once "
                             + "Apple Health has it.")
                    }
                }
            }
        }
        // Presented by item, so the sheet is built with the phase captured at the tap. Nothing here
        // pauses the timer, ends the audio session or touches the engine: the workout runs on
        // underneath, and the cues keep sounding, which is the hard constraint on this feature.
        .alert("Start before your walk floor?", isPresented: $showEarlyLegConfirmation) {
            Button("Start now") { model?.startNextLeg() }
            Button("Keep walking", role: .cancel) {}
        } message: {
            Text(earlyLegMessage)
        }
        .sheet(item: $legEndContext) { context in
            if let model {
                LegEndSheet(context: context, logger: logger, model: model)
            }
        }
        .sheet(item: $noteContext) { context in
            if let model, let executionID = model.executionID {
                NavigationStack {
                    WorkoutNoteSheet(logger: logger,
                                     executionID: executionID,
                                     context: context) { text in
                        model.saveNote(text, context: context, logger: logger)
                    }
                }
            } else {
                // Same reasoning as the early-log sheet below: an empty sheet reads as the app
                // having ignored the tap. Say which precondition failed, and do not invite the
                // user to type something that cannot be kept.
                NavigationStack {
                    ContentUnavailableView {
                        Label("Notes are unavailable for this workout",
                              systemImage: "exclamationmark.triangle.fill")
                    } description: {
                        Text("No timer session was recorded for this workout, so a note would "
                             + "have nothing to attach to. The timer and cues still work.")
                    }
                }
            }
        }
        .sheet(item: $candidateWorkouts) { list in
            NavigationStack {
                WorkoutPickerView(workouts: list.workouts) { chosen in
                    candidateWorkouts = nil
                    // Picking from this list is the same decision `findWorkoutToLog`'s `.matched`
                    // branch makes automatically, so it must have the same consequence: a log
                    // written during cooldown gets joined to the workout. Only the automatic branch
                    // did, so resolving an ambiguity by hand left the log orphaned. Attached here
                    // rather than left to the reconciliation sweep because the user has just stated
                    // which workout it is — re-deriving that later is strictly worse information.
                    if let executionID = model?.executionID,
                       let error = logger.attach(workout: chosen, toPendingLogFor: executionID) {
                        logger.errorMessage = error
                    }
                    workoutToLog = chosen
                } onCancel: {
                    candidateWorkouts = nil
                    dismiss()
                }
            }
        }
    }

    // MARK: - Armed, before the workout starts

    /// The screen before the timer is running.
    ///
    /// Nothing is recorded until Start: no timer session, no audio session, no Live Activity, and
    /// no Watch workout. Backing out leaves no trace. Start then launches the Watch's workout as
    /// well as the timer, so the two begin from one tap.
    ///
    /// Arming was introduced when the run began as two taps — the Watch, then this timer — and
    /// the gap between them had to stay inside `RecentWorkoutMatcher.startToleranceSeconds`.
    @ViewBuilder
    private func armed(model: ActiveWorkoutModel) -> some View {
        VStack(spacing: 24) {
            // A start that failed still lands here, because `hasStarted` only flips on a start that
            // got as far as the engine. Without this the failure would have nowhere to appear.
            if let message = model.errorMessage {
                notice(message, systemImage: "exclamationmark.triangle.fill") {
                    model.errorMessage = nil
                }
            }

            Spacer(minLength: 0)

            Text("READY")
                .font(.system(size: 56, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)

            Text(plan.name)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(plannedShape)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.8))

            Text(startOrderHint)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal)

            Spacer(minLength: 0)

            Button {
                model.start(plan: plan)
            } label: {
                Text("Start")
                    .font(.title.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 72)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white.opacity(0.25))

            Button {
                dismiss()
            } label: {
                Text("Back")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
        .foregroundStyle(.white)
        .padding()
    }

    /// "4/1 × 5", or "4:00 continuous" when the plan has no walk.
    ///
    /// Built in its own property: this project's SwiftUI type-checker gives up on interpolation
    /// mixed with concatenation inside a view initialiser, and fails the Release build rather than
    /// warning about it.
    private var plannedShape: String {
        // `intervalSummary` reads the plan's resolved shape, so this renders "5/1×1 · 8/1×2 ·
        // 5/1×1" for a plan of several segments instead of the flat fields' first block. It was a
        // third independent copy of this string, and the copy that would have gone on lying while
        // the timer beside it ran something else.
        plan.intervalSummary
    }

    /// Changed with watch plan step 2. The old text told the runner to start the Watch's workout
    /// first; now Start does that itself, and doing both would record **two** workouts.
    private var startOrderHint: String {
        "Start also starts the workout on your Apple Watch. Don't start one on the Watch yourself. "
            + "Nothing is recorded until you tap Start."
    }

    // MARK: - Content

    @ViewBuilder
    private func content(model: ActiveWorkoutModel) -> some View {
        VStack(spacing: 24) {
            // Live Activity problems are reported here too. They were previously collected and
            // never displayed, so a Lock Screen card that failed to start looked like nothing
            // happening at all — the worst possible presentation of a handled error.
            //
            // Each source is rendered separately and is separately dismissible. This used to be a
            // `??` chain, which showed only the first non-nil source: on a real run a stale
            // headphone notice sat here for the whole workout with no way to clear it, and anything
            // that went wrong afterwards was hidden behind it.
            if let message = model.errorMessage {
                notice(message, systemImage: "exclamationmark.triangle.fill") {
                    model.errorMessage = nil
                }
            }
            if let message = audio.lastError {
                notice(message, systemImage: "exclamationmark.triangle.fill") {
                    audio.clearError()
                }
            }
            if let message = model.liveActivity.lastError {
                notice(message, systemImage: "exclamationmark.triangle.fill") {
                    model.liveActivity.clearError()
                }
            }
            // Informational, and clears itself when the route comes back — but still dismissible,
            // because a run that ends on the speaker should not need a reconnect to silence it.
            if let message = audio.routeNotice {
                notice(message, systemImage: "airpods") {
                    audio.clearRouteNotice()
                }
            }
            // The diagnostic files are how a failed Watch run gets diagnosed afterwards. This was
            // shown only on Settings' link diagnostic screen until the 2026-09-29 clean-out removed
            // that screen, so it moved here rather than going silent.
            if let message = watchLink.fileError {
                notice(message, systemImage: "doc.badge.ellipsis") {
                    watchLink.clearFileError()
                }
            }

            watchStatus

            Spacer(minLength: 0)

            Text(phaseTitle(model))
                .font(.system(size: 64, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)

            if let floorRemaining = model.engine.walkFloorRemainingSeconds {
                // An open recovery walk still under its floor. This is the headline the walk
                // actually has: the floor is the next thing that happens to it. Before this, the
                // branch below rendered `phaseRemainingSeconds` — nil for an open walk — so the
                // biggest number on the screen was "—" and the countdown lived in the Start
                // button's label, where it described the button instead of the walk.
                Text(Display.countdown(floorRemaining))
                    .font(.system(size: 88, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("until next leg").font(.headline).foregroundStyle(.white.opacity(0.75))
            } else if model.engine.phaseEndDate == nil {
                // Any phase with no end to count down to: an open cooldown, an open warmup, and an
                // open walk that has passed its floor and is now waiting on the runner. Elapsed is
                // the only honest number for all three.
                //
                // Tested on `phaseEndDate` rather than on `.cooldown`, which is what it used to
                // say: every open phase hit the countdown branch and rendered "—", so the cooldown
                // was merely the one that had been noticed.
                Text(Display.duration(model.engine.phaseElapsedSeconds))
                    .font(.system(size: 76, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("elapsed").font(.headline).foregroundStyle(.white.opacity(0.75))
            } else {
                Text(Display.countdown(model.engine.phaseRemainingSeconds))
                    .font(.system(size: 88, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("remaining").font(.headline).foregroundStyle(.white.opacity(0.75))
            }

            if model.engine.totalRepetitions > 0, model.engine.currentRepetition > 0 {
                Text("Round \(model.engine.currentRepetition) of \(model.engine.totalRepetitions)")
                    .font(.title3.weight(.medium))
            }

            if let next = model.engine.nextPhase {
                Text("Next: \(nextDescription(next))")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.8))
            }

            Text("Total elapsed \(Display.duration(model.engine.elapsedWorkoutSeconds))")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .monospacedDigit()

            Spacer(minLength: 0)

            controls(model: model)
        }
        .foregroundStyle(.white)
        .padding()
    }

    // MARK: - The Watch

    /// Shown when the run finishes. The Watch's workout ends by itself only if this run was
    /// connected to it; otherwise there may be one the runner started by hand, which they must end.
    /// Worded as a request, because that is all the phone knows: it asked; the Watch saves.
    private var completionMessage: String {
        if watchLink.lastRunAskedWatchToSave {
            return "Your Watch was asked to save the workout. Log how it felt."
        }
        return "If you recorded on your Apple Watch yourself, end that workout too, then log how it felt."
    }

    /// Whether the Watch is recording this run, in words, with Try again when it is not.
    ///
    /// A Watch that fails never stops the run — the timer and cues carry on exactly as they did
    /// before the Watch app existed — but the runner must know the run has no Watch data rather than
    /// discover it afterwards. Try again stays until the connection has a measured track record.
    @ViewBuilder
    private var watchStatus: some View {
        switch watchLink.runConnection {
        case .off:
            EmptyView()
        case .connecting:
            watchLine("Connecting to your Watch…", systemImage: "applewatch")
        case .connected where watchLink.phaseUnsent:
            // Connected, but the latest phase did not get through, so the Watch may show the wrong
            // one. Clears itself when a resend lands (`WatchLink.phaseUnsent`).
            watchLine("Watch not updated. It may show the wrong phase until the link recovers.",
                      systemImage: "exclamationmark.applewatch")
        case .connected:
            watchLine(watchConnectedText, systemImage: "applewatch.radiowaves.left.and.right")
        case .failed(let reason), .disconnected(let reason):
            VStack(spacing: 8) {
                watchLine(watchProblemText(reason), systemImage: "applewatch.slash")
                Button("Try again") { watchLink.retryRun() }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
        }
    }

    private var watchConnectedText: String {
        guard let bpm = watchLink.latestStatus?.heartRate else { return "Watch recording" }
        return "Watch recording · \(Display.heartRate(bpm))"
    }

    /// A system error's text often has no final full stop ("Unable to launch watch app"), which ran it
    /// into the next sentence; one is added when it is missing.
    private func watchProblemText(_ reason: String) -> String {
        let sentence = reason.hasSuffix(".") ? reason : reason + "."
        return sentence + " This run continues on the phone only."
    }

    /// Wraps to as many lines as it needs. Without `fixedSize` the run screen, short of height,
    /// squeezed it to one line — measured in the smoke test as "The Watch did not respond within
    /// 15 s. This run…", hiding the part that matters: the run continues on the phone only.
    private func watchLine(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white.opacity(0.85))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One dismissible banner.
    ///
    /// Extracted so its call sites cannot drift apart, and kept deliberately plain: this screen
    /// is read at arm's length in sunlight, and this project's type-checker has given up on smaller
    /// view expressions than this one.
    ///
    /// The closure is named `onDismiss` rather than `dismiss` on purpose — `dismiss` is already the
    /// environment action that closes the whole workout screen, and shadowing it here would be an
    /// unpleasant surprise for whoever edits this next.
    @ViewBuilder
    private func notice(_ message: String,
                        systemImage: String,
                        onDismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
            Text(message)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
        }
        .font(.footnote)
        .padding(10)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal)
    }

    @ViewBuilder
    private func controls(model: ActiveWorkoutModel) -> some View {
        VStack(spacing: 14) {
            openIntervalControls(model: model)

            // Offered from cooldown onwards: this is when the run is over but the details are
            // still fresh, and it is the last moment before the walk home blurs them.
            if model.engine.phase == .cooldown {
                Button {
                    showEarlyLog = true
                } label: {
                    Label(model.hasPendingLog ? "Edit run log" : "Log this run now",
                          systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }

            if model.engine.phase == .cooldown && model.engine.phaseEndDate == nil {
                Button {
                    model.finish()
                    promptToLog()
                } label: {
                    Text("Finish")
                        .font(.title2.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.25))
            }

            // Offered in every phase, not only during walks. The point of the app is to capture
            // data at the moment the thought exists, and a thought that lands 20 seconds into a run
            // interval is worth exactly as much as one that lands in the walk. The note records
            // which phase it was taken in, so capturing during a run is data rather than a mistake.
            Button {
                noteContext = model.noteContext()
            } label: {
                Label(noteButtonTitle(model), systemImage: "note.text.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.bordered)
            .tint(.white)

            // Pause and Skip slide rather than tap, because both were hit by accident on real runs:
            // the phone is carried in one hand with this screen in front of it for the whole
            // workout. Stacked full width rather than side by side — two half-width tracks leave
            // too little distance for the drag to mean anything.
            //
            // Resume stays a tap, deliberately. An unnoticed pause costs an interval before it is
            // spotted; an accidental resume happens while the runner is already looking at a phone
            // they paused on purpose, and when they do want it they want it immediately.
            if model.engine.isPaused {
                Button {
                    model.resume()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            } else {
                SlideToConfirm(title: "Slide to pause", systemImage: "pause.fill") {
                    model.pause()
                }

                // Hidden on an open-interval run. Skip and "End this leg" both end the phase and
                // advance, but Skip writes `wasSkipped: true`, no end reason and no readings — a
                // row describing an abandoned leg rather than a measured one. Offering a worse
                // version of the correct button, next to it, is how the wrong one gets tapped.
                // Starting the next leg early lives on that button now, behind a confirmation.
                if !model.engine.endsLegsByHand {
                    SlideToConfirm(title: "Slide to skip", systemImage: "forward.fill") {
                        model.skip()
                    }
                }
            }

            // Kept visually apart from Pause/Skip so it is not tapped by mistake mid-interval.
            Button(role: .destructive) {
                showEndConfirmation = true
            } label: {
                Text("End Workout")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .padding(.top, 6)
        }
    }

    /// The leg and recovery-walk controls of an open-interval workout.
    ///
    /// Empty for every other kind, so an interval run's screen is exactly what it was. The engine
    /// is asked which kind is running rather than the plan, so these buttons and the timer cannot
    /// disagree about what is happening.
    @ViewBuilder
    private func openIntervalControls(model: ActiveWorkoutModel) -> some View {
        if model.engine.endsLegsByHand && !model.engine.isPaused {
            switch model.engine.phase {
            case .run:
                Button {
                    // Ends the leg here, on the tap, before the sheet is built. The runner is
                    // already walking; the walk's cue and clock start with them, and the leg's
                    // recorded length stops where the running did. The sheet that follows only
                    // annotates it.
                    let context = model.legEndContext()
                    model.endLeg(context: context)
                    legEndContext = context
                } label: {
                    Text("End this leg")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.25))

            case .walk:
                Button {
                    model.markBaseline()
                } label: {
                    Label(baselineButtonTitle(model), systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .disabled(model.engine.hasMarkedBaseline)

                Button {
                    // Tappable before the floor, behind a confirmation that names the number.
                    // A disabled button with no way past it left Skip as the only early start —
                    // and Skip records the walk with no reason and the leg as abandoned.
                    if model.engine.walkFloorReached {
                        model.startNextLeg()
                    } else {
                        showEarlyLegConfirmation = true
                    }
                } label: {
                    // Says what it does, in every state. The countdown it used to carry is now the
                    // headline, where it belongs: the wait is a property of the walk, not of the
                    // button. Tapping before the floor still routes through the confirmation that
                    // names both numbers, so nothing is lost by the label going quiet.
                    Text("Start next leg")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 60)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.25))

            default:
                EmptyView()
            }
        }
    }

    /// What the mid-walk marker button reads, before and after it is tapped.
    ///
    /// Built as its own string rather than interpolated in the view — see `planSubtitle` in
    /// `PlannedWorkoutViews` and the Release-only type-checker failure LEARNINGS.md records.
    private func baselineButtonTitle(_ model: ActiveWorkoutModel) -> String {
        guard !model.engine.hasMarkedBaseline else { return "Baseline recorded" }
        return "Back to baseline"
    }

    /// Names both numbers, so the choice is made against the plan rather than against a feeling.
    private var earlyLegMessage: String {
        guard let model, let floor = model.engine.walkFloorSeconds else {
            return "Your walk has not reached its floor yet."
        }
        let walked = Display.duration(model.engine.phaseElapsedSeconds)
        let target = Display.duration(Double(floor))
        return "You have walked \(walked) of \(target). The walk is recorded as it happened either "
            + "way."
    }

    // MARK: - Presentation

    private var phaseColor: Color {
        guard let model else { return .black }
        switch model.engine.phase {
        case .run: return Color(red: 0.05, green: 0.35, blue: 0.18)
        case .walk: return Color(red: 0.10, green: 0.22, blue: 0.45)
        case .cooldown: return Color(red: 0.28, green: 0.20, blue: 0.42)
        case .countdown, .warmup: return Color(red: 0.30, green: 0.24, blue: 0.05)
        case .paused: return Color(white: 0.18)
        case .completed, .idle: return .black
        }
    }

    /// "Add note", or how many are already written.
    ///
    /// The count is the only acknowledgement the workout screen gives that a note was saved, and it
    /// is worth the fetch: a capture surface that shows nothing back reads as one that dropped the
    /// text. `notes(forExecution:)` reads `storeRevision`, which is what makes this redraw at all —
    /// Observation cannot see a SwiftData fetch.
    ///
    /// Built here rather than inline in the label: this project's SwiftUI type-checker gives up on
    /// interpolation inside a view initialiser and fails the Release build rather than warning.
    private func noteButtonTitle(_ model: ActiveWorkoutModel) -> String {
        guard let executionID = model.executionID else { return "Add note" }
        let count = logger.notes(forExecution: executionID).count
        return count == 0 ? "Add note" : "Add note (\(count))"
    }

    private func phaseTitle(_ model: ActiveWorkoutModel) -> String {
        if model.engine.isPaused { return "PAUSED" }
        return model.engine.phase.displayName.uppercased()
    }

    private func nextDescription(_ phase: WorkoutPhaseSchedule.PlannedPhase) -> String {
        guard let seconds = phase.plannedSeconds else {
            return "\(phase.phase.displayName) (open)"
        }
        return "\(phase.phase.displayName) \(PlannedWorkout.clockDuration(seconds))"
    }

    /// Asks the right question at the end of a workout, rather than always the same one.
    ///
    /// Logging during cooldown and then ending the run used to produce "No Apple Watch workout
    /// found" — because `findWorkoutToLog` searches `unloggedWorkouts`, and a run you have already
    /// logged is by definition not in it. So the app rendered "already logged" and "the Watch has
    /// not synced" identically, and picked the alarming wording for the harmless case. Worse, its
    /// "Log it anyway" button opened a fresh form, which would have written a second log for the
    /// same run.
    ///
    /// Checked against the execution rather than HealthKit: at the moment the timer stops, the
    /// Watch's workout usually does not exist yet, so HealthKit cannot answer "did I log this?"
    private func promptToLog() {
        if let executionID = model?.executionID,
           logger.existingLog(forExecution: executionID) != nil {
            showAlreadyLogged = true
        } else {
            showLogPrompt = true
        }
    }

    /// Opens the existing log for editing, in whichever form owns it.
    ///
    /// A log still waiting for its workout is edited through `EarlyRunLogView`, which looks it up by
    /// execution. Once joined, `RunLogFormView` owns it and looks it up by workout UUID. Sending it
    /// to the wrong one would show a blank form over saved writing — the exact bug that cost the
    /// owner a set of cooldown notes.
    private func editExistingLog() async {
        guard let executionID = model?.executionID,
              let log = logger.existingLog(forExecution: executionID) else {
            dismiss()
            return
        }

        guard let uuid = log.healthKitWorkoutUUID else {
            showEarlyLog = true
            return
        }

        // The workout list may be stale here; refresh before concluding it cannot be found.
        await logger.refresh()
        if let workout = logger.workout(withUUID: uuid) {
            workoutToLog = workout
        } else {
            logger.errorMessage = "This run is logged, but its workout could not be read from "
                + "Apple Health just now. Open it from History to edit the log."
            dismiss()
        }
    }

    /// After finishing, identify the HealthKit workout the Watch just recorded.
    ///
    /// Runs the matcher rather than taking the most recent workout: if more than one is plausible
    /// the user picks, because a log attached to the wrong workout is silently wrong forever.
    /// HealthKit can take a little while to receive the workout, so an empty result is reported as
    /// "not there yet" rather than as an error.
    private func findWorkoutToLog() async {
        await logger.refresh()

        let outcome = RecentWorkoutMatcher.match(workouts: logger.unloggedWorkouts,
                                                 execution: model?.matchCandidate)

        switch outcome {
        case .matched(let uuid, _):
            if let workout = logger.workout(withUUID: uuid) {
                // A log written during cooldown gets its workout attached here, so the objective
                // and subjective halves join up without the user re-entering anything.
                if let executionID = model?.executionID {
                    if let error = logger.attach(workout: workout,
                                                 toPendingLogFor: executionID) {
                        logger.errorMessage = error
                    }
                }
                workoutToLog = workout
            } else {
                reportNotArrived()
            }

        case .ambiguous(let uuids):
            let choices = uuids.compactMap { logger.workout(withUUID: $0) }
            if choices.count > 1 {
                candidateWorkouts = CandidateList(workouts: choices)
            } else if let only = choices.first {
                workoutToLog = only
            } else {
                reportNotArrived()
            }

        case .outsideWindow(let uuids, let offset):
            // Nearest first, from the matcher. Offering only the closest keeps the decision to one
            // yes or no; the rest are reachable by logging from Today if this one is wrong.
            if let nearest = uuids.compactMap({ logger.workout(withUUID: $0) }).first {
                nearMiss = NearMiss(workout: nearest, offsetSeconds: offset)
            } else {
                reportNotArrived()
            }

        case .noCandidates:
            reportNotArrived()
        }
    }

    /// Attaches a workout the user confirmed despite it falling outside the window.
    ///
    /// Goes through the same `attach` as the automatic path rather than writing the UUID here, so
    /// the intervals are stamped too. Skipping that is how a run once ended up with its legs naming
    /// no workout while the log looked fine.
    private func link(_ miss: NearMiss) {
        nearMiss = nil
        if let executionID = model?.executionID,
           let error = logger.attach(workout: miss.workout, toPendingLogFor: executionID) {
            logger.errorMessage = error
        }
        workoutToLog = miss.workout
    }

    /// Says how far apart the two starts were and what using the workout will do.
    ///
    /// Built outside the view initialiser: interpolation mixed with `+` inside one defeats the
    /// SwiftUI type-checker in Release only, which LEARNINGS.md records.
    private func nearMissMessage(_ miss: NearMiss) -> String {
        let gap = Display.duration(miss.offsetSeconds)
        let distance = Display.miles(miss.workout.distanceMiles)
        return "A \(distance) run started \(gap) away from when you tapped Start. This app links "
            + "them automatically only within two minutes, so it did not, and waiting will not "
            + "change that.\n\nUsing it attaches this session's legs, distance, pace and heart "
            + "rate to that workout."
    }

    /// No HealthKit workout matched — which has two very different causes.
    ///
    /// Either a Watch workout is still syncing, or there was never one: the timer can be run on
    /// the phone alone, with no Watch involved. The app used to assume the first and tell the user
    /// to end a workout that did not exist. Since a run log no longer requires a HealthKit
    /// workout, the honest response is to offer to log it anyway.
    private func reportNotArrived() {
        showNoWorkoutOptions = true
    }
}
