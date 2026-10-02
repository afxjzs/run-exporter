import Foundation
import SwiftData

/// Rewrites the zeros older builds stored to mean "this shape is described elsewhere" into "not set".
///
/// Until the shape fields became optional, a plan described by its blocks or by an open-interval
/// shape held `0/0/0` in its flat run, walk and rounds, and executions and run logs copied those
/// zeros. Every summary built from them reported a plausible zero. SwiftData keeps the stored values
/// when a column becomes optional, so this clears them, once, at launch — and finds nothing to do on
/// every launch after.
///
/// It clears only zeros that stood for "described elsewhere", never a real value. A continuous run
/// walks for 0 seconds, and that 0 is a measurement.
enum ShapeZeroRepair {

    /// Clears the stored zeros and saves. Returns how many records changed.
    @MainActor
    static func run(in context: ModelContext) throws -> Int {
        var changed = 0

        for plan in try context.fetch(FetchDescriptor<PlannedWorkout>()) {
            let describedElsewhere = !plan.blocks.isEmpty || plan.openIntervalShape != nil
            // No runnable single shape has a run of zero or no rounds; such fields describe nothing,
            // and leaving the zeros would only be a second way of saying so.
            let describesNothing = (plan.runIntervalSeconds ?? 0) <= 0 || (plan.plannedRepetitions ?? 0) <= 0
            let anySet = plan.runIntervalSeconds != nil || plan.walkIntervalSeconds != nil
                || plan.plannedRepetitions != nil
            guard (describedElsewhere || describesNothing), anySet else { continue }
            plan.runIntervalSeconds = nil
            plan.walkIntervalSeconds = nil
            plan.plannedRepetitions = nil
            changed += 1
        }

        for execution in try context.fetch(FetchDescriptor<PendingWorkoutExecution>()) {
            // A session from before `blockShape` existed has no other record of its shape: its own
            // columns are the truth about it and are left alone.
            guard let shape = execution.blockShape else { continue }
            if shape.hasPrefix(PlannedWorkout.openShapePrefix) {
                // An open run decides its legs, rounds and length as it goes.
                guard execution.runIntervalSeconds != nil || execution.walkIntervalSeconds != nil
                    || execution.plannedRepetitions != nil || execution.expectedDurationSeconds != nil
                else { continue }
                execution.runIntervalSeconds = nil
                execution.walkIntervalSeconds = nil
                execution.plannedRepetitions = nil
                execution.expectedDurationSeconds = nil
                changed += 1
            } else if shape.contains(PlannedWorkout.blockShapeSeparator) {
                // Several segments: no single run or walk length. Rounds and length are real.
                guard execution.runIntervalSeconds != nil || execution.walkIntervalSeconds != nil
                else { continue }
                execution.runIntervalSeconds = nil
                execution.walkIntervalSeconds = nil
                changed += 1
            }
        }

        for log in try context.fetch(FetchDescriptor<RunLog>()) {
            // A log carries no shape record of its own; it copied its execution's columns. Its zero
            // run length is the copied "no single shape", and its zero rounds the copied "decided
            // during the run". A walk of 0 beside a real run length is a continuous run and stays.
            var touched = false
            if log.runIntervalSeconds == 0 {
                log.runIntervalSeconds = nil
                log.walkIntervalSeconds = nil
                touched = true
            }
            if log.plannedRepetitions == 0 {
                log.plannedRepetitions = nil
                touched = true
            }
            if touched { changed += 1 }
        }

        if changed > 0 { try context.save() }
        return changed
    }
}
