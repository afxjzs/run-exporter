import Foundation
import SwiftData

/// A run/walk interval plan (spec §6).
///
/// Mode fields are persisted as their `rawValue` strings. Readers go through the optional typed
/// accessors below; an unrecognized string surfaces as `nil` so a corrupted or future value is
/// reported rather than silently treated as "none".
@Model
final class PlannedWorkout {

    @Attribute(.unique) var id: UUID
    var name: String

    var activityType: String

    var warmupMode: String
    var warmupSeconds: Int?

    var runIntervalSeconds: Int
    var walkIntervalSeconds: Int
    var plannedRepetitions: Int

    /// Whether the plan ends with a walk after the final run. Default false: spec §11.1 requires
    /// the last run to hand straight over to cooldown unless the plan explicitly says otherwise.
    var includesFinalWalk: Bool

    var cooldownMode: String
    var cooldownSeconds: Int?

    var countdownSeconds: Int
    var createdAt: Date
    var updatedAt: Date

    var isNextWorkout: Bool
    var workoutKitIdentifier: String?

    /// The segments this plan runs, when its intervals are not all the same shape.
    ///
    /// Empty for an ordinary `4/1 × 5`, which is described by the three flat fields above. Read
    /// through `resolvedBlocks`, never directly — that accessor returns the same value type for
    /// both shapes, which is what keeps this from becoming two code paths. See
    /// `PlannedWorkoutBlock`.
    @Relationship(deleteRule: .cascade, inverse: \PlannedWorkoutBlock.plan)
    var blocks: [PlannedWorkoutBlock] = []

    /// Present only on an open-interval plan, whose legs the runner ends rather than a
    /// duration. Its presence is what distinguishes the two kinds of plan — read it through
    /// `shape`, never directly, so a reader cannot forget that this plan's flat interval fields
    /// describe nothing. See `OpenIntervalShape`.
    @Relationship(deleteRule: .cascade, inverse: \OpenIntervalShape.plan)
    var openIntervalShape: OpenIntervalShape?

    init(id: UUID = UUID(),
         name: String,
         activityType: PlannedActivityType = .running,
         warmupMode: WarmupMode = .none,
         warmupSeconds: Int? = nil,
         runIntervalSeconds: Int,
         walkIntervalSeconds: Int,
         plannedRepetitions: Int,
         includesFinalWalk: Bool = false,
         cooldownMode: CooldownMode = .open,
         cooldownSeconds: Int? = nil,
         countdownSeconds: Int = 0,
         isNextWorkout: Bool = false,
         workoutKitIdentifier: String? = nil,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.activityType = activityType.rawValue
        self.warmupMode = warmupMode.rawValue
        self.warmupSeconds = warmupSeconds
        self.runIntervalSeconds = runIntervalSeconds
        self.walkIntervalSeconds = walkIntervalSeconds
        self.plannedRepetitions = plannedRepetitions
        self.includesFinalWalk = includesFinalWalk
        self.cooldownMode = cooldownMode.rawValue
        self.cooldownSeconds = cooldownSeconds
        self.countdownSeconds = countdownSeconds
        self.isNextWorkout = isNextWorkout
        self.workoutKitIdentifier = workoutKitIdentifier
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Typed accessors

    var activityTypeValue: PlannedActivityType? { PlannedActivityType(rawValue: activityType) }
    var warmupModeValue: WarmupMode? { WarmupMode(rawValue: warmupMode) }
    var cooldownModeValue: CooldownMode? { CooldownMode(rawValue: cooldownMode) }

    // MARK: - Shape

    /// What kind of workout this plan describes, with the data that describes it.
    ///
    /// Every reader of a plan's shape goes through this. A `switch` is exhaustive, so a reader that
    /// has not considered a kind fails to compile — rather than reading a flat interval field that
    /// means nothing for that kind and getting a plausible zero back. That failure mode is the one
    /// `MISTAKES.md` records over and over.
    enum Shape: Equatable {
        /// An ordinary interval plan: one or more segments of `run/walk × repetitions`.
        case intervals([Block])
        /// Legs the runner ends, repeated until `target` seconds of running have accumulated,
        /// with at least `walkFloor` seconds of walking between them. Which body signals it asks
        /// about at the end of a leg is not part of the plan — every area is offered.
        case openIntervals(target: Int, walkFloor: Int)
        /// The plan's `PlannedWorkoutBlock` rows are gone from the store and the zeroed flat fields
        /// are all that is left. Reported, never rendered as a workout. See `hasDamagedShape`.
        case damaged
    }

    /// This plan's shape — the single entry point for every reader. See `Shape`.
    ///
    /// Order matters: an open-interval plan has no run interval and no repetitions, so it satisfies
    /// `hasDamagedShape` exactly. Asking what kind of plan this is must therefore come before
    /// asking whether an interval plan's data survived.
    var shape: Shape {
        if let openIntervalShape {
            return .openIntervals(target: openIntervalShape.targetRunSeconds,
                                  walkFloor: openIntervalShape.walkFloorSeconds)
        }
        if blocksDescribeNoWorkout { return .damaged }
        return .intervals(resolvedBlocks)
    }

    // MARK: - Derived durations

    // All four read `expandedIntervals`, which is also what `WorkoutPhaseSchedule` builds its
    // phases from. They used to multiply the flat fields out by hand, which was correct only while
    // a plan had exactly one shape — and would have quietly reported the wrong main set the moment
    // blocks arrived, in a number the plan is judged against.

    /// Total planned running time, in seconds.
    ///
    /// For an open-interval plan this is the target: the one duration such a plan does decide in
    /// advance. Summing its (empty) intervals would report no running planned for a workout whose
    /// entire definition is how much running it ends at.
    var totalRunSeconds: Int {
        switch shape {
        case .openIntervals(let target, _):
            return target
        case .intervals, .damaged:
            return expandedIntervals.reduce(0) { $0 + ($1.isRun ? $1.seconds : 0) }
        }
    }

    /// Number of walk intervals in the plan. The walk after the final run only exists when the
    /// plan explicitly asks for it (spec §11.1).
    var walkIntervalCount: Int { expandedIntervals.count { !$0.isRun } }

    /// Total planned walking time inside the main set, in seconds.
    var totalWalkSeconds: Int {
        expandedIntervals.reduce(0) { $0 + ($1.isRun ? 0 : $1.seconds) }
    }

    /// Total repetitions across every block. Equals `plannedRepetitions` for a single-shape plan.
    var totalRepetitions: Int { Self.totalRepetitions(blocks: resolvedBlocks) }

    /// Rounds for a shape that has not been saved yet — the editor counts them while building.
    static func totalRepetitions(blocks: [Block]) -> Int {
        blocks.reduce(0) { $0 + max(0, $1.repetitions) }
    }

    /// This plan's one shape, or nil when it has several.
    ///
    /// The question "does this plan have a single run and walk length, and if so what are they?"
    /// is asked wherever a record or a screen can hold only one — the timer session's shape copy,
    /// the post-run log form's prefill, the plan card. Answering it in each of those places is how
    /// two of them come to disagree.
    ///
    /// Nil for an open-interval plan as well as a multi-block one, and for the same reason: it has
    /// no single run length or walk length to give. Reading the flat fields there would hand back a
    /// `0/0` block, which the plan card would render as a workout.
    var singleShape: Block? {
        switch shape {
        case .openIntervals, .damaged:
            return nil
        case .intervals(let blocks):
            return blocks.count > 1 ? nil : blocks.first
        }
    }

    /// "Block 1" — the label for a segment at a given position, shared by the editor and the card
    /// so the two screens cannot name the same segment differently.
    static func blockLabel(at index: Int) -> String { "Block \(index + 1)" }

    /// Main set only — warmup, countdown and cooldown are excluded by design so a long cooldown
    /// never inflates the number the plan is judged against.
    var mainSetSeconds: Int { totalRunSeconds + totalWalkSeconds }

    /// Everything with a known duration: warmup (when timed) + main set + cooldown (when timed).
    /// An open warmup or cooldown contributes nothing because its length is not knowable up front.
    var expectedTotalSeconds: Int {
        var total = mainSetSeconds
        if warmupModeValue == .timed { total += warmupSeconds ?? 0 }
        if cooldownModeValue == .timed { total += cooldownSeconds ?? 0 }
        return total
    }

    /// "4/1 × 5" for a plan of one shape, "5/1×1 · 8/1×2 · 5/1×1" for one that runs several.
    ///
    /// Reads `resolvedBlocks` rather than the flat fields. Those fields describe a multi-block plan
    /// no better than a single number describes a list, so a plan built as 5/1×1 → 8/1×2 → 5/1×1
    /// used to appear on the plan list as "5/1 × 1" — the app running one workout and naming
    /// another.
    /// `resolvedBlocks` supplies the flat-field fallback itself, so there is nothing to repeat
    /// here. An earlier version guarded against an empty list with a second copy of that fallback,
    /// which could never run and was one more place for the rule to drift.
    var intervalSummary: String {
        switch shape {
        case .damaged:
            return Self.damagedShapeSummary
        case .openIntervals(let target, let walkFloor):
            return Self.openIntervalSummary(target: target, walkFloor: walkFloor)
        case .intervals(let blocks):
            return Self.summary(blocks: blocks, includesFinalWalk: includesFinalWalk)
        }
    }

    /// "Run to 30 min · 3 min walks" — the two numbers that define an open-interval plan.
    ///
    /// Neither a leg length nor a round count appears, because neither exists until the run
    /// happens. Stating the target and the walk floor is the whole of what was decided in advance.
    static func openIntervalSummary(target: Int, walkFloor: Int) -> String {
        "Run to \(compactDuration(target)) min · \(compactDuration(walkFloor)) min walks"
    }

    /// True when this plan's stored shape describes no workout at all.
    ///
    /// No plan can be saved in this state: `WorkoutPhaseSchedule.build` refuses a run interval of
    /// zero, and the editor refuses to save what the schedule would refuse to run. It appears for
    /// one reason — the plan's `PlannedWorkoutBlock` rows are gone from the store while the flat
    /// fields, zeroed on the assumption those rows would always be there, are all that is left.
    ///
    /// **That happens silently.** Installing an app build whose schema has no `PlannedWorkoutBlock`
    /// over a store that contains such rows does not fail: SwiftData drops the table, the plan
    /// reads 0/0×0, and `hasMultipleBlocks` becomes false — so without this check the plan would
    /// render as "0 continuous" and export a `runIntervalSeconds` of 0 as though it were measured.
    /// A workout that runs for no time is not a plausible reading of anything, so it is reported.
    ///
    /// Answered from `shape`, not from the blocks directly. An open-interval plan has no run
    /// interval and no repetitions **by design**, so it satisfies the raw predicate below exactly —
    /// and this flag raises the warning on the plan list and blanks three export columns. A healthy
    /// plan tripping the data-loss alarm would train its owner to ignore the alarm, which is worse
    /// than not having one.
    var hasDamagedShape: Bool {
        if case .damaged = shape { return true }
        return false
    }

    /// The raw test: every segment this plan describes runs for no time, or no rounds.
    ///
    /// Only `shape` may read this, and only after it has ruled out the kinds of plan for which
    /// zeroed interval fields are correct rather than destroyed.
    private var blocksDescribeNoWorkout: Bool {
        resolvedBlocks.allSatisfy { $0.runSeconds <= 0 || $0.repetitions <= 0 }
    }

    /// Shown wherever a damaged plan's shape would otherwise be rendered as a number.
    ///
    /// Names the recovery route, because there is one: every plan's segments are written to
    /// `planned_workout_blocks.csv` on every export, including plans of a single segment.
    static let damagedShapeSummary = "Shape missing — restore from your last export"

    /// The same summary for a shape that has not been saved yet.
    ///
    /// The editor names a workout after its shape as the user builds it, before any
    /// `PlannedWorkout` exists to ask. Sharing this with `intervalSummary` is what keeps the name
    /// the editor proposes identical to the one the plan list will show back.
    static func summary(blocks: [Block], includesFinalWalk: Bool) -> String {
        if blocks.count > 1 {
            return blocks.map(blockSummary).joined(separator: " · ")
        }
        // No blocks at all describes no workout. Empty rather than a fabricated shape: this is a
        // state the editor prevents and the model cannot reach, and inventing "0 continuous" for
        // it would put a plausible name on nothing.
        guard let only = blocks.first else { return "" }

        // "Continuous" means no walk is ever run, which needs `includesFinalWalk` to decide. A
        // single round drops its trailing walk under spec §11.1 — unless the plan asks for it, and
        // then the plan really does walk. Without this flag the summary called such a plan
        // continuous while `expandedIntervals` appended a walk to it.
        let runsAWalk = only.walkSeconds > 0 && (only.repetitions > 1 || includesFinalWalk)
        guard runsAWalk else {
            return compactDuration(only.runSeconds) + " continuous"
        }
        return "\(compactDuration(only.runSeconds))/\(compactDuration(only.walkSeconds)) × \(only.repetitions)"
    }

    /// This plan's shape as one string: `"300/60x1|480/60x2|300/60x1"`.
    ///
    /// For records that must remember a shape after the plan itself has moved on —
    /// `PendingWorkoutExecution` copies a plan's shape precisely so a later edit cannot rewrite
    /// what was actually run, and three integer columns cannot hold a plan of several segments.
    ///
    /// Seconds and ASCII rather than the display form, because this ends up in a CSV column that
    /// someone will parse. Every plan gets one, including a plain `4/1 × 5` (`"240/60x5"`), so the
    /// column is never a special case.
    /// An open-interval plan writes `"open:1800/180"` — target seconds, then walk floor. It has no
    /// segments, and the flat fields would write `"0/0x0"`, which is exactly what a plan whose
    /// block rows were destroyed writes. The session record would then describe a perfectly good
    /// run as data loss, in the one column kept precisely so the truth about it survives.
    var blockShapeDescriptor: String {
        switch shape {
        case .openIntervals(let target, let walkFloor):
            return "\(Self.openShapePrefix)\(target)/\(walkFloor)"
        case .intervals, .damaged:
            return resolvedBlocks
                .map { "\($0.runSeconds)/\($0.walkSeconds)x\($0.repetitions)" }
                .joined(separator: Self.blockShapeSeparator)
        }
    }

    /// Marks a `blockShapeDescriptor` as describing an open-interval plan rather than segments.
    /// Named for the same reason the separator is: a literal in two places drifts.
    static let openShapePrefix = "open:"

    /// Separates one segment from the next in `blockShapeDescriptor`. Named because the readers
    /// that count segments split on it, and a literal in two places is a bug waiting to happen.
    static let blockShapeSeparator = "|"

    /// One block, compactly: "8/1×2", or "8×2" / "8" for a block with no recovery walk.
    ///
    /// Tighter than the single-shape form — no spaces around the ×, since three of these sit on one
    /// row. Shared with the editor's block rows so the string a user builds against is the same one
    /// the plan list shows back.
    static func blockSummary(_ block: Block) -> String {
        let run = compactDuration(block.runSeconds)
        guard block.walkSeconds > 0 else {
            return block.repetitions > 1 ? "\(run)×\(block.repetitions)" : run
        }
        return "\(run)/\(compactDuration(block.walkSeconds))×\(block.repetitions)"
    }

    /// Minutes when the value divides evenly, otherwise m:ss — "4", "1", "1:30".
    static func compactDuration(_ seconds: Int) -> String {
        guard seconds > 0 else { return "0" }
        if seconds % 60 == 0 { return String(seconds / 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    /// m:ss — used wherever an exact interval length is shown.
    static func clockDuration(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }

    // MARK: - Copying

    /// A new plan describing the same workout.
    ///
    /// Lives on the model for the same reason `deleteConsequenceMessage` does: two screens
    /// duplicate a plan — the list's swipe action and the detail screen's button — and a second
    /// copy of this logic is free to drift from the first. Both previously built the copy from the
    /// flat fields alone, so duplicating `5/1×1 → 8/1×2 → 5/1×1` handed back a flat `5/1 × 1`.
    ///
    /// Mode fields are copied as their **raw strings** rather than through the typed accessors. An
    /// unrecognized value is meant to surface as `nil` and be reported; passing it through
    /// `?? .running` would silently rewrite a corrupted plan into a valid-looking one, which is
    /// exactly the repair-without-saying-so this model's own comment refuses.
    ///
    /// Two things are deliberately **not** copied. `workoutKitIdentifier` names an entry in this
    /// iPhone's workout queue and deleting a plan removes whatever it names — a copy carrying the
    /// original's identifier would mean deleting the copy clears the original's queue entry. And
    /// `isNextWorkout`, because duplicating a plan says nothing about what to run next.
    func duplicate() -> PlannedWorkout {
        let copy = PlannedWorkout(name: "\(name) copy",
                                  runIntervalSeconds: runIntervalSeconds,
                                  walkIntervalSeconds: walkIntervalSeconds,
                                  plannedRepetitions: plannedRepetitions,
                                  includesFinalWalk: includesFinalWalk,
                                  countdownSeconds: countdownSeconds)
        copy.activityType = activityType
        copy.warmupMode = warmupMode
        copy.warmupSeconds = warmupSeconds
        copy.cooldownMode = cooldownMode
        copy.cooldownSeconds = cooldownSeconds

        // New records, never the originals. `PlannedWorkoutBlock.plan` is the inverse of `blocks`,
        // so assigning the original's blocks re-parents them: the plan being copied is left with
        // none, silently becoming a flat plan, and the cascade delete rule would then take those
        // blocks away with the copy.
        copy.blocks = blocks.map { block in
            PlannedWorkoutBlock(orderIndex: block.orderIndex,
                                runIntervalSeconds: block.runIntervalSeconds,
                                walkIntervalSeconds: block.walkIntervalSeconds,
                                repetitions: block.repetitions)
        }
        return copy
    }

    // MARK: - Deletion

    /// What to tell the user when clearing this plan's queue entry did not work.
    ///
    /// One string, on the model, because two screens delete a plan and both handle the failure. The
    /// list view used to say "try again, or clear the queue from Send to Watch" while the detail
    /// view said restarting the iPhone is the only known remedy — and `LEARNINGS.md` records
    /// `removeAllWorkouts()` leaving a queue of four untouched across repeated taps, so the list's
    /// advice pointed at a fix that was measured not to work.
    static let stuckQueueMessage =
        "This workout is still in this iPhone's queue, so it was not deleted here. If it stays "
        + "stuck, restarting the iPhone is the only known way to clear it — WorkoutKit's own "
        + "removal can wedge."

    /// What deleting this plan will actually do, in the user's terms.
    ///
    /// Lives on the model because two screens delete a plan — the list's swipe action and the detail
    /// screen's button — and a second copy of this wording would be free to drift from the first.
    /// This project already has one bug of exactly that shape, where two copies of a mapping
    /// disagreed about which timestamp to use.
    ///
    /// Built in steps as an annotated `String` rather than inline in a `Text(...)`. A ternary mixing
    /// interpolation with `+` concatenation inside a `Text` initialiser is what has made this
    /// project's type-checker give up three times, and it fails the Release build rather than
    /// warning.
    var deleteConsequenceMessage: String {
        let removed: String = "\"\(name)\" will be removed"
        guard workoutKitIdentifier != nil else {
            return removed + ". This cannot be undone."
        }
        // Says "queue on this iPhone", not "Watch". Deleting a plan removes its entry from
        // `WorkoutScheduler`, which lives on the phone — it cannot touch a workout that is already
        // on the Watch, and on the owner's hardware nothing scheduled has ever got there anyway.
        // The previous wording promised the delete reached a second device, which it does not.
        return removed + ", along with its entry in this iPhone's workout queue. Anything already "
            + "on your Watch stays there and must be deleted on the Watch. This cannot be undone."
    }
}

// MARK: - Presets

/// The starter plans from spec §7. Selecting one creates an ordinary editable `PlannedWorkout`.
struct PlannedWorkoutPreset: Identifiable, Hashable {
    let name: String
    let runSeconds: Int
    let walkSeconds: Int
    let repetitions: Int

    var id: String { name }

    static let all: [PlannedWorkoutPreset] = [
        PlannedWorkoutPreset(name: "1/1 × 8", runSeconds: 60, walkSeconds: 60, repetitions: 8),
        PlannedWorkoutPreset(name: "90/60 × 8", runSeconds: 90, walkSeconds: 60, repetitions: 8),
        PlannedWorkoutPreset(name: "2/1 × 8", runSeconds: 120, walkSeconds: 60, repetitions: 8),
        PlannedWorkoutPreset(name: "3/1 × 5", runSeconds: 180, walkSeconds: 60, repetitions: 5),
        PlannedWorkoutPreset(name: "3/1 × 6", runSeconds: 180, walkSeconds: 60, repetitions: 6),
        PlannedWorkoutPreset(name: "4/1 × 5", runSeconds: 240, walkSeconds: 60, repetitions: 5),
        PlannedWorkoutPreset(name: "5/1 × 4", runSeconds: 300, walkSeconds: 60, repetitions: 4),
        PlannedWorkoutPreset(name: "8/1 × 3", runSeconds: 480, walkSeconds: 60, repetitions: 3),
        PlannedWorkoutPreset(name: "10/1 × 2", runSeconds: 600, walkSeconds: 60, repetitions: 2),
        PlannedWorkoutPreset(name: "20 min continuous", runSeconds: 1200, walkSeconds: 0, repetitions: 1),
    ]

    func makeWorkout(defaults: LoggerDefaults) -> PlannedWorkout {
        PlannedWorkout(name: name,
                       activityType: defaults.activityType,
                       warmupMode: .none,
                       runIntervalSeconds: runSeconds,
                       walkIntervalSeconds: walkSeconds,
                       plannedRepetitions: repetitions,
                       cooldownMode: defaults.cooldownMode,
                       // A timed cooldown *must* carry a duration or the plan cannot be
                       // scheduled; nil is only valid for none/open.
                       cooldownSeconds: defaults.cooldownMode == .timed
                           ? defaults.defaultCooldownSeconds
                           : nil,
                       countdownSeconds: defaults.countdownSeconds)
    }
}
