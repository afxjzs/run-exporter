import Foundation

/// Turns the phone's interval-engine state into the `PhaseAnchor` sent to the watch.
///
/// The engine keeps absolute dates on the phone's clock. The anchor carries only durations, so the
/// watch never has to compare the two devices' clocks (see `PhaseClock`). This is the one place the
/// conversion happens. Tested in `WatchPhaseMappingTests`.
enum WatchPhaseMapping {

    /// What the engine knows about the current phase, copied out so the mapping stays pure.
    struct EngineSnapshot {
        /// The engine's displayed phase — `.paused` while paused.
        let phase: WorkoutPhase
        /// The phase underneath: the one a pause interrupted, otherwise the same as `phase`.
        let plannedPhase: WorkoutPhase?
        let isPaused: Bool
        let repetition: Int
        let totalRepetitions: Int
        /// Phone clock.
        let phaseStart: Date
        /// Phone clock; nil for an open-ended phase.
        let phaseEnd: Date?
        /// While paused the engine's clock is stopped, so its last values stand.
        let frozenElapsed: TimeInterval
        let frozenRemaining: TimeInterval?
    }

    /// The anchor for `snapshot` as of `now`, or nil when there is nothing the watch should show:
    /// the phone's UI-only states (`idle`, `completed`), or a pause with no phase underneath it.
    static func anchor(from snapshot: EngineSnapshot, now: Date, oneWayLatency: TimeInterval) -> PhaseAnchor? {
        let shownPhase = snapshot.isPaused ? snapshot.plannedPhase : snapshot.phase
        guard let shownPhase, let watchPhase = watchPhase(for: shownPhase) else { return nil }

        let elapsed: TimeInterval
        let remaining: TimeInterval?
        if snapshot.isPaused {
            elapsed = snapshot.frozenElapsed
            remaining = snapshot.phaseEnd == nil ? nil : snapshot.frozenRemaining
        } else {
            // A snapshot can land a hair before the start the engine recorded; a negative elapsed
            // would be refused on the watch as a corrupt anchor, so it is floored at the start.
            elapsed = max(0, now.timeIntervalSince(snapshot.phaseStart))
            remaining = snapshot.phaseEnd.map { max(0, $0.timeIntervalSince(now)) }
        }

        return PhaseAnchor(phase: watchPhase,
                           legNumber: snapshot.repetition > 0 ? snapshot.repetition : nil,
                           legCount: snapshot.totalRepetitions > 0 ? snapshot.totalRepetitions : nil,
                           elapsedAtSend: elapsed,
                           remainingAtSend: remaining,
                           isPaused: snapshot.isPaused,
                           oneWayLatency: oneWayLatency,
                           sentAt: now)
    }

    /// The watch's name for a phone phase; nil for the ones that are never shown there.
    static func watchPhase(for phase: WorkoutPhase) -> WatchPhase? {
        switch phase {
        case .countdown: return .countdown
        case .warmup: return .warmup
        case .run: return .run
        case .walk: return .walk
        case .cooldown: return .cooldown
        case .idle, .paused, .completed: return nil
        }
    }
}
