import Foundation
import SwiftData

/// One elapsed phase of one execution (spec §13).
///
/// Recorded from the app's own timer, because HealthKit does not preserve run/walk boundaries in a
/// form that survives export. `healthKitWorkoutUUID` is filled in once the execution is matched,
/// which is why it is optional here: the intervals exist before the workout is matched, and losing
/// them until a match happens would defeat the point.
@Model
final class WorkoutIntervalLog {

    @Attribute(.unique) var id: UUID
    var executionID: UUID
    var healthKitWorkoutUUID: UUID?

    var sequenceIndex: Int
    var phaseType: String

    var repetitionNumber: Int?
    var plannedDurationSeconds: Int?
    var actualDurationSeconds: Double

    var startDate: Date
    var endDate: Date

    var wasSkipped: Bool
    var wasInterrupted: Bool

    // MARK: - Open-interval legs
    //
    // Nil on every interval run, which measures none of this. Optional columns on this table
    // rather than a table of their own, deliberately: a new SwiftData entity is a new one-way door
    // — an older build drops the table and takes the rows with it, the way `PlannedWorkoutBlock`
    // already did once. Columns degrade differently, losing the annotation and keeping the workout.

    /// Why the leg stopped, as a `LegEndReason` rawValue. Recorded, never inferred: a leg's
    /// duration cannot distinguish a runner who stopped from a target that ran out.
    var endReason: String?

    /// The 0–10 readings taken when the leg ended, one per body area.
    ///
    /// Five columns rather than a related record, and named exactly as `RunLog`'s are, so a leg's
    /// readings join to the post-run ones without a translation step. Nil means the question was
    /// never asked — every interval workout, every walk, and a leg the target ended without a
    /// prompt; `0` means it was asked and the answer was nothing. Read and written through
    /// `signalReadings`, so nothing has to remember the order.
    var lowerBackSeverity: Double?
    var leftAnkleSeverity: Double?
    var rightAnkleSeverity: Double?
    var leftKneeSeverity: Double?
    var rightKneeSeverity: Double?

    var signalReadings: BodySignalReadings {
        get {
            BodySignalReadings(lowerBack: lowerBackSeverity,
                               leftAnkle: leftAnkleSeverity,
                               rightAnkle: rightAnkleSeverity,
                               leftKnee: leftKneeSeverity,
                               rightKnee: rightKneeSeverity)
        }
        set {
            lowerBackSeverity = newValue.lowerBack
            leftAnkleSeverity = newValue.leftAnkle
            rightAnkleSeverity = newValue.rightAnkle
            leftKneeSeverity = newValue.leftKnee
            rightKneeSeverity = newValue.rightKnee
        }
    }

    /// When, during a recovery walk, the runner reported that signal gone. This is not the walk's end —
    /// the walk continues to its floor and beyond — and the gap between the two is the number the
    /// protocol is trying to measure.
    var baselineReachedAt: Date?

    init(id: UUID = UUID(),
         executionID: UUID,
         healthKitWorkoutUUID: UUID? = nil,
         sequenceIndex: Int,
         phaseType: WorkoutPhase,
         repetitionNumber: Int? = nil,
         plannedDurationSeconds: Int? = nil,
         actualDurationSeconds: Double,
         startDate: Date,
         endDate: Date,
         wasSkipped: Bool = false,
         wasInterrupted: Bool = false,
         endReason: LegEndReason? = nil,
         signalReadings: BodySignalReadings = BodySignalReadings(),
         baselineReachedAt: Date? = nil) {
        self.id = id
        self.executionID = executionID
        self.healthKitWorkoutUUID = healthKitWorkoutUUID
        self.sequenceIndex = sequenceIndex
        self.phaseType = phaseType.rawValue
        self.repetitionNumber = repetitionNumber
        self.plannedDurationSeconds = plannedDurationSeconds
        self.actualDurationSeconds = actualDurationSeconds
        self.startDate = startDate
        self.endDate = endDate
        self.wasSkipped = wasSkipped
        self.wasInterrupted = wasInterrupted
        self.endReason = endReason?.rawValue
        self.lowerBackSeverity = signalReadings.lowerBack
        self.leftAnkleSeverity = signalReadings.leftAnkle
        self.rightAnkleSeverity = signalReadings.rightAnkle
        self.leftKneeSeverity = signalReadings.leftKnee
        self.rightKneeSeverity = signalReadings.rightKnee
        self.baselineReachedAt = baselineReachedAt
    }

    var phaseTypeValue: WorkoutPhase? { WorkoutPhase(rawValue: phaseType) }

    /// Nil both when nothing was recorded and when the stored string is not one this build knows.
    /// An unrecognized value is reported rather than swapped for a plausible case, same as every
    /// other mode field here.
    var endReasonValue: LegEndReason? { endReason.flatMap(LegEndReason.init(rawValue:)) }
}
