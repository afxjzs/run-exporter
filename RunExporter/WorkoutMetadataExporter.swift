import Foundation
import HealthKit

/// Turns an `HKWorkout` into a `WorkoutExportRow`, including the weather and environment
/// metadata Apple stores alongside outdoor workouts.
///
/// Everything here reads `HKWorkout.metadata` that is already in memory — no network request and
/// no weather service is involved. Values stored in an unexpected type are reported and left
/// blank rather than guessed at; the untouched originals are always still visible in the row's
/// `metadataJSON` column.
struct WorkoutMetadataExporter {

    /// Result of reading one workout: the row plus any non-fatal issues worth logging.
    struct Output {
        /// `var` so the caller can attach classification the exporter has no knowledge of, such
        /// as a user's "this walk was really a run" annotation.
        var row: WorkoutExportRow
        let weather: WorkoutWeather?
        let issues: [ExportLogEntry]
    }

    func makeRow(for workout: HKWorkout, includeWeather: Bool) -> Output {
        var row = baseRow(for: workout)

        guard includeWeather else {
            row.weatherValues = WorkoutWeather.disabledValues
            return Output(row: row, weather: nil, issues: [])
        }

        let (weather, issues) = Self.weather(from: workout.metadata,
                                             workoutUUID: workout.uuid.uuidString)
        row.weatherValues = weather.values
        return Output(row: row, weather: weather, issues: issues)
    }

    // MARK: - Weather metadata

    /// Extracts weather + environment values from a workout metadata dictionary.
    static func weather(from metadata: [String: Any]?,
                        workoutUUID: String) -> (WorkoutWeather, [ExportLogEntry]) {

        var weather = WorkoutWeather()
        var issues: [ExportLogEntry] = []
        guard let metadata else { return (weather, issues) }

        func warn(_ message: String) {
            issues.append(ExportLogEntry(level: .warning, category: "weather",
                                         workoutUUID: workoutUUID, message: message))
        }
        func note(_ message: String) {
            issues.append(ExportLogEntry(level: .info, category: "weather",
                                         workoutUUID: workoutUUID, message: message))
        }

        // --- Temperature -------------------------------------------------------------------
        if let raw = metadata[HKMetadataKeyWeatherTemperature] {
            if let quantity = raw as? HKQuantity {
                if quantity.is(compatibleWith: .degreeCelsius()) {
                    weather.temperatureCelsius = quantity.doubleValue(for: .degreeCelsius())
                    weather.temperatureFahrenheit = quantity.doubleValue(for: .degreeFahrenheit())
                } else {
                    warn("Weather temperature quantity was not a temperature unit (\(quantity)); left blank.")
                }
            } else {
                // A bare number carries no unit, and 20 could be °C or °F. Guessing would
                // silently corrupt the analysis, so the value is left blank instead.
                warn("Weather temperature was \(type(of: raw)), not HKQuantity, so its unit is unknown; left blank.")
            }
        }

        // --- Humidity ----------------------------------------------------------------------
        if let raw = metadata[HKMetadataKeyWeatherHumidity] {
            if let quantity = raw as? HKQuantity {
                if quantity.is(compatibleWith: .percent()) {
                    let value = quantity.doubleValue(for: .percent())
                    apply(humidity: value, to: &weather)
                } else {
                    warn("Weather humidity quantity was not a percent unit (\(quantity)); left blank.")
                }
            } else if let number = raw as? NSNumber {
                // Unit-free, but humidity has only one plausible unit, so the same
                // fraction-vs-percentage-points normalization applies.
                note("Weather humidity was NSNumber rather than HKQuantity; normalized as a percentage.")
                apply(humidity: number.doubleValue, to: &weather)
            } else {
                warn("Weather humidity was \(type(of: raw)), which is not a number; left blank.")
            }

            if let percent = weather.humidityPercent, !(0...100).contains(percent) {
                warn("Weather humidity normalized to \(percent)%, outside 0–100; exported as-is.")
            }
        }

        // --- Condition ---------------------------------------------------------------------
        if let raw = metadata[HKMetadataKeyWeatherCondition] {
            if let number = raw as? NSNumber {
                let code = number.intValue
                weather.conditionCode = code
                let name = WorkoutWeather.conditionName(forRawValue: code)
                weather.conditionName = name
                if name == "unknown" {
                    note("Weather condition code \(code) is not a known HKWeatherCondition; name exported as \"unknown\".")
                }
            } else {
                warn("Weather condition was \(type(of: raw)), not NSNumber; left blank.")
            }
        }

        // --- Barometric pressure ------------------------------------------------------------
        if let raw = metadata[HKMetadataKeyBarometricPressure] {
            if let quantity = raw as? HKQuantity {
                let hPa = HKUnit.pascalUnit(with: .hecto)
                if quantity.is(compatibleWith: hPa) {
                    weather.barometricPressureHPA = quantity.doubleValue(for: hPa)
                } else {
                    warn("Barometric pressure quantity was not a pressure unit (\(quantity)); left blank.")
                }
            } else {
                // hPa / kPa / atm / mmHg are all plausible for a bare number — not guessable.
                warn("Barometric pressure was \(type(of: raw)), not HKQuantity, so its unit is unknown; left blank.")
            }
        }

        // --- Time zone -----------------------------------------------------------------------
        if let raw = metadata[HKMetadataKeyTimeZone] {
            if let identifier = raw as? String {
                weather.timeZoneIdentifier = identifier
            } else {
                warn("Workout time zone was \(type(of: raw)), not String; left blank.")
            }
        }

        // --- Indoor flag ----------------------------------------------------------------------
        // Absent stays blank: "not recorded" is not the same claim as "outdoors".
        if let raw = metadata[HKMetadataKeyIndoorWorkout] {
            if let number = raw as? NSNumber {
                weather.isIndoor = number.boolValue
            } else {
                warn("Indoor workout flag was \(type(of: raw)), not NSNumber; left blank.")
            }
        }

        return (weather, issues)
    }

    /// Normalizes a raw humidity number to 0–100 and records which shape it arrived in.
    ///
    /// `HKUnit.percent()` is documented as a 0.0–1.0 fraction, but workouts in the wild store
    /// humidity both ways. Values at or below 1.0 are read as a fraction — real-world relative
    /// humidity never sits at 1% — and anything above as percentage points.
    private static func apply(humidity value: Double, to weather: inout WorkoutWeather) {
        guard value.isFinite else { return }
        if value <= 1.0 {
            weather.humidityPercent = value * 100.0
            weather.humidityInterpretation = .fraction
        } else {
            weather.humidityPercent = value
            weather.humidityInterpretation = .percentagePoints
        }
    }

    // MARK: - Base (v1) workout row

    private func baseRow(for workout: HKWorkout) -> WorkoutExportRow {
        let rawName = HealthKitManager.activityTypeRawName(workout.workoutActivityType)
        let distanceMeters = workout.totalDistance?.doubleValue(for: .meter())
        let distanceMiles = workout.totalDistance?.doubleValue(for: .mile())
        let energyKcal = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())

        // Nested statistics as JSON.
        var statsArray: [[String: Any]] = []
        for stat in workout.allStatistics {
            let type = stat.key
            let s = stat.value
            var entry: [String: Any] = ["type": type.identifier]
            if let sum = s.sumQuantity() { entry["sum"] = String(describing: sum) }
            if let avg = s.averageQuantity() { entry["average"] = String(describing: avg) }
            if let mn = s.minimumQuantity() { entry["minimum"] = String(describing: mn) }
            if let mx = s.maximumQuantity() { entry["maximum"] = String(describing: mx) }
            statsArray.append(entry)
        }

        let eventsArray: [[String: Any]] = (workout.workoutEvents ?? []).map { ev in
            [
                "type": ev.type.rawValue,
                "startDate": Fmt.isoString(ev.dateInterval.start),
                "endDate": Fmt.isoString(ev.dateInterval.end),
            ]
        }

        let src = workout.sourceRevision
        let device = workout.device

        return WorkoutExportRow(
            uuid: workout.uuid.uuidString,
            workoutActivityType: rawName,
            workoutActivityTypeName: HealthKitManager.activityTypeHumanName(workout.workoutActivityType),
            startDate: Fmt.isoString(workout.startDate),
            endDate: Fmt.isoString(workout.endDate),
            duration: Fmt.num(workout.duration),
            totalDistance: Fmt.num(distanceMiles),
            totalDistanceUnit: distanceMiles != nil ? "mi" : "",
            totalDistanceMeters: Fmt.num(distanceMeters),
            totalEnergyBurned: Fmt.num(energyKcal),
            totalEnergyBurnedUnit: energyKcal != nil ? "kcal" : "",
            totalEnergyKilocalories: Fmt.num(energyKcal),
            sourceName: src.source.name,
            sourceBundleIdentifier: src.source.bundleIdentifier,
            sourceVersion: src.version ?? "",
            deviceName: device?.name ?? "",
            deviceJSON: HealthKitManager.deviceJSON(device),
            metadataJSON: JSONUtil.string(from: workout.metadata),
            workoutEventsJSON: JSONUtil.string(fromArray: eventsArray),
            workoutStatisticsJSON: JSONUtil.string(fromArray: statsArray)
        )
    }
}
