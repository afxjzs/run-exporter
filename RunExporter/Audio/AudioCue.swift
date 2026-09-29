import Foundation

/// One thing the app can say or sound (spec §9.1).
enum AudioCue: Equatable {
    case countdown(Int)
    case run
    case walk
    case cooldown
    case complete
    case finalRound
    case halfway
    /// Warns what is coming and when, e.g. "Walk in 5". Named rather than a bare tone so a
    /// transition never arrives as a surprise.
    case nextPhase(WorkoutPhase, seconds: Int)
    /// "Twelve minutes left" — the running still to do before an open-interval workout ends.
    /// Announced as each leg starts, which is the moment the number is both known and useful.
    case runningRemaining(seconds: Int)
    /// The recovery walk has run at least its floor. It does not end the walk — only the runner
    /// does — so this says the next leg is now available, not that it is time.
    case recoveryFloorReached

    // Confirmations that a control was actually pressed. The phone is usually in a pocket or on
    // an armband mid-run, so a tap with no audible response is indistinguishable from a missed
    // tap — which is how a workout gets silently paused.
    case paused
    case resumed(WorkoutPhase)
    case skipped
    case ended

    /// What the voice says. `nil` for cues that are a sound only.
    var spokenText: String? {
        switch self {
        case .countdown(let value): return String(value)
        case .run: return "Run"
        case .walk: return "Walk"
        case .cooldown: return "Cooldown"
        case .complete: return "Workout complete"
        case .finalRound: return "Final round"
        case .halfway: return "Halfway"
        case .nextPhase(let phase, let seconds):
            return "\(phase.displayName) in \(seconds)"
        case .runningRemaining(let seconds):
            // Truncated, not rounded, so the voice agrees with the screen. The display counts down
            // in m:ss, so at 16:30 it reads "16:30" — and rounding up announced "17 minutes left"
            // over the top of it. A cue that contradicts the number in front of the runner is worse
            // than one that is half a minute conservative.
            let minutes = seconds / 60
            if minutes < 1 { return "Less than a minute left" }
            if minutes == 1 { return "One minute left" }
            return "\(minutes) minutes left"
        case .recoveryFloorReached: return "Start when you are ready"
        case .paused: return "Paused"
        case .resumed(let phase): return "Resuming \(phase.displayName)"
        case .skipped: return "Skipped"
        case .ended: return "Workout ended"
        }
    }

    /// The tone played for this cue.
    var tone: [ToneGenerator.Segment] {
        switch self {
        case .countdown: return ToneGenerator.countdownTick
        case .run: return ToneGenerator.run
        case .walk: return ToneGenerator.walk
        case .cooldown: return ToneGenerator.cooldown
        case .complete: return ToneGenerator.complete
        case .finalRound, .halfway, .runningRemaining, .recoveryFloorReached:
            return ToneGenerator.countdownTick
        case .nextPhase: return ToneGenerator.warning
        case .paused: return ToneGenerator.paused
        case .resumed: return ToneGenerator.resumed
        case .skipped: return ToneGenerator.confirm
        case .ended: return ToneGenerator.cooldown
        }
    }

    /// Confirmations of a button press. These always sound, in every cue mode — the whole point
    /// is knowing the tap registered, which a silent mode would defeat.
    var isControlConfirmation: Bool {
        switch self {
        case .paused, .resumed, .skipped, .ended: return true
        case .countdown, .run, .walk, .cooldown, .complete,
             .finalRound, .halfway, .nextPhase, .runningRemaining,
             .recoveryFloorReached: return false
        }
    }

    /// Cues that are announcements rather than transitions. In beeps-only mode they are skipped
    /// entirely: a tick that means "final round" and a tick that means "3" are indistinguishable,
    /// and an ambiguous cue is worse than no cue.
    var isAnnouncementOnly: Bool {
        switch self {
        case .finalRound, .halfway, .runningRemaining, .recoveryFloorReached: return true
        case .countdown, .run, .walk, .cooldown, .complete, .nextPhase,
             .paused, .resumed, .skipped, .ended: return false
        }
    }

    /// Stable name used in logs and the cue-test screen.
    var identifier: String {
        switch self {
        case .countdown(let value): return "countdown_\(value)"
        case .run: return "run"
        case .walk: return "walk"
        case .cooldown: return "cooldown"
        case .complete: return "complete"
        case .finalRound: return "final_round"
        case .halfway: return "halfway"
        case .nextPhase: return "next_phase_warning"
        case .runningRemaining: return "running_remaining"
        case .recoveryFloorReached: return "recovery_floor_reached"
        case .paused: return "paused"
        case .resumed: return "resumed"
        case .skipped: return "skipped"
        case .ended: return "ended"
        }
    }
}
