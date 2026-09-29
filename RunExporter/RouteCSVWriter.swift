import Foundation

/// Writes the per-workout `routes/route_<uuid>.csv` file: one row per GPS point.
///
/// Core Location's negative sentinel values (invalid speed, course, altitude, …) have already
/// been resolved to `nil` by `RoutePoint`, and `nil` is written as an empty field — never as a
/// number that would read as a real measurement.
enum RouteCSVWriter {

    static let columns = [
        "workoutUUID",
        "workoutStartDate",
        "timestamp",
        "latitude",
        "longitude",
        "altitudeMeters",
        "horizontalAccuracyMeters",
        "verticalAccuracyMeters",
        "speedMetersPerSecond",
        "speedAccuracyMetersPerSecond",
        "courseDegrees",
        "courseAccuracyDegrees",
        "floor",
        "sourceIndex",
    ]

    /// - Parameters:
    ///   - points: chronologically ordered, de-duplicated points.
    ///   - workoutUUID: owning workout's HealthKit UUID.
    ///   - workoutStartDate: ISO 8601 start of the owning workout.
    static func data(points: [RoutePoint], workoutUUID: String, workoutStartDate: String) -> Data {
        var csv = CSVWriter(columns: columns)

        // sourceIndex is the point's zero-based position in this final sorted, de-duplicated
        // ordering, so a row can be traced back to its place in the sequence.
        for (index, point) in points.enumerated() {
            // Explicitly typed: a bare literal of this many formatter calls is slow to infer.
            let row: [String] = [
                workoutUUID,
                workoutStartDate,
                Fmt.isoString(point.timestamp),
                Fmt.coord(point.latitude),
                Fmt.coord(point.longitude),
                Fmt.fixed(point.altitudeMeters, places: 3),
                Fmt.fixed(point.horizontalAccuracyMeters, places: 3),
                Fmt.fixed(point.verticalAccuracyMeters, places: 3),
                Fmt.fixed(point.speedMetersPerSecond, places: 4),
                Fmt.fixed(point.speedAccuracyMetersPerSecond, places: 4),
                Fmt.fixed(point.courseDegrees, places: 4),
                Fmt.fixed(point.courseAccuracyDegrees, places: 4),
                point.floor.map(String.init) ?? "",
                String(index),
            ]
            csv.addRow(row)
        }

        return csv.data
    }
}
