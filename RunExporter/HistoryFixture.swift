#if DEBUG
import Foundation
import CoreLocation

/// Invented runs for the History UI test (`UITesting.historyFixture`), Debug builds only.
///
/// Nothing here is real. Dates are placed relative to the current week so the groups the test
/// checks ("This week", "Last week") always exist; routes are made-up out-and-back lines around a
/// public park; heart rate and distance are generated. Each shape the test looks for is used by one
/// run only, so it finds one card.
///
/// The legs go into the store as interval rows and the samples stand in for Health, so History's
/// charts run through the real derivation (`RecordedRun`) and analysis (`AerobicAnalysis`).
enum HistoryFixture {

    struct Run {
        let weeksAgo: Int
        /// 0 is Monday.
        let day: Int
        let runMinutes: Int
        let walkMinutes: Int
        let rounds: Int
        let kind: RunKind?
        let logged: Bool
        let hasRoute: Bool
        /// False for a run the Watch recorded no heart rate for.
        let hasHeartRate: Bool
        /// Minutes the Watch went on recording after the phone's timer ended: its stop never
        /// arrived (`WatchStop`). History should read the run only inside the timer.
        var watchExtraMinutes = 0

        var shape: String { "\(runMinutes)/\(walkMinutes) × \(rounds)" }
    }

    /// Per kind: what the test needs. Recovery has three runs with legs and heart rate, so both
    /// charts draw. Speed has three, one without heart rate, so efficiency has two. Endurance has
    /// two, so neither chart has enough.
    static let runs: [Run] = [
        Run(weeksAgo: 0, day: 0, runMinutes: 1, walkMinutes: 2, rounds: 8, kind: .speed,
            logged: true, hasRoute: true, hasHeartRate: true),
        Run(weeksAgo: 1, day: 0, runMinutes: 1, walkMinutes: 2, rounds: 8, kind: .speed,
            logged: true, hasRoute: true, hasHeartRate: true),
        Run(weeksAgo: 1, day: 2, runMinutes: 3, walkMinutes: 1, rounds: 6, kind: .recovery,
            logged: true, hasRoute: true, hasHeartRate: true),
        Run(weeksAgo: 1, day: 4, runMinutes: 6, walkMinutes: 1, rounds: 4, kind: .endurance,
            logged: false, hasRoute: true, hasHeartRate: true),
        Run(weeksAgo: 2, day: 1, runMinutes: 1, walkMinutes: 2, rounds: 8, kind: .speed,
            logged: true, hasRoute: false, hasHeartRate: false),
        Run(weeksAgo: 2, day: 3, runMinutes: 2, walkMinutes: 1, rounds: 10, kind: .recovery,
            logged: true, hasRoute: true, hasHeartRate: true),
        Run(weeksAgo: 2, day: 5, runMinutes: 5, walkMinutes: 1, rounds: 4, kind: .endurance,
            logged: true, hasRoute: true, hasHeartRate: true),
        // Recorded before kinds existed: it has a timer session, so its kind can be set later.
        Run(weeksAgo: 3, day: 0, runMinutes: 4, walkMinutes: 1, rounds: 5, kind: nil,
            logged: true, hasRoute: true, hasHeartRate: true),
        Run(weeksAgo: 4, day: 2, runMinutes: 3, walkMinutes: 1, rounds: 6, kind: .recovery,
            logged: true, hasRoute: true, hasHeartRate: true),
        // The Watch never got the stop and recorded three more hours at home.
        Run(weeksAgo: 3, day: 2, runMinutes: 2, walkMinutes: 2, rounds: 5, kind: nil,
            logged: true, hasRoute: true, hasHeartRate: true, watchExtraMinutes: 180),
    ]

    struct Seeded {
        let workouts: [HealthKitManager.WorkoutSummary]
        let routes: [UUID: RouteLoad]
        let samples: [UUID: WorkoutSamples]
    }

    /// Inserts each run's timer session, legs and (when logged) log into `store`, and returns the
    /// workouts, routes and samples that stand in for Health. Nil and an error when the store
    /// refuses.
    @MainActor
    static func seed(into store: LoggerStore, now: Date) -> (Seeded?, String?) {
        guard let context = store.context else {
            return (nil, "The History fixture has no store to write to.")
        }
        let thisWeek = HistoryWeeks.start(of: now)
        var workouts: [HealthKitManager.WorkoutSummary] = []
        var routes: [UUID: RouteLoad] = [:]
        var samples: [UUID: WorkoutSamples] = [:]

        for (index, run) in runs.enumerated() {
            let day = HistoryWeeks.adding(days: run.day - 7 * run.weeksAgo, to: thisWeek)
            let start = day.addingTimeInterval(7 * 3_600)
            let uuid = UUID()

            let execution = PendingWorkoutExecution(plannedWorkoutID: UUID(),
                                                    plannedWorkoutName: run.shape,
                                                    expectedActivityType: .running,
                                                    expectedDurationSeconds: nil,
                                                    runIntervalSeconds: run.runMinutes * 60,
                                                    walkIntervalSeconds: run.walkMinutes * 60,
                                                    plannedRepetitions: run.rounds,
                                                    status: .matched,
                                                    createdAt: start)
            execution.matchedHealthKitWorkoutUUID = uuid
            execution.timerStartedAt = start
            execution.runKind = run.kind?.rawValue
            context.insert(execution)

            // Weeks further back are a little slower for the same heart rate, so the charts
            // trend upward the way a fitter runner's would.
            let fitness = Double(4 - run.weeksAgo) * 0.04
            let runSpeed = (run.kind == .speed ? 3.0 : 2.5) + fitness
            var legSamples = WorkoutSamples(heartRate: [], distance: [])
            var cursor = start
            var meters = 0.0
            for round in 1...run.rounds {
                for (phase, minutes) in [(WorkoutPhase.run, run.runMinutes), (.walk, run.walkMinutes)] {
                    let end = cursor.addingTimeInterval(Double(minutes * 60))
                    context.insert(WorkoutIntervalLog(executionID: execution.id,
                                                      healthKitWorkoutUUID: uuid,
                                                      sequenceIndex: (round - 1) * 2 + (phase == .run ? 0 : 1),
                                                      phaseType: phase,
                                                      repetitionNumber: round,
                                                      plannedDurationSeconds: minutes * 60,
                                                      actualDurationSeconds: Double(minutes * 60),
                                                      startDate: cursor,
                                                      endDate: end))
                    let speed = phase == .run ? runSpeed : 1.4
                    let (low, high): (Double, Double) = phase == .run ? (118, 152) : (150, 118)
                    var t = cursor
                    while t < end {
                        let progress = t.timeIntervalSince(cursor) / Double(minutes * 60)
                        if run.hasHeartRate {
                            legSamples.heartRate.append(WorkoutSample(start: t, end: t,
                                                                      value: low + (high - low) * progress))
                        }
                        let next = min(t.addingTimeInterval(5), end)
                        let step = speed * next.timeIntervalSince(t)
                        legSamples.distance.append(WorkoutSample(start: t, end: next, value: step))
                        meters += step
                        t = next
                    }
                    cursor = end
                }
            }
            // The phone's timer ends here, whatever the Watch does next.
            let timerEnd = cursor
            execution.timerEndedAt = timerEnd
            // After it: slow pottering about at home, with a resting heart rate.
            var watchEnd = timerEnd
            if run.watchExtraMinutes > 0 {
                watchEnd = timerEnd.addingTimeInterval(Double(run.watchExtraMinutes * 60))
                var t = timerEnd
                while t < watchEnd {
                    let next = min(t.addingTimeInterval(60), watchEnd)
                    legSamples.heartRate.append(WorkoutSample(start: t, end: t, value: 72))
                    legSamples.distance.append(WorkoutSample(start: t, end: next, value: 3))
                    meters += 3
                    t = next
                }
            }
            samples[uuid] = legSamples

            if run.logged {
                context.insert(RunLog(healthKitWorkoutUUID: uuid,
                                      workoutStartDate: start,
                                      workoutDistanceMiles: meters / AerobicAnalysis.metersPerMile,
                                      workoutActivityType: PlannedActivityType.running.rawValue,
                                      executionID: execution.id,
                                      effortRPE: 4,
                                      personalHeatRating: 5))
            }

            let duration = watchEnd.timeIntervalSince(start)
            let heartRates = legSamples.heartRate.map(\.value)
            workouts.append(HealthKitManager.WorkoutSummary(
                uuid: uuid, activityType: .running,
                startDate: start, endDate: watchEnd, duration: duration,
                distanceMiles: meters / AerobicAnalysis.metersPerMile,
                averageHeartRate: heartRates.isEmpty ? nil
                    : heartRates.reduce(0, +) / Double(heartRates.count),
                peakHeartRate: heartRates.max(), temperatureFahrenheit: nil, humidityPercent: nil,
                sourceName: "Invented", hasWeatherMetadata: false, isIndoor: false,
                metadataKeys: [], isReclassifiedAsRunning: false, executionID: execution.id))
            routes[uuid] = run.hasRoute ? .points(outAndBack(variant: index)) : .noRoute
        }

        if let error = store.save() { return (nil, "The History fixture could not be saved: " + error) }
        // Newest first, as Health returns them.
        return (Seeded(workouts: workouts.sorted { $0.startDate > $1.startDate },
                       routes: routes, samples: samples), nil)
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
