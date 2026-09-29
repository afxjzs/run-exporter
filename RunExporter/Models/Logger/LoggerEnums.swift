import Foundation

/// String-backed enums for the SwiftData models.
///
/// The models persist the `rawValue` (as the spec's field list does) rather than the enum itself,
/// so the store stays readable and migration-tolerant. Every reader goes through the optional
/// `init(rawValue:)` — an unrecognized string is surfaced as `nil` and reported by the caller, and
/// is never coerced into a plausible-looking default.
enum WarmupMode: String, CaseIterable, Identifiable {
    case none
    case timed
    case open

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .timed: return "Timed"
        case .open: return "Open"
        }
    }
}

enum CooldownMode: String, CaseIterable, Identifiable {
    case none
    case timed
    case open

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .timed: return "Timed"
        case .open: return "Open"
        }
    }
}

/// Activity types this app plans and logs. Deliberately the same two the exporter already keeps.
enum PlannedActivityType: String, CaseIterable, Identifiable {
    case running
    case walking

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .running: return "Running"
        case .walking: return "Walking"
        }
    }
}

/// Lifecycle of a `PendingWorkoutExecution`.
enum ExecutionStatus: String, CaseIterable {
    case prepared
    case sentToWatch
    case started
    case completed
    case matched
    case cancelled
    case expired

    /// Statuses that are still eligible to be matched against a finished HealthKit workout.
    static let matchable: Set<ExecutionStatus> = [.prepared, .sentToWatch, .started, .completed]
}

/// The phases a workout moves through, used by both the timer engine and `WorkoutIntervalLog`.
enum WorkoutPhase: String, CaseIterable {
    case idle
    case countdown
    case warmup
    case run
    case walk
    case cooldown
    case paused
    case completed

    /// Phases that are written to `workout_intervals.csv`. `idle` and `completed` are UI states,
    /// not elapsed intervals, so they are never logged.
    var isLoggable: Bool {
        switch self {
        case .idle, .completed: return false
        case .countdown, .warmup, .run, .walk, .cooldown, .paused: return true
        }
    }

    /// Single character carried in the Live Activity's `phaseKinds`.
    ///
    /// One character per phase keeps a 41-phase plan inside `ContentState`'s 4 KB budget. The
    /// widget cannot import this enum — it is compiled into the app target only — so the two ends
    /// agree on these letters rather than on a shared type. `paused` and `idle` never appear in a
    /// schedule; they map to `?` so an unexpected value is drawn as unknown instead of silently
    /// borrowing another phase's colour.
    var timelineSymbol: Character {
        switch self {
        case .run: return "r"
        case .walk: return "w"
        case .cooldown: return "c"
        case .warmup: return "u"
        case .countdown: return "d"
        case .idle, .paused, .completed: return "?"
        }
    }

    /// Phases that make up the main set. Cooldown, warmup, countdown and pause are deliberately
    /// excluded so a 20-minute conversation during an open cooldown cannot move main-set numbers.
    var isMainSet: Bool {
        switch self {
        case .run, .walk: return true
        case .idle, .countdown, .warmup, .cooldown, .paused, .completed: return false
        }
    }

    var displayName: String {
        switch self {
        case .idle: return "Ready"
        case .countdown: return "Starting"
        case .warmup: return "Warmup"
        case .run: return "Run"
        case .walk: return "Walk"
        case .cooldown: return "Cooldown"
        case .paused: return "Paused"
        case .completed: return "Done"
        }
    }
}

/// Whether this iPhone plays the workout's cues. Mirrors `cue_source` in manifest.json.
///
/// Settings shows it as the "Play cues" toggle (`LoggerDefaults.playsCues`). Two Watch sources —
/// `apple_workout` and `watch_companion` — were removed in the 2026-09-29 clean-out: the first only
/// made sense alongside the removed WorkoutKit route, and the second was never built. A phone that
/// still has one stored gets it reported by `LoggerDefaults` rather than silently replaced, and
/// exports made before then keep those values.
enum CueSource: String, CaseIterable, Identifiable {
    case iphoneAudioEngine = "iphone_audio_engine"
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .iphoneAudioEngine: return "iPhone audio engine"
        case .none: return "No cues"
        }
    }
}

/// Spoken cues, tones, or both. Mirrors `cue_mode` in manifest.json.
enum CueMode: String, CaseIterable, Identifiable {
    case voice
    case beeps
    case voiceAndBeeps = "voice_and_beeps"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .voice: return "Voice"
        case .beeps: return "Beeps"
        case .voiceAndBeeps: return "Voice + beeps"
        }
    }

    var includesVoice: Bool { self != .beeps }
    var includesBeeps: Bool { self != .voice }
}

/// The cue configuration as it is recorded in an export.
///
/// A flat value rather than a dictionary so it can travel into the export task, and so the
/// manifest keys live next to the fields that produce them.
struct IntervalAudioSettings: Sendable {
    var cueSource: String
    var cueMode: String
    var countdownSeconds: Int
    var fiveSecondWarning: Bool
    var finalRoundAnnouncement: Bool
    var halfwayAnnouncement: Bool
    var transitionCountdown: Bool
    var duckOtherAudio: Bool

    var json: [String: Any] {
        [
            "cue_source": cueSource,
            "cue_mode": cueMode,
            "countdown_seconds": countdownSeconds,
            "five_second_warning": fiveSecondWarning,
            "final_round_announcement": finalRoundAnnouncement,
            "halfway_announcement": halfwayAnnouncement,
            "transition_countdown": transitionCountdown,
            "duck_other_audio": duckOtherAudio,
        ]
    }
}

/// Optional detail attached to a body-signal entry (spec §15.3). Optional layer — a log is
/// complete without any of these.
enum BodySignalTiming: String, CaseIterable, Identifiable {
    case beginning
    case middle
    case end
    case after
    case nextDay = "next_day"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .beginning: return "Beginning"
        case .middle: return "Middle"
        case .end: return "End"
        case .after: return "After"
        case .nextDay: return "Next day"
        }
    }
}

enum BodySignalCharacter: String, CaseIterable, Identifiable {
    case brief
    case stable
    case worsening
    case improvedDuringWalk = "improved_during_walk"
    case changedStride = "changed_stride"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .brief: return "Brief/transient"
        case .stable: return "Stable"
        case .worsening: return "Worsening"
        case .improvedDuringWalk: return "Improved during walk"
        case .changedStride: return "Changed stride"
        }
    }
}

/// The five tracked body areas. One enum keeps the logger UI, the `RunLog` columns and the
/// recovery log from drifting apart.
enum BodyArea: String, CaseIterable, Identifiable {
    case lowerBack = "lower_back"
    case leftAnkle = "left_ankle"
    case rightAnkle = "right_ankle"
    case leftKnee = "left_knee"
    case rightKnee = "right_knee"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lowerBack: return "Lower back"
        case .leftAnkle: return "Left ankle"
        case .rightAnkle: return "Right ankle"
        case .leftKnee: return "Left knee"
        case .rightKnee: return "Right knee"
        }
    }
}

/// Why a running leg in an open-interval workout stopped.
///
/// Recorded rather than inferred. A leg's duration cannot tell these apart, and the difference is
/// the whole point of the dataset: a leg that ran 2:40 because the target arrived is not a reading
/// of how long it took the runner to reach their threshold. Inferring one from the other would put
/// a fabricated measurement in the only column the run exists to fill.
enum LegEndReason: String, CaseIterable, Identifiable {
    /// The runner ended the leg. The measurement — why they ended it is the score and the note.
    case runnerEnded
    /// The accumulated running target arrived first and ended the leg.
    case targetReached
    /// Ended for some other reason — the workout was stopped, or the leg was abandoned.
    case endedEarly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .runnerEnded: return "Ended by runner"
        case .targetReached: return "Target reached"
        case .endedEarly: return "Ended early"
        }
    }
}
