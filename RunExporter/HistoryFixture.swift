#if DEBUG
import Foundation
import CoreLocation

/// Invented runs for the History UI test (`UITesting.historyFixture`), Debug builds only.
///
/// Nothing here is real. Dates are placed relative to the current week so the groups the test
/// checks ("This week", "Last week") always exist; routes are made-up out-and-back lines around a
/// public park. Each shape the test looks for is used by one run only, so it finds one card.
enum HistoryFixture {

    struct Run {
        let weeksAgo: Int
        /// 0 is Monday.
        let day: Int
        let shape: String
        let kind: RunKind?
        let logged: Bool
        let hasRoute: Bool
        let miles: Double
        let minutes: Double
        let averageHeartRate: Double
    }

    static let runs: [Run] = [
        Run(weeksAgo: 0, day: 0, shape: "1/2 × 8", kind: .speed, logged: true, hasRoute: true,
            miles: 2.1, minutes: 29, averageHeartRate: 141),
        Run(weeksAgo: 1, day: 0, shape: "1/2 × 8", kind: .speed, logged: true, hasRoute: true,
            miles: 2.0, minutes: 29, averageHeartRate: 143),
        Run(weeksAgo: 1, day: 2, shape: "3/1 × 6", kind: .recovery, logged: true, hasRoute: true,
            miles: 2.4, minutes: 29, averageHeartRate: 134),
        Run(weeksAgo: 1, day: 4, shape: "6/1 × 4", kind: .endurance, logged: false, hasRoute: true,
            miles: 2.6, minutes: 33, averageHeartRate: 138),
        Run(weeksAgo: 2, day: 1, shape: "1/2 × 8", kind: .speed, logged: true, hasRoute: false,
            miles: 2.0, minutes: 29, averageHeartRate: 144),
        Run(weeksAgo: 2, day: 3, shape: "2/1 × 10", kind: .recovery, logged: true, hasRoute: true,
            miles: 2.5, minutes: 35, averageHeartRate: 133),
        Run(weeksAgo: 2, day: 5, shape: "5/1 × 4", kind: .endurance, logged: true, hasRoute: true,
            miles: 2.3, minutes: 29, averageHeartRate: 137),
        // Recorded before kinds existed: it has a timer session, so its kind can be set later.
        Run(weeksAgo: 3, day: 0, shape: "4/1 × 5", kind: nil, logged: true, hasRoute: true,
            miles: 2.2, minutes: 30, averageHeartRate: 139),
        Run(weeksAgo: 4, day: 2, shape: "3/1 × 6", kind: .recovery, logged: true, hasRoute: true,
            miles: 2.3, minutes: 29, averageHeartRate: 136),
    ]

    struct Seeded {
        let workouts: [HealthKitManager.WorkoutSummary]
        let routes: [UUID: RouteLoad]
    }

    /// Inserts each run's timer session (and its log, when logged) into `store`, and returns the
    /// workouts and routes that stand in for Health. Nil and an error when the store refuses.
    @MainActor
    static func seed(into store: LoggerStore, now: Date) -> (Seeded?, String?) {
        guard let context = store.context else {
            return (nil, "The History fixture has no store to write to.")
        }
        let thisWeek = HistoryWeeks.start(of: now)
        var workouts: [HealthKitManager.WorkoutSummary] = []
        var routes: [UUID: RouteLoad] = [:]

        for (index, run) in runs.enumerated() {
            let day = HistoryWeeks.adding(days: run.day - 7 * run.weeksAgo, to: thisWeek)
            let start = day.addingTimeInterval(7 * 3_600)
            let duration = run.minutes * 60
            let uuid = UUID()

            let execution = PendingWorkoutExecution(plannedWorkoutID: UUID(),
                                                    plannedWorkoutName: run.shape,
                                                    expectedActivityType: .running,
                                                    expectedDurationSeconds: nil,
                                                    runIntervalSeconds: nil,
                                                    walkIntervalSeconds: nil,
                                                    plannedRepetitions: nil,
                                                    status: .matched,
                                                    createdAt: start)
            execution.matchedHealthKitWorkoutUUID = uuid
            execution.runKind = run.kind?.rawValue
            context.insert(execution)

            if run.logged {
                context.insert(RunLog(healthKitWorkoutUUID: uuid,
                                      workoutStartDate: start,
                                      workoutDistanceMiles: run.miles,
                                      workoutActivityType: PlannedActivityType.running.rawValue,
                                      executionID: execution.id,
                                      effortRPE: 4,
                                      personalHeatRating: 5))
            }

            workouts.append(HealthKitManager.WorkoutSummary(
                uuid: uuid, activityType: .running,
                startDate: start, endDate: start.addingTimeInterval(duration), duration: duration,
                distanceMiles: run.miles, averageHeartRate: run.averageHeartRate,
                peakHeartRate: nil, temperatureFahrenheit: nil, humidityPercent: nil,
                sourceName: "Invented", hasWeatherMetadata: false, isIndoor: false,
                metadataKeys: [], isReclassifiedAsRunning: false, executionID: execution.id))
            routes[uuid] = run.hasRoute ? .points(outAndBack(variant: index)) : .noRoute
        }

        if let error = store.save() { return (nil, "The History fixture could not be saved: " + error) }
        // Newest first, as Health returns them.
        return (Seeded(workouts: workouts.sorted { $0.startDate > $1.startDate }, routes: routes), nil)
    }

    /// An invented out-and-back route: out along a few street-like legs, then the same way back.
    private static func outAndBack(variant: Int) -> [CLLocationCoordinate2D] {
        let start = CLLocationCoordinate2D(latitude: 40.7794, longitude: -73.9632)
        let step = 0.0018
        var legs: [(Double, Double)] = [(1, 0), (0, 1), (1, 0), (0, 1)]
        if variant % 2 == 1 { legs = legs.map { ($0.1, $0.0) } }
        var points = [start]
        var current = start
        for (north, east) in legs.prefix(2 + variant % 3) {
            current = CLLocationCoordinate2D(latitude: current.latitude + north * step * 1.6,
                                             longitude: current.longitude + east * step)
            points.append(current)
        }
        return points + points.reversed().dropFirst()
    }
}
#endif
