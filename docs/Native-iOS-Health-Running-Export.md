# Spec: Native iOS Health Running Exporter

> **Historical — this is the v1.0 spec, and v1.0 shipped.** Everything below describes what was
> being asked for before the app existed. It is **not** a statement about how the app behaves now,
> and it is not a to-do list: several things here were built differently on purpose, and the
> reasoning for those lives in [../README.md](../README.md) under Known limitations.
>
> Kept because it records *why* v1.0 was scoped the way it was, which nothing else does. The live
> requirements document is [../RUNNING_APP_V1_1_SPEC.md](../RUNNING_APP_V1_1_SPEC.md) — that is the
> one `spec §…` in the source refers to, never this file.
>
> Moved here from the repository root on 2026-09-25, so that 836 lines of superseded requirements
> stop reading as current ones.

1. Product summary

Build a native iOS app that exports a focused Apple Health running dataset from the user’s phone without requiring a full Apple Health XML export.

The app should:

1. Open to a simple export screen.
2. Show a date range.
3. Default the start date to June 18, 2026.
4. Default the end date to today / now.
5. Let the user tap Export.
6. Query HealthKit for running-relevant workouts and samples.
7. Generate a small export folder containing CSV and JSON files equivalent to the existing Python script output.
8. ZIP the folder.
9. Open the native iOS share sheet so the user can send the ZIP to ChatGPT, AirDrop, Files, email, etc.
10. Delete the temporary ZIP and export folder after sharing completes or is cancelled.

This is a personal utility app. Prioritize correctness, transparency, and debuggability over polish.

2. Target platform

* iOS app
* Swift
* SwiftUI
* HealthKit
* Minimum target: iOS 17.0, unless there is a strong reason to support older
* No server
* No account system
* No analytics
* No external networking
* Local-only export

3. Primary user flow

3.1 First launch

1. User opens app.
2. App shows:
    * Title: Running Health Export
    * Date range controls:
        * Start Date: defaults to June 18, 2026
        * End Date: defaults to Now
    * Export button
    * Health permission status
3. If HealthKit permission has not been requested, show:
    * Grant Health Access
4. User taps Grant Health Access.
5. App requests read permission for all needed HealthKit types.
6. After permission, user returns to main screen.

3.2 Normal export

1. User opens app.
2. App shows date range:
    * Start: June 18, 2026
    * End: Now
3. User taps Export.
4. App shows progress:
    * Reading workouts...
    * Reading heart rate...
    * Reading running metrics...
    * Writing CSV files...
    * Creating ZIP...
5. When ZIP is ready, app presents native iOS share sheet.
6. User shares ZIP.
7. After share sheet completes or is dismissed, app deletes temp files.
8. App returns to main screen with a small status message:
    * Export complete. Temporary files deleted.

3.3 User changes date range

The user can manually adjust:

* Start date
* End date

The start date should persist after edits. End date should always default to now when the app opens unless the user changes it for the current session.

4. HealthKit permissions

Request read access only. Do not request write access.

4.1 Workout types

Read:

* HKObjectType.workoutType()

Include workouts where:

* workoutActivityType == .running
* workoutActivityType == .walking

Reason: some run/walk sessions may be accidentally labeled as Outdoor Walk.

4.2 Quantity types to request

Request read access for these quantity types when available on the current iOS version:

Heart and recovery

* heartRate
* restingHeartRate
* heartRateVariabilitySDNN
* walkingHeartRateAverage
* vo2Max

Distance, steps, energy

* distanceWalkingRunning
* stepCount
* activeEnergyBurned
* basalEnergyBurned

Running dynamics

* runningSpeed
* runningPower
* runningStrideLength
* runningGroundContactTime
* runningVerticalOscillation

Running cadence

HealthKit may expose cadence differently depending on SDK availability. The app should attempt to include:

* runningCadence, if available in the installed SDK

If runningCadence is not available at compile time, do not block the build. Continue with stepCount and other running metrics.

Walking metrics

Useful when run/walk workouts are mislabeled as walks:

* walkingSpeed
* walkingStepLength
* walkingDoubleSupportPercentage
* sixMinuteWalkTestDistance

4.3 Graceful handling of unavailable types

Some HealthKit identifiers may not exist on all iOS versions or may not have data for the user.

The app should:

* Build even if a newer identifier is unavailable.
* Skip unavailable identifiers.
* Include unavailable identifiers in manifest.json under unavailable_types.
* Include requested-but-empty identifiers in records_by_type.json with count 0.

5. Export window

5.1 Default date logic

Use:

* Program start: 2026-06-18 00:00:00 America/Los_Angeles
* Start extraction window: program start minus 1 day
* End extraction window: now plus 1 day

The 1-day buffer is intentional. It mirrors the Python script and helps avoid timezone/export boundary issues.

5.2 User-facing display

Display the default range as:

* Start: Jun 18, 2026
* End: Now

Internally query:

* 2026-06-17 00:00:00 America/Los_Angeles
* Date.now + 1 day

5.3 Timezone

Use the device’s current timezone for display and date pickers.

For export files:

* Preserve HealthKit sample timestamps as ISO 8601 strings with timezone offsets.
* Include timezone metadata in manifest.json.

6. Data to export

The app should generate a ZIP with this structure:

running_health_extract_2026-06-18_to_now/
  manifest.json
  workouts.csv
  records.csv
  activity_summaries.csv
  workout_type_counts.json
  records_by_type.json

Optional but useful:

  export_log.json
  README.txt

7. File formats

7.1 workouts.csv

One row per included workout.

Include at minimum:

uuid
workoutActivityType
startDate
endDate
duration
totalDistance
totalDistanceUnit
totalEnergyBurned
totalEnergyBurnedUnit
sourceName
sourceBundleIdentifier
deviceName
metadataJSON
workoutEventsJSON
workoutStatisticsJSON

Notes:

* duration should be seconds.
* totalDistance should be exported in miles if available, but include unit explicitly.
* Also include raw SI values where useful:
    * totalDistanceMeters
    * totalEnergyKilocalories
* metadataJSON, workoutEventsJSON, and workoutStatisticsJSON can be JSON strings inside the CSV cells.

7.2 records.csv

One row per HealthKit quantity sample.

Include:

uuid
type
startDate
endDate
value
unit
sourceName
sourceBundleIdentifier
deviceName
metadataJSON

Use sensible units:

heartRate: count/min
restingHeartRate: count/min
heartRateVariabilitySDNN: ms
walkingHeartRateAverage: count/min
vo2Max: mL/kg*min
distanceWalkingRunning: mi and meters
stepCount: count
activeEnergyBurned: kcal
basalEnergyBurned: kcal
runningSpeed: mi/hr and m/s
runningPower: W
runningStrideLength: m
runningGroundContactTime: ms
runningVerticalOscillation: cm
runningCadence: count/min if available
walkingSpeed: mi/hr and m/s
walkingStepLength: m
walkingDoubleSupportPercentage: %
sixMinuteWalkTestDistance: m

For types where both raw and human-readable units are useful, include both:

value
unit
valueSI
unitSI

Example:

runningSpeed,value=5.8,unit=mi/hr,valueSI=2.59,unitSI=m/s

7.3 activity_summaries.csv

One row per activity summary day in the export window.

Include:

dateComponents
activeEnergyBurned
activeEnergyBurnedGoal
appleExerciseTime
appleExerciseTimeGoal
appleStandHours
appleStandHoursGoal

If some fields are unavailable, leave blank.

7.4 workout_type_counts.json

Include:

{
  "all_workout_types_in_window": {
    "running": 12,
    "walking": 3
  },
  "kept_workout_types": {
    "running": 12,
    "walking": 3
  },
  "workout_types_to_keep": [
    "running",
    "walking"
  ]
}

Also include all workout types encountered in the date range, not just kept types, if practical. This helps identify accidental labels.

7.5 records_by_type.json

Include:

{
  "requested_types": [],
  "available_types": [],
  "unavailable_types": [],
  "kept_record_types": {
    "heartRate": 1290,
    "distanceWalkingRunning": 433,
    "stepCount": 1012
  },
  "empty_requested_types": []
}

7.6 manifest.json

Include:

{
  "app_name": "Running Health Export",
  "app_version": "0.1.0",
  "export_created_at": "2026-07-10T12:34:56-07:00",
  "program_start_date": "2026-06-18T00:00:00-07:00",
  "start_date": "2026-06-17T00:00:00-07:00",
  "end_date": "2026-07-10T12:34:56-07:00",
  "end_date_mode": "dynamic_now_plus_one_day",
  "timezone": "America/Los_Angeles",
  "workout_types_to_keep": [
    "running",
    "walking"
  ],
  "record_types_requested": [],
  "record_types_available": [],
  "record_types_unavailable": [],
  "workout_count": 0,
  "record_count": 0,
  "activity_summary_count": 0,
  "files": [
    "workouts.csv",
    "records.csv",
    "activity_summaries.csv",
    "workout_type_counts.json",
    "records_by_type.json"
  ]
}

7.7 README.txt

Include plain-English notes:

This export was generated locally on iPhone from HealthKit.
It includes running and walking workouts from June 18, 2026 through the export date, plus relevant HealthKit quantity samples such as heart rate, distance, steps, energy, running speed, running dynamics, walking metrics, resting heart rate, HRV, and VO2 Max when available.
No data was uploaded by this app. The ZIP was shared manually using the iOS share sheet.

8. HealthKit query strategy

8.1 Authorization

Create a HealthKitManager.

Responsibilities:

* Check HKHealthStore.isHealthDataAvailable().
* Build the set of requested read types.
* Request authorization.
* Expose permission status to the UI.
* Provide async query methods.

8.2 Workout query

Use HKSampleQuery or HKAnchoredObjectQuery against HKObjectType.workoutType().

Predicate:

HKQuery.predicateForSamples(
    withStart: startDate,
    end: endDate,
    options: [.strictStartDate]
)

Then filter returned workouts:

workout.workoutActivityType == .running || workout.workoutActivityType == .walking

Sort by startDate.

8.3 Quantity sample queries

For each available quantity type:

1. Build date predicate.
2. Query all samples within the date range.
3. Sort by start date.
4. Convert units.
5. Append to records.csv.

Use async wrappers around HealthKit queries for cleaner code.

Important: do not assume all useful samples are attached directly to workouts. Query quantity samples by date range.

8.4 Activity summaries

Use HKActivitySummaryQuery.

Query summaries from start date through end date.

If this is annoying or brittle, activity summaries can be treated as optional for v1. The core files are workouts.csv, records.csv, manifest.json, workout_type_counts.json, and records_by_type.json.

9. ZIP generation

The app should write the export folder into a temporary directory:

FileManager.default.temporaryDirectory/
  running_health_export/
    running_health_extract_2026-06-18_to_now/

Then create:

running_health_extract_2026-06-18_to_now.zip

Requirements:

* ZIP should be standard and readable on macOS, Windows, Python, and ChatGPT file upload.
* Prefer using a small, reputable Swift ZIP package if Foundation does not provide a clean standard ZIP writer for the deployment target.
* Acceptable package: ZIPFoundation.
* Avoid proprietary Apple Archive format if it creates compatibility risk for downstream consumers.

10. Share sheet

Use UIActivityViewController from SwiftUI via UIViewControllerRepresentable.

Flow:

1. Export completes.
2. App sets shareURL to the ZIP file URL.
3. SwiftUI presents share sheet.
4. On completion or cancellation:
    * Delete ZIP file.
    * Delete export folder.
    * Clear shareURL.
    * Show result message.

The share sheet should share the file URL, not file contents loaded into memory.

11. Deletion behavior

After the share sheet completes or is dismissed:

* Delete the ZIP file.
* Delete the temporary export folder.
* If deletion fails, show a non-scary warning:
    * Export shared, but temporary file cleanup failed. You can try again or restart the app.
* Log cleanup failure in memory only. Do not persist logs unless needed.

12. UI requirements

12.1 Main screen

SwiftUI layout:

Running Health Export
Date Range
Start: [Jun 18, 2026]
End: [Now]
[Grant Health Access] or [Health Access Granted]
[Export]
Status:
Ready

12.2 During export

Disable controls.

Show progress:

Exporting...
Reading workouts
Reading heart rate
Reading running metrics
Writing files
Creating ZIP

Progress can be approximate. A spinner is fine.

12.3 After export

Show share sheet automatically.

After completion:

Export complete. Temporary files deleted.

12.4 Error states

Show clear errors:

* HealthKit not available
* Health permission denied
* No workouts found
* Export failed
* ZIP failed
* Share failed
* Cleanup failed

13. Privacy requirements

* No network requests.
* No analytics.
* No crash reporting SDK.
* No third-party service APIs.
* Health data only leaves device through explicit user action in the share sheet.
* Temporary export files are deleted after sharing.
* App should not persist exported health data in Documents.
* If using a ZIP library, it should be the only third-party dependency.

14. Suggested app architecture

RunningHealthExporterApp
  ContentView
  ExportViewModel
  HealthKitManager
  ExportBuilder
  CSVWriter
  ZipService
  ShareSheet
  Models/
    ExportManifest
    WorkoutExportRow
    RecordExportRow
    ActivitySummaryExportRow

14.1 ExportViewModel

Responsibilities:

* Own selected start/end date.
* Track permission state.
* Trigger export.
* Track progress.
* Hold shareURL.
* Handle cleanup after share sheet completes.

14.2 HealthKitManager

Responsibilities:

* Build HealthKit type sets.
* Request authorization.
* Query workouts.
* Query quantity samples.
* Query activity summaries.
* Convert HealthKit objects into export models.

14.3 ExportBuilder

Responsibilities:

* Create temp folder.
* Ask HealthKitManager for data.
* Write CSV/JSON files.
* Create manifest.
* Return folder URL.

14.4 ZipService

Responsibilities:

* Create standard ZIP file from export folder.
* Return ZIP file URL.

14.5 ShareSheet

Responsibilities:

* Present UIActivityViewController.
* Call completion handler.
* Trigger cleanup.

15. Implementation details

15.1 Date defaults

In ExportViewModel:

let programStartDate = Calendar.current.date(
    from: DateComponents(
        timeZone: TimeZone(identifier: "America/Los_Angeles"),
        year: 2026,
        month: 6,
        day: 18,
        hour: 0,
        minute: 0,
        second: 0
    )
)!

Default export window:

let exportStartDate = Calendar.current.date(byAdding: .day, value: -1, to: programStartDate)!
let exportEndDate = Calendar.current.date(byAdding: .day, value: 1, to: Date())!

15.2 Workout type mapping

Map these:

HKWorkoutActivityType.running -> "HKWorkoutActivityTypeRunning"
HKWorkoutActivityType.walking -> "HKWorkoutActivityTypeWalking"

Also include a human-readable column:

running
walking

15.3 Source/device fields

For each sample/workout, include:

sample.sourceRevision.source.name
sample.sourceRevision.source.bundleIdentifier
sample.sourceRevision.version
sample.device?.name
sample.device?.manufacturer
sample.device?.model
sample.device?.hardwareVersion
sample.device?.softwareVersion
sample.device?.localIdentifier
sample.device?.udiDeviceIdentifier

Include as separate columns where easy. Otherwise include deviceJSON.

15.4 Metadata

HealthKit metadata can contain values that are not trivially JSON encodable.

Create a safe conversion function:

* String
* Number
* Bool
* Date as ISO 8601
* Other values converted to String(describing:)

15.5 CSV escaping

Implement a real CSV writer, not naive comma joining.

Rules:

* Quote fields containing comma, quote, newline, or carriage return.
* Escape quotes as doubled quotes.
* Preserve UTF-8.

15.6 Units

Use explicit unit conversion helpers.

Examples:

HKUnit.count().unitDivided(by: .minute()) // heart rate
HKUnit.mile() // distance
HKUnit.meter() // SI distance
HKUnit.kilocalorie() // energy
HKUnit.mile().unitDivided(by: .hour()) // speed display
HKUnit.meter().unitDivided(by: .second()) // SI speed
HKUnit.watt() // running power
HKUnit.meter() // stride length
HKUnit.secondUnit(with: .milli) // ground contact time
HKUnit.meterUnit(with: .centi) // vertical oscillation
HKUnit.percent() // double support percentage

If a unit conversion throws or is unsupported, export the raw value with a best-effort unit and record an issue in export_log.json.

16. Acceptance criteria

16.1 Permissions

* App requests HealthKit read permissions.
* App does not request write permissions.
* App handles denied permissions gracefully.

16.2 Export correctness

Given HealthKit data from June 18, 2026 to now:

* App exports running workouts.
* App exports walking workouts.
* App exports heart rate samples.
* App exports distance, step, energy samples.
* App exports available running dynamics.
* App exports available walking metrics.
* App creates manifest.json.
* App creates workout_type_counts.json.
* App creates records_by_type.json.
* App creates valid CSV files.

16.3 Share behavior

* App creates a ZIP.
* App presents native share sheet.
* User can share the ZIP to Files, AirDrop, Messages, Mail, or ChatGPT if available.
* App deletes temporary files after share completion or cancellation.

16.4 No full Apple Health export required

* User does not need to open Apple Health.
* User does not need to export XML.
* User does not need to run Python.
* App queries HealthKit directly on device.

17. Nice-to-have v2 features

Not required for v1:

1. Save export presets.
2. Export only workouts, only records, or both.
3. Preview detected workouts before export.
4. Let user relabel suspected run/walk workouts in export metadata.
5. Include GPX-like route export if HealthKit route data is accessible from workouts.
6. Add charts for HR by workout.
7. Add a “copy summary to clipboard” button.
8. Add automatic detection of likely run/walk sessions mislabeled as walks.
9. Allow custom CSV vs JSON export mode.
10. Allow export as .jsonl.

18. Route data v2

For v1, route export is optional.

For v2, investigate exporting workout routes associated with each HKWorkout.

Goal:

routes/
  route_<workout_start>.gpx

or:

routes.csv

Columns:

workoutUUID
timestamp
latitude
longitude
altitude
horizontalAccuracy
verticalAccuracy
speed
course

If implementing route export, request the appropriate HealthKit route type permission and query routes associated with workouts.

19. Risks and caveats

1. HealthKit permissions are per-type. Missing data may mean permission denied, type unavailable, or no samples exist.
2. First-party Apple Workout samples may be condensed, so the app should query by date window rather than relying only on associated workout samples.
3. Some running dynamics may only exist for workouts recorded with Apple Watch and may be absent for older workouts.
4. Some run/walk workouts may be mislabeled as walking. Include walking workouts by default.
5. Very large date windows may produce large CSVs. Current window from June 18, 2026 to now should be manageable.
6. Share sheet availability depends on installed apps and iOS behavior.
7. The app should not keep exported files longer than necessary.

20. Deliverables

The coding agent should produce:

1. Xcode project
2. SwiftUI app
3. HealthKit authorization flow
4. Export pipeline
5. CSV/JSON generation
6. ZIP generation
7. Share sheet integration
8. Temp file cleanup
9. README with:
    * how to build
    * required capabilities
    * HealthKit entitlement setup
    * sideloading notes
    * known limitations

21. Xcode setup notes

Enable:

* HealthKit capability
* Appropriate HealthKit usage descriptions in Info.plist

Add usage strings:

NSHealthShareUsageDescription
This app reads selected workout, heart rate, distance, step, energy, and running metrics to create a local export file that you can manually share.

No HealthKit write usage description should be needed if the app never writes data.

22. Recommended implementation order

1. Create SwiftUI shell.
2. Add HealthKit capability and permission request.
3. Query workouts for fixed date window.
4. Display workout count on screen.
5. Write workouts.csv.
6. Query heart rate and write records.csv.
7. Add all remaining quantity types.
8. Add JSON sidecar files.
9. Add ZIP generation.
10. Add share sheet.
11. Add cleanup.
12. Add better progress/error handling.
13. Test with accidentally mislabeled walking workouts.

A few implementation notes for the agent: use Apple’s native share sheet via UIActivityViewController, which is the standard UIKit mechanism for sharing copies of app data.   For ZIP, I’d favor a standard ZIP output over Apple Archive because the file needs to be portable to ChatGPT, macOS, Python, etc. Apple Archive and Compression are useful native frameworks, but a conventional ZIP library like ZIPFoundation may be simpler for cross-platform sharing.  