import Foundation
import SwiftData

/// A run the owner chose to leave out of History: a demo, a test, a run that was not one.
///
/// Keyed by the Health workout, so any run can be hidden, including one this app did not start.
/// Hiding changes only History, its cards, totals and charts. The workout stays in Health and in
/// exports. Undone from History's "Hidden runs" list.
@Model
final class HiddenHistoryRun {
    var healthKitWorkoutUUID: UUID
    var hiddenAt: Date

    init(healthKitWorkoutUUID: UUID, hiddenAt: Date) {
        self.healthKitWorkoutUUID = healthKitWorkoutUUID
        self.hiddenAt = hiddenAt
    }
}
