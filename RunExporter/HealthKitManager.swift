import Foundation
import HealthKit

/// Describes one quantity type we want to export, including display + SI unit handling.
struct QuantitySpec {
    let key: String              // human key, e.g. "heartRate"
    let identifier: String       // raw HKQuantityTypeIdentifier string
    let unit: HKUnit
    let unitName: String
    let siUnit: HKUnit?          // optional second (SI) unit
    let siUnitName: String?
    /// Multiply the display value after conversion (used for percent -> %).
    let displayScale: Double

    init(_ key: String, _ identifier: String, _ unit: HKUnit, _ unitName: String,
         si: HKUnit? = nil, siName: String? = nil, scale: Double = 1.0) {
        self.key = key
        self.identifier = identifier
        self.unit = unit
        self.unitName = unitName
        self.siUnit = si
        self.siUnitName = siName
        self.displayScale = scale
    }
}

enum HealthKitError: Error, LocalizedError {
    case notAvailable
    /// A quantity came back in a unit that cannot be converted to the one asked for. Converting
    /// anyway would trap; guessing would put a wrong number in the export.
    case incompatibleUnit(type: String, unit: String)
    var errorDescription: String? {
        switch self {
        case .notAvailable: return "HealthKit is not available on this device."
        case .incompatibleUnit(let type, let unit):
            return "A \(type) sample could not be read in \(unit)."
        }
    }
}

final class HealthKitManager {

    let store = HKHealthStore()

    // Common HKUnit shorthands
    private static let bpm = HKUnit.count().unitDivided(by: .minute())
    private static let ms = HKUnit.secondUnit(with: .milli)
    private static let mph = HKUnit.mile().unitDivided(by: .hour())
    private static let mps = HKUnit.meter().unitDivided(by: .second())

    /// The full list of quantity types we attempt to export, in a stable order.
    /// Resolved against the running SDK at runtime; unavailable ones are reported gracefully.
    static let quantitySpecs: [QuantitySpec] = [
        // Heart / recovery
        QuantitySpec("heartRate", "HKQuantityTypeIdentifierHeartRate", bpm, "count/min"),
        QuantitySpec("restingHeartRate", "HKQuantityTypeIdentifierRestingHeartRate", bpm, "count/min"),
        QuantitySpec("heartRateVariabilitySDNN", "HKQuantityTypeIdentifierHeartRateVariabilitySDNN", ms, "ms"),
        QuantitySpec("walkingHeartRateAverage", "HKQuantityTypeIdentifierWalkingHeartRateAverage", bpm, "count/min"),
        QuantitySpec("vo2Max", "HKQuantityTypeIdentifierVO2Max", HKUnit(from: "ml/kg*min"), "mL/kg*min"),

        // Distance / steps / energy
        QuantitySpec("distanceWalkingRunning", "HKQuantityTypeIdentifierDistanceWalkingRunning",
                     HKUnit.mile(), "mi", si: HKUnit.meter(), siName: "m"),
        QuantitySpec("stepCount", "HKQuantityTypeIdentifierStepCount", HKUnit.count(), "count"),
        QuantitySpec("activeEnergyBurned", "HKQuantityTypeIdentifierActiveEnergyBurned", HKUnit.kilocalorie(), "kcal"),
        QuantitySpec("basalEnergyBurned", "HKQuantityTypeIdentifierBasalEnergyBurned", HKUnit.kilocalorie(), "kcal"),

        // Running dynamics
        QuantitySpec("runningSpeed", "HKQuantityTypeIdentifierRunningSpeed", mph, "mi/hr", si: mps, siName: "m/s"),
        QuantitySpec("runningPower", "HKQuantityTypeIdentifierRunningPower", HKUnit.watt(), "W"),
        QuantitySpec("runningStrideLength", "HKQuantityTypeIdentifierRunningStrideLength", HKUnit.meter(), "m"),
        QuantitySpec("runningGroundContactTime", "HKQuantityTypeIdentifierRunningGroundContactTime", ms, "ms"),
        QuantitySpec("runningVerticalOscillation", "HKQuantityTypeIdentifierRunningVerticalOscillation",
                     HKUnit.meterUnit(with: .centi), "cm"),
        // May be unavailable at runtime; handled gracefully.
        QuantitySpec("runningCadence", "HKQuantityTypeIdentifierRunningCadence", bpm, "count/min"),

        // Walking metrics
        QuantitySpec("walkingSpeed", "HKQuantityTypeIdentifierWalkingSpeed", mph, "mi/hr", si: mps, siName: "m/s"),
        QuantitySpec("walkingStepLength", "HKQuantityTypeIdentifierWalkingStepLength", HKUnit.meter(), "m"),
        QuantitySpec("walkingDoubleSupportPercentage", "HKQuantityTypeIdentifierWalkingDoubleSupportPercentage",
                     HKUnit.percent(), "%", scale: 100.0),
        QuantitySpec("sixMinuteWalkTestDistance", "HKQuantityTypeIdentifierSixMinuteWalkTestDistance", HKUnit.meter(), "m"),
    ]

    /// Which specs actually resolve to a real quantity type on this device/SDK.
    struct ResolvedSpecs {
        var available: [(spec: QuantitySpec, type: HKQuantityType)] = []
        var unavailable: [QuantitySpec] = []
    }

    func resolveSpecs() -> ResolvedSpecs {
        var result = ResolvedSpecs()
        for spec in Self.quantitySpecs {
            let id = HKQuantityTypeIdentifier(rawValue: spec.identifier)
            if let type = HKObjectType.quantityType(forIdentifier: id) {
                result.available.append((spec, type))
            } else {
                result.unavailable.append(spec)
            }
        }
        return result
    }

    // MARK: - Authorization

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Bumped whenever the set of requested read types changes.
    ///
    /// A user who granted access under an older version has already dismissed the permission
    /// sheet, so without this the newly-added workout-route type would never be requested and
    /// routes would silently come back empty. `ExportViewModel` re-requests when the stored
    /// version is behind.
    static let authorizationSchemaVersion = 2

    /// Read-only: the export and logger never write. (The watch link asks separately for workout
    /// share access so the phone can start the Watch's workout — see `WatchLink`.)
    func readTypes() -> Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType(),
                                        HKObjectType.activitySummaryType()]
        // Historical workout routes. Reading these needs no Core Location authorization.
        types.insert(HKSeriesType.workoutRoute())
        for (_, type) in resolveSpecs().available {
            types.insert(type)
        }
        return types
    }

    func requestAuthorization() async throws {
        guard isAvailable else { throw HealthKitError.notAvailable }
        try await store.requestAuthorization(toShare: [], read: readTypes())
    }

    // MARK: - Generic async sample query

    private func fetchSamples(type: HKSampleType, start: Date, end: Date) async throws -> [HKSample] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type,
                                      predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: sort) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
    }

    // MARK: - Workouts

    /// Returns (kept workouts, all-type counts, kept-type counts, kept workout time intervals).
    ///
    /// The `HKWorkout` objects themselves are returned rather than finished rows so the caller
    /// can also read each workout's weather metadata and query its routes. Row construction
    /// lives in `WorkoutMetadataExporter`.
    /// - Parameter includeWalking: when false, only running workouts are kept. Walking is excluded
    ///   by default because a walkable neighbourhood produces many walks that are not training.
    ///   `allCounts` still reports every type seen, so the export always shows what was filtered.
    func fetchWorkouts(start: Date, end: Date, includeWalking: Bool,
                       reclassifiedAsRunning: Set<UUID> = []) async throws
        -> (workouts: [HKWorkout], allCounts: [String: Int], keptCounts: [String: Int],
            keptIntervals: [DateInterval]) {

        let samples = try await fetchSamples(type: HKObjectType.workoutType(), start: start, end: end)
        let workouts = samples.compactMap { $0 as? HKWorkout }

        var allCounts: [String: Int] = [:]
        var keptCounts: [String: Int] = [:]
        var kept: [HKWorkout] = []
        var intervals: [DateInterval] = []

        for w in workouts {
            let rawName = Self.activityTypeRawName(w.workoutActivityType)
            allCounts[rawName, default: 0] += 1

            guard Self.keeps(w.workoutActivityType, uuid: w.uuid,
                             includeWalking: includeWalking,
                             reclassifiedAsRunning: reclassifiedAsRunning) else { continue }
            keptCounts[rawName, default: 0] += 1

            kept.append(w)
            // Guard against any zero/negative-length workouts.
            if w.endDate >= w.startDate {
                intervals.append(DateInterval(start: w.startDate, end: w.endDate))
            }
        }

        return (kept, allCounts, keptCounts, intervals)
    }

    // MARK: - Recent workouts (run logger)

    /// A finished workout, reduced to what the logger UI and the matcher need.
    ///
    /// A plain value rather than an `HKWorkout` so it can be held by SwiftUI state and compared in
    /// tests without HealthKit.
    struct WorkoutSummary: Identifiable, Equatable {
        let uuid: UUID
        let activityType: PlannedActivityType
        let startDate: Date
        let endDate: Date
        let duration: TimeInterval
        let distanceMiles: Double?
        let averageHeartRate: Double?
        let peakHeartRate: Double?
        let temperatureFahrenheit: Double?
        let humidityPercent: Double?
        let sourceName: String

        /// True when Apple actually stored weather with this workout.
        ///
        /// Distinguishes "no weather recorded" from "weather recorded but unreadable" — a blank
        /// temperature otherwise looks identical in both cases, and only one of them is a bug.
        let hasWeatherMetadata: Bool
        /// `HKMetadataKeyIndoorWorkout`, when present. Indoor workouts legitimately carry no
        /// weather, which is the most common innocent explanation for a blank reading.
        let isIndoor: Bool?
        /// Metadata keys HealthKit stored, for diagnosing an unexpected blank. Empty means the
        /// workout carries no metadata at all, which is itself informative.
        let metadataKeys: [String]
        /// True when HealthKit recorded this as a walk and the user marked it as really a run.
        /// `activityType` above reports what the *user* asserted; `recordedActivityType` keeps
        /// what Apple stored.
        let isReclassifiedAsRunning: Bool
        /// The phone execution this workout was recorded for, when our watch app saved it (watch
        /// plan step 3). Read from `WorkoutMetadataKeys.executionID`; nil for any other workout.
        let executionID: UUID?

        var id: UUID { uuid }

        /// What HealthKit actually recorded, before any local reclassification.
        var recordedActivityType: PlannedActivityType {
            isReclassifiedAsRunning ? .walking : activityType
        }

        var paceSecondsPerMile: Double? {
            guard let distanceMiles, distanceMiles > 0.01 else { return nil }
            return duration / distanceMiles
        }
    }

    /// Workouts that finished within the last `hours`, newest first.
    ///
    /// Uses the same activity-type rule as the export, so the logger never offers a workout the
    /// export would not contain — and never hides one it would.
    func fetchRecentWorkouts(hours: Int, includeWalking: Bool,
                             reclassifiedAsRunning: Set<UUID> = [],
                             now: Date = Date()) async throws -> [WorkoutSummary] {
        let start = now.addingTimeInterval(-Double(hours) * 3600)
        // A workout in progress can have an end date in the future relative to `now`.
        let end = now.addingTimeInterval(3600)
        let result = try await fetchWorkouts(start: start, end: end,
                                             includeWalking: includeWalking,
                                             reclassifiedAsRunning: reclassifiedAsRunning)
        return result.workouts
            .compactMap { Self.summary(for: $0, reclassifiedAsRunning: reclassifiedAsRunning) }
            .sorted { $0.startDate > $1.startDate }
    }

    /// Every walking workout in the window, regardless of the walking filter.
    ///
    /// Used by History's "Walks" browser so a run that the Watch mislabelled as a walk can still
    /// be found and reclassified — otherwise excluding walks would also hide the one workout the
    /// user most needs to reach.
    func fetchWalkingWorkouts(hours: Int, reclassifiedAsRunning: Set<UUID> = [],
                              now: Date = Date()) async throws -> [WorkoutSummary] {
        let start = now.addingTimeInterval(-Double(hours) * 3600)
        let end = now.addingTimeInterval(3600)
        let result = try await fetchWorkouts(start: start, end: end, includeWalking: true)
        return result.workouts
            .filter { $0.workoutActivityType == .walking }
            .compactMap { Self.summary(for: $0, reclassifiedAsRunning: reclassifiedAsRunning) }
            .sorted { $0.startDate > $1.startDate }
    }

    /// The single rule for which workouts this app handles.
    ///
    /// One place so the export, the logger queue and History can never disagree about what exists.
    ///
    /// - Parameter reclassifiedAsRunning: workouts the user has marked as really being runs. A
    ///   walk in this set is kept even when walking is otherwise excluded — that is the whole
    ///   point of the annotation.
    static func keeps(_ type: HKWorkoutActivityType,
                      uuid: UUID? = nil,
                      includeWalking: Bool,
                      reclassifiedAsRunning: Set<UUID> = []) -> Bool {
        switch type {
        case .running:
            return true
        case .walking:
            if let uuid, reclassifiedAsRunning.contains(uuid) { return true }
            return includeWalking
        default:
            return false
        }
    }

    /// Human names of the activity types kept, for the manifest and `workout_type_counts.json`.
    static func keptTypeNames(includeWalking: Bool) -> [String] {
        includeWalking ? ["running", "walking"] : ["running"]
    }

    /// One workout by its HealthKit UUID, or nil when it no longer exists (it may have been
    /// deleted in the Health app after being logged).
    func fetchWorkout(uuid: UUID) async throws -> WorkoutSummary? {
        let predicate = HKQuery.predicateForObject(with: uuid)
        let samples: [HKSample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKObjectType.workoutType(),
                                      predicate: predicate,
                                      limit: 1,
                                      sortDescriptors: nil) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
        guard let workout = samples.compactMap({ $0 as? HKWorkout }).first else { return nil }
        return Self.summary(for: workout)
    }

    /// Reduces an `HKWorkout` to a `WorkoutSummary`, or nil for an activity type the app does not
    /// handle.
    static func summary(for workout: HKWorkout,
                        reclassifiedAsRunning: Set<UUID> = []) -> WorkoutSummary? {
        let reclassified: Bool
        let activity: PlannedActivityType
        switch workout.workoutActivityType {
        case .running:
            activity = .running
            reclassified = false
        case .walking:
            // A reclassified walk is presented as a run everywhere in the UI; the original type
            // is still recoverable via `recordedActivityType` and is what the export writes.
            reclassified = reclassifiedAsRunning.contains(workout.uuid)
            activity = reclassified ? .running : .walking
        default:
            return nil
        }

        let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate)
        let heartRateStats = heartRateType.flatMap { workout.statistics(for: $0) }
        let bpm = HKUnit.count().unitDivided(by: .minute())

        let (weather, _) = WorkoutMetadataExporter.weather(from: workout.metadata,
                                                           workoutUUID: workout.uuid.uuidString)

        return WorkoutSummary(
            uuid: workout.uuid,
            activityType: activity,
            startDate: workout.startDate,
            endDate: workout.endDate,
            duration: workout.duration,
            distanceMiles: workout.totalDistance?.doubleValue(for: .mile()),
            averageHeartRate: heartRateStats?.averageQuantity()?.doubleValue(for: bpm),
            peakHeartRate: heartRateStats?.maximumQuantity()?.doubleValue(for: bpm),
            temperatureFahrenheit: weather.temperatureFahrenheit,
            humidityPercent: weather.humidityPercent,
            sourceName: workout.sourceRevision.source.name,
            hasWeatherMetadata: weather.hasAnyWeather,
            isIndoor: weather.isIndoor,
            metadataKeys: (workout.metadata ?? [:]).keys.sorted(),
            isReclassifiedAsRunning: reclassified,
            executionID: (workout.metadata?[WorkoutMetadataKeys.executionID] as? String).flatMap(UUID.init(uuidString:)))
    }

    // MARK: - Quantity records

    /// - Parameter windows: when non-nil, only samples whose start date falls inside one of the
    ///   (already merged) windows are kept. A single date-range query returns each sample once, so
    ///   filtering the result guarantees no duplicates even when workout windows overlap.
    func fetchRecords(spec: QuantitySpec, type: HKQuantityType, start: Date, end: Date,
                      windows: [DateInterval]? = nil) async throws
        -> [RecordExportRow] {

        let samples = try await fetchSamples(type: type, start: start, end: end)
        var rows: [RecordExportRow] = []
        rows.reserveCapacity(samples.count)

        for case let q as HKQuantitySample in samples {
            if let windows, !Self.date(q.startDate, isInAnyOf: windows) { continue }
            let quantity = q.quantity

            var value = ""
            var unitName = spec.unitName
            if quantity.is(compatibleWith: spec.unit) {
                value = Fmt.num(quantity.doubleValue(for: spec.unit) * spec.displayScale)
            } else {
                // Best-effort fallback; record an issue upstream via empty value.
                unitName = spec.unitName + "?"
            }

            var valueSI = ""
            var unitSIName = ""
            if let si = spec.siUnit, let siName = spec.siUnitName, quantity.is(compatibleWith: si) {
                valueSI = Fmt.num(quantity.doubleValue(for: si))
                unitSIName = siName
            }

            let src = q.sourceRevision
            rows.append(RecordExportRow(
                uuid: q.uuid.uuidString,
                type: spec.key,
                typeIdentifier: spec.identifier,
                startDate: Fmt.isoString(q.startDate),
                endDate: Fmt.isoString(q.endDate),
                value: value,
                unit: unitName,
                valueSI: valueSI,
                unitSI: unitSIName,
                sourceName: src.source.name,
                sourceBundleIdentifier: src.source.bundleIdentifier,
                sourceVersion: src.version ?? "",
                deviceName: q.device?.name ?? "",
                deviceJSON: Self.deviceJSON(q.device),
                metadataJSON: JSONUtil.string(from: q.metadata)
            ))
        }
        return rows
    }

    // MARK: - One workout's own samples (aerobic spec, Decisions D1)

    /// The heart-rate and distance samples HealthKit associates with `workout`: its own recording,
    /// not every source that wrote during its window. Measured on a real export, the iPhone writes
    /// a second, partial distance series inside most runs (LEARNINGS.md), which a time-window query
    /// would add to the Watch's.
    ///
    /// **Not yet verified on the device:** that this returns exactly the Watch's samples for this
    /// app's workouts and for older ones.
    func fetchWorkoutSamples(for workout: HKWorkout) async throws -> WorkoutSamples {
        let predicate = HKQuery.predicateForObjects(from: workout)
        let heartRate = try await associatedQuantities(.heartRate, predicate: predicate,
                                                       unit: HKUnit.count().unitDivided(by: .minute()))
        let distance = try await associatedQuantities(.distanceWalkingRunning, predicate: predicate,
                                                      unit: .meter())
        return WorkoutSamples(heartRate: heartRate, distance: distance)
    }

    private func associatedQuantities(_ identifier: HKQuantityTypeIdentifier,
                                      predicate: NSPredicate,
                                      unit: HKUnit) async throws -> [WorkoutSample] {
        let type = HKQuantityType(identifier)
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
        let samples: [HKSample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: sort) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
        return try samples.compactMap { $0 as? HKQuantitySample }.map { sample in
            guard sample.quantity.is(compatibleWith: unit) else {
                throw HealthKitError.incompatibleUnit(type: identifier.rawValue, unit: unit.unitString)
            }
            return WorkoutSample(start: sample.startDate, end: sample.endDate,
                                 value: sample.quantity.doubleValue(for: unit))
        }
    }

    // MARK: - Activity summaries

    func fetchActivitySummaries(start: Date, end: Date) async throws -> [ActivitySummaryExportRow] {
        let calendar = Calendar.current
        var startComps = calendar.dateComponents([.year, .month, .day], from: start)
        startComps.calendar = calendar
        var endComps = calendar.dateComponents([.year, .month, .day], from: end)
        endComps.calendar = calendar

        let predicate = HKQuery.predicate(forActivitySummariesBetweenStart: startComps, end: endComps)

        let summaries: [HKActivitySummary] = try await withCheckedThrowingContinuation { continuation in
            let query = HKActivitySummaryQuery(predicate: predicate) { _, results, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: results ?? [])
                }
            }
            store.execute(query)
        }

        return summaries.map { s in
            let comps = s.dateComponents(for: calendar)
            let dateStr: String
            if let y = comps.year, let m = comps.month, let d = comps.day {
                dateStr = String(format: "%04d-%02d-%02d", y, m, d)
            } else {
                dateStr = ""
            }
            let kcal = HKUnit.kilocalorie()
            let minute = HKUnit.minute()
            let count = HKUnit.count()
            return ActivitySummaryExportRow(
                dateComponents: dateStr,
                activeEnergyBurned: Fmt.num(s.activeEnergyBurned.doubleValue(for: kcal)),
                activeEnergyBurnedGoal: Fmt.num(s.activeEnergyBurnedGoal.doubleValue(for: kcal)),
                appleExerciseTime: Fmt.num(s.appleExerciseTime.doubleValue(for: minute)),
                appleExerciseTimeGoal: Fmt.num(s.appleExerciseTimeGoal.doubleValue(for: minute)),
                appleStandHours: Fmt.num(s.appleStandHours.doubleValue(for: count)),
                appleStandHoursGoal: Fmt.num(s.appleStandHoursGoal.doubleValue(for: count))
            )
        }
    }

    // MARK: - Workout window helpers

    /// Buffer each interval by `buffer` seconds on both ends, then merge overlapping/adjacent
    /// intervals into a minimal sorted set.
    static func mergedWindows(from intervals: [DateInterval], buffer: TimeInterval) -> [DateInterval] {
        guard !intervals.isEmpty else { return [] }
        let buffered = intervals
            .map { DateInterval(start: $0.start.addingTimeInterval(-buffer),
                                end: $0.end.addingTimeInterval(buffer)) }
            .sorted { $0.start < $1.start }

        var merged: [DateInterval] = [buffered[0]]
        for interval in buffered.dropFirst() {
            let last = merged[merged.count - 1]
            if interval.start <= last.end {
                if interval.end > last.end {
                    merged[merged.count - 1] = DateInterval(start: last.start, end: interval.end)
                }
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    static func date(_ date: Date, isInAnyOf windows: [DateInterval]) -> Bool {
        for w in windows {
            if date < w.start { return false } // windows are sorted by start
            if date <= w.end { return true }
        }
        return false
    }

    // MARK: - Naming + device helpers

    static func deviceJSON(_ device: HKDevice?) -> String {
        guard let device else { return "{}" }
        var d: [String: Any] = [:]
        if let v = device.name { d["name"] = v }
        if let v = device.manufacturer { d["manufacturer"] = v }
        if let v = device.model { d["model"] = v }
        if let v = device.hardwareVersion { d["hardwareVersion"] = v }
        if let v = device.softwareVersion { d["softwareVersion"] = v }
        if let v = device.firmwareVersion { d["firmwareVersion"] = v }
        if let v = device.localIdentifier { d["localIdentifier"] = v }
        if let v = device.udiDeviceIdentifier { d["udiDeviceIdentifier"] = v }
        return JSONUtil.string(from: d)
    }

    static func activityTypeHumanName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "running"
        case .walking: return "walking"
        default: return "other(\(type.rawValue))"
        }
    }

    /// Map to the HKWorkoutActivityType* raw string used by Apple's XML export.
    static func activityTypeRawName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "HKWorkoutActivityTypeRunning"
        case .walking: return "HKWorkoutActivityTypeWalking"
        default: return "HKWorkoutActivityType(\(type.rawValue))"
        }
    }
}
