import Foundation

/// Derives shoe mileage from the run logs assigned to each shoe.
///
/// Pure functions over plain values so the same arithmetic serves the shoes screen, the post-run
/// form and `shoes.csv` — and so it can be tested without a store. Nothing here reads SwiftData.
///
/// Mileage is derived rather than stored because the spec requires a shoe assignment to stay
/// correctable; a stored running total would drift the first time one was changed.
enum ShoeMileage {

    /// One workout's contribution to a shoe's odometer.
    struct Assignment {
        let shoeID: UUID
        let workoutStartDate: Date
        let distanceMiles: Double

        init(shoeID: UUID, workoutStartDate: Date, distanceMiles: Double?) {
            self.shoeID = shoeID
            self.workoutStartDate = workoutStartDate
            // A workout with no recorded distance contributes nothing rather than a guessed value.
            if let distanceMiles, distanceMiles.isFinite, distanceMiles > 0 {
                self.distanceMiles = distanceMiles
            } else {
                self.distanceMiles = 0
            }
        }
    }

    /// Total miles logged against each shoe, excluding `startingMileage`.
    static func assignedMiles(from assignments: [Assignment]) -> [UUID: Double] {
        var totals: [UUID: Double] = [:]
        for assignment in assignments {
            totals[assignment.shoeID, default: 0] += assignment.distanceMiles
        }
        return totals
    }

    /// The shoe's odometer reading immediately **after** the given workout: `startingMileage` plus
    /// every workout assigned to that shoe that started no later than this one.
    ///
    /// Workouts starting at the same instant are all counted, so the reading never depends on
    /// fetch order.
    static func mileageAtWorkout(shoeID: UUID,
                                 startingMileage: Double,
                                 workoutStartDate: Date,
                                 assignments: [Assignment]) -> Double {
        assignments
            .filter { $0.shoeID == shoeID && $0.workoutStartDate <= workoutStartDate }
            .reduce(startingMileage) { $0 + $1.distanceMiles }
    }
}
