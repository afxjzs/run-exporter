import Foundation
import Observation

/// User settings for cues, logging and plan defaults (spec §22).
///
/// Backed by `UserDefaults` rather than SwiftData: these are device preferences, not logged data,
/// and keeping them out of the store means a settings change never touches the export.
///
/// A stored value that no longer maps to a known case is **not** silently replaced. It is recorded
/// in `configurationIssues`, which the Settings screen shows, and the documented default is used
/// only after that has been reported.
@Observable
final class LoggerDefaults {

    // MARK: - Keys

    private enum Key {
        static let cueSource = "cue.source"
        static let cueMode = "cue.mode"
        static let cueVoiceIdentifier = "cue.voiceIdentifier"
        static let cueVolume = "cue.volume"
        static let duckOtherAudio = "cue.duckOtherAudio"
        static let countdownSeconds = "cue.countdownSeconds"
        static let fiveSecondWarning = "cue.fiveSecondWarning"
        static let finalRoundAnnouncement = "cue.finalRoundAnnouncement"
        static let halfwayAnnouncement = "cue.halfwayAnnouncement"
        static let transitionCountdown = "cue.transitionCountdown"

        static let defaultShoeID = "defaults.shoeID"
        static let defaultCooldownMode = "defaults.cooldownMode"
        static let defaultCooldownSeconds = "defaults.cooldownSeconds"
        static let defaultActivityType = "defaults.activityType"
        static let defaultRunSeconds = "defaults.runSeconds"
        static let defaultWalkSeconds = "defaults.walkSeconds"
        static let defaultRepetitions = "defaults.repetitions"

        static let includeWalkingWorkouts = "workouts.includeWalking"
        static let reclassifiedAsRunning = "workouts.reclassifiedAsRunning"
        static let showBodySignals = "logging.showBodySignals"
        static let showRecoveryPrompt = "logging.showRecoveryPrompt"
        static let showScaleExplanations = "logging.showScaleExplanations"
        static let unloggedPromptDays = "logging.unloggedPromptDays"
        static let hideUnloggedBefore = "logging.hideUnloggedBefore"

        static let noteDraftExecution = "logging.noteDraft.execution"
        static let noteDraftText = "logging.noteDraft.text"
    }

    private let defaults: UserDefaults

    /// Stored values that could not be understood. Surfaced in Settings rather than swallowed.
    private(set) var configurationIssues: [String] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Collected locally: the observable property cannot be passed `inout` until every stored
        // property is initialized.
        var issues: [String] = []

        self.cueSource = Self.readEnum(defaults, Key.cueSource, default: CueSource.iphoneAudioEngine,
                                       label: "Cue source (now the Play cues setting)",
                                       issues: &issues)
        // Voice, not voice+beeps. Every cue in the combined mode plays a tone *and* an utterance,
        // and the utterance carries a 0.14s `preUtteranceDelay` to let the tone through first — so
        // the mode doubles the audio events and lengthens each one, on a cue timeline that already
        // packs five cues into the last five seconds of every interval. Heard during a real
        // run: the cues drifted audibly off their seconds. The voice alone carries all the
        // meaning; the tone only adds queue pressure. See LEARNINGS.md.
        self.cueMode = Self.readEnum(defaults, Key.cueMode, default: CueMode.voice,
                                     label: "Cue mode", issues: &issues)
        self.cueVoiceIdentifier = defaults.string(forKey: Key.cueVoiceIdentifier)
        self.cueVolume = Self.readCueVolume(defaults, issues: &issues)
        self.duckOtherAudio = Self.readBool(defaults, Key.duckOtherAudio, default: true)
        // Spec §6's 3 seconds. It was 0 while a run started as two taps — the Watch, then the phone —
        // where a countdown added exactly the offset that start was trying to close. Since Start
        // launches the Watch itself, the countdown gives the Watch time to connect before the
        // first phase (restored in the 2026-09-29 clean-out). Applies to new plans; each plan
        // stores its own. Selectable per plan and here.
        self.countdownSeconds = Self.readInt(defaults, Key.countdownSeconds, default: 3,
                                             allowed: Self.allowedCountdownSeconds,
                                             label: "Countdown", issues: &issues)
        self.fiveSecondWarning = Self.readBool(defaults, Key.fiveSecondWarning, default: true)
        self.finalRoundAnnouncement = Self.readBool(defaults, Key.finalRoundAnnouncement, default: true)
        self.halfwayAnnouncement = Self.readBool(defaults, Key.halfwayAnnouncement, default: false)
        self.transitionCountdown = Self.readBool(defaults, Key.transitionCountdown, default: true)

        self.defaultShoeID = Self.readUUID(defaults, Key.defaultShoeID, issues: &issues)
        self.cooldownMode = Self.readEnum(defaults, Key.defaultCooldownMode, default: CooldownMode.open,
                                          label: "Default cooldown", issues: &issues)
        self.activityType = Self.readEnum(defaults, Key.defaultActivityType,
                                          default: PlannedActivityType.running,
                                          label: "Default activity", issues: &issues)
        self.defaultCooldownSeconds = Self.readInt(defaults, Key.defaultCooldownSeconds,
                                                   default: 300, minimum: 60)
        self.defaultRunSeconds = Self.readInt(defaults, Key.defaultRunSeconds, default: 240,
                                              minimum: 5)
        self.defaultWalkSeconds = Self.readInt(defaults, Key.defaultWalkSeconds, default: 60,
                                               minimum: 0)
        self.defaultRepetitions = Self.readInt(defaults, Key.defaultRepetitions, default: 5,
                                               minimum: 1)

        self.includeWalkingWorkouts = Self.readBool(defaults, Key.includeWalkingWorkouts,
                                                    default: false)
        self.reclassifiedAsRunning = Self.readUUIDSet(defaults, Key.reclassifiedAsRunning,
                                                      issues: &issues)
        self.showBodySignals = Self.readBool(defaults, Key.showBodySignals, default: true)
        self.showRecoveryPrompt = Self.readBool(defaults, Key.showRecoveryPrompt, default: true)
        self.showScaleExplanations = Self.readBool(defaults, Key.showScaleExplanations, default: true)
        self.unloggedPromptDays = Self.readInt(defaults, Key.unloggedPromptDays, default: 7,
                                               minimum: 1)
        self.hideUnloggedBefore = defaults.object(forKey: Key.hideUnloggedBefore) as? Date

        self.configurationIssues = issues
    }

    static let allowedCountdownSeconds = [0, 3, 5, 10]

    /// The lowest selectable cue volume. Deliberately not 0.
    ///
    /// A cue at volume 0 was silent but still a cue: it started, ducked whatever else was playing,
    /// and then had to report finishing to un-duck it. So "mute" did all the work inaudibly instead
    /// of skipping it, and one missing un-duck left the user's music quiet for the rest of the
    /// workout. Turning cues off is `CueSource.none`, which stops the work rather than silencing
    /// its output.
    static let minimumCueVolume = 0.1

    // MARK: - Cues

    var cueSource: CueSource { didSet { defaults.set(cueSource.rawValue, forKey: Key.cueSource) } }

    /// Settings' "Play cues" toggle. A view onto `cueSource`, not a second stored setting, so the
    /// two cannot disagree and the export's `cue_source` keeps its existing values.
    var playsCues: Bool {
        get { cueSource == .iphoneAudioEngine }
        set { cueSource = newValue ? .iphoneAudioEngine : .none }
    }
    var cueMode: CueMode { didSet { defaults.set(cueMode.rawValue, forKey: Key.cueMode) } }
    var cueVoiceIdentifier: String? {
        didSet { defaults.set(cueVoiceIdentifier, forKey: Key.cueVoiceIdentifier) }
    }
    /// 0…1, applied to both speech and tones.
    var cueVolume: Double { didSet { defaults.set(cueVolume, forKey: Key.cueVolume) } }
    var duckOtherAudio: Bool { didSet { defaults.set(duckOtherAudio, forKey: Key.duckOtherAudio) } }
    var countdownSeconds: Int { didSet { defaults.set(countdownSeconds, forKey: Key.countdownSeconds) } }
    var fiveSecondWarning: Bool { didSet { defaults.set(fiveSecondWarning, forKey: Key.fiveSecondWarning) } }
    var finalRoundAnnouncement: Bool {
        didSet { defaults.set(finalRoundAnnouncement, forKey: Key.finalRoundAnnouncement) }
    }
    var halfwayAnnouncement: Bool {
        didSet { defaults.set(halfwayAnnouncement, forKey: Key.halfwayAnnouncement) }
    }
    /// Spoken "3, 2, 1" before every transition, not just the workout start.
    ///
    /// The spec (§11.3) defaults this off. Turned on after a real run, where transitions arriving
    /// with no warning were repeatedly surprising — a documented deviation, still switchable.
    var transitionCountdown: Bool {
        didSet { defaults.set(transitionCountdown, forKey: Key.transitionCountdown) }
    }

    // MARK: - Plan + logging defaults

    var defaultShoeID: UUID? {
        didSet { defaults.set(defaultShoeID?.uuidString, forKey: Key.defaultShoeID) }
    }
    var cooldownMode: CooldownMode {
        didSet { defaults.set(cooldownMode.rawValue, forKey: Key.defaultCooldownMode) }
    }

    /// Length used when the default cooldown mode is `timed`.
    ///
    /// Exists because a timed cooldown with no duration is not a valid plan: the schedule builder
    /// rejects it, so a preset created under that default would save fine and then refuse to
    /// start. Every code path that builds a timed cooldown must supply a length.
    var defaultCooldownSeconds: Int {
        didSet { defaults.set(defaultCooldownSeconds, forKey: Key.defaultCooldownSeconds) }
    }
    var activityType: PlannedActivityType {
        didSet { defaults.set(activityType.rawValue, forKey: Key.defaultActivityType) }
    }
    var defaultRunSeconds: Int { didSet { defaults.set(defaultRunSeconds, forKey: Key.defaultRunSeconds) } }
    var defaultWalkSeconds: Int { didSet { defaults.set(defaultWalkSeconds, forKey: Key.defaultWalkSeconds) } }
    var defaultRepetitions: Int { didSet { defaults.set(defaultRepetitions, forKey: Key.defaultRepetitions) } }

    /// Whether walking workouts are read at all — by the logger, History **and** the export.
    ///
    /// Off by default: a walkable neighbourhood produces far more walks than runs, and every one
    /// of them would otherwise sit in the "needs a log" queue and pad the export.
    ///
    /// Unlike the weather and route toggles this one persists, because it is a statement about
    /// what this user considers training data rather than a per-export choice. Excluding walks is
    /// recorded in `manifest.json` and `README.txt` so a reader can always tell "filtered out"
    /// from "never happened".
    var includeWalkingWorkouts: Bool {
        didSet { defaults.set(includeWalkingWorkouts, forKey: Key.includeWalkingWorkouts) }
    }

    /// HealthKit workout UUIDs the user has marked "this walk was really a run".
    ///
    /// A **local annotation, not an edit to Apple Health.** `HKWorkout` is immutable — nothing can
    /// change a recorded workout's activity type — and this app is read-only against HealthKit by
    /// design. So the Watch's own record stays exactly as it was, and this set is what makes the
    /// workout show up as a run in the logger, History and the export.
    ///
    /// Exports keep `workoutActivityType` as HealthKit recorded it and add a separate
    /// `reclassifiedAsRunning` column, so a reader sees both what Apple recorded and what the user
    /// asserted, and can disagree with the second without losing the first.
    var reclassifiedAsRunning: Set<UUID> {
        didSet {
            defaults.set(reclassifiedAsRunning.map(\.uuidString).sorted(),
                         forKey: Key.reclassifiedAsRunning)
        }
    }

    var showBodySignals: Bool { didSet { defaults.set(showBodySignals, forKey: Key.showBodySignals) } }
    var showRecoveryPrompt: Bool { didSet { defaults.set(showRecoveryPrompt, forKey: Key.showRecoveryPrompt) } }
    var showScaleExplanations: Bool {
        didSet { defaults.set(showScaleExplanations, forKey: Key.showScaleExplanations) }
    }
    /// How far back the "you have an unlogged workout" prompt looks (spec §21, default 7 days).
    var unloggedPromptDays: Int { didSet { defaults.set(unloggedPromptDays, forKey: Key.unloggedPromptDays) } }
    /// Workouts before this date are never offered for logging (spec §21).
    var hideUnloggedBefore: Date? {
        didSet { defaults.set(hideUnloggedBefore, forKey: Key.hideUnloggedBefore) }
    }

    // MARK: - The half-typed note

    // A note in progress, so text thumbed in during a walk break is not lost if the app dies
    // before Save is tapped. Deliberately **not** an observable property: the note sheet owns the
    // text in its own `@State` and writes through to here, so nothing needs to re-render when it
    // changes, and a stored dictionary keyed by execution would grow without bound.
    //
    // Only one draft is kept, because only one workout can be in progress at a time. It is stored
    // alongside the execution it belongs to and returned only for that execution — otherwise a
    // draft abandoned weeks ago would surface inside an unrelated run and read as an observation
    // about it.
    //
    // A draft is not logged data and never reaches the export. It is a crash backstop for text
    // the user has not committed yet; the moment they tap Save it becomes a `WorkoutNote`.

    /// The unsaved note text for this workout, or "" when there is none.
    func noteDraft(forExecution executionID: UUID) -> String {
        guard defaults.string(forKey: Key.noteDraftExecution) == executionID.uuidString else {
            return ""
        }
        return defaults.string(forKey: Key.noteDraftText) ?? ""
    }

    /// Records the in-progress text, replacing any draft from an earlier workout.
    func setNoteDraft(_ text: String, forExecution executionID: UUID) {
        defaults.set(executionID.uuidString, forKey: Key.noteDraftExecution)
        defaults.set(text, forKey: Key.noteDraftText)
    }

    /// Discards this workout's draft, once its text is safely in the store.
    ///
    /// Scoped to the execution so clearing after a save cannot throw away a draft belonging to a
    /// different session.
    func clearNoteDraft(forExecution executionID: UUID) {
        guard defaults.string(forKey: Key.noteDraftExecution) == executionID.uuidString else {
            return
        }
        defaults.removeObject(forKey: Key.noteDraftExecution)
        defaults.removeObject(forKey: Key.noteDraftText)
    }

    /// The cue configuration recorded in the export's `interval_audio` manifest block.
    var intervalAudioSettings: IntervalAudioSettings {
        IntervalAudioSettings(cueSource: cueSource.rawValue,
                              cueMode: cueMode.rawValue,
                              countdownSeconds: countdownSeconds,
                              fiveSecondWarning: fiveSecondWarning,
                              finalRoundAnnouncement: finalRoundAnnouncement,
                              halfwayAnnouncement: halfwayAnnouncement,
                              transitionCountdown: transitionCountdown,
                              duckOtherAudio: duckOtherAudio)
    }

    // MARK: - Reading

    private static func readEnum<T: RawRepresentable>(_ defaults: UserDefaults,
                                                      _ key: String,
                                                      default fallback: T,
                                                      label: String,
                                                      issues: inout [String]) -> T
    where T.RawValue == String {
        guard let raw = defaults.string(forKey: key) else { return fallback }
        guard let value = T(rawValue: raw) else {
            issues.append("\(label) was stored as \"\(raw)\", which this version does not recognize. "
                          + "Using \"\(fallback.rawValue)\" until you choose a value.")
            return fallback
        }
        return value
    }

    private static func readUUID(_ defaults: UserDefaults, _ key: String,
                                 issues: inout [String]) -> UUID? {
        guard let raw = defaults.string(forKey: key) else { return nil }
        guard let value = UUID(uuidString: raw) else {
            issues.append("Default shoe was stored as \"\(raw)\", which is not a valid identifier. "
                          + "No shoe will be pre-selected until you pick one.")
            return nil
        }
        return value
    }

    /// Reads stored UUID strings, reporting any that cannot be parsed rather than dropping them
    /// quietly — a lost entry would silently un-reclassify a workout.
    private static func readUUIDSet(_ defaults: UserDefaults, _ key: String,
                                    issues: inout [String]) -> Set<UUID> {
        guard let raw = defaults.stringArray(forKey: key) else { return [] }
        var result: Set<UUID> = []
        var bad: [String] = []
        for value in raw {
            if let uuid = UUID(uuidString: value) { result.insert(uuid) } else { bad.append(value) }
        }
        if !bad.isEmpty {
            issues.append("\(bad.count) reclassified-workout entr\(bad.count == 1 ? "y is" : "ies are") "
                          + "not valid identifiers and were ignored: \(bad.joined(separator: ", ")).")
        }
        return result
    }

    private static func readBool(_ defaults: UserDefaults, _ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    /// Reads the cue volume, **reporting** a stored value below the floor rather than quietly
    /// raising it.
    ///
    /// Volume 0 used to be selectable. Raising it makes cues audible again, which a user who had
    /// deliberately muted them would otherwise discover mid-run — so the change is surfaced in
    /// Settings, and points at "Play cues" (`CueSource.none` when off), the control that actually
    /// silences cues.
    private static func readCueVolume(_ defaults: UserDefaults, issues: inout [String]) -> Double {
        guard let stored = defaults.object(forKey: Key.cueVolume) as? Double,
              stored.isFinite else { return 1.0 }
        guard stored >= minimumCueVolume else {
            let percent = { (value: Double) in Int((value * 100).rounded()) }
            issues.append("Cue volume was stored at \(percent(stored))%, below the "
                          + "\(percent(minimumCueVolume))% minimum, and is now "
                          + "\(percent(minimumCueVolume))%. To silence cues entirely, turn off "
                          + "\"Play cues\".")
            return minimumCueVolume
        }
        return min(stored, 1)
    }

    private static func readInt(_ defaults: UserDefaults, _ key: String,
                                default fallback: Int, minimum: Int = 0) -> Int {
        guard let value = defaults.object(forKey: key) as? Int else { return fallback }
        return max(minimum, value)
    }

    private static func readInt(_ defaults: UserDefaults, _ key: String,
                                default fallback: Int, allowed: [Int],
                                label: String, issues: inout [String]) -> Int {
        guard let value = defaults.object(forKey: key) as? Int else { return fallback }
        guard allowed.contains(value) else {
            issues.append("\(label) was stored as \(value)s, which is not one of "
                          + "\(allowed.map(String.init).joined(separator: ", "))s. Using \(fallback)s.")
            return fallback
        }
        return value
    }
}
