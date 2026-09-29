import Foundation
import SwiftData

/// Optional next-day recovery note for one workout (spec §17).
///
/// Deliberately separate from `RunLog`: it is filled in a day later, is entirely optional, and
/// must not make the post-run form feel unfinished. `recoveryRating` has no default — a log only
/// exists once the user has actually chosen a value.
@Model
final class RecoveryLog {

    @Attribute(.unique) var id: UUID
    var healthKitWorkoutUUID: UUID
    var runLogID: UUID?

    /// 10 = completely recovered, 1 = severely affected.
    var recoveryRating: Double

    var lowerBackSeverity: Double
    var leftAnkleSeverity: Double
    var rightAnkleSeverity: Double
    var leftKneeSeverity: Double
    var rightKneeSeverity: Double

    var notes: String?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         healthKitWorkoutUUID: UUID,
         runLogID: UUID? = nil,
         recoveryRating: Double,
         lowerBackSeverity: Double = 0,
         leftAnkleSeverity: Double = 0,
         rightAnkleSeverity: Double = 0,
         leftKneeSeverity: Double = 0,
         rightKneeSeverity: Double = 0,
         notes: String? = nil,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.healthKitWorkoutUUID = healthKitWorkoutUUID
        self.runLogID = runLogID
        self.recoveryRating = recoveryRating
        self.lowerBackSeverity = lowerBackSeverity
        self.leftAnkleSeverity = leftAnkleSeverity
        self.rightAnkleSeverity = rightAnkleSeverity
        self.leftKneeSeverity = leftKneeSeverity
        self.rightKneeSeverity = rightKneeSeverity
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
