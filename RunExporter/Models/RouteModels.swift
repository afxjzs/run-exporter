import Foundation
import CoreLocation

// MARK: - Route point

/// One GPS sample from an `HKWorkoutRoute`, with Core Location's negative sentinel values already
/// resolved to `nil` so an invalid reading is never mistaken for a real measurement.
struct RoutePoint {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let altitudeMeters: Double?
    let horizontalAccuracyMeters: Double?
    let verticalAccuracyMeters: Double?
    let speedMetersPerSecond: Double?
    let speedAccuracyMetersPerSecond: Double?
    let courseDegrees: Double?
    let courseAccuracyDegrees: Double?
    let floor: Int?

    /// Builds a point from a `CLLocation`, or returns `nil` when the location carries no usable
    /// coordinate (Core Location reports that as a negative `horizontalAccuracy`).
    init?(_ location: CLLocation) {
        let coordinate = location.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate),
              location.horizontalAccuracy >= 0,
              coordinate.latitude.isFinite, coordinate.longitude.isFinite else {
            return nil
        }

        timestamp = location.timestamp
        latitude = coordinate.latitude
        longitude = coordinate.longitude

        // verticalAccuracy <= 0 means the altitude is invalid.
        let verticalValid = location.verticalAccuracy > 0
        altitudeMeters = verticalValid ? location.altitude : nil
        verticalAccuracyMeters = verticalValid ? location.verticalAccuracy : nil

        horizontalAccuracyMeters = location.horizontalAccuracy
        speedMetersPerSecond = location.speed >= 0 ? location.speed : nil
        speedAccuracyMetersPerSecond = location.speedAccuracy >= 0 ? location.speedAccuracy : nil
        courseDegrees = location.course >= 0 ? location.course : nil
        courseAccuracyDegrees = location.courseAccuracy >= 0 ? location.courseAccuracy : nil
        floor = location.floor?.level
    }

    /// Identity used to drop exact duplicates: same instant, same coordinate, same altitude.
    var dedupeKey: DedupeKey {
        DedupeKey(time: timestamp.timeIntervalSinceReferenceDate,
                  latitude: latitude,
                  longitude: longitude,
                  altitude: altitudeMeters)
    }

    struct DedupeKey: Hashable {
        let time: Double
        let latitude: Double
        let longitude: Double
        let altitude: Double?
    }

    var clLocation: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Aggregated route data for one workout

/// All route samples for one workout, combined into a single chronological point set.
struct RouteAggregate {
    /// Number of `HKWorkoutRoute` samples HealthKit returned for the workout.
    var routeSampleCount = 0
    /// Chronologically sorted, de-duplicated points across every route sample.
    var points: [RoutePoint] = []
    /// Locations discarded because they carried no usable coordinate.
    var droppedInvalidCount = 0
    /// Points removed because they were exact duplicates of another point.
    var duplicateCount = 0

    var hasPoints: Bool { !points.isEmpty }
}

// MARK: - Derived route statistics

/// Geometry and quality statistics derived from a route's own location points.
struct RouteStats {
    var startLatitude: Double?
    var startLongitude: Double?
    var endLatitude: Double?
    var endLongitude: Double?
    var centroidLatitude: Double?
    var centroidLongitude: Double?
    var minAltitudeMeters: Double?
    var maxAltitudeMeters: Double?
    var elevationGainMeters: Double?
    var elevationLossMeters: Double?
    var distanceMeters: Double?
    var durationSeconds: Double?
    var averageSpeedMetersPerSecond: Double?
    var averageHorizontalAccuracyMeters: Double?
    var medianHorizontalAccuracyMeters: Double?
}

enum RouteMath {

    /// Vertical movement smaller than this between two accepted points is treated as GPS noise
    /// and contributes to neither gain nor loss. Consumer GPS altitude routinely wanders by a
    /// metre or two while standing still.
    static let elevationNoiseThresholdMeters = 1.5

    static func stats(for points: [RoutePoint]) -> RouteStats {
        var stats = RouteStats()
        guard let first = points.first, let last = points.last else { return stats }

        stats.startLatitude = first.latitude
        stats.startLongitude = first.longitude
        stats.endLatitude = last.latitude
        stats.endLongitude = last.longitude

        // Centroid: arithmetic mean of latitude and longitude. Adequate for short local routes;
        // it is not a great-circle centroid and is not meaningful across the antimeridian.
        stats.centroidLatitude = points.reduce(0.0) { $0 + $1.latitude } / Double(points.count)
        stats.centroidLongitude = points.reduce(0.0) { $0 + $1.longitude } / Double(points.count)

        // Distance walked along the recorded points, not the workout's own total-distance value.
        var distance = 0.0
        var previous: CLLocation?
        for point in points {
            let current = point.clLocation
            if let previous { distance += current.distance(from: previous) }
            previous = current
        }
        stats.distanceMeters = distance

        let duration = last.timestamp.timeIntervalSince(first.timestamp)
        stats.durationSeconds = duration
        // Average speed over the ground: route distance / elapsed route time.
        if duration > 0 { stats.averageSpeedMetersPerSecond = distance / duration }

        // Altitude: only points whose vertical accuracy was valid.
        let altitudes = points.compactMap { $0.altitudeMeters }
        stats.minAltitudeMeters = altitudes.min()
        stats.maxAltitudeMeters = altitudes.max()
        if !altitudes.isEmpty {
            let (gain, loss) = elevationGainAndLoss(altitudes)
            stats.elevationGainMeters = gain
            stats.elevationLossMeters = loss
        }

        let accuracies = points.compactMap { $0.horizontalAccuracyMeters }
        if !accuracies.isEmpty {
            stats.averageHorizontalAccuracyMeters =
                accuracies.reduce(0, +) / Double(accuracies.count)
            stats.medianHorizontalAccuracyMeters = median(accuracies)
        }

        return stats
    }

    /// Noise-filtered elevation gain/loss.
    ///
    /// Walks the altitude series holding a reference altitude. A change is only counted once it
    /// exceeds `elevationNoiseThresholdMeters`, at which point the reference moves to the new
    /// altitude. This is an estimate from consumer GPS, not surveyed elevation.
    static func elevationGainAndLoss(_ altitudes: [Double]) -> (gain: Double, loss: Double) {
        var gain = 0.0
        var loss = 0.0
        var reference: Double?

        for altitude in altitudes {
            guard let current = reference else {
                reference = altitude
                continue
            }
            let delta = altitude - current
            guard abs(delta) >= elevationNoiseThresholdMeters else { continue }
            if delta > 0 { gain += delta } else { loss += -delta }
            reference = altitude
        }
        return (gain, loss)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}

// MARK: - Route authorization status

/// Deterministic route-access outcome reported in manifest.json.
///
/// HealthKit deliberately does not disclose *read* authorization, so `authorized` here means
/// "at least one route query completed without an authorization error" — a denied read usually
/// looks identical to "this workout has no route".
enum RouteAuthorizationStatus: String {
    case authorized
    case denied
    case notDetermined
    case unavailable
    case notRequested
    case unknown
}

// MARK: - routes_summary.csv row

/// One row of `routes_summary.csv` — written for every exported workout, including those with no
/// route data, so downstream analysis can see route coverage without opening each route file.
struct RouteSummaryRow {
    var workoutUUID: String
    var workoutActivityType: String
    var startDate: String
    var endDate: String
    var routeAvailable: Bool
    var routeCount: Int
    var routePointCount: Int
    var routeCSVFile: String
    var routeGPXFile: String
    var stats: RouteStats

    init(workoutUUID: String,
         workoutActivityType: String,
         startDate: String,
         endDate: String,
         routeAvailable: Bool = false,
         routeCount: Int = 0,
         routePointCount: Int = 0,
         routeCSVFile: String = "",
         routeGPXFile: String = "",
         stats: RouteStats = RouteStats()) {
        self.workoutUUID = workoutUUID
        self.workoutActivityType = workoutActivityType
        self.startDate = startDate
        self.endDate = endDate
        self.routeAvailable = routeAvailable
        self.routeCount = routeCount
        self.routePointCount = routePointCount
        self.routeCSVFile = routeCSVFile
        self.routeGPXFile = routeGPXFile
        self.stats = stats
    }

    static let columns = [
        "workoutUUID", "workoutActivityType", "startDate", "endDate",
        "routeAvailable", "routeCount", "routePointCount",
        "routeCSVFile", "routeGPXFile",
        "startLatitude", "startLongitude",
        "endLatitude", "endLongitude",
        "centroidLatitude", "centroidLongitude",
        "minAltitudeMeters", "maxAltitudeMeters",
        "elevationGainMeters", "elevationLossMeters",
        "routeDistanceMeters", "routeDurationSeconds",
        "averageRouteSpeedMetersPerSecond",
        "averageHorizontalAccuracyMeters", "medianHorizontalAccuracyMeters",
    ]

    var values: [String] {
        [
            workoutUUID, workoutActivityType, startDate, endDate,
            routeAvailable ? "true" : "false",
            String(routeCount), String(routePointCount),
            routeCSVFile, routeGPXFile,
            Fmt.coord(stats.startLatitude), Fmt.coord(stats.startLongitude),
            Fmt.coord(stats.endLatitude), Fmt.coord(stats.endLongitude),
            Fmt.coord(stats.centroidLatitude), Fmt.coord(stats.centroidLongitude),
            Fmt.fixed(stats.minAltitudeMeters, places: 3),
            Fmt.fixed(stats.maxAltitudeMeters, places: 3),
            Fmt.fixed(stats.elevationGainMeters, places: 3),
            Fmt.fixed(stats.elevationLossMeters, places: 3),
            Fmt.fixed(stats.distanceMeters, places: 3),
            Fmt.fixed(stats.durationSeconds, places: 3),
            Fmt.fixed(stats.averageSpeedMetersPerSecond, places: 4),
            Fmt.fixed(stats.averageHorizontalAccuracyMeters, places: 3),
            Fmt.fixed(stats.medianHorizontalAccuracyMeters, places: 3),
        ]
    }

    // MARK: workouts.csv projection

    /// The route columns appended to `workouts.csv` (a re-ordered subset of the summary row).
    static let workoutColumns = [
        "routeAvailable", "routeCount", "routePointCount",
        "routeCSVFile", "routeGPXFile",
        "routeStartLatitude", "routeStartLongitude",
        "routeEndLatitude", "routeEndLongitude",
        "routeCentroidLatitude", "routeCentroidLongitude",
        "routeMinAltitudeMeters", "routeMaxAltitudeMeters",
        "routeElevationGainMeters", "routeElevationLossMeters",
        "routeDistanceFromLocationsMeters", "routeDurationSeconds",
    ]

    var workoutValues: [String] {
        [
            routeAvailable ? "true" : "false",
            String(routeCount), String(routePointCount),
            routeCSVFile, routeGPXFile,
            Fmt.coord(stats.startLatitude), Fmt.coord(stats.startLongitude),
            Fmt.coord(stats.endLatitude), Fmt.coord(stats.endLongitude),
            Fmt.coord(stats.centroidLatitude), Fmt.coord(stats.centroidLongitude),
            Fmt.fixed(stats.minAltitudeMeters, places: 3),
            Fmt.fixed(stats.maxAltitudeMeters, places: 3),
            Fmt.fixed(stats.elevationGainMeters, places: 3),
            Fmt.fixed(stats.elevationLossMeters, places: 3),
            Fmt.fixed(stats.distanceMeters, places: 3),
            Fmt.fixed(stats.durationSeconds, places: 3),
        ]
    }

    /// Route columns for a workout that was never checked (route export switched off).
    static let disabledWorkoutValues: [String] =
        ["false", "0", "0"] + Array(repeating: "", count: workoutColumns.count - 3)
}

// MARK: - Diagnostics

/// Counters backing the `route_export` block in manifest.json.
struct RouteDiagnostics {
    var authorizationRequested = false
    var authorizationStatus: RouteAuthorizationStatus = .notRequested
    var workoutsChecked = 0
    var workoutsWithRoutes = 0
    var workoutsWithoutRoutes = 0
    var routeSamplesFound = 0
    var routePointsExported = 0
    var routeCSVFilesCreated = 0
    var routeGPXFilesCreated = 0
    var pointsDroppedInvalid = 0
    var duplicatePointsRemoved = 0
    var routesWithZeroValidPoints = 0
    /// Relative paths of every route file written, in the order created.
    var files: [String] = []

    var json: [String: Any] {
        [
            "authorization_requested": authorizationRequested,
            "authorization_status": authorizationStatus.rawValue,
            "workouts_checked": workoutsChecked,
            "workouts_with_routes": workoutsWithRoutes,
            "workouts_without_routes": workoutsWithoutRoutes,
            "route_samples_found": routeSamplesFound,
            "route_points_exported": routePointsExported,
            "route_csv_files_created": routeCSVFilesCreated,
            "route_gpx_files_created": routeGPXFilesCreated,
            "route_points_dropped_invalid": pointsDroppedInvalid,
            "route_duplicate_points_removed": duplicatePointsRemoved,
            "routes_with_zero_valid_points": routesWithZeroValidPoints,
            "elevation_noise_threshold_meters": RouteMath.elevationNoiseThresholdMeters,
        ]
    }
}
