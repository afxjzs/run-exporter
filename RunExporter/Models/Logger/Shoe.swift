import Foundation
import SwiftData

/// A pair of shoes a workout can be assigned to (spec §18).
///
/// Mileage is deliberately **not** stored on the shoe. `startingMileage` records what the shoe had
/// already covered before the app started tracking it; everything after that is derived by summing
/// the distances of the `RunLog`s assigned to it. A stored running total would drift the moment a
/// log's shoe assignment is corrected — which the spec explicitly requires to be possible.
@Model
final class Shoe {

    @Attribute(.unique) var id: UUID
    var brand: String
    var model: String
    var displayName: String
    var firstUseDate: Date?
    var retiredDate: Date?
    /// Miles the shoe had covered before it was added to the app.
    var startingMileage: Double
    var isDefault: Bool
    var notes: String?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         brand: String,
         model: String,
         displayName: String? = nil,
         firstUseDate: Date? = nil,
         retiredDate: Date? = nil,
         startingMileage: Double = 0,
         isDefault: Bool = false,
         notes: String? = nil,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.brand = brand
        self.model = model
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = (trimmed?.isEmpty == false)
            ? trimmed!
            : "\(brand) \(model)".trimmingCharacters(in: .whitespacesAndNewlines)
        self.firstUseDate = firstUseDate
        self.retiredDate = retiredDate
        self.startingMileage = startingMileage
        self.isDefault = isDefault
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isRetired: Bool { retiredDate != nil }
}
