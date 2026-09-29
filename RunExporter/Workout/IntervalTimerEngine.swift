import Foundation
import Observation

/// Runs a `WorkoutPhaseSchedule` against the wall clock and emits cues and interval records.
///
/// ## Why absolute timestamps
///
/// Every boundary is a `Date`, and each phase's end is derived from the *previous boundary* plus
/// the planned duration — never from "now" and never by decrementing a counter. A tick that
/// arrives late, or a burst of ticks after the app was suspended, therefore cannot accumulate
/// drift: the schedule's shape is fixed the moment a phase starts, and a late tick simply lands
/// further into it.
///
/// The engine deliberately knows nothing about audio, SwiftData or SwiftUI. It reports what
/// happened through `onCue` and `onIntervalCompleted`, which makes the sequencing testable and
/// keeps a cue failure from corrupting timing.
@MainActor
@Observable
final class IntervalTimerEngine {

    // MARK: - Observable state

    private(set) var phase: WorkoutPhase = .idle
    private(set) var currentRepetition = 0
    private(set) var totalRepetitions = 0
    private(set) var phaseStartDate = Date()
    /// Nil for an open-ended phase (open warmup, open cooldown) and while paused.
    private(set) var phaseEndDate: Date?
    private(set) var isPaused = false

    /// Recomputed each tick from `Date()`, never accumulated.
    private(set) var phaseElapsedSeconds: TimeInterval = 0
    private(set) var phaseRemainingSeconds: TimeInterval?
    /// Wall-clock time since the workout began, minus paused time.
    private(set) var elapsedWorkoutSeconds: TimeInterval = 0

    /// Run intervals that ran to their planned end. Pre-fills "completed repetitions" in the
    /// post-run form.
    private(set) var completedRunIntervals = 0

    /// Running accumulated across finished run phases, in seconds.
    ///
    /// The number an open-interval run ends on, and the one announced at the start of each leg.
    /// Run phases only: walks are recovery and were never part of the target. An interval plan
    /// tracks it too — it costs nothing and means the figure is never a special case.
    private(set) var accumulatedRunSeconds = 0

    /// A problem the user needs to know about — the engine never fails quietly.
    private(set) var lastError: String?

    // MARK: - Callbacks

    /// Fired when a cue should sound. Never called for a cue the engine skipped over during
    /// catch-up, so a suspended app cannot wake up and play five cues at once.
    var onCue: ((AudioCue) -> Void)?
    /// Fired once per completed phase, in order.
    var onIntervalCompleted: ((RecordedInterval) -> Void)?
    /// Fired when the workout reaches its end.
    var onFinished: (() -> Void)?
    /// Fired whenever the displayed phase changes — entering a phase, pausing, or resuming.
    /// Lets an observer refresh out-of-app surfaces without polling.
    var onPhaseChanged: (() -> Void)?

    /// The whole plan as a timeline, for a Live Activity that must stay correct without updates.
    ///
    /// The anchor is derived by walking **back** from the current phase's real start rather than
    /// from `workoutStartDate`, so pauses and skips are absorbed: whatever has actually happened,
    /// the current phase always lands where the timeline says it does. Phases already behind us are
    /// drawn as if they ran to plan, which is harmless — they render as complete either way.
    ///
    /// Returns `nil` when nothing is scheduled, so the card carries no timeline rather than an
    /// invented one.
    var liveActivityTimeline: (start: Date, kinds: String, durations: [Int])? {
        // `fixedPhases` is empty for a workout with no knowable end — an open-interval run. The
        // card then carries no timeline, which is the honest answer: a timeline needs every phase
        // and its length up front, and this one has neither until it has been run.
        guard let source, !source.fixedPhases.isEmpty else { return nil }

        let elapsedBefore = source.fixedPhases
            .prefix(currentIndex)
            .reduce(0) { $0 + ($1.plannedSeconds ?? 0) }
        let anchor = phaseStartDate.addingTimeInterval(-TimeInterval(elapsedBefore))

        let kinds = String(source.fixedPhases.map { $0.phase.timelineSymbol })
        let durations = source.fixedPhases.map { $0.plannedSeconds ?? 0 }
        return (anchor, kinds, durations)
    }

    /// One elapsed phase, as it actually happened.
    struct RecordedInterval {
        let sequenceIndex: Int
        let phase: WorkoutPhase
        let repetition: Int?
        let plannedSeconds: Int?
        let start: Date
        let end: Date
        let wasSkipped: Bool
        /// True when the phase ended without the app being awake to cue it — its boundary is
        /// accurate, but no cue was heard for it.
        let wasInterrupted: Bool
        /// Why an open-interval leg stopped. Nil for every other phase, which measures nothing of
        /// the kind — and nil is what reaches the export, where blank never means zero.
        var endReason: LegEndReason?
        /// When, during a recovery walk, the runner reported the signal gone. Nil when
        /// it had not by the time the walk ended, which is a real and different answer.
        var baselineReachedAt: Date?
        /// The 0–10 readings given as a leg ended, one per body area. Empty for every phase that
        /// was never asked. They travel with the event rather than through state on the model, so
        /// the record written is a pure function of what happened.
        var signals = BodySignalReadings()

        var actualSeconds: Double { end.timeIntervalSince(start) }
    }

    // MARK: - Private state

    /// Where the phases come from: a fixed `WorkoutPhaseSchedule` for an interval plan, a computed
    /// `OpenIntervalSchedule` for a plan whose legs the runner ends. One code path here
    /// either way — the difference is entirely inside the source.
    private var source: (any WorkoutPhaseSource)?
    private var currentIndex = 0
    /// Set by `markBaseline` during a recovery walk, attached to that walk when it completes and
    /// cleared with it. Held here rather than on the phase because a phase in progress is not yet
    /// a record.
    private var pendingBaselineDate: Date?
    private var workoutStartDate: Date?
    private var pausedAtDate: Date?
    private var totalPausedSeconds: TimeInterval = 0
    private var sequenceCounter = 0

    /// Countdown ticks and the five-second warning, with the instant each becomes due.
    private var pendingCues: [(fireDate: Date, cue: AudioCue)] = []

    private var ticker: Timer?
    private var settings: LoggerDefaults?

    /// How often the engine re-reads the clock. Well under the ~250 ms cue accuracy the spec asks
    /// for, and cheap because a tick is arithmetic on two `Date`s.
    private static let tickInterval: TimeInterval = 0.1

    var isRunning: Bool { source != nil && phase != .idle && phase != .completed }

    /// The phase after the current one, for the "Next: …" line.
    var nextPhase: WorkoutPhaseSchedule.PlannedPhase? {
        source?.phase(at: currentIndex + 1, accumulatedRunSeconds: accumulatedRunSeconds)
    }

    var currentPlannedPhase: WorkoutPhaseSchedule.PlannedPhase? {
        source?.phase(at: currentIndex, accumulatedRunSeconds: accumulatedRunSeconds)
    }

    // MARK: - Open intervals
    //
    // The run screen asks the engine these rather than reaching for the plan, so what the buttons
    // do and what the timer does cannot disagree about which kind of workout is running.

    /// True when this workout's legs end by the runner's hand — an open-interval plan.
    var endsLegsByHand: Bool { source?.legsEndByHand == true }

    /// The shortest this workout's recovery walks run, or nil when its walks are timed.
    var walkFloorSeconds: Int? { source?.walkFloorSeconds }

    /// True once the runner has marked the signal gone during the walk in progress.
    ///
    /// Drives the button's disabled state. The first answer stands, so a second tap cannot quietly
    /// rewrite a measurement already taken.
    var hasMarkedBaseline: Bool { pendingBaselineDate != nil }

    /// True when the walk in progress has run at least its floor.
    ///
    /// The floor does not end the walk — only the runner does — but it is what the Start button
    /// waits for, since starting before it contradicts the plan the runner wrote.
    var walkFloorReached: Bool {
        guard phase == .walk, let floor = walkFloorSeconds else { return false }
        return phaseElapsedSeconds >= Double(floor)
    }

    /// How much longer the walk in progress runs before it reaches its floor, or nil when the
    /// question does not apply: any other phase, a timed walk, or a floor already passed.
    ///
    /// Exists so the headline can count the floor down. An open walk has no `phaseEndDate`, so
    /// `phaseRemainingSeconds` is nil and `Display.countdown` rendered it as "—" for the entire
    /// walk, while the only real countdown sat in the Start button's label — describing the
    /// button's availability rather than the walk the runner was in.
    ///
    /// Returns nil rather than zero at the floor so the caller has one value to switch on, and
    /// cannot render a countdown that has stopped counting.
    var walkFloorRemainingSeconds: TimeInterval? {
        guard phase == .walk, let floor = walkFloorSeconds else { return nil }
        let remaining = Double(floor) - phaseElapsedSeconds
        return remaining > 0 ? remaining : nil
    }

    // MARK: - Lifecycle

    /// Starts a workout. Throws when the plan cannot be scheduled at all, so the UI can explain
    /// why instead of showing a timer that will not run.
    func start(plan: PlannedWorkout, settings: LoggerDefaults, now: Date = Date()) throws {
        // `makePhaseSource` decides by the plan's kind, and is also what the editors call to refuse
        // saving a plan the timer would not accept. One switch, so the two cannot disagree.
        let source = try plan.makePhaseSource()

        accumulatedRunSeconds = 0
        guard let first = source.phase(at: 0, accumulatedRunSeconds: 0) else {
            // `totalRepetitions`, not the flat field: for a plan carrying blocks the flat field is
            // not the plan's round count, and this number goes into the message the user reads.
            throw WorkoutPhaseSchedule.ScheduleError.nonPositiveRepetitions(plan.totalRepetitions)
        }

        self.source = source
        self.settings = settings
        totalRepetitions = source.totalRepetitions
        currentIndex = 0
        sequenceCounter = 0
        totalPausedSeconds = 0
        pausedAtDate = nil
        isPaused = false
        lastError = nil
        workoutStartDate = now

        enter(first, at: now, announce: true)
        startTicker()
        tick(now: now)
    }

    /// Ends the workout immediately, recording the phase in progress.
    func end(now: Date = Date()) {
        guard isRunning else { return }
        onCue?(.ended)
        // Ending while paused must not fold the pause into the interval it interrupted: the phase
        // really stopped when the pause began.
        completeCurrentPhase(at: pausedAtDate ?? now, wasSkipped: true, wasInterrupted: false)
        finish(at: now, announce: false)
    }

    /// Ends the running leg in progress, recording why it stopped.
    ///
    /// This is a leg's **normal completion**, not a skip: under an open-interval plan every leg
    /// ends by the owner's hand, and `completeCurrentPhase` refuses to count a skipped run. Routing
    /// this through `skip()` would report a workout in which no leg was ever completed and leave
    /// the export's `wasSkipped` true on every row.
    func endLeg(reason: LegEndReason, signals: BodySignalReadings = BodySignalReadings(), now: Date = Date()) {
        guard isRunning, !isPaused else { return }
        guard source?.legsEndByHand == true, phase == .run else {
            // Never silently: on an interval plan this would close a run early while recording it
            // as having run to plan, which overstates a workout that did not happen.
            lastError = "This workout's intervals end on their own; there is no leg to end."
            return
        }
        completeCurrentPhase(at: now, wasSkipped: false, wasInterrupted: false,
                             endReason: reason, signals: signals)
        advance(from: now)
    }

    /// Records that the signal the plan watches has subsided, without ending the recovery walk.
    ///
    /// Two different events. The walk runs on to its floor and past it; the signal subsided when it
    /// subsided. The distance between them is the recovery the protocol measures, and collapsing
    /// them into one tap would leave that column reading the plan's floor on every row.
    func markBaseline(now: Date = Date()) {
        guard isRunning, !isPaused, phase == .walk else { return }
        // First answer wins: tapping twice means the second tap was a correction of nothing. A
        // later tap moving the timestamp would silently rewrite a measurement already taken.
        guard pendingBaselineDate == nil else { return }
        pendingBaselineDate = now
        onPhaseChanged?()
    }

    /// Ends the recovery walk and starts the next leg.
    ///
    /// The walk's normal completion, not a skip — the runner deciding they are ready is the only
    /// ending this phase has.
    func startNextLeg(now: Date = Date()) {
        guard isRunning, !isPaused else { return }
        guard source?.legsEndByHand == true, phase == .walk else {
            lastError = "This workout's walks end on their own; there is no leg to start."
            return
        }
        completeCurrentPhase(at: now, wasSkipped: false, wasInterrupted: false)
        advance(from: now)
    }

    /// Finishes the workout normally — used by the Finish button during an open cooldown.
    func finishCooldown(now: Date = Date()) {
        guard isRunning else { return }
        completeCurrentPhase(at: now, wasSkipped: false, wasInterrupted: false)
        finish(at: now, announce: true)
    }

    // MARK: - Pause / resume / skip

    func pause(now: Date = Date()) {
        guard isRunning, !isPaused else { return }
        // Announced before anything else: an unheard pause is the failure mode that costs a whole
        // interval before it is noticed.
        onCue?(.paused)
        isPaused = true
        pausedAtDate = now
        phase = .paused
        onPhaseChanged?()
        // Stop the clock for the current phase; `resume` shifts its end date forward by exactly
        // the paused duration, so a pause never shortens an interval.
        stopTicker()
    }

    func resume(now: Date = Date()) {
        guard isPaused, let pausedAt = pausedAtDate else { return }
        let pausedFor = max(0, now.timeIntervalSince(pausedAt))
        totalPausedSeconds += pausedFor

        // The pause itself is an interval, so a long stop is visible in the export rather than
        // hidden inside the phase it interrupted.
        onIntervalCompleted?(RecordedInterval(sequenceIndex: nextSequence(),
                                              phase: .paused,
                                              repetition: nil,
                                              plannedSeconds: nil,
                                              start: pausedAt,
                                              end: now,
                                              wasSkipped: false,
                                              wasInterrupted: false))

        phaseStartDate = phaseStartDate.addingTimeInterval(pausedFor)
        phaseEndDate = phaseEndDate?.addingTimeInterval(pausedFor)
        pendingCues = pendingCues.map { ($0.fireDate.addingTimeInterval(pausedFor), $0.cue) }

        isPaused = false
        pausedAtDate = nil
        phase = currentPlannedPhase?.phase ?? .idle
        onPhaseChanged?()
        onCue?(.resumed(phase))
        startTicker()
        tick(now: now)
    }

    /// Ends the current phase now and moves to the next one.
    func skip(now: Date = Date()) {
        guard isRunning, !isPaused else { return }
        onCue?(.skipped)
        completeCurrentPhase(at: now, wasSkipped: true, wasInterrupted: false)
        advance(from: now)
    }

    /// Restarts the current phase from this instant, keeping its planned duration.
    func restartCurrentPhase(now: Date = Date()) {
        guard isRunning, !isPaused, let planned = currentPlannedPhase else { return }
        onCue?(.skipped)
        completeCurrentPhase(at: now, wasSkipped: true, wasInterrupted: false)
        enter(planned, at: now, announce: true)
        tick(now: now)
    }

    // MARK: - Ticking

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        // `.common` keeps the timer firing while a scroll view is tracking; without it the UI
        // freezes the clock during a drag.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    /// Re-derives everything from the clock. Safe to call at any time — the scene coming back to
    /// the foreground calls it directly so the display is correct before the next scheduled tick.
    func tick(now: Date = Date()) {
        guard isRunning, !isPaused else { return }

        fireDueCues(now: now)
        advanceThroughElapsedPhases(now: now)
        guard isRunning else { return }

        phaseElapsedSeconds = max(0, now.timeIntervalSince(phaseStartDate))
        phaseRemainingSeconds = phaseEndDate.map { max(0, $0.timeIntervalSince(now)) }
        if let start = workoutStartDate {
            elapsedWorkoutSeconds = max(0, now.timeIntervalSince(start) - totalPausedSeconds)
        }
    }

    /// Moves forward over every boundary already in the past.
    ///
    /// More than one can elapse at once if the app was suspended. Each is recorded with its true
    /// planned boundary — so the interval data stays exact — but is marked `wasInterrupted`,
    /// because no cue was heard for it. Only the phase actually landed on is announced.
    private func advanceThroughElapsedPhases(now: Date) {
        var crossedBoundary = false

        while isRunning, let end = phaseEndDate, now >= end {
            let missed = crossedBoundary
            // A running leg the clock ends is one the accumulated target ran out under: its cap is
            // what remains to the target, so reaching that cap *is* reaching the target. Recorded
            // here because this path never goes through `endLeg` — the engine advances itself — and
            // without it every leg that ends this way exports a blank reason, which is the one
            // distinction the column exists to make.
            let reason: LegEndReason? =
                (source?.legsEndByHand == true && phase == .run) ? .targetReached : nil
            completeCurrentPhase(at: end, wasSkipped: false, wasInterrupted: missed,
                                 endReason: reason)
            crossedBoundary = true

            guard let source,
                  let next = source.phase(at: currentIndex + 1,
                                          accumulatedRunSeconds: accumulatedRunSeconds) else {
                finish(at: end, announce: true)
                return
            }

            // The next phase starts at the *planned* boundary, not at `now`. This is what keeps
            // the workout drift-free across a late tick.
            let nextEnd = next.plannedSeconds.map { end.addingTimeInterval(TimeInterval($0)) }
            // Announce only the phase actually landed on. One we are already past will be closed
            // by the next turn of this loop and marked interrupted instead of cued late.
            let landsHere = nextEnd.map { now < $0 } ?? true
            enter(next, at: end, announce: landsHere)
        }
    }

    private func fireDueCues(now: Date) {
        guard !pendingCues.isEmpty else { return }
        var remaining: [(fireDate: Date, cue: AudioCue)] = []
        for entry in pendingCues {
            if entry.fireDate <= now {
                // A cue whose moment passed while the app was asleep is dropped, not replayed:
                // "3" announced ten seconds late is worse than silence.
                if now.timeIntervalSince(entry.fireDate) < 1.5 {
                    onCue?(entry.cue)
                }
            } else {
                remaining.append(entry)
            }
        }
        pendingCues = remaining
    }

    // MARK: - Phase transitions

    private func enter(_ planned: WorkoutPhaseSchedule.PlannedPhase, at start: Date, announce: Bool) {
        currentIndex = planned.index
        phase = planned.phase
        currentRepetition = planned.repetition ?? currentRepetition
        phaseStartDate = start
        phaseEndDate = planned.plannedSeconds.map { start.addingTimeInterval(TimeInterval($0)) }
        phaseElapsedSeconds = 0
        phaseRemainingSeconds = planned.plannedSeconds.map(TimeInterval.init)

        pendingCues = scheduledCues(for: planned, start: start)
        onPhaseChanged?()
        if announce {
            for cue in entryCues(for: planned) { onCue?(cue) }
        }
    }

    /// The cue announcing that this phase has begun.
    private func entryCues(for planned: WorkoutPhaseSchedule.PlannedPhase) -> [AudioCue] {
        guard let settings else { return [] }
        var cues: [AudioCue] = []

        switch planned.phase {
        case .run:
            if settings.finalRoundAnnouncement,
               source?.isFinalRun(at: planned.index,
                                  accumulatedRunSeconds: accumulatedRunSeconds) == true,
               totalRepetitions > 1 {
                cues.append(.finalRound)
            }
            cues.append(.run)
            // An open-interval leg has no length of its own, so "how much is left" is the only
            // number that says where the workout is. It is the leg's cap — what remains to the
            // target — which is exactly what this phase was built with.
            if source?.legsEndByHand == true, let remaining = planned.plannedSeconds {
                cues.append(.runningRemaining(seconds: remaining))
            }
        case .walk:
            cues.append(.walk)
            if settings.halfwayAnnouncement, isHalfway(planned) {
                cues.append(.halfway)
            }
        case .cooldown:
            cues.append(.cooldown)
        case .countdown, .warmup, .idle, .paused, .completed:
            break
        }
        return cues
    }

    /// True at the walk that sits at the midpoint of the repetitions.
    private func isHalfway(_ planned: WorkoutPhaseSchedule.PlannedPhase) -> Bool {
        guard let repetition = planned.repetition, totalRepetitions > 2 else { return false }
        return repetition == totalRepetitions / 2
    }

    /// Cues that fire partway through a phase rather than at its start.
    private func scheduledCues(for planned: WorkoutPhaseSchedule.PlannedPhase,
                               start: Date) -> [(fireDate: Date, cue: AudioCue)] {
        guard let settings else { return [] }
        var cues: [(Date, AudioCue)] = []

        // A recovery walk has no end date, so nothing else in this function would ever fire for it.
        // The floor is the one instant inside it worth announcing: it is when the Start button
        // becomes available, and without a cue the runner has to keep looking at the screen for a
        // moment they specifically chose not to be told by a timer.
        if planned.phase == .walk, planned.isOpen, let floor = source?.walkFloorSeconds, floor > 0 {
            cues.append((start.addingTimeInterval(TimeInterval(floor)), .recoveryFloorReached))

            // The same "3, 2, 1" a timed walk gets on its way out. It cannot come from the block
            // below, which is gated on `plannedSeconds` that an open walk does not have, so the
            // floor used to arrive announced only by `.recoveryFloorReached` with no run-up. Asked
            // for after the first outdoor run: the floor was the one boundary that arrived cold.
            if settings.transitionCountdown, floor > 4 {
                for remaining in 1...3 {
                    cues.append((start.addingTimeInterval(TimeInterval(floor - remaining)),
                                 .countdown(remaining)))
                }
            }

            // Deliberately **no** five-second `.nextPhase` warning here, though a timed walk gets
            // one. That cue names the phase that follows and says it is seconds away, which is true
            // at a timed boundary and false at a floor: the floor does not start the next leg, the
            // runner does. Announcing "running in 5 seconds" would promise a transition the app
            // will not make. `.recoveryFloorReached` says "Start when you are ready" instead, which
            // is what actually happens.
        }

        if planned.phase == .countdown, let seconds = planned.plannedSeconds {
            // "3, 2, 1" — one per second, counting down to the boundary.
            for offset in 0..<seconds {
                cues.append((start.addingTimeInterval(TimeInterval(offset)),
                             .countdown(seconds - offset)))
            }
        }

        // Warn about transitions out of any timed phase, not just run and walk: the end of a
        // timed warmup or cooldown is just as easy to be caught out by.
        if let seconds = planned.plannedSeconds, planned.phase != .countdown {
            // Naming the upcoming phase is the point — "in 5 seconds" without saying *what*
            // still leaves you guessing at the boundary.
            let upcoming = source?.phase(at: planned.index + 1,
                                         accumulatedRunSeconds: accumulatedRunSeconds)?.phase

            if settings.fiveSecondWarning, seconds > 6, let upcoming {
                cues.append((start.addingTimeInterval(TimeInterval(seconds - 5)),
                             .nextPhase(upcoming, seconds: 5)))
            }
            if settings.transitionCountdown, seconds > 4 {
                for remaining in 1...3 {
                    cues.append((start.addingTimeInterval(TimeInterval(seconds - remaining)),
                                 .countdown(remaining)))
                }
            }
        }

        return cues.sorted { $0.0 < $1.0 }.map { (fireDate: $0.0, cue: $0.1) }
    }

    private func completeCurrentPhase(at end: Date,
                                      wasSkipped: Bool,
                                      wasInterrupted: Bool,
                                      endReason: LegEndReason? = nil,
                                      signals: BodySignalReadings = BodySignalReadings()) {
        guard let planned = currentPlannedPhase else { return }
        // A phase that somehow ends before it started would produce a negative duration; clamp to
        // the start so no negative interval ever reaches the export.
        let safeEnd = max(end, phaseStartDate)

        if planned.phase == .run {
            // Every second actually run counts toward an open-interval target, however the leg
            // ended: running until the signal appears is still running. `completedRunIntervals` answers a
            // different question — how many ran to their planned end — and a run skipped out of
            // must not inflate it.
            accumulatedRunSeconds += Int(safeEnd.timeIntervalSince(phaseStartDate).rounded())
            if !wasSkipped { completedRunIntervals += 1 }
        }

        onIntervalCompleted?(RecordedInterval(sequenceIndex: nextSequence(),
                                              phase: planned.phase,
                                              repetition: planned.repetition,
                                              plannedSeconds: planned.plannedSeconds,
                                              start: phaseStartDate,
                                              end: safeEnd,
                                              wasSkipped: wasSkipped,
                                              wasInterrupted: wasInterrupted,
                                              endReason: endReason,
                                              baselineReachedAt: pendingBaselineDate,
                                              signals: signals))
        pendingBaselineDate = nil
        pendingCues.removeAll()
    }

    private func advance(from now: Date) {
        guard let source,
              let next = source.phase(at: currentIndex + 1,
                                      accumulatedRunSeconds: accumulatedRunSeconds) else {
            finish(at: now, announce: true)
            return
        }
        enter(next, at: now, announce: true)
        tick(now: now)
    }

    private func finish(at end: Date, announce: Bool) {
        stopTicker()
        phase = .completed
        phaseEndDate = nil
        phaseRemainingSeconds = nil
        onPhaseChanged?()
        if let start = workoutStartDate {
            elapsedWorkoutSeconds = max(0, end.timeIntervalSince(start) - totalPausedSeconds)
        }
        if announce { onCue?(.complete) }
        source = nil
        onFinished?()
    }

    private func nextSequence() -> Int {
        defer { sequenceCounter += 1 }
        return sequenceCounter
    }

    func reset() {
        stopTicker()
        source = nil
        accumulatedRunSeconds = 0
        pendingBaselineDate = nil
        phase = .idle
        currentIndex = 0
        currentRepetition = 0
        totalRepetitions = 0
        phaseEndDate = nil
        phaseRemainingSeconds = nil
        phaseElapsedSeconds = 0
        elapsedWorkoutSeconds = 0
        isPaused = false
        pausedAtDate = nil
        totalPausedSeconds = 0
        sequenceCounter = 0
        completedRunIntervals = 0
        pendingCues.removeAll()
        lastError = nil
    }
}
