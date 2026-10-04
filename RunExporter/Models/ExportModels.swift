import Foundation

// MARK: - Export mode

enum ExportMode: String, CaseIterable, Identifiable {
    case fullDateRange = "full_date_range"
    case workoutWindowsOnly = "workout_windows_only"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fullDateRange: return "Full date range"
        case .workoutWindowsOnly: return "Workout windows only"
        }
    }

    /// Buffer applied to each workout's start/end when selecting records in workout-windows mode.
    static let workoutWindowBufferMinutes = 30
}

// MARK: - Optional data toggles

/// User-facing "Additional Data" switches.
struct ExportOptions {
    var includeWeather: Bool = true
    var includeRoutes: Bool = true
    /// Walking workouts. Off by default — see `LoggerDefaults.includeWalkingWorkouts`. When off,
    /// `workout_type_counts.json` still reports how many walks were seen and skipped.
    var includeWalking: Bool = false
    /// Walks the user marked as really being runs. Kept even when `includeWalking` is false.
    var reclassifiedAsRunning: Set<UUID> = []
}

// MARK: - Structured export log

/// One non-fatal issue encountered during an export. Written to `export_log.json`.
struct ExportLogEntry {

    enum Level: String {
        case info
        case warning
        case error
    }

    let level: Level
    let category: String        // "weather" | "route" | "records" | "summaries" | "export"
    let workoutUUID: String?
    let message: String

    init(level: Level, category: String, workoutUUID: String? = nil, message: String) {
        self.level = level
        self.category = category
        self.workoutUUID = workoutUUID
        self.message = message
    }

    var json: [String: Any] {
        var out: [String: Any] = [
            "level": level.rawValue,
            "category": category,
            "message": message,
        ]
        if let workoutUUID { out["workout_uuid"] = workoutUUID }
        return out
    }

    /// Flat rendering kept for the legacy `issues` string array in `export_log.json`.
    var text: String {
        var out = "[\(level.rawValue)] \(category): \(message)"
        if let workoutUUID { out += " (workout \(workoutUUID))" }
        return out
    }
}

// MARK: - Shared formatting helpers

enum Fmt {
    /// ISO 8601 with a timezone offset (e.g. 2026-07-10T12:34:56-07:00), in the device's current zone.
    static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return f
    }()

    static func isoString(_ date: Date?) -> String {
        guard let date else { return "" }
        return iso.string(from: date)
    }

    /// ISO 8601 in UTC with a trailing `Z`. GPX 1.1 timestamps use this form, which every GPX
    /// reader accepts.
    static let isoUTC: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f
    }()

    static func isoUTCString(_ date: Date?) -> String {
        guard let date else { return "" }
        return isoUTC.string(from: date)
    }

    /// Trims trailing zeros so 5.800000 -> "5.8" but keeps integers clean.
    static func num(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        if value == value.rounded() && abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%.6g", value)
    }

    /// Fixed-decimal rendering with trailing zeros trimmed.
    ///
    /// Unlike `num`, this is significant-digit safe: `%.6g` would round 12345.678 to "12345.7",
    /// which is fine for a display number but lossy for measurements.
    static func fixed(_ value: Double?, places: Int) -> String {
        guard let value, value.isFinite else { return "" }
        return trimTrailingZeros(String(format: "%.\(places)f", value))
    }

    /// Latitude/longitude with enough precision to be lossless in practice (~1 mm).
    ///
    /// Coordinates must never go through `num`: `%.6g` would truncate 37.774929 to "37.7749",
    /// moving the point by roughly 10 metres.
    static func coord(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return trimTrailingZeros(String(format: "%.8f", value))
    }

    /// "true" / "false", or blank when the underlying value was absent. Blank deliberately means
    /// "not recorded" rather than defaulting to false.
    static func bool(_ value: Bool?) -> String {
        guard let value else { return "" }
        return value ? "true" : "false"
    }

    private static func trimTrailingZeros(_ string: String) -> String {
        guard string.contains(".") else { return string }
        var out = string
        while out.hasSuffix("0") { out.removeLast() }
        if out.hasSuffix(".") { out.removeLast() }
        return out
    }
}

// MARK: - Safe JSON conversion for HealthKit metadata / nested structures

enum JSONUtil {
    static func string(from dict: [String: Any]?) -> String {
        guard let dict, !dict.isEmpty else { return "{}" }
        var clean: [String: Any] = [:]
        for (k, v) in dict { clean[k] = coerce(v) }
        return serialize(clean)
    }

    static func string(fromArray array: [[String: Any]]) -> String {
        let clean = array.map { dict -> [String: Any] in
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = coerce(v) }
            return out
        }
        return serialize(clean)
    }

    private static func serialize(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    /// Coerce arbitrary HealthKit metadata values into JSON-encodable primitives.
    /// String / Number / Bool pass through; Date becomes ISO 8601; anything else -> String(describing:).
    static func coerce(_ value: Any) -> Any {
        switch value {
        case let n as NSNumber:
            return n
        case let s as String:
            return s
        case let d as Date:
            return Fmt.isoString(d)
        case let arr as [Any]:
            return arr.map { coerce($0) }
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = coerce(v) }
            return out
        default:
            return String(describing: value)
        }
    }
}

// MARK: - Export row models

struct WorkoutExportRow {
    var uuid: String
    var workoutActivityType: String        // HKWorkoutActivityTypeRunning
    var workoutActivityTypeName: String    // running
    var startDate: String
    var endDate: String
    var duration: String                   // seconds
    var totalDistance: String              // miles
    var totalDistanceUnit: String
    var totalDistanceMeters: String
    var totalEnergyBurned: String          // kcal
    var totalEnergyBurnedUnit: String
    var totalEnergyKilocalories: String
    var sourceName: String
    var sourceBundleIdentifier: String
    var sourceVersion: String
    var deviceName: String
    var deviceJSON: String
    var metadataJSON: String
    var workoutEventsJSON: String
    var workoutStatisticsJSON: String

    /// Weather columns. Defaults to the "weather not collected" shape; replaced once the
    /// workout's metadata has been read.
    var weatherValues: [String] = WorkoutWeather.disabledValues

    /// Route columns. Defaults to the "routes not collected" shape; replaced once the workout's
    /// routes have been read.
    var routeValues: [String] = RouteSummaryRow.disabledWorkoutValues

    /// Subjective run-logger columns (v1.1). Defaults to all-blank, which is what an unlogged
    /// workout exports; replaced once a matching `RunLog` is found.
    var loggerValues: [String] = WorkoutLoggerJoin.blankValues

    /// True when HealthKit recorded a walk that the user marked as really a run.
    ///
    /// `workoutActivityType` above always reports what Apple stored — a user assertion never
    /// overwrites the source record. This column carries the assertion alongside it, so an
    /// analysis can honour it, ignore it, or audit it.
    var reclassifiedAsRunning = false

    static let classificationColumns = ["reclassifiedAsRunning"]

    var classificationValues: [String] { [reclassifiedAsRunning ? "true" : "false"] }

    /// The v1 columns, unchanged. New columns are appended after these so existing readers that
    /// address columns by name (or by leading position) keep working.
    static let baseColumns = [
        "uuid", "workoutActivityType", "workoutActivityTypeName",
        "startDate", "endDate", "duration",
        "totalDistance", "totalDistanceUnit", "totalDistanceMeters",
        "totalEnergyBurned", "totalEnergyBurnedUnit", "totalEnergyKilocalories",
        "sourceName", "sourceBundleIdentifier", "sourceVersion",
        "deviceName", "deviceJSON",
        "metadataJSON", "workoutEventsJSON", "workoutStatisticsJSON",
    ]

    /// What the run actually ran (`WorkoutLoggerJoin.actualColumns`), blank for an unlogged workout.
    var actualValues: [String] = WorkoutLoggerJoin.blankActualValues

    /// Groups in the order they were added. A new group goes at the END — after every group that
    /// has shipped — never inside one, or a column that has shipped moves.
    static let columns = baseColumns
        + WorkoutWeather.columns
        + RouteSummaryRow.workoutColumns
        + WorkoutLoggerJoin.columns
        + classificationColumns
        + WorkoutLoggerJoin.actualColumns

    var baseValues: [String] {
        [uuid, workoutActivityType, workoutActivityTypeName,
         startDate, endDate, duration,
         totalDistance, totalDistanceUnit, totalDistanceMeters,
         totalEnergyBurned, totalEnergyBurnedUnit, totalEnergyKilocalories,
         sourceName, sourceBundleIdentifier, sourceVersion,
         deviceName, deviceJSON,
         metadataJSON, workoutEventsJSON, workoutStatisticsJSON]
    }

    var values: [String] {
        baseValues + weatherValues + routeValues + loggerValues + classificationValues + actualValues
    }
}

struct RecordExportRow {
    var uuid: String
    var type: String            // human key e.g. heartRate
    var typeIdentifier: String  // HKQuantityTypeIdentifierHeartRate
    var startDate: String
    var endDate: String
    var value: String
    var unit: String
    var valueSI: String
    var unitSI: String
    var sourceName: String
    var sourceBundleIdentifier: String
    var sourceVersion: String
    var deviceName: String
    var deviceJSON: String
    var metadataJSON: String

    static let columns = [
        "uuid", "type", "typeIdentifier", "startDate", "endDate",
        "value", "unit", "valueSI", "unitSI",
        "sourceName", "sourceBundleIdentifier", "sourceVersion",
        "deviceName", "deviceJSON", "metadataJSON",
    ]

    var values: [String] {
        [uuid, type, typeIdentifier, startDate, endDate,
         value, unit, valueSI, unitSI,
         sourceName, sourceBundleIdentifier, sourceVersion,
         deviceName, deviceJSON, metadataJSON]
    }
}

struct ActivitySummaryExportRow {
    var dateComponents: String
    var activeEnergyBurned: String
    var activeEnergyBurnedGoal: String
    var appleExerciseTime: String
    var appleExerciseTimeGoal: String
    var appleStandHours: String
    var appleStandHoursGoal: String

    static let columns = [
        "dateComponents",
        "activeEnergyBurned", "activeEnergyBurnedGoal",
        "appleExerciseTime", "appleExerciseTimeGoal",
        "appleStandHours", "appleStandHoursGoal",
    ]

    var values: [String] {
        [dateComponents,
         activeEnergyBurned, activeEnergyBurnedGoal,
         appleExerciseTime, appleExerciseTimeGoal,
         appleStandHours, appleStandHoursGoal]
    }
}

/// One HealthKit quantity sample, as a number in the analysis's unit: beats per minute for heart
/// rate, meters for distance. A heart-rate sample is an instant (`start == end`); a distance sample
/// spans the time it was measured over.
struct WorkoutSample: Equatable {
    let start: Date
    let end: Date
    let value: Double
}

/// The samples HealthKit associates with one workout (aerobic spec, Decisions D1): the workout's
/// own recording, not every source that wrote during its window.
struct WorkoutSamples: Equatable {
    var heartRate: [WorkoutSample]
    var distance: [WorkoutSample]
}

/// Everything the export pipeline produces, handed from HealthKitManager to ExportBuilder.
struct ExportDataset {
    var workouts: [WorkoutExportRow] = []
    var records: [RecordExportRow] = []
    var activitySummaries: [ActivitySummaryExportRow] = []

    // Workout counts keyed by HK activity-type raw name (all in window, and kept)
    var allWorkoutTypeCounts: [String: Int] = [:]
    var keptWorkoutTypeCounts: [String: Int] = [:]

    // Record type bookkeeping (human keys)
    var requestedTypes: [String] = []
    var availableTypes: [String] = []
    var unavailableTypes: [String] = []
    var keptRecordCounts: [String: Int] = [:]   // available types with count > 0
    var emptyRequestedTypes: [String] = []       // available types with count == 0

    // Workout-window bookkeeping (workout-windows-only mode)
    var rawWorkoutWindowsCount: Int = 0
    var mergedWorkoutWindowsCount: Int = 0

    // Weather + route bookkeeping
    var routeSummaries: [RouteSummaryRow] = []
    var weatherDiagnostics = WeatherDiagnostics()
    var routeDiagnostics = RouteDiagnostics()

    // Run logger (v1.1): the subjective side of the export, snapshotted before the export ran.
    var logger = LoggerExportData()

    /// Each workout's own heart-rate and distance samples, by workout UUID, as numbers — what the
    /// aerobic analysis reads (aerobic spec, Decisions D1). A workout with no entry was not read.
    var workoutSamples: [String: WorkoutSamples] = [:]

    var issues: [String] = []                    // legacy flat strings for export_log.json
    var logEntries: [ExportLogEntry] = []        // structured entries for export_log.json

    /// Records a non-fatal issue in both the structured and legacy log forms.
    mutating func log(_ level: ExportLogEntry.Level,
                      _ category: String,
                      workoutUUID: String? = nil,
                      _ message: String) {
        append(ExportLogEntry(level: level, category: category,
                              workoutUUID: workoutUUID, message: message))
    }

    /// Records an already-built entry in both log forms.
    mutating func append(_ entry: ExportLogEntry) {
        logEntries.append(entry)
        issues.append(entry.text)
    }
}
