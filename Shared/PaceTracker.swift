import Foundation

/// The pace figures on the watch's run screen: leg pace, the current mile split, total distance.
///
/// Fed the workout's **cumulative** distance as HealthKit reports it, with the watch's own dates —
/// so no clock is ever compared across devices (watch plan step 2). Distance arrives in batches, so
/// every pace is measured **to the latest reading**, never to "now": dividing by time-until-now
/// would make the runner look slower in the seconds between batches.
///
/// Pure; all dates are passed in. Tested in `PaceTrackerTests`.
///
/// Known limit, not handled yet: a pause is counted as time. A paused leg's pace reads slow until
/// the next leg begins.
struct PaceTracker: Equatable, Sendable {
    static let metersPerMile = 1_609.344
    /// Below this, a pace is noise — the first steps of a leg give absurd figures — so none is shown.
    static let minimumMetersForPace = 20.0

    /// Cumulative distance, meters.
    private(set) var totalMeters: Double = 0
    /// When the mile in progress began: the run's start, or the interpolated crossing of the last
    /// whole mile.
    private(set) var currentMileStartedAt: Date
    private(set) var completedMiles = 0
    /// Readings that went backwards and were ignored. Counted so a bad data source is visible.
    private(set) var rejectedReadings = 0

    private var latestReadingAt: Date
    private var legStartedAt: Date?
    private var legStartMeters: Double = 0

    init(start: Date) {
        currentMileStartedAt = start
        latestReadingAt = start
    }

    /// Seconds per mile since the leg began, or nil before a leg begins or before enough distance.
    var legPaceSecondsPerMile: TimeInterval? {
        guard let legStartedAt else { return nil }
        return pace(seconds: latestReadingAt.timeIntervalSince(legStartedAt),
                    meters: totalMeters - legStartMeters)
    }

    /// Seconds per mile since the current mile began, or nil before enough distance.
    var mileSplitSecondsPerMile: TimeInterval? {
        pace(seconds: latestReadingAt.timeIntervalSince(currentMileStartedAt),
             meters: totalMeters - Double(completedMiles) * Self.metersPerMile)
    }

    mutating func record(totalMeters newTotal: Double, at date: Date) {
        guard newTotal >= totalMeters else {
            rejectedReadings += 1
            return
        }
        let previousTotal = totalMeters
        let previousDate = latestReadingAt
        let wholeMiles = Int(newTotal / Self.metersPerMile)
        if wholeMiles > completedMiles {
            // The last whole mile passed between the two readings. Place its crossing linearly
            // between them rather than at the reading that happened to come next.
            let crossingMeters = Double(wholeMiles) * Self.metersPerMile
            let span = newTotal - previousTotal
            let fraction = span > 0 ? (crossingMeters - previousTotal) / span : 1
            currentMileStartedAt = previousDate.addingTimeInterval(fraction * date.timeIntervalSince(previousDate))
            completedMiles = wholeMiles
        }
        totalMeters = newTotal
        latestReadingAt = date
    }

    /// A leg began at `date`. Its baseline distance is the latest reading.
    mutating func beginLeg(at date: Date) {
        legStartedAt = date
        legStartMeters = totalMeters
    }

    private func pace(seconds: TimeInterval, meters: Double) -> TimeInterval? {
        guard meters >= Self.minimumMetersForPace, seconds > 0 else { return nil }
        return seconds / (meters / Self.metersPerMile)
    }
}
