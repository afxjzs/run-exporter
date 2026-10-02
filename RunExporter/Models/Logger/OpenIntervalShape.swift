import Foundation
import SwiftData

/// The settings of a plan whose running legs end when the runner ends them, not when a clock does.
///
/// You run until whatever you are watching for shows up — a joint that starts complaining, a level
/// of effort you have decided to stop at — then walk until it has gone, and repeat until a target
/// amount of running has accumulated. How many legs that takes is the measurement, so it cannot be
/// stored in advance.
///
/// "Open" is this app's existing word for a phase that ends only when its owner says so: see
/// `WarmupMode.open`, `CooldownMode.open` and `WorkoutPhaseSchedule.PlannedPhase.isOpen`. An open
/// interval plan simply applies that to the main set.
///
/// ## Why this is a separate model rather than a flag
///
/// Its presence on a `PlannedWorkout` **is** the discriminator: `plan.openIntervalShape != nil` is
/// what makes a plan an open-interval plan. A stored `kind` string would have to be checked by each
/// of the nine properties that derive a plan's shape from `resolvedBlocks`, and the tenth reader to
/// forget would get a plausible zero. Read through `PlannedWorkout.shape` instead, which returns a
/// case per kind and makes a missed one a compile error.
///
/// The fields an open-interval plan does not use — `runIntervalSeconds`, `walkIntervalSeconds`,
/// `plannedRepetitions` — are not set, as for a plan carrying blocks. (They were zero until those
/// zeros were found in every summary an open plan produced; `ShapeZeroRepair` clears old ones.)
@Model
final class OpenIntervalShape {

    @Attribute(.unique) var id: UUID

    /// Total running to accumulate before the workout ends. Walks are not counted toward it.
    var targetRunSeconds: Int

    /// The shortest walk between legs. A cue marks it; the walk does not end there on its own,
    /// because the walk's real end condition is the signal subsiding and only the runner can
    /// observe that.
    var walkFloorSeconds: Int

    var plan: PlannedWorkout?

    init(id: UUID = UUID(),
         targetRunSeconds: Int,
         walkFloorSeconds: Int) {
        self.id = id
        self.targetRunSeconds = targetRunSeconds
        self.walkFloorSeconds = walkFloorSeconds
    }
}
