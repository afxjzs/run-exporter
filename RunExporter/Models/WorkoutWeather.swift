import Foundation
import HealthKit

/// How a raw humidity number was interpreted when normalizing to 0–100.
///
/// `HKUnit.percent()` is documented as a 0.0–1.0 fraction, but real Apple Watch workouts have
/// been observed storing humidity as percentage points (73 rather than 0.73). We normalize both
/// shapes and record which one we saw, so the reshaping is auditable rather than silent.
enum HumidityInterpretation: String {
    case fraction          // 0.73 -> 73
    case percentagePoints  // 73   -> 73
}

/// Weather + environment metadata read from a single `HKWorkout.metadata` dictionary.
///
/// Every field is optional: HealthKit only records weather for some outdoor workouts, and a
/// field that is present but stored in an unexpected type is left `nil` (and reported as a
/// warning) rather than guessed at.
struct WorkoutWeather {

    var temperatureCelsius: Double?
    var temperatureFahrenheit: Double?
    var humidityPercent: Double?
    var humidityInterpretation: HumidityInterpretation?
    var conditionCode: Int?
    var conditionName: String?
    var barometricPressureHPA: Double?
    var timeZoneIdentifier: String?
    var isIndoor: Bool?

    /// True when at least one of the four *weather* fields was present and successfully parsed.
    ///
    /// Time zone and the indoor flag are environment metadata, not weather, so they deliberately
    /// do not make a workout count as "has weather" — that keeps this flag consistent with the
    /// `weather_metadata` counters in manifest.json.
    var hasAnyWeather: Bool {
        temperatureCelsius != nil
            || humidityPercent != nil
            || conditionCode != nil
            || barometricPressureHPA != nil
    }

    // MARK: - CSV projection

    static let columns = [
        "weatherTemperatureCelsius",
        "weatherTemperatureFahrenheit",
        "weatherHumidityPercent",
        "weatherConditionCode",
        "weatherConditionName",
        "barometricPressureHPA",
        "workoutTimeZone",
        "isIndoorWorkout",
        "weatherMetadataAvailable",
    ]

    var values: [String] {
        [
            Fmt.fixed(temperatureCelsius, places: 2),
            Fmt.fixed(temperatureFahrenheit, places: 2),
            Fmt.fixed(humidityPercent, places: 2),
            conditionCode.map(String.init) ?? "",
            conditionName ?? "",
            Fmt.fixed(barometricPressureHPA, places: 2),
            timeZoneIdentifier ?? "",
            Fmt.bool(isIndoor),
            hasAnyWeather ? "true" : "false",
        ]
    }

    /// Row values used when weather collection is switched off for an export. The columns stay
    /// in place so the CSV schema is stable; `manifest.json` records `weather_included: false`
    /// and export_log.json carries an entry so a reader can tell "off" from "none found".
    static let disabledValues: [String] = ["", "", "", "", "", "", "", "", "false"]
}

// MARK: - HKWeatherCondition naming

extension WorkoutWeather {

    /// Human-readable name for Apple's `HKWeatherCondition`, using the real enum only.
    ///
    /// Any raw value the running SDK does not define maps to `"unknown"` while the numeric code
    /// is still exported — no condition names are invented.
    static func conditionName(forRawValue raw: Int) -> String {
        guard let condition = HKWeatherCondition(rawValue: raw) else { return "unknown" }
        switch condition {
        case .none:               return "none"
        case .clear:              return "clear"
        case .fair:               return "fair"
        case .partlyCloudy:       return "partlyCloudy"
        case .mostlyCloudy:       return "mostlyCloudy"
        case .cloudy:             return "cloudy"
        case .foggy:              return "foggy"
        case .haze:               return "haze"
        case .windy:              return "windy"
        case .blustery:           return "blustery"
        case .smoky:              return "smoky"
        case .dust:               return "dust"
        case .snow:               return "snow"
        case .hail:               return "hail"
        case .sleet:              return "sleet"
        case .freezingDrizzle:    return "freezingDrizzle"
        case .freezingRain:       return "freezingRain"
        case .mixedRainAndHail:   return "mixedRainAndHail"
        case .mixedRainAndSnow:   return "mixedRainAndSnow"
        case .mixedRainAndSleet:  return "mixedRainAndSleet"
        case .mixedSnowAndSleet:  return "mixedSnowAndSleet"
        case .drizzle:            return "drizzle"
        case .scatteredShowers:   return "scatteredShowers"
        case .showers:            return "showers"
        case .thunderstorms:      return "thunderstorms"
        case .tropicalStorm:      return "tropicalStorm"
        case .hurricane:          return "hurricane"
        case .tornado:            return "tornado"
        @unknown default:         return "unknown"
        }
    }
}

// MARK: - Diagnostics

/// Counters backing the `weather_metadata` block in manifest.json. Incremented once per exported
/// workout row so the totals always match `workouts.csv`.
struct WeatherDiagnostics {
    var withTemperature = 0
    var withHumidity = 0
    var withCondition = 0
    var withBarometricPressure = 0
    var withAnyWeather = 0
    var withoutAnyWeather = 0

    /// How many humidity values arrived in each shape (see `HumidityInterpretation`).
    var humidityAsFraction = 0
    var humidityAsPercentagePoints = 0

    mutating func record(_ weather: WorkoutWeather) {
        if weather.temperatureCelsius != nil { withTemperature += 1 }
        if weather.humidityPercent != nil { withHumidity += 1 }
        if weather.conditionCode != nil { withCondition += 1 }
        if weather.barometricPressureHPA != nil { withBarometricPressure += 1 }
        if weather.hasAnyWeather { withAnyWeather += 1 } else { withoutAnyWeather += 1 }

        switch weather.humidityInterpretation {
        case .fraction: humidityAsFraction += 1
        case .percentagePoints: humidityAsPercentagePoints += 1
        case nil: break
        }
    }

    /// Counts a workout that was exported without any weather lookup (weather switched off).
    mutating func recordSkipped() {
        withoutAnyWeather += 1
    }

    var json: [String: Any] {
        [
            "workouts_with_temperature": withTemperature,
            "workouts_with_humidity": withHumidity,
            "workouts_with_condition": withCondition,
            "workouts_with_barometric_pressure": withBarometricPressure,
            "workouts_with_any_weather_metadata": withAnyWeather,
            "workouts_without_weather_metadata": withoutAnyWeather,
            "humidity_values_read_as_fraction": humidityAsFraction,
            "humidity_values_read_as_percentage_points": humidityAsPercentagePoints,
        ]
    }
}
