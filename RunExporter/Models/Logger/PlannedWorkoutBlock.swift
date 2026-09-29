import Foundation
import SwiftData

/// One `run/walk × repetitions` segment of a plan.
///
/// A plan used to be a single triple — one run length, one walk length, one repetition count — so
/// every interval in a workout was necessarily identical. Blocks are what let a plan say
/// `5/1 × 1 → 8/1 × 2 → 5/1 × 1`.
///
/// ## Why plans without blocks still work
///
/// A plan with an empty `blocks` relationship is not broken or half-migrated: it is a
/// single-block plan whose one block is described by the flat `runIntervalSeconds` /
/// `walkIntervalSeconds` / `plannedRepetitions` fields. `PlannedWorkout.resolvedBlocks` reads
/// either shape and returns the same value type, so everything downstream — the schedule, the
/// durations, the WorkoutKit payload — has exactly one code path and no notion of "old" plans.
///
/// That is deliberate, and it is why this change needs no migration. The same reasoning the
/// interval-linking fix used: a permanent code path to rewrite a handful of rows is worse than
/// reading both shapes correctly forever.
///
/// `orderIndex` decides the sequence. A SwiftData to-many relationship comes back unordered, so
/// nothing may depend on array position.
@Model
final class PlannedWorkoutBlock {

    @Attribute(.unique) var id: UUID
    /// Position within the plan, ascending. Not the array index — the relationship is unordered.
    var orderIndex: Int

    var runIntervalSeconds: Int
    /// Zero for a block that runs straight through with no recovery walk.
    var walkIntervalSeconds: Int
    var repetitions: Int

    var plan: PlannedWorkout?

    init(id: UUID = UUID(),
         orderIndex: Int,
         runIntervalSeconds: Int,
         walkIntervalSeconds: Int,
         repetitions: Int) {
        self.id = id
        self.orderIndex = orderIndex
        self.runIntervalSeconds = runIntervalSeconds
        self.walkIntervalSeconds = walkIntervalSeconds
        self.repetitions = repetitions
    }
}

extension PlannedWorkout {

    /// One segment of a plan, resolved from either the stored blocks or the flat fields.
    ///
    /// A plain value so the schedule builder, the duration maths and the WorkoutKit payload all
    /// read the same thing and cannot disagree about a plan's shape.
    struct Block: Equatable {
        let runSeconds: Int
        let walkSeconds: Int
        let repetitions: Int
    }

    /// This plan's segments in order — the single source of truth about its shape.
    ///
    /// Falls back to the flat fields when there are no stored blocks, which is what a plan created
    /// before blocks existed looks like, and also what a plain `4/1 × 5` still looks like today.
    var resolvedBlocks: [Block] {
        guard !blocks.isEmpty else {
            return [Block(runSeconds: runIntervalSeconds,
                          walkSeconds: walkIntervalSeconds,
                          repetitions: plannedRepetitions)]
        }
        return blocks
            .sorted { $0.orderIndex < $1.orderIndex }
            .map { Block(runSeconds: $0.runIntervalSeconds,
                         walkSeconds: $0.walkIntervalSeconds,
                         repetitions: $0.repetitions) }
    }

    /// True when this plan's intervals are not all the same shape.
    ///
    /// The flat `runIntervalSeconds` / `walkIntervalSeconds` / `plannedRepetitions` columns cannot
    /// describe such a plan, so the export blanks them rather than reporting the first block's
    /// numbers as though they applied to the whole run.
    var hasMultipleBlocks: Bool { resolvedBlocks.count > 1 }

    /// Every interval the main set will run, in order, as `(isRun, seconds, repetition)`.
    ///
    /// The one place the shape is expanded. `WorkoutPhaseSchedule` builds its phases from this and
    /// the duration properties below add it up, so a plan's advertised main set and the schedule it
    /// actually runs can never drift apart.
    ///
    /// The "no walk after the final run" rule (spec §11.1) is a statement about the **workout**, not
    /// about each block. Applied per block it would drop the walk between blocks and weld one
    /// block's opening run onto the previous block's closing run.
    var expandedIntervals: [(isRun: Bool, seconds: Int, repetition: Int)] {
        Self.expandedIntervals(blocks: resolvedBlocks, includesFinalWalk: includesFinalWalk)
    }

    /// The same expansion for a shape that has not been saved yet.
    ///
    /// The editor has to show a main set for blocks the user is still assembling, when no
    /// `PlannedWorkout` exists to ask. Computing it there would be a second copy of the rule below,
    /// free to drift from this one — and a preview that disagrees with what gets saved is the plan
    /// stating one number and running another.
    static func expandedIntervals(blocks: [Block],
                                  includesFinalWalk: Bool)
        -> [(isRun: Bool, seconds: Int, repetition: Int)] {
        let totalRepetitions = blocks.reduce(0) { $0 + max(0, $1.repetitions) }

        var intervals: [(isRun: Bool, seconds: Int, repetition: Int)] = []
        var repetition = 0

        for block in blocks {
            guard block.repetitions > 0 else { continue }
            for _ in 1...block.repetitions {
                repetition += 1
                intervals.append((true, block.runSeconds, repetition))

                let isFinalRunOfWorkout = repetition == totalRepetitions
                let wantsWalk = block.walkSeconds > 0
                    && (!isFinalRunOfWorkout || includesFinalWalk)
                if wantsWalk {
                    intervals.append((false, block.walkSeconds, repetition))
                }
            }
        }
        return intervals
    }

    /// Main set for an unsaved shape — run and walk only, matching `mainSetSeconds`.
    static func mainSetSeconds(blocks: [Block], includesFinalWalk: Bool) -> Int {
        expandedIntervals(blocks: blocks, includesFinalWalk: includesFinalWalk)
            .reduce(0) { $0 + $1.seconds }
    }
}
