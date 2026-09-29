import Foundation
import SwiftData

/// The subjective log attached to one completed HealthKit workout (spec §16).
///
/// `healthKitWorkoutUUID` is the durable link. It is the HealthKit sample UUID, not a date string,
/// so re-exporting, editing the log, or a timezone change can never re-point a log at a different
/// workout.
///
/// Two fields beyond the spec's suggested list are stored: `workoutStartDate` and
/// `workoutDistanceMiles`. Both are snapshots of the matched HealthKit workout taken at save time.
/// They exist because shoe mileage has to be derivable without a HealthKit round-trip — the export
/// and the shoe screen both need "miles on this shoe", and the spec requires shoe assignments to
/// stay editable, which rules out a stored running total on `Shoe`.
@Model
final class RunLog {

    @Attribute(.unique) var id: UUID

    /// The matched HealthKit workout, or nil for a log written **before** the workout finished.
    ///
    /// Optional so the log can be filled in during cooldown, while the run is fresh, and attached
    /// once the Watch's workout reaches HealthKit. `executionID` identifies it in the meantime.
    /// An unattached log exports with a blank `healthKitWorkoutUUID`, which is honest: it has not
    /// been matched to a workout yet, and pretending otherwise would be worse.
    var healthKitWorkoutUUID: UUID?
    var plannedWorkoutID: UUID?
    var executionID: UUID?

    var createdAt: Date
    var updatedAt: Date

    /// Snapshot of the matched workout, for ordering and mileage. See the type comment.
    var workoutStartDate: Date
    var workoutDistanceMiles: Double?
    var workoutActivityType: String

    var runIntervalSeconds: Int?
    var walkIntervalSeconds: Int?
    var plannedRepetitions: Int?
    var completedRepetitions: Int?

    var effortRPE: Double
    var personalHeatRating: Double

    var lowerBackSeverity: Double
    var leftAnkleSeverity: Double
    var rightAnkleSeverity: Double
    var leftKneeSeverity: Double
    var rightKneeSeverity: Double

    var shoeID: UUID?
    var notes: String?

    @Relationship(deleteRule: .cascade, inverse: \BodySignalDetail.runLog)
    var bodySignalDetails: [BodySignalDetail] = []

    /// True while this log is waiting to be matched to a finished HealthKit workout.
    var isAwaitingWorkoutMatch: Bool { healthKitWorkoutUUID == nil }

    init(id: UUID = UUID(),
         healthKitWorkoutUUID: UUID?,
         workoutStartDate: Date,
         workoutDistanceMiles: Double?,
         workoutActivityType: String,
         plannedWorkoutID: UUID? = nil,
         executionID: UUID? = nil,
         runIntervalSeconds: Int? = nil,
         walkIntervalSeconds: Int? = nil,
         plannedRepetitions: Int? = nil,
         completedRepetitions: Int? = nil,
         effortRPE: Double,
         personalHeatRating: Double,
         lowerBackSeverity: Double = 0,
         leftAnkleSeverity: Double = 0,
         rightAnkleSeverity: Double = 0,
         leftKneeSeverity: Double = 0,
         rightKneeSeverity: Double = 0,
         shoeID: UUID? = nil,
         notes: String? = nil,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.healthKitWorkoutUUID = healthKitWorkoutUUID
        self.workoutStartDate = workoutStartDate
        self.workoutDistanceMiles = workoutDistanceMiles
        self.workoutActivityType = workoutActivityType
        self.plannedWorkoutID = plannedWorkoutID
        self.executionID = executionID
        self.runIntervalSeconds = runIntervalSeconds
        self.walkIntervalSeconds = walkIntervalSeconds
        self.plannedRepetitions = plannedRepetitions
        self.completedRepetitions = completedRepetitions
        self.effortRPE = effortRPE
        self.personalHeatRating = personalHeatRating
        self.lowerBackSeverity = lowerBackSeverity
        self.leftAnkleSeverity = leftAnkleSeverity
        self.rightAnkleSeverity = rightAnkleSeverity
        self.leftKneeSeverity = leftKneeSeverity
        self.rightKneeSeverity = rightKneeSeverity
        self.shoeID = shoeID
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func severity(for area: BodyArea) -> Double {
        switch area {
        case .lowerBack: return lowerBackSeverity
        case .leftAnkle: return leftAnkleSeverity
        case .rightAnkle: return rightAnkleSeverity
        case .leftKnee: return leftKneeSeverity
        case .rightKnee: return rightKneeSeverity
        }
    }

    func setSeverity(_ value: Double, for area: BodyArea) {
        switch area {
        case .lowerBack: lowerBackSeverity = value
        case .leftAnkle: leftAnkleSeverity = value
        case .rightAnkle: rightAnkleSeverity = value
        case .leftKnee: leftKneeSeverity = value
        case .rightKnee: rightKneeSeverity = value
        }
    }
}

/// Optional extra context for one body area on one run (spec §15.3). Absent for most logs.
@Model
final class BodySignalDetail {

    @Attribute(.unique) var id: UUID
    var area: String
    var timing: String?
    var character: String?
    var note: String?
    var createdAt: Date

    var runLog: RunLog?

    init(id: UUID = UUID(),
         area: BodyArea,
         timing: BodySignalTiming? = nil,
         character: BodySignalCharacter? = nil,
         note: String? = nil,
         createdAt: Date = Date()) {
        self.id = id
        self.area = area.rawValue
        self.timing = timing?.rawValue
        self.character = character?.rawValue
        self.note = note
        self.createdAt = createdAt
    }

    var areaValue: BodyArea? { BodyArea(rawValue: area) }
}
