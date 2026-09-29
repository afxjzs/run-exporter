import Foundation
import Observation
import SwiftData

/// Owns one run of the interval timer: the engine, the audio, and the records they produce.
///
/// The engine stays free of audio and persistence; this type wires the three together. Interval
/// records are written to the store **as each phase ends**, not at the finish, so a workout that
/// is interrupted by the app being killed still leaves everything it completed.
@MainActor
@Observable
final class ActiveWorkoutModel {

    let engine = IntervalTimerEngine()
    let liveActivity = LiveActivityController()

    private(set) var executionID: UUID?
    private(set) var plannedWorkoutID: UUID?
    private(set) var planName = ""
    /// When the timer started — the stand-in workout start until HealthKit's own is known.
    private(set) var startedAt = Date()
    private(set) var activityType: PlannedActivityType = .running
    /// True once a log has been written mid-workout for this execution.
    ///
    /// Read by the cooldown button, which offers "Edit run log" rather than "Log this run now".
    /// Refreshed from the store by `refreshPendingLog(using:)` — it used to be a plain flag that
    /// nothing ever set true, so the button spent every run inviting a first log for a run that
    /// might already have one.
    private(set) var hasPendingLog = false

    /// False until the user actually starts the workout.
    ///
    /// The screen is created armed and records nothing: no timer session, no audio session, no
    /// Live Activity. All of that begins at `start(plan:)`. The reason is the two-device start —
    /// there is no app on the Watch, so a run begins as a tap there and a tap here, and
    /// `RecentWorkoutMatcher` will only link the two recordings when their starts fall within
    /// `startToleranceSeconds`. A session opened when the screen appeared would spend that budget
    /// on however long the walk between devices took.
    private(set) var hasStarted = false
    private(set) var runIntervalSeconds = 0
    private(set) var walkIntervalSeconds = 0
    private(set) var plannedRepetitions = 0


    /// A problem the user must see: a plan that cannot be scheduled, audio that will not start,
    /// or an interval that could not be saved.
    var errorMessage: String?
    /// Set when the workout finishes, so the UI can offer to log it.
    private(set) var didFinish = false

    private let store: LoggerStore
    private let defaults: LoggerDefaults
    private let audio: AudioCueEngine
    /// Starts, updates and finishes the Watch's workout for this run (watch plan step 2). Nil only
    /// in tests of the timer and logging, which do not involve a Watch. Required rather than
    /// defaulted, so no caller can leave the Watch out by forgetting it.
    let watchLink: WatchLink?

    init(store: LoggerStore, defaults: LoggerDefaults, audio: AudioCueEngine, watchLink: WatchLink?) {
        self.store = store
        self.defaults = defaults
        self.audio = audio
        self.watchLink = watchLink

        engine.onCue = { [weak self] cue in
            self?.audio.play(cue)
        }
        engine.onIntervalCompleted = { [weak self] interval in
            self?.persist(interval)
        }
        engine.onFinished = { [weak self] in
            self?.finishUp()
        }
        // A phase change is exactly when the Lock Screen card needs new state — and the only time
        // it does, since the widget ticks its own clock between transitions. The same is true of the
        // Watch: this one hook covers entering a phase, pause, resume, skip, a leg's end and the
        // finish, so nothing that moves the run can leave the Watch behind.
        engine.onPhaseChanged = { [weak self] in
            self?.refreshLiveActivity()
            self?.watchLink?.phaseChanged()
        }
    }

    /// Where the run is right now, in the shape the Watch is sent (`WatchPhaseMapping`).
    private func watchAnchor(oneWayLatency: TimeInterval) -> PhaseAnchor? {
        let snapshot = WatchPhaseMapping.EngineSnapshot(
            phase: engine.phase,
            plannedPhase: engine.currentPlannedPhase?.phase,
            isPaused: engine.isPaused,
            repetition: engine.currentRepetition,
            totalRepetitions: engine.totalRepetitions,
            phaseStart: engine.phaseStartDate,
            phaseEnd: engine.phaseEndDate,
            frozenElapsed: engine.phaseElapsedSeconds,
            frozenRemaining: engine.phaseRemainingSeconds)
        return WatchPhaseMapping.anchor(from: snapshot, now: Date(), oneWayLatency: oneWayLatency)
    }

    /// Current engine state, in the shape the Live Activity needs.
    ///
    /// Carries the whole schedule, not just the current phase: iOS discards Live Activity updates
    /// sent while the app is backgrounded, so anything the card must keep right through a locked
    /// workout has to be derivable from a single push. See `ContentState.timelineStart`.
    private var liveActivityState: RunWorkoutAttributes.ContentState {
        let timeline = engine.liveActivityTimeline
        return RunWorkoutAttributes.ContentState(
            phaseName: engine.phase.displayName,
            phaseRawValue: engine.phase.rawValue,
            repetition: engine.currentRepetition,
            totalRepetitions: engine.totalRepetitions,
            phaseStart: engine.phaseStartDate,
            phaseEnd: engine.phaseEndDate,
            nextPhaseName: engine.nextPhase.map { phase in
                guard let seconds = phase.plannedSeconds else { return phase.phase.displayName }
                return "\(phase.phase.displayName) \(PlannedWorkout.clockDuration(seconds))"
            },
            isPaused: engine.isPaused,
            pausedAt: engine.isPaused ? Date() : nil,
            timelineStart: timeline?.start,
            phaseKinds: timeline?.kinds ?? "",
            phaseDurations: timeline?.durations ?? [])
    }

    private func refreshLiveActivity() {
        guard liveActivity.isActive else { return }
        liveActivity.update(liveActivityState)
    }

    var isRunning: Bool { engine.isRunning }

    // MARK: - Starting

    /// Prepares audio, records the execution, and starts the timer.
    ///
    /// Audio is prepared *before* the first cue can be due, and a failure to prepare is reported
    /// rather than letting the workout start silently while appearing to work.
    func start(plan: PlannedWorkout) {
        // A second tap must not open a second timer session. Two overlapping executions around one
        // run is what made a real run permanently ambiguous to the matcher, and this is now a
        // button the user can hit twice rather than something the screen did once on appearing.
        guard !hasStarted else { return }
        // Set before anything can fail, not after everything succeeds. `recordExecution` below
        // writes the session, so a start that then fails and left this false would let a retry
        // write a second one — the ambiguity this guard exists to prevent. A failed start shows its
        // error on the running screen instead, which is what it did before the screen was armed.
        hasStarted = true
        errorMessage = nil
        didFinish = false

        if let audioError = audio.prepare(settings: defaults) {
            errorMessage = audioError
        } else if let sessionError = audio.beginWorkoutAudio() {
            errorMessage = sessionError
        }

        let execution = recordExecution(for: plan)
        executionID = execution?.id
        plannedWorkoutID = plan.id
        planName = plan.name
        startedAt = execution?.timerStartedAt ?? Date()
        activityType = plan.activityTypeValue ?? .running
        hasPendingLog = false
        // A plan of several segments offers the post-run log form no interval shape, because a
        // blank field asks the user and a wrong one does not. `logDraftContext` turns these zeros
        // into nils.
        runIntervalSeconds = plan.singleShape?.runSeconds ?? 0
        walkIntervalSeconds = plan.singleShape?.walkSeconds ?? 0
        plannedRepetitions = plan.totalRepetitions

        do {
            try engine.start(plan: plan, settings: defaults)
            // Started after the engine, so the first state pushed is a real phase rather than
            // `idle`. `start` clears stale activities itself, in order — doing it here as a
            // separate call is what previously killed the new card.
            liveActivity.start(workoutName: plan.name,
                               activityName: activityType.displayName,
                               state: liveActivityState)
            // After the engine, so the Watch is sent a real phase. The run does not wait for it: a
            // Watch that fails to connect leaves the run exactly as it was before the Watch app
            // existed, and the screen says so, with Try again.
            watchLink?.beginRun { [weak self] latency in
                self?.watchAnchor(oneWayLatency: latency)
            }
        } catch {
            // The plan itself is unusable — stop cleanly rather than showing a dead timer.
            errorMessage = error.localizedDescription
            audio.endWorkoutAudio()
            engine.reset()
        }
    }

    /// Re-reads whether this session already has a log.
    ///
    /// Asked of the store rather than remembered, because the mid-run log sheet closes on both save
    /// and cancel and only the store knows which happened. Called when that sheet is dismissed:
    /// once per dismissal, not once per render of a screen that redraws every second.
    func refreshPendingLog(using logger: RunLoggerModel) {
        guard let executionID else {
            hasPendingLog = false
            return
        }
        hasPendingLog = logger.existingLog(forExecution: executionID) != nil
    }

    private func recordExecution(for plan: PlannedWorkout) -> PendingWorkoutExecution? {
        guard let context = store.context else {
            errorMessage = "The run logger database is unavailable, so this workout's intervals "
                + "will not be recorded. The timer and cues still work."
            return nil
        }
        guard let activity = plan.activityTypeValue else {
            errorMessage = "This workout's activity type is \"\(plan.activityType)\", which this "
                + "version does not recognize. Edit the workout and choose an activity."
            return nil
        }

        // A plan of several segments has no single run or walk length, so it records none — see
        // `PendingWorkoutExecution.runIntervalSeconds` for why zero rather than the first segment.
        // `blockShape` carries the whole of it either way, and rounds are well defined for any
        // plan, so they stay populated.
        let singleShape = plan.singleShape

        let execution = PendingWorkoutExecution(
            plannedWorkoutID: plan.id,
            plannedWorkoutName: plan.name,
            expectedActivityType: activity,
            expectedDurationSeconds: plan.expectedTotalSeconds,
            runIntervalSeconds: singleShape?.runSeconds ?? 0,
            walkIntervalSeconds: singleShape?.walkSeconds ?? 0,
            plannedRepetitions: plan.totalRepetitions,
            status: .started)
        execution.blockShape = plan.blockShapeDescriptor
        execution.timerStartedAt = Date()
        context.insert(execution)

        if let error = store.save() {
            errorMessage = "This workout's intervals may not be recorded: \(error)"
        }
        return execution
    }

    // MARK: - Controls

    func pause() { engine.pause() }
    func resume() { engine.resume() }
    func skip() { engine.skip() }

    // MARK: - Open intervals

    /// Records that the signal the plan watches has gone, without ending the recovery walk.
    func markBaseline() { engine.markBaseline() }

    /// Ends the recovery walk and starts the next leg.
    func startNextLeg() { engine.startNextLeg() }

    /// Where the workout was when the runner reached for "End this leg".
    ///
    /// Frozen at the tap, like `NoteContext`, and for a sharper reason: the leg ended when the
    /// runner stopped running, not when they finished rating it. Stamping at save time would add
    /// however long the slider took to the leg's length — directly into the number the run exists
    /// to measure.
    struct LegEndContext: Identifiable {
        let id = UUID()
        let legNumber: Int?
        let legSeconds: TimeInterval
        let endedAt: Date
    }

    func legEndContext(now: Date = Date()) -> LegEndContext {
        LegEndContext(legNumber: engine.currentRepetition > 0 ? engine.currentRepetition : nil,
                      legSeconds: engine.phaseElapsedSeconds,
                      endedAt: now)
    }

    /// Ends the leg in progress, immediately.
    ///
    /// Called from the tap, **not** from the sheet that follows it. The runner starts walking the
    /// moment they press the button, so the walk has to start then too: its cue sounds, its clock
    /// starts, and the leg's recorded length is what they actually ran. Ending it on the sheet's
    /// Done button instead added however long the rating took onto the leg — straight into the one
    /// number this workout exists to measure — and left them running on a screen already showing
    /// the walk.
    ///
    /// The readings arrive afterwards, through `recordLegReadings`, against the row this writes.
    func endLeg(context: LegEndContext) {
        engine.endLeg(reason: .runnerEnded, now: context.endedAt)
    }

    /// The interval row written for the leg that just ended, so the sheet can annotate it.
    ///
    /// Set synchronously inside `endLeg` — `persist` runs on the engine's `onIntervalCompleted`
    /// callback before that call returns — so it is always the leg the sheet is about. Nothing else
    /// can complete a phase in between: the next transition needs the runner, and the sheet is in
    /// front of them.
    private(set) var lastLegLog: WorkoutIntervalLog?

    /// Attaches the readings given on the sheet to the leg that has already ended.
    ///
    /// Returns a message on failure rather than losing them quietly. The leg itself is already
    /// recorded either way, so a failure here costs the annotation, not the workout.
    func recordLegReadings(_ readings: BodySignalReadings) -> String? {
        guard let lastLegLog else {
            return "That leg was not recorded, so there is nothing to attach these readings to."
        }
        lastLegLog.signalReadings = readings
        return store.save()
    }
    func restartInterval() { engine.restartCurrentPhase() }

    /// Ends an open cooldown normally.
    func finish() { engine.finishCooldown() }

    /// Stops everything immediately.
    func endEarly() { engine.end() }

    /// Called when the app returns to the foreground, so the display is right before the next
    /// scheduled tick rather than up to a tenth of a second stale.
    func refreshFromClock() {
        engine.tick()
        // Returning to the foreground is the one moment iOS reliably *accepts* a Live Activity
        // update, and `tick()` only pushes one if a phase boundary happens to land on this exact
        // instant — so a card that went stale while the phone was locked would otherwise stay
        // wrong even while the user is looking at the corrected app. Push unconditionally.
        refreshLiveActivity()
    }

    // MARK: - Recording

    private func persist(_ interval: IntervalTimerEngine.RecordedInterval) {
        // The single most consequential silent failure this file could have, and it had it: both of
        // these used to be one `guard ... else { return }`, so a run could record not one interval
        // boundary — the data this whole app exists to capture — and look completely normal while
        // doing it. `start()` does report why an execution could not be created, but that message is
        // one line at the top of a screen being read at arm's length, and this added nothing to it.
        guard let executionID else {
            errorMessage = "This workout's intervals are NOT being recorded, because no timer "
                + "session could be created for it. The timer and cues still work, but the run and "
                + "walk boundaries will not appear in your export."
            return
        }
        guard let context = store.context else {
            errorMessage = "This workout's intervals are NOT being recorded: the run logger "
                + "database is unavailable. The timer and cues still work."
            return
        }

        let log = WorkoutIntervalLog(executionID: executionID,
                                     sequenceIndex: interval.sequenceIndex,
                                     phaseType: interval.phase,
                                     repetitionNumber: interval.repetition,
                                     plannedDurationSeconds: interval.plannedSeconds,
                                     actualDurationSeconds: interval.actualSeconds,
                                     startDate: interval.start,
                                     endDate: interval.end,
                                     wasSkipped: interval.wasSkipped,
                                     wasInterrupted: interval.wasInterrupted,
                                     endReason: interval.endReason,
                                     signalReadings: interval.signals,
                                     baselineReachedAt: interval.baselineReachedAt)
        context.insert(log)

        // Remembered so the end-of-leg sheet can attach its readings to the row that was just
        // written. Only a leg qualifies: a walk or a cooldown has nothing to annotate, and letting
        // one of those become `lastLegLog` would send the readings to the wrong record.
        if interval.phase == .run, interval.endReason != nil {
            lastLegLog = log
        }

        if let error = store.save() {
            errorMessage = "An interval could not be saved: \(error)"
        }
    }

    private func finishUp() {
        audio.endWorkoutAudio()
        liveActivity.end(finalState: liveActivityState)
        // The Watch saves its workout tagged with this execution — the id the phone will join on.
        watchLink?.finishRun(executionID: executionID)
        didFinish = true

        // No execution means there is nothing to mark finished, and `start()` already said why.
        guard let executionID else { return }

        var descriptor = FetchDescriptor<PendingWorkoutExecution>(
            predicate: #Predicate { $0.id == executionID })
        descriptor.fetchLimit = 1

        switch store.fetch(descriptor) {
        case .success(let executions):
            guard let execution = executions.first else {
                errorMessage = "This workout finished, but the timer session it belongs to could no "
                    + "longer be found, so it was not marked as finished. It may later be treated "
                    + "as an abandoned timer."
                return
            }
            execution.setStatus(.completed)
            execution.timerEndedAt = Date()
            execution.completedRepetitions = engine.completedRunIntervals
            if let error = store.save() {
                errorMessage = "The workout finished, but its record could not be updated: \(error)"
            }

        case .failure(let error):
            // This failure manufactures the exact problem the retirement sweep exists to clean up.
            // Without `timerEndedAt` the session stays `.started` with no end — which is the precise
            // shape of an abandoned timer, and indistinguishable from the user having force-quit.
            // Six such rows exist in the owner's store, and because this was silent there is no way
            // to know whether any of them came from here rather than from a force-quit.
            errorMessage = "The workout finished, but its timer session could not be read, so it was "
                + "not marked as finished and may later be treated as abandoned: \(error.message)"
        }
    }

    /// Abandons the session without finishing it — used when the user backs out of the screen.
    func cancel() {
        guard isRunning else { return }
        // Before `engine.end()`, whose finish callback would otherwise tell the Watch to *save* a
        // run the user has just abandoned.
        watchLink?.abandonRun()
        engine.end()
        audio.endWorkoutAudio()
        liveActivity.end(finalState: nil)

        guard let executionID else { return }
        var descriptor = FetchDescriptor<PendingWorkoutExecution>(
            predicate: #Predicate { $0.id == executionID })
        descriptor.fetchLimit = 1
        switch store.fetch(descriptor) {
        case .success(let executions):
            guard let execution = executions.first else { return }
            execution.setStatus(.cancelled)
            if let error = store.save() {
                errorMessage = "The workout was cancelled, but its record could not be updated: "
                    + error
            }

        case .failure(let error):
            // A session left uncancelled stays in `matchable`, so it can still be offered as the
            // match for a later run and claim intervals that are not its own.
            errorMessage = "The workout was cancelled, but its timer session could not be read, so "
                + "it may still be offered as a match for a later run: \(error.message)"
        }
    }

    /// This session as a matching candidate, so the finished HealthKit workout can be identified
    /// rather than guessed at.
    var matchCandidate: RecentWorkoutMatcher.Candidate? {
        guard let executionID, let plannedWorkoutID else { return nil }
        _ = plannedWorkoutID
        // The `store.context` guard that used to sit here returned nil silently for an unavailable
        // database, which is now the `.failure` arm's job — `store.fetch` reports it rather than
        // letting it read as "no candidate". Nothing else used the context.

        var descriptor = FetchDescriptor<PendingWorkoutExecution>(
            predicate: #Predicate { $0.id == executionID })
        descriptor.fetchLimit = 1
        // `matchCandidate` rather than a mapping written out here. This was the second of two
        // hand-written copies, and the copies disagreed about which timestamp to pass as `createdAt`
        // — the field `score()` keys on — so the same workout and execution could score differently
        // depending on which matching direction happened to ask.
        switch store.fetch(descriptor) {
        case .success(let executions):
            guard let execution = executions.first else { return nil }
            return execution.matchCandidate
        case .failure(let error):
            // Previously discarded, which made an unreadable store indistinguishable from "no
            // execution" and silently cost the workout its match.
            errorMessage = error.message
            return nil
        }
    }

    // MARK: - Notes captured mid-workout

    /// Where the workout was when the user reached for the note button.
    ///
    /// Frozen at the moment the sheet opens rather than read again at save time. Open the sheet in
    /// walk 3, thumb in a sentence, and the walk can end while you are typing — stamping at save
    /// would file a thought about the walk under the run that followed it. Freezing also keeps
    /// `takenAt` inside the interval that `phase` names, so the export's timestamp join to
    /// `workout_intervals.csv` can never contradict its own phase column.
    struct NoteContext: Identifiable {
        /// Identity for `.sheet(item:)`. Presenting by item rather than by a boolean is what
        /// guarantees the sheet is built with the context captured at the tap, not one re-read
        /// after the phase has moved on.
        let id = UUID()
        let phase: WorkoutPhase
        let repetition: Int?
        let secondsIntoWorkout: TimeInterval
        let takenAt: Date
    }

    /// The current phase, captured for a note about to be written.
    ///
    /// Reads already-computed engine state and nothing else: no tick is forced, no audio call is
    /// made, and the schedule is untouched. Opening the note sheet therefore cannot perturb the
    /// timer or the audio session, which is the hard constraint on this whole feature.
    ///
    /// The phase is recorded exactly as the engine reports it, including `paused`. A user who
    /// stopped the clock to type did pause, and saying "walk" instead would be a small lie about
    /// what happened; the repetition still says which round they were in either way.
    func noteContext(now: Date = Date()) -> NoteContext {
        NoteContext(phase: engine.phase,
                    repetition: engine.currentRepetition > 0 ? engine.currentRepetition : nil,
                    secondsIntoWorkout: engine.elapsedWorkoutSeconds,
                    takenAt: now)
    }

    /// Writes one note against this workout. Returns an error message on failure, never silence.
    func saveNote(_ text: String,
                  context: NoteContext,
                  logger: RunLoggerModel) -> String? {
        guard let executionID else {
            // `start()` already reported why there is no session, but that message is one line at
            // the top of a screen read at arm's length. A note the user has just typed disappearing
            // needs its own answer.
            return "There is no timer session for this workout, so this note has nowhere to "
                + "attach. Copy the text somewhere safe before closing this — it cannot be saved "
                + "here."
        }
        return logger.saveNote(text,
                               executionID: executionID,
                               phase: context.phase,
                               repetition: context.repetition,
                               secondsIntoWorkout: context.secondsIntoWorkout,
                               at: context.takenAt)
    }

    /// The draft values the post-run form should start from.
    var logDraftContext: (plannedWorkoutID: UUID?, executionID: UUID?,
                          run: Int?, walk: Int?, planned: Int?, completed: Int?) {
        (plannedWorkoutID, executionID,
         runIntervalSeconds > 0 ? runIntervalSeconds : nil,
         walkIntervalSeconds > 0 ? walkIntervalSeconds : nil,
         plannedRepetitions > 0 ? plannedRepetitions : nil,
         engine.completedRunIntervals)
    }
}
