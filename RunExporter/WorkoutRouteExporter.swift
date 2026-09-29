import Foundation
import HealthKit
import CoreLocation

/// Reads historical `HKWorkoutRoute` data for workouts and writes the per-workout route files.
///
/// Routes come out of HealthKit only — the app never starts a `CLLocationManager`, never reads
/// the device's current position, and needs no Core Location authorization. `CoreLocation` is
/// imported purely for the `CLLocation` type HealthKit hands back.
struct WorkoutRouteExporter {

    let store: HKHealthStore

    /// Everything produced for one workout's routes.
    struct Output {
        var summary: RouteSummaryRow
        var points: [RoutePoint] = []
        var routeSampleCount = 0
        var droppedInvalidCount = 0
        var duplicateCount = 0
        var issues: [ExportLogEntry] = []
        /// Set when the failure looked like an authorization problem rather than missing data.
        var authorizationProblem: RouteAuthorizationStatus?
    }

    // MARK: - Reading

    /// Reads and combines every route sample attached to `workout`.
    ///
    /// Never throws: a workout whose routes cannot be read is reported through `Output.issues`
    /// so one bad workout cannot fail the whole export.
    func readRoutes(for workout: HKWorkout) async -> Output {

        let uuid = workout.uuid.uuidString
        var output = Output(summary: RouteSummaryRow(
            workoutUUID: uuid,
            workoutActivityType: HealthKitManager.activityTypeRawName(workout.workoutActivityType),
            startDate: Fmt.isoString(workout.startDate),
            endDate: Fmt.isoString(workout.endDate)
        ))

        // 1. Which route samples belong to this workout?
        let routes: [HKWorkoutRoute]
        do {
            routes = try await routeSamples(for: workout)
        } catch {
            output.authorizationProblem = Self.authorizationProblem(from: error)
            output.issues.append(ExportLogEntry(
                level: .warning, category: "route", workoutUUID: uuid,
                message: "Route sample query failed: \(error.localizedDescription)"))
            return output
        }

        output.routeSampleCount = routes.count
        output.summary.routeCount = routes.count
        guard !routes.isEmpty else { return output }

        // 2. Read the locations of each sample. A workout can in principle carry more than one
        //    route sample; all of them are merged into a single chronological point set, while
        //    routeCount still reports how many samples HealthKit actually held.
        var collected: [RoutePoint] = []
        var dropped = 0

        for route in routes {
            do {
                let locations = try await self.locations(for: route)
                for location in locations {
                    if let point = RoutePoint(location) {
                        collected.append(point)
                    } else {
                        dropped += 1
                    }
                }
            } catch {
                output.authorizationProblem = Self.authorizationProblem(from: error)
                output.issues.append(ExportLogEntry(
                    level: .warning, category: "route", workoutUUID: uuid,
                    message: "Failed reading locations for route \(route.uuid.uuidString): \(error.localizedDescription)"))
            }
        }

        output.droppedInvalidCount = dropped
        if dropped > 0 {
            output.issues.append(ExportLogEntry(
                level: .warning, category: "route", workoutUUID: uuid,
                message: "Discarded \(dropped) location(s) with no usable coordinate."))
        }

        // 3. Sort chronologically, then drop exact duplicates. Latitude/longitude break
        //    timestamp ties so the same workout always exports in the same order.
        let sorted = collected.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            if lhs.latitude != rhs.latitude { return lhs.latitude < rhs.latitude }
            return lhs.longitude < rhs.longitude
        }

        var seen = Set<RoutePoint.DedupeKey>()
        var unique: [RoutePoint] = []
        unique.reserveCapacity(sorted.count)
        for point in sorted where seen.insert(point.dedupeKey).inserted {
            unique.append(point)
        }
        output.duplicateCount = sorted.count - unique.count
        output.points = unique

        guard !unique.isEmpty else {
            output.issues.append(ExportLogEntry(
                level: .warning, category: "route", workoutUUID: uuid,
                message: "Route sample existed but returned zero valid locations."))
            return output
        }

        output.summary.routeAvailable = true
        output.summary.routePointCount = unique.count
        output.summary.stats = RouteMath.stats(for: unique)
        return output
    }

    /// The `HKWorkoutRoute` samples associated with a workout.
    private func routeSamples(for workout: HKWorkout) async throws -> [HKWorkoutRoute] {
        let predicate = HKQuery.predicateForObjects(from: workout)
        let samples: [HKSample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(),
                                      predicate: predicate,
                                      limit: HKObjectQueryNoLimit,
                                      sortDescriptors: nil) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
        return samples.compactMap { $0 as? HKWorkoutRoute }
    }

    /// All locations of one route sample.
    ///
    /// `HKWorkoutRouteQueryDescriptor` is the modern async replacement for the deprecated
    /// `HKWorkoutRouteQuery`; its `AsyncSequence` transparently pulls the multiple batches
    /// HealthKit delivers a long route in.
    private func locations(for route: HKWorkoutRoute) async throws -> [CLLocation] {
        var results: [CLLocation] = []
        for try await location in HKWorkoutRouteQueryDescriptor(route).results(for: store) {
            results.append(location)
        }
        return results
    }

    // MARK: - Writing

    /// Writes `routes/route_<uuid>.csv` and `routes/route_<uuid>.gpx` for one workout.
    ///
    /// Returns the relative paths actually created. A GPX failure does not prevent the CSV from
    /// being kept (and vice versa) — each is reported separately.
    func writeFiles(for output: inout Output,
                    workout: HKWorkout,
                    activityTypeName: String,
                    routesFolder: URL,
                    relativeFolder: String) -> [String] {

        guard !output.points.isEmpty else { return [] }

        let uuid = workout.uuid.uuidString
        let safeName = Self.sanitizedFileName(uuid)
        var created: [String] = []

        // --- CSV ---
        let csvName = "route_\(safeName).csv"
        do {
            let data = RouteCSVWriter.data(points: output.points,
                                           workoutUUID: uuid,
                                           workoutStartDate: Fmt.isoString(workout.startDate))
            try data.write(to: routesFolder.appendingPathComponent(csvName), options: .atomic)
            output.summary.routeCSVFile = "\(relativeFolder)/\(csvName)"
            created.append(output.summary.routeCSVFile)
        } catch {
            output.issues.append(ExportLogEntry(
                level: .error, category: "route", workoutUUID: uuid,
                message: "Failed writing route CSV: \(error.localizedDescription)"))
        }

        // --- GPX ---
        let gpxName = "route_\(safeName).gpx"
        do {
            let data = GPXWriter.data(points: output.points,
                                      trackName: Self.trackName(for: workout,
                                                                activityTypeName: activityTypeName),
                                      trackType: activityTypeName)
            try data.write(to: routesFolder.appendingPathComponent(gpxName), options: .atomic)
            output.summary.routeGPXFile = "\(relativeFolder)/\(gpxName)"
            created.append(output.summary.routeGPXFile)
        } catch {
            output.issues.append(ExportLogEntry(
                level: .error, category: "route", workoutUUID: uuid,
                message: "Failed writing route GPX: \(error.localizedDescription)"))
        }

        return created
    }

    // MARK: - Helpers

    /// e.g. "Running 2026-07-21".
    static func trackName(for workout: HKWorkout, activityTypeName: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        let capitalized = activityTypeName.prefix(1).uppercased() + activityTypeName.dropFirst()
        return "\(capitalized) \(formatter.string(from: workout.startDate))"
    }

    /// HealthKit UUID strings are already filesystem-safe; this is belt-and-braces so a file name
    /// can never escape the routes folder.
    static func sanitizedFileName(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")
        let cleaned = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return cleaned.isEmpty ? "unknown" : cleaned
    }

    /// Maps a HealthKit error to an authorization outcome, or `nil` when it was some other
    /// failure. A *read* denial normally surfaces as empty results rather than an error, so this
    /// only catches the cases HealthKit does report explicitly.
    static func authorizationProblem(from error: Error) -> RouteAuthorizationStatus? {
        let nsError = error as NSError
        guard nsError.domain == HKError.errorDomain else { return nil }
        switch nsError.code {
        case HKError.errorAuthorizationDenied.rawValue:
            return .denied
        case HKError.errorAuthorizationNotDetermined.rawValue:
            return .notDetermined
        default:
            return nil
        }
    }
}
