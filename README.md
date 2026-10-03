# Running Health Export

A native iOS app that exports a focused Apple Health **running** dataset (workouts, heart
rate, distance, energy, running/walking dynamics, activity summaries) straight from HealthKit
on the device — no full Apple Health XML export, no Python, no server, no network.

It writes a small folder of CSV + JSON files, zips it with a standard portable ZIP, and hands
it to the iOS share sheet. Temporary files are deleted after you share (or cancel).

**v1.1** adds a run/walk workout planner, an iPhone-owned interval audio cue engine, and a post-run
subjective logger (RPE, personal heat rating, body signals, notes). All of it exports alongside the
HealthKit data in the same ZIP. See [v1.1: planner, cues and logger](#v11-planner-cues-and-logger)
below.

Two things this sentence used to claim and no longer does. **WorkoutKit sync to Apple Watch** was
built and then removed in the 2026-09-29 clean-out; the phone's Start now launches this app's own
watch workout instead (`docs/WATCHOS_RECORDER_PLAN.md`), and `LEARNINGS.md` records why the
WorkoutKit route was unreliable on this hardware. **Shoes** are still logged, exported and
mileage-tracked, but every screen that showed them was hidden on 2026-10-01 — a new log records the
one pair without asking. See "Hide shoes for now" in [docs/BACKLOG.md](docs/BACKLOG.md).

## What it produces

A ZIP named `running_health_extract_<start>_to_<taken>.zip` — both dates `yyyy-MM-dd`, the second
the day the export was taken — containing:

```
running_health_extract_<start>_to_<taken>/
  manifest.json             # window, timezone, counts, type availability, weather + route diagnostics
  workouts.csv              # one row per running/walking workout (incl. weather + route summary)
  records.csv               # one row per HealthKit quantity sample
  activity_summaries.csv    # per-day move/exercise/stand
  routes_summary.csv        # one row per workout: route coverage, geometry, GPS quality
  workout_type_counts.json  # all vs kept workout types in window
  records_by_type.json      # requested / available / unavailable / counts
  export_log.json           # issues encountered (flat strings + structured entries)
  README.txt                # plain-English provenance note
  routes/
    route_<workoutUUID>.csv # every GPS point of one workout
    route_<workoutUUID>.gpx # the same track as standard GPX 1.1

  # v1.1 — the subjective side, always written (header-only when empty)
  run_logs.csv                    # RPE, personal heat rating, body signals, shoe, notes
  recovery_logs.csv               # optional next-day recovery ratings
  shoes.csv                       # shoe profiles with derived mileage
  planned_workouts.csv            # the interval plans defined in the app
  planned_workout_blocks.csv      # every fixed plan's segments, one row each, in order
  workout_intervals.csv           # actual run/walk/cooldown boundaries from the app's timer
  pending_workout_executions.csv  # each attempt at a plan, and the workout it matched
  body_signal_details.csv         # optional extra context on a body signal
  workout_notes.csv               # free-text notes typed during a workout, one row each
```

Distances/speeds are exported in miles + SI meters/(m/s); energy in kcal; running dynamics in
their natural units, with both display and SI values where useful. See the in-app export and the
v1.0 spec ([docs/Native-iOS-Health-Running-Export.md](docs/Native-iOS-Health-Running-Export.md)) for
the exact column list — historical, and kept for that list and for why v1.0 was scoped as it was.

`workouts.csv` is backward compatible: the original 20 columns are unchanged and in the same
order, with these groups appended after them, in this order: weather, route, (v1.1) run logger,
`reclassifiedAsRunning`, and the `actual*` columns. A new group goes at the end, never inside one.
This is enforced by `ExportSchemaTests`, which asserts the v1.0 header verbatim and pins the whole
shipped header in `shippedWorkoutColumns`.

**Planned versus actual.** `runIntervalSeconds`, `walkIntervalSeconds`, `plannedRepetitions` and
`blockShape` describe the plan as it stood when a run began. `actualShape`, `actualRunLegCount`,
`actualRunSeconds` and `actualWalkSeconds` — in `pending_workout_executions.csv` and
`workouts.csv` — describe what was run, derived from the run's legs in `workout_intervals.csv`
(`RecordedRun`). For an open-interval run they are the only description of its legs. The
README.txt in each export explains them under "PLANNED vs ACTUAL".

## Weather

Weather is read from the metadata Apple already stored on each `HKWorkout`
(`HKMetadataKeyWeatherTemperature`, `…Humidity`, `…Condition`, `HKMetadataKeyBarometricPressure`,
plus `HKMetadataKeyTimeZone` and `HKMetadataKeyIndoorWorkout`). **No weather API, no historical
weather service, no network request of any kind.** `manifest.json` states this explicitly as
`"weather_source": "healthkit_workout_metadata"`.

Notes on the conversions:

- **Temperature** is exported in both Celsius and Fahrenheit.
- **Humidity** is normalized to 0–100. `HKUnit.percent()` is documented as a 0.0–1.0 fraction, but
  workouts in the wild store humidity both as `0.73` and as `73`. Values ≤ 1.0 are read as a
  fraction (real relative humidity is never 1%), anything above as percentage points, and
  `manifest.json` reports how many values arrived in each shape.
- **Condition** names come from Apple's `HKWeatherCondition` enum only. An unrecognized code is
  exported with its number intact and the name `unknown` — no condition mappings are invented.
- **Barometric pressure** is normalized to hPa.
- **Indoor flag** is left blank when absent; blank means "not recorded", not "outdoors".
- A value stored in an unexpected type (e.g. a bare number for temperature, whose unit would be a
  guess between °C and °F) is left blank and logged to `export_log.json`. The untouched original
  is still in the row's `metadataJSON` column.

Weather is absent for many workouts — that is normal, and `weatherMetadataAvailable` is `false`
for those rows.

## GPS routes

Routes come from `HKWorkoutRoute` samples already stored in HealthKit, read with
`HKWorkoutRouteQueryDescriptor` (the modern async replacement for `HKWorkoutRouteQuery`), which
transparently handles the multiple batches a long route is delivered in. The app reads **historical
route data only** — it never starts location services and needs no Core Location permission.
`CoreLocation` is linked purely for the `CLLocation` type.

- All of a workout's route samples are merged into one chronological, de-duplicated point set;
  `routeCount` still reports how many samples HealthKit held.
- Core Location's negative sentinels (invalid speed, course, altitude, …) are exported as **blank**
  fields, never as measurements. Points with no usable coordinate are dropped and counted.
- **Elevation gain/loss is an estimate.** GPS altitude is noisy, so vertical changes below
  **1.5 m** between sequential accepted points are ignored; larger rises add to gain and larger
  drops to loss. Only points with valid vertical accuracy are used. The threshold is recorded as
  `elevation_noise_threshold_meters`. This is not surveyed elevation.
- **Route distance** is measured along the recorded points, independently of the workout's own
  total-distance value, so the two can legitimately differ.
- **Centroid** is a plain arithmetic mean of latitude/longitude — fine for short local routes, not
  a great-circle centroid.
- Per-point horizontal accuracy, plus average and median accuracy per route, let you judge how
  much to trust a track.
- CSV timestamps are ISO 8601 with the device's UTC offset; GPX timestamps are UTC with a
  trailing `Z`, which is what GPX readers expect.

**Route data is sensitive** — it reveals where you live, work, and run, and your habitual routes
and times. Treat the export accordingly.

### Route authorization reporting

`manifest.json` records `route_export.authorization_status` as one of `authorized`, `denied`,
`notDetermined`, `unavailable`, `notRequested`, or `unknown`. Be aware that HealthKit deliberately
does **not** disclose read authorization: a denied read normally looks identical to "this workout
has no route". `authorized` therefore means "at least one route query completed without an
authorization error", and `unknown` means nothing observable was learned (e.g. no workouts to
check). If route access fails, the rest of the export still completes and the limitation is
recorded in both the manifest and `export_log.json`.

## Requirements

- Xcode 16 or newer (built and tested with Xcode 27.0; see [docs/INSTALLS.md](docs/INSTALLS.md)).
- iOS 17.0+ device with health data. HealthKit is not available in most simulators for real data.
- An Apple Developer team for signing. The project ships with no team set; see
  [Building it yourself](#building-it-yourself).

## Build

```bash
# List the target/scheme
xcodebuild -list -project RunExporter.xcodeproj

# Build Release for a connected device (automatic signing provisions HealthKit)
xcodebuild -project RunExporter.xcodeproj -scheme RunExporter -configuration Release \
  -destination 'id=<DEVICE_UDID>' -derivedDataPath ./build -allowProvisioningUpdates build
```

Find your device UDID with `xcrun devicectl list devices`.

### Building it yourself

Personal settings live in git-ignored local files, each with a committed template:

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set DEVELOPMENT_TEAM to your team ID
cp scripts/local.env.example scripts/local.env           # optional: your phone's device id
```

`Config/Shared.xcconfig` includes `Local.xcconfig` for every target, so the team is set once, for
Xcode and command-line builds alike. Without it the project still builds for the simulator. The bundle
identifiers all start with `is.doug.`, which belongs to the author's team; change them to a prefix you
own, or automatic signing will refuse to provision them. `Config/RunExporterWatch-Info.plist` names
the phone app's bundle id as the watch app's companion, and the helper scripts in `scripts/` name it
too, so update those to match.

**Contributing:** this repository is public, and nothing personal may be committed. Enable the guard
with `git config core.hooksPath .githooks` and list your own values in `private/sensitive-patterns.txt`
(template alongside it) — see [private/README.md](private/README.md).

## Capabilities & entitlements

- **HealthKit capability** — declared in `RunExporter/RunExporter.entitlements`
  (`com.apple.developer.healthkit`). Automatic signing adds the matching capability to the
  provisioning profile when you build with `-allowProvisioningUpdates`.
- **The iPhone app never writes to HealthKit** — its export and logger read only
  (`HealthKitManager.requestAuthorization`, `toShare: []`). **Since 2026-09-25 it also asks for
  permission to share workouts**, from `WatchLink.launchWatchWorkout`, at the owner's direction:
  starting and controlling the Watch's workout from the phone may need it, and whether it strictly
  does is unmeasured. The phone's code still performs no write; the Watch saves the workout. Hence
  `NSHealthUpdateUsageDescription` on the phone target. See **Privacy**.
- **Usage description** — `NSHealthShareUsageDescription` is set via the target's
  `INFOPLIST_KEY_NSHealthShareUsageDescription` build setting (the Info.plist is generated).
- **No third-party dependencies** — ZIP is written by a small built-in writer using the system
  `Compression` framework (standard DEFLATE + CRC32), so the output opens on macOS, Windows,
  Python `zipfile`, and file-upload consumers. Nothing else is linked.

### Added in v1.1

- **Background audio mode** — `UIBackgroundModes = [audio]`, declared in
  `Config/RunExporter-Info.plist`. Required so interval cues keep firing with the screen locked or
  the app backgrounded. This is the only new entitlement or capability; there is no new
  usage-description string, because nothing new is requested from the user.

  **Do not move this to `INFOPLIST_KEY_UIBackgroundModes`.** That build setting is accepted without
  any error or warning and silently produces no key: Xcode only maps an allowlist of known
  `INFOPLIST_KEY_*` settings into the generated plist, and array-valued `UIBackgroundModes` is not
  among them. The result builds, installs and runs, and cues simply stop when the screen locks.
  The target therefore keeps `GENERATE_INFOPLIST_FILE = YES` *and* sets `INFOPLIST_FILE` to the
  partial plist above; Xcode merges the two. Verify after any Info.plist change with:

  ```bash
  plutil -extract UIBackgroundModes json -o - \
    build/Build/Products/Release-iphoneos/RunExporter.app/Info.plist
  # must print ["audio","workout-processing"]; the second was added for the watch link
  ```
- **WorkoutKit — no longer used.** Kept here because it needed no entitlement, so its removal in
  the 2026-09-29 clean-out took nothing out of the project's permissions: scheduling had asked for
  permission at runtime through `WorkoutScheduler.requestAuthorization()`, which iOS presented
  itself. Nothing to restore if it ever comes back.
- **The workout-share request added on 2026-09-25 is for the watch link**, not for WorkoutKit,
  which never needed HealthKit *write* access (spec §23). It is the one still in use.

### Added for the watchOS target (v1.2, in progress)

- **HealthKit write — watch target only.** `RunExporterWatch Watch App/RunExporterWatch.entitlements`
  declares the HealthKit capability for the watch app, and its Info.plist carries
  `NSHealthUpdateUsageDescription`.

  This is a deliberate, scoped change to a property the app has held since v1.0, so it is stated
  plainly rather than buried: **a watch recorder cannot be read-only.** Saving a workout means
  `HKLiveWorkoutBuilder.finishWorkout()`, which writes an `HKWorkout`. Scope is workouts and their
  GPS routes.

  **Used since 2026-09-29.** A run started with the phone's **Start** is saved by the watch app when
  the phone finishes it (`WatchWorkoutController.finish(executionID:)`): the workout, its GPS route,
  and the phone's execution id in the workout's metadata (`WorkoutMetadataKeys.executionID`), which
  is what the phone joins on — or untagged, joined by start time, when the phone recorded no
  execution. A run abandoned on the phone is discarded (`WatchWorkoutController.end`).

- **Background modes** — `Config/RunExporterWatch-Info.plist` declares
  `UIBackgroundModes = ["workout-processing", "audio"]`. `workout-processing` is what gives a
  watchOS app real background execution during an `HKWorkoutSession`. It also declares
  `WKBackgroundModes = ["workout-processing"]`, without which the phone's launch never starts the
  watch app (see [LEARNINGS.md](LEARNINGS.md)). Verify both survived the build the same way as the
  phone's:

  ```bash
  plutil -extract UIBackgroundModes json -o - \
    "build/Build/Products/Release-iphoneos/RunExporter.app/Watch/RunExporterWatch Watch App.app/Info.plist"
  plutil -extract WKBackgroundModes json -o - \
    "build/Build/Products/Release-iphoneos/RunExporter.app/Watch/RunExporterWatch Watch App.app/Info.plist"
  ```

## Tests

```bash
xcodebuild test -project RunExporter.xcodeproj -scheme RunExporter \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The suite in `RunExporterTests/` covers the export schema and ZIP validity, the interval schedule
and timer, workout matching, shoe mileage, cue-tone generation, settings persistence, and the Live
Activity timeline and staleness rules. Run it for the current count rather than trusting a number
here — the previously quoted figure had been wrong for two sessions.

**End-to-end smoke test** — `scripts/smoke-test.sh`. Drives the real app in the simulator
(`RunExporterUITests/SmokeTests.swift`, its own `RunExporterUITests` scheme so the unit loop stays
fast): every tab, a plan from a preset and an open-interval plan, Settings, the export screen, and a
run from Start Workout to End Workout. It checks that removed controls are **absent**, not only that
the rest are present. Each run starts from a clean install and writes the result bundle and one
screenshot per step to `build/smoke-test/<timestamp>/` (git-ignored). The simulator has no Watch,
so the run screen is expected to report that the run continues on the phone only; the Watch path
needs the device. It launches the app with `-uiTestingSkipsHealthAuthorization`, which a **Debug**
build honors by never requesting HealthKit access (`UITesting`; a Release build ignores it), and
with cues off so the simulator does not speak through the Mac. Dismissing the simulator's Health
sheet instead made the test fail three runs in five.

The export tests drive `ExportBuilder.writeFiles` directly with a prepared dataset rather than going
through `build`, which reads HealthKit — an unauthorized store in the test environment would
otherwise fail every one of them for a reason unrelated to what they check.

## Sideloading to a device

Helper scripts live in `scripts/`. Each takes the phone's device id as its first argument, or reads
`PHONE_DEVICE_ID` from `scripts/local.env`, prints which it used, and stops with a usage message if
it has neither (find the id with `xcrun devicectl list devices`):

```bash
scripts/sideload.sh [device-id]    # clean Release build + install + launch
scripts/relaunch.sh [device-id]    # launch the already-installed app (no rebuild)
```

### Verifying a real export

```bash
python3 scripts/verify_export.py <export.zip | extracted_folder>
```

Run this against an export produced on the phone. The unit tests build synthetic datasets, so they
pass on inputs that are small, clean and ASCII — this checks the properties only real HealthKit data
exercises: CSV field counts across ~240,000 rows (93 fields in the owner's export contain a comma or
a quote), UTF-8 throughout, per-entry CRCs, manifest/archive agreement, and whether interval records
actually reach a workout. Exit code is 0 only when every check passed, and a section that ran zero
checks counts as a failure rather than printing an empty header that reads like success.

Or manually:

```bash
xcrun devicectl device install app    --device <UDID> build/Build/Products/Release-iphoneos/RunExporter.app
xcrun devicectl device process launch  --device <UDID> is.doug.runexporter
```

Notes:
- The phone must be **unlocked** at launch time, or the launch is denied with `Locked`.
- On the very first install of a build signed by a new developer cert, trust it under
  **Settings → General → VPN & Device Management → (developer) → Trust**.
- Free (personal-team) signing expires ~7 days after install; paid-team signing lasts far
  longer. This project uses a paid team, so re-sideloading is only needed when code changes.

## Using the app

1. Launch. Tap **Grant Health Access** and allow the requested read types in the Health sheet.
2. The date range defaults to **Start: Jun 18, 2026** (persisted across launches) and **End: Now**
   (resets to now each launch). Adjust if you like.
3. Choose an **Export Mode** (see below).
4. Under **Additional Data**, leave *Include workout weather* and *Include GPS routes* on (both
   default to on at every launch). Turning routes off skips route queries entirely and writes no
   `routes/` folder; the manifest still records that routes were not requested.
5. Tap **Export**. The app reads workouts, weather metadata, quantity samples, activity summaries,
   and workout routes, writes the files, and zips them.
6. The share sheet appears — send the ZIP to Files, AirDrop, Messages, Mail, ChatGPT, etc.
7. After sharing (or cancelling), temporary files are deleted and the status shows
   *"Export complete. Temporary files deleted."*

### Export modes

- **Full date range** (default) — every requested HealthKit quantity sample across the whole
  window (program start − 1 day through now + 1 day). Largest, most complete export.
- **Workout windows only** — quantity samples are limited to within **30 minutes before/after**
  each running or walking workout; overlapping windows are merged so no sample is duplicated. This
  produces a much smaller `records.csv` while keeping the data needed to analyze heart rate, speed,
  distance, steps, energy, and running dynamics *during* workouts. `workouts.csv` and
  `activity_summaries.csv` still cover the full range. The manifest records
  `"export_mode": "workout_windows_only"`, the buffer, and the raw/merged window counts.

The manifest always records the mode used, the complete `files` list, and source-count
diagnostics (`record_source_counts`, `heart_rate_source_counts`, `workout_source_counts`) so you
can see which devices/apps (Apple Watch, iPhone, Oura, RENPHO, …) contributed the data.

## Architecture

```
RunExporterApp           @main entry; owns LoggerStore, LoggerDefaults, AudioCueEngine
ContentView              TabView root: Today / Plans / History / Settings
Views/ExportView         the v1.0 export screen, unchanged, reachable from Today and Settings
ExportViewModel          dates, toggles, permission state, progress, share + cleanup (@MainActor)
HealthKitManager         auth + async workout/quantity/activity-summary queries + unit conversion
WorkoutMetadataExporter  HKWorkout -> workout row, incl. weather metadata extraction
WorkoutRouteExporter     HKWorkoutRoute queries, point merge/sort/dedupe, route file writing
RouteCSVWriter           per-workout route point CSV
GPXWriter                standard GPX 1.1 track
ExportBuilder            orchestrates queries, writes CSV/JSON, builds manifest, zips
CSVWriter                RFC 4180 CSV escaping
ZipService               dependency-free standard ZIP (DEFLATE via Compression + CRC32)
ShareSheet               UIActivityViewController wrapper with completion → cleanup
Models/ExportModels      row structs, JSON/date/number helpers, log entries, dataset
Models/WorkoutWeather    weather value model, HKWeatherCondition naming, diagnostics
Models/RouteModels       route point/summary models, route math, diagnostics

— v1.1 —
Models/Logger/*          SwiftData models (Shoe, PlannedWorkout, PlannedWorkoutBlock,
                         OpenIntervalShape, RunLog, RecoveryLog, WorkoutIntervalLog, WorkoutNote,
                         PendingWorkoutExecution), BodySignalReadings, store, settings, seeding
Models/Logger/RecordedRun   what a run actually ran, derived from its legs, never stored; each
                         leg's active windows with pauses removed (the analysis slices by these)
Models/Logger/ShapeZeroRepair  at launch, clears the 0/0/0 that older builds stored in shape fields
Models/LoggerExportModels   CSV row structs for the subjective files + workouts.csv join
Workout/WorkoutPhaseSchedule pure run/walk/cooldown sequencing (no clock, no I/O); declares the
                         WorkoutPhaseSource protocol that both schedules answer
Workout/OpenIntervalSequencer  the open-interval rules and schedule: each leg capped by what is
                         left of the target, phases computed from accumulated running not stored
Workout/IntervalTimerEngine  absolute-timestamp timer; emits cues and interval records
Workout/RecentWorkoutMatcher matches a finished HealthKit workout to a planned execution: by the
                         execution id the watch app saved, else inside a two-minute start window;
                         a near miss is offered, never linked silently
Workout/WatchLink        the phone's end of the watch link: launches the watch app, receives its
                         mirrored session, sends phases, asks it to save or discard; writes the
                         two diagnostic logs
Workout/WatchPhaseMapping    interval-engine state -> the PhaseAnchor sent to the watch
Workout/LatencyEstimate  one-way phone->watch delay: half the smallest ping round trip
Workout/DiagnosticLogFile    append-only log file in Documents, pulled with devicectl
Audio/AudioCueEngine     AVAudioSession + speech + tones, background audio, route/interruption
Audio/CueDuckCounter     holds the ducking invariant: only un-duck what this cue ducked
Audio/ToneGenerator      programmatically generated WAV cue tones (no bundled/licensed audio)
Workout/LiveActivityController  Live Activity lifecycle and stale dates (the card needs no updates)
Views/*                  Today, Plans (list + detail + editor), OpenIntervalPlanEditorView,
                         active workout, LegEndSheet (annotates a leg that has already ended),
                         SlideToConfirm (the drag behind Pause and Skip), post-run logger,
                         history, shoes (present but unreachable since 2026-10-01), settings

— shared / other targets —
Shared/RunWorkoutActivityAttributes  Live Activity state + whole-workout timeline (app + widget)
Shared/WatchLinkMessage      the phone<->watch wire format, versioned; also PhaseAnchor and
                             WorkoutMetadataKeys (phone + watch)
Shared/PhaseClock            a PhaseAnchor turned into a countdown on the watch's own clock
Shared/PaceTracker           the watch's leg pace, current mile split and total distance
Shared/WatchHealthAccess     the watch's Health access, per type (workouts, routes), and the
                             launch decision; RouteTally reports a route short of complete
RunExporterLiveActivity/     widget extension: Lock Screen card and Dynamic Island
RunExporterWatch Watch App/  watchOS companion; ships embedded at RunExporter.app/Watch/
  RootView                   picks the screen: run, link diagnostics, or idle; asks for Health
                             access every time the app comes on screen
  WatchRunView               the run screen: phase, time left, heart rate, pace, distance
  WatchLinkView              a run until its first phase arrives, and why a start failed
  WatchIdleView              "Start a workout from your iPhone" and the Health access status
                             (replaced the stage 2 probe, which passed on 2026-09-25, in the
                             2026-09-29 clean-out)
  WatchWorkoutController     the watch end of the phone link: starts and mirrors the session,
                             records phases and the GPS route, saves or discards when told
  WatchEventLog              saved event log, forwarded to the phone's Documents/watch-events.log
  *.entitlements             HealthKit WRITE — the watch saves workouts; the phone never writes
Config/*.plist               UIBackgroundModes, NSSupportsLiveActivities — keys that do NOT
                             work as INFOPLIST_KEY_* build settings; verify with plutil.
                             RunExporterWatch-Info.plist is partial by necessity; read its comments
```

`Shared/` is a plain Xcode group, not a synchronized one: files added there must be wired into each
target's build phase by hand, or they silently fail to compile into the widget.

## v1.1: planner, cues and logger

Requirements are specified in [RUNNING_APP_V1_1_SPEC.md](RUNNING_APP_V1_1_SPEC.md) (the `§` numbers
cited throughout this README and in the source refer to it). **That spec covers v1.1 and stops
there** — open-interval runs were asked for and built afterwards and are specified nowhere, so their
reasoning lives in the code's own comments and in [docs/BACKLOG.md](docs/BACKLOG.md).

The code diverges from the spec deliberately in four places, and they are **not** all explained in
the same file:

| Deviation | Spec | Explained in |
|---|---|---|
| Deployment target stays at iOS 17.0 | suggests iOS 18 | [Known limitations](#known-limitations) |
| Cue mode defaults to Voice, not Voice + beeps | §9.2 | [Known limitations](#known-limitations) |
| Transition countdown defaults **on** | §11.3 | [Known limitations](#known-limitations) — inside the cue-mode entry, which it sits in tension with |
| Two `AVAudioSession` options changed | §9.4 | [docs/CUE_FEASIBILITY_TEST.md](docs/CUE_FEASIBILITY_TEST.md), **not** here |

These are decisions, not drift: do not "fix" the code to match the spec without reading the
reasoning first.

### Flow

1. **Plans** — build a run/walk plan (`4/1 × 5`) or start from a preset. Under 30 seconds. A plan
   can also run blocks of differing length — `5/1×1 · 8/1×2 · 5/1×1` — by adding blocks in the
   editor; they run top to bottom, with the walk between blocks kept and only the walk after the
   workout's final run dropped.

   A third kind, **open intervals**, has no fixed leg length at all: you run until you decide to
   stop, walk until you decide to go, and the plan ends when the running adds up to a target. See
   [Open-interval runs](#open-interval-runs).
2. **Start Workout** on the phone (named "Start Audio Timer" until the 2026-09-29 clean-out). There is no separate send-to-Watch step: the WorkoutKit
   "Send to Apple Watch" screen was removed in the 2026-09-29 clean-out (see
   [LEARNINGS.md](LEARNINGS.md#workoutkit) for why it was unreliable on this hardware). The screen
   opens *armed* and records nothing — no timer session, no audio session, no Live Activity. **Start** also launches the workout on the Watch
   (watch plan step 2, from 2026-09-29): one tap, both devices. Do not start a workout on the Watch
   yourself as well, or two are recorded. The run screen says whether the Watch is recording and
   offers **Try again** if it is not; a Watch that fails never stops the run, which carries on
   phone-only. Before this, the Watch's workout was started by hand and matched to the timer by
   start time, which is why the start countdown defaulted to 0 until the 2026-09-29 clean-out.
3. **Cues play through AirPods** — run, walk, cooldown and completion, plus the five-second warning
   and the 3-2-1 into each transition (both on by default), the final-round call (on) and the
   halfway call (off). Pause, resume, skip and end are confirmed aloud in every cue mode, because a
   tap with no audible answer is indistinguishable from a missed one. The **start** countdown is
   3 seconds by default (spec §6), which also gives the Watch time to connect before the first
   phase; plans made before the 2026-09-29 clean-out keep the countdown they were saved with. An open-interval run adds two more: the running still
   to do, announced as each leg begins, and the recovery walk reaching its floor — the latter
   counted into with the same 3-2-1, and never announcing a run, because the floor does not start
   the next leg.
4. **Add a note whenever something is worth saying** — the workout screen carries an **Add note**
   button in every phase. Each note is stored on its own, stamped with the phase and round it was
   written in, so a walk-break observation stays attached to that walk. The timer and the audio
   session are untouched while the sheet is open.
5. **Open the app afterwards** — the new workout is detected, matched to the plan, and offered for
   logging.
6. **Log it** — RPE, personal heat rating, body signals, notes. About 20 seconds. The shoe is
   recorded too, but no longer asked for: the picker was hidden on 2026-10-01 and the log takes the
   most recently used pair by itself.

### Open-interval runs

A plan for running to a *signal* rather than to a clock: run until the thing you are watching for
turns up, walk until it goes away, repeat until the running adds up to a target. Added after
v1.1.

A plan of this kind stores only two numbers — a target of accumulated running and a floor for the
recovery walks — as an `OpenIntervalShape` hung off `PlannedWorkout`. **The presence of that
relationship is what makes a plan open-ended**; `PlannedWorkout.shape` turns it into a `Shape` sum
type so every reader has to choose a branch.

How it runs:

- **Each leg is capped by what is left of the target.** End a 30-minute target's first leg at 12:32
  and the second is capped at 17:28. The final leg therefore ends on its cap, and records
  `targetReached` instead of `runnerEnded`, which is the only way to tell a leg that ran out of
  target from one you stopped.
- **The recovery walk has a floor but no ceiling.** It never ends on its own. The headline counts
  down to the floor, the floor is announced, and the walk then waits — the button reads **Start
  next leg** throughout. Starting before the floor is allowed, behind a confirmation naming both
  numbers, and the walk is still recorded as it actually happened.
- **"Back to baseline"** stamps the moment the signal went, without ending the walk. Blank means it
  had not gone by the time the walk ended, which is a different and real answer.
- **Ending a leg opens a sheet** asking all five body areas, and the leg ends on the *tap*, not on
  the sheet's Save — otherwise however long the rating took would be counted as running. The sheet
  is optional and a note alone will satisfy it, since a leg can end for a reason that is not pain.
- **Skip is hidden** on these runs. It writes an abandoned leg with no reason and no readings, next
  to a button that records a measured one.

Seven columns on `workout_intervals.csv` carry it: `endReason`, `baselineReachedAt`, and one
severity per body area, named exactly as `run_logs.csv` names them.

**On the Watch, an open-interval run works like any other.** **Start** launches the Watch's workout,
and while the Watch is connected each phase is written into that workout as a segment. Do not start
one on the Watch by hand as well, or two are recorded.

The older arrangement is gone on both sides: the WorkoutKit send route was removed from every plan
in the 2026-09-29 clean-out, and the line of explanatory text that stood in its place on the plan
screen — which told the reader to start a workout on the Watch and press Lap — went with it. It had
become wrong twice over, since Start now launches the Watch itself and
[LEARNINGS.md](LEARNINGS.md#run-logging) records that pressing Lap adds nothing to the data.

The reason an open plan could never have used WorkoutKit is still worth keeping, because
[docs/BACKLOG.md](docs/BACKLOG.md) holds an open question about sending one some other way: a
watchOS 10 `CustomWorkout` is a fixed list of blocks, and an open-interval plan is an unknown number
of legs.

### Intervals and the workout they belong to

Storing your interval boundaries so they can be correlated with the HealthKit workout is the reason
this app exists, and the rules are worth knowing because they are visible and occasionally
surprising.

While the timer runs, the app records a `WorkoutIntervalLog` per run/walk/cooldown segment. Those
records belong to a *timer session* (`PendingWorkoutExecution`), not to the Watch's workout — the two
are separate recordings of the same run and have to be joined afterwards.

**The join happens when you save a run log.** Both directions work:

- Logging **during** cooldown attaches the workout as soon as it arrives from the Watch.
- Logging **afterwards**, from Today's queue or from History, resolves the timer session by matching
  it against the workout. This direction did not exist before `b55974a`; a run logged after the fact
  had its intervals attached to nothing at all, with no error and nothing on screen.

**Logs written before `b55974a` are only linked if you re-save them.** There is no backfill: open the
run in History, tap **Edit log**, and save. Simulated against the owner's real data, a migration would
have affected exactly one log — a permanent code path to serve one row, when one tap does the same
thing.

**Two things about `workout_intervals.csv` surprise people, and both are deliberate.**
`sequenceIndex` is the order records were *written*, not the order phases started — a pause is
written when you resume, so it gets a lower index than the phase it interrupted. And a phase that
was paused has its `startDate` shifted forward by the paused time, because `actualDurationSeconds`
counts only running time, so the phases do not tile the run end to end. The gaps are the pauses,
which appear as their own rows. Sort by `startDate` for chronology, and see
[LEARNINGS.md](LEARNINGS.md#run-logging) before joining `workout_notes.csv` on timestamps.

**A workout saved by this app's watch app is joined by its execution id first.** The watch writes
the phone's execution id into the workout's metadata (`WorkoutMetadataKeys.executionID`), and
`RecentWorkoutMatcher` checks that tag before anything else, in both directions: a matching tag wins
whatever the start time, and a workout tagged for a different run is never time-matched to this one.
Everything below about the window applies only to **untagged** workouts — runs recorded before the
watch app saved, and workouts from Apple's Workout app.

**An untagged workout counts as this run's only if the timer started within two minutes of it.**
Measured rather than picked: `createdAt` and `timerStartedAt` are the same instant in all 23 of the
owner's real executions, and the one verified match started its timer **1 second** before the workout
began. The window was 90 minutes, which turned out to be strictly worse — every window from 30s to
90min produced the same single automatic match, while the wide ones additionally pulled in abandoned
timers and made one real run permanently ambiguous. A wider window bought no matches and cost a link.

**Miss the window and the app says so, and offers the workout anyway.** A run of the right kind that
started outside the two minutes comes back as `.outsideWindow` rather than "nothing found", and the
screen names the gap — "a <distance> run started 4:12 away from when you tapped Start" — with the
option to use it. Confirming by hand goes through the same `attach` as an automatic match, so the
intervals are stamped identically and the export cannot tell the two apart.

This exists because the old behavior was worse than silence: a near miss was reported as
`.noCandidates`, rendered as "No Apple Watch workout found", and the advice was to wait for the
Watch to sync — which can never help, since the reverse direction applies the same gate however long
you wait. **Widening the window is not the fix** and is ruled out by the measurement above; offering
the near miss is. Unjoined interval legs now also appear in `export_log.json`, at `info` rather than
`warning`, because every leg of a phone-only run legitimately has no workout UUID.

**Eligibility and confidence are separate constants, deliberately.** `startToleranceSeconds` decides
which sessions are *eligible*; `startScoreReferenceSeconds` scales how strongly one eligible session
is *preferred* over another. They used to be the same value, so narrowing the window silently
multiplied every score, pushed indistinguishable pairs past the ambiguity margin, and converted "too
close to call, so ask" into a confident pick — a behavior change arriving as a side effect of an
unrelated edit. Do not re-fuse them.

**When two sessions genuinely overlap, the app asks instead of guessing.** Intervals stamped onto the
wrong run are wrong permanently and nothing would ever say so, so no tiebreak is applied. The run's
History screen offers the candidate sessions — start time, plan, interval count, and whether the
timer was ever stopped — and you pick the one you ran. Previously it refused and offered nothing,
which made an ambiguous run unlinkable for good.

**A timer started and never stopped is retired after 12 hours.** Such a session cannot be excluded on
evidence — it may genuinely still have been running — so left alone it stays a candidate forever, and
enough of them near a real run makes that run ambiguous. Retirement sets `ExecutionStatus.expired`,
which the matcher already excluded, and it is **reported on the Today screen rather than done
quietly**. Nothing is deleted: `WorkoutIntervalLog` refers to its session by a plain ID with no
SwiftData relationship, so deleting a session would strand its interval records with an ID pointing
at nothing, and they would keep exporting as though intact. `completed` sessions are never retired at
any age, because a run logged days later must still resolve.

**Verified end to end on real hardware.** Re-saving one pre-fix log took the export's join integrity
from **0 of 98** interval records reaching a workout to **12 of 98** — exactly the count predicted
offline, which excludes both a still-broken matcher (would link none) and an over-eager one (would
link more). Check any export with `scripts/verify_export.py`. Of the remaining 86, none are
linkable: they belong to cue-test sessions for which no Watch workout was ever recorded, so there is
nothing to link them to. That is not a defect.

**And now covered by tests, which is the part that was missing.** `RunLoggerModelTests` drives
`RunLoggerModel` against an in-memory SwiftData store (`LoggerStore(inMemory: true)`), so the path
from `save(draft:for:)` through the matcher to a stamped interval row is asserted rather than
reasoned about. Its absence is precisely what let the original defect ship: the pure matcher logic
was unit-tested and correct, and 98 interval records still reached no workout, because nothing tested
the **wiring**. Dropping the `resolvedExecution` fallback — reinstating the original bug exactly —
fails three of its fourteen tests, so the harness demonstrably catches what shipped.

### Irreversible actions confirm

Deleting a **plan** asks first, from both the list's swipe action and the detail screen. The message
names the plan and says the deletion cannot be undone, and that is all it says: it used to report
whether the plan would also be unscheduled from the Watch, which stopped being true when the
WorkoutKit route went in the 2026-09-29 clean-out. Deleting a plan now just deletes it.

Deleting a **shoe** asks too, and says that the runs logged with it are kept but lose their shoe
assignment, so mileage totals will change; it also points at **Retired** as the option that keeps
the history. That screen is still in the app but unreachable since shoes were hidden on
2026-10-01 — the confirmation is described here because the screen comes back if shoes do.

Neither used to ask. `role: .destructive` only colors a button red — it prompts for nothing — so the
app was confirming *"End this workout?"*, the most recoverable action it has, while deleting plans and
shoes on a single tap. The detail screen's button also read "Delete workout", which invited the
reading that it could delete a recorded run; it cannot, and now says "Delete plan".

### Personal heat rating

Deliberately separate from the objective weather columns, and **never derived from them**:
1 = felt cold, 5 = thermally neutral, 10 = severely overheated, half points allowed. Required.
Exported as `personalHeatRating`.

### Main set vs cooldown

`mainSetDurationSeconds` counts only run and walk intervals. Cooldown and paused time are recorded
separately and are never folded in, so a long open cooldown — or a twenty-minute conversation
mid-cooldown — cannot move main-set numbers.

### Shoe mileage is derived, not stored

A shoe's total is `startingMileage` plus the distance of every run log assigned to it, so correcting
a shoe assignment corrects every total. `shoeMileageAtWorkoutMiles` in `workouts.csv` is that shoe's
odometer immediately **after** the workout on that row.

### Blank vs zero

An unlogged workout exports **blank** in every subjective column. Blank means "not logged"; it never
means zero, and zero never means "not logged" — a body-signal severity of 0 is a real answer.

### Audio cues

See **[docs/CUE_FEASIBILITY_TEST.md](docs/CUE_FEASIBILITY_TEST.md)** for the on-device test
protocols, their results, and the two documented deviations from the spec's suggested
`AVAudioSession` options (both forced by current SDK behaviour, both explained there). Background
cues rely on the `audio` background mode plus a silent keep-alive player; ducking is applied per cue
rather than for the session, so media is never left paused for the whole workout.

**Both behaviours are now verified on device, not just intended.** Cues fire through a locked screen
for a full workout, and they duck Netflix without ever pausing it — measured by comparing Netflix's
own transport position against the workout's elapsed clock across three Lock Screen captures, where
media time and wall-clock time advanced in lockstep to the second.

**Cue volume has a floor of 10%.** A stored 0 is raised to the floor on read *and reported* in
`configurationIssues`, naming the control that actually silences cues. Silently making muted cues
audible would be the worse failure: someone who deliberately muted them would discover it mid-run.
One constant (`LoggerDefaults.minimumCueVolume`) drives both the slider and the stored-value read.

**"Play cues" off means no cues.** Settings has one switch, **Play cues**. Off (`CueSource.none`)
suppresses the control confirmations — paused, resumed, skipped, ended — as well as the interval
cues. Those four once played regardless, because one condition was doing the work of two rules.

**There used to be two Watch cue sources**, "Apple Workout app" and "Watch companion", which
silenced the phone's transition cues but still confirmed taps. They were removed in the 2026-09-29
clean-out: the first only made sense alongside the removed WorkoutKit route, and the second was
never built. A phone that still has one stored reports it under "Settings that could not be read"
and plays cues from the iPhone. Exports made before then may carry `apple_workout` or
`watch_companion` in `cue_source`.

`CueSourceExplanationTests` asserts each Settings footer against `AudioCueEngine.shouldPlay`
directly, because that promise and its implementation once drifted apart with neither side able to
notice.

## Known limitations

Three companion files, kept separate because they answer different questions:

- [LEARNINGS.md](LEARNINGS.md) — measured facts that cost real time to establish. **Read it before
  changing anything that touches the Watch.**
- [MISTAKES.md](MISTAKES.md) — how past investigations went wrong, so they go wrong differently next time.
- [docs/BACKLOG.md](docs/BACKLOG.md) — wanted but not built, with the reasoning recorded.

- **No WorkoutKit.** The app no longer sends plans to Apple's Workout app; the phone's Start
  launches this app's own watch workout. The WorkoutKit screen was removed in the 2026-09-29
  clean-out after `WorkoutScheduler` never delivered on this pairing
  ([LEARNINGS.md](LEARNINGS.md#workoutkit)). Plans that were queued before then keep their
  `workoutKitIdentifier`, which is no longer written; any entry still in this iPhone's WorkoutKit
  queue stays there, unreachable.
- **Cue mode defaults to Voice, not Voice + beeps (spec §9.2 deviation).** The combined mode plays a
  tone *and* an utterance per cue and delays the speech 0.14s so the tone lands first, on a timeline
  that already packs five cues into the last five seconds of every interval. `AVSpeechSynthesizer`
  queues serially, so the extra audio pushes later cues late — heard during a run as cues
  drifting off their seconds. **This reduces the drift; it does not fix it.** Five utterances
  in five seconds still queue. The real fix is to make `IntervalTimerEngine` aware of the
  synthesizer's backlog and drop a cue that would arrive late rather than enqueuing it; until then,
  turning off **transition countdown** removes "3, 2, 1" and leaves two well-separated cues per
  boundary. Note this sits in tension with the §11.3 deviation, which turned that countdown *on*
  after a run where unannounced transitions were surprising — the two were decided from different
  runs and the next change here should settle them together. See [LEARNINGS.md](LEARNINGS.md).
- **Plans made before 2026-09-29 keep the start countdown they were saved with** — 0 unless it was
  changed by hand. The default was 0 — a spec §6 deviation —
  while a run started as two taps, the Watch then the phone, where a countdown added exactly the
  offset that start was trying to close. The 2026-09-29 clean-out restored the spec's 3 seconds,
  since Start now launches the Watch. That changes **new** plans only: each `PlannedWorkout`
  stores its own countdown, and `readInt` keeps a Settings value that was ever stored. Change an
  existing plan's countdown in its editor.
- **The phone sees only part of the Watch.** What it can see comes through this app's own watch
  link, during a run: the mirrored session's state, the heart rate the watch sends, and the watch's
  forwarded event log. It cannot see the Watch save a workout. (When the app used WorkoutKit, three
  sentences described `WorkoutScheduler`'s list — the *phone's* queue — as Watch state, and each
  misdirected a real diagnosis; see MISTAKES.md.)

- **HealthKit read permission is opaque.** iOS does not tell an app whether read access was
  granted for privacy reasons, so "Health Access Granted" means *requested*. Missing data can mean
  permission denied, type unavailable on this OS, or simply no samples exist. Re-check toggles in
  the Health app under Sharing if something you expected is absent.
- **Running dynamics** (power, stride length, ground contact time, vertical oscillation) generally
  only exist for workouts recorded with a recent Apple Watch and may be absent for older runs.
- **`runningCadence`** is not a standard HealthKit quantity identifier on current SDKs; it is
  attempted and reported under `unavailable_types` when the OS doesn't expose it. Step count and
  other running metrics still export.
- **Walking workouts are excluded by default (v1.1).** Only running workouts are read — by the
  export, the "needs a log" queue and History alike. Turn on **Include walking workouts** on the
  export screen to get them back; the setting is remembered and applies everywhere.

  Excluding them is never silent: `manifest.json` records `"walking_included": false`,
  `workout_types_to_keep` becomes `["running"]`, `export_log.json` says how many walks were
  skipped, `workout_type_counts.json` still lists every type seen in the window, and `README.txt`
  inside the ZIP explains it. A reader can always tell filtering from an empty week.

  **Caveat:** run/walk sessions occasionally record as *Outdoor Walk* rather than *Outdoor Run* —
  v1.0 included walking for exactly this reason. Any such session is now excluded too. If a run
  goes missing from the export, turn the toggle on and re-export.
- **Activity summaries** are best-effort; if the query fails the other files still export and the
  issue is noted in `export_log.json`.
- **Weather is often missing.** Apple records it only for some outdoor workouts, mostly Apple
  Watch ones. Missing weather is not an error.
- **Route authorization cannot be observed directly** — see "Route authorization reporting" above.
- **Elevation gain/loss is estimated** from noisy consumer GPS with a 1.5 m noise threshold, not
  surveyed.
- **Adding the route read type re-prompts once.** Health permission is requested per read-type
  set; because workout routes are new, the Health sheet appears one more time after upgrading
  from a build that predates routes. Without that, iOS would never ask for route access and
  routes would silently come back empty.

### v1.1

- **The cue tests have been run — three of the four.** Spec §26 Tests 1–3 were run on the physical
  iPhone, Watch and AirPods with a person listening. Protocols and full results are in
  [docs/CUE_FEASIBILITY_TEST.md](docs/CUE_FEASIBILITY_TEST.md). **Test 4 (call/Siri interruption)
  is still outstanding.**

  - **Test 1 — Apple's native Workout app: not usable on this hardware.** Its voiceover does speak
    at transitions ("previous interval: zero feet … now cool down"), so the mechanism works. But the
    field that would name the phase, `WorkoutStep.displayName`, is watchOS 11+ and this Series 5
    caps at watchOS 10, and there is no watchOS 10-legal payload that makes the Workout app say
    "run" or "walk". More decisively, **AirPods play from one source at a time**: with media playing
    on the phone, Watch-side cues are never heard at all.
  - **Test 2 — the iPhone engine: passed**, ducking included. Verified against Netflix with AirPods
    bound to the phone: cues dip the video and it is never paused.
  - **Test 3 — locked screen and backgrounded: passed.** Every cue fired on schedule; phase and
    elapsed time were correct on return.

  The iPhone engine is the app's only cue source (the Watch sources were removed on 2026-09-29),
  and that is a measured decision rather than a precaution.
- **Live Activity** (spec §12.1). The **Lock Screen card** shows the activity name, the workout
  name, an elapsed clock, a whole-workout timeline bar and a one-line plan summary. The **Dynamic
  Island** carries a subset — expanded, it shows the activity name, the elapsed clock and the
  timeline bar; compact and minimal show a running icon and the elapsed clock. Tapping either opens
  the workout screen.

  **It deliberately shows no current phase, no countdown to the next one, and no round number.**
  Those were all present and were removed. `Activity.update(_:)` applies content only while the app
  is in the **foreground**: called from the background it returns normally, throws nothing, reports
  nothing, and discards the update. So each of those elements froze and then actively contradicted
  the workout — the card read "Run 1 of 3" while the engine was demonstrably in Run 3. Updates are
  still attempted at every transition and are still discarded while backgrounded; the difference is
  that nothing on the card depends on them any more.

  What replaced them needs no updates at all. The activity state carries the **whole schedule** —
  an anchor plus one kind and one duration per phase — and the widget draws one
  `ProgressView(timerInterval:)` per phase, each filling on the system's own clock. The elapsed
  clock is `Text(timelineStart, style: .timer)`. Both derive from bounds that never move, which is
  precisely why they stay correct on a locked screen with nothing delivered. Confirmed on device.

  The plan summary reads `3 rounds · run 1:00 · walk 0:30`, with "run" and "walk" tinted to match
  their segments in the bar above — the card's only colour legend. It replaced `1:00 / 0:30 × 3`,
  which was misread as "1/0" on a real Lock Screen and conveyed no round count.

  **A countdown to the next phase change remains genuinely impossible locally.** It has to know
  which phase is current, which needs a re-render, which Live Activities do not do. Only a watchOS
  companion or APNs push breaks that ceiling, and APNs would need a server, contradicting the app's
  local-only design.

  Lives in the `RunExporterLiveActivity` widget extension; `Shared/` holds the state struct
  compiled into both targets. Requires `NSSupportsLiveActivities`, which — like `UIBackgroundModes`
  — has no working `INFOPLIST_KEY_` form and is declared in `Config/RunExporter-Info.plist`.
- **watchOS companion — installed, background execution proven, launched from the phone.** Spec §10.3 puts a custom
  `HKWorkoutSession` recorder in v1.2, gated behind the cue tests. Those tests have now run and
  split the decision rather than settling it: **Path A** (Apple's Workout app) cannot satisfy the
  audio requirement on this Watch, while **Path B** (the iPhone engine) passed. So the Watch is
  still needed, but not for audio. The resulting build plan is
  [docs/WATCHOS_RECORDER_PLAN.md](docs/WATCHOS_RECORDER_PLAN.md), scoped to its §7a: a Watch that
  starts and records the workout while **cues stay on the phone** — because AirPods play from one
  source at a time, and the phone is the source that matters when you are listening to something.

  The target now exists and ships embedded at `RunExporter.app/Watch/` — stage 1, verified in the
  signed product rather than in build settings. It first **installed on the Watch on 2026-09-25** —
  for seven weeks it had not, because the Watch was missing from the provisioning profile, not
  because Xcode could not reach it. **Stage 2's background-execution probe passed** the same day: a
  worst gap of 1.1 s between one-second ticks with the screen off. Since 2026-09-29 the phone can
  **launch the watch app** (`startWatchApp`), which needed `WKBackgroundModes` in its plist, and the
  run screen's **Start** does so for every run (plan step 2). The plan of record — phone decides,
  watch records — and its remaining steps are in the plan document; how to install, launch and read
  the watch's logs is [docs/WATCH_DEVELOPMENT.md](docs/WATCH_DEVELOPMENT.md).
- **The phone drives the Watch's workout, and a failed Watch never stops the run.** **Start**
  launches the watch app's workout (`ActiveWorkoutModel.start` → `WatchLink.beginRun`); each phase
  change is sent to it; finishing the run asks the Watch to save its workout, tagged with the
  execution id (`WatchLink.finishRun`); abandoning the run asks it to discard (`WatchLink.abandonRun`).
  The phone cannot see the save itself, so the finish screen says the Watch was *asked* to save. If
  the Watch fails to connect within 15 seconds, reports an error, or drops, the run screen says so
  and offers **Try again**, and the run carries on phone-only. The interval boundaries are still
  stored on the phone either way, which is why a phone-only run keeps them.
- **Deployment target stays at iOS 17.0.** The spec suggests iOS 18; raising it would emit a
  deprecation warning for `HKWorkout.totalEnergyBurned`, and the supported replacement
  (`statistics(for:)`) is not guaranteed to return a value for workouts saved by older HealthKit
  versions. Changing that could silently blank an already-exported column, so the target was left
  alone.
- **Nothing that runs on the Watch may use API newer than watchOS 10.** The paired Series 5 caps
  there. When the app still sent WorkoutKit workouts, a payload built on the phone was parsed by the
  Watch, and `#available` — which describes *this* device — could not stop a watchOS 11 field:
  setting `WorkoutStep.displayName` crashed and rebooted the Watch. That route is gone (2026-09-29
  clean-out). The watch app's own code is guarded by the compiler instead: its deployment target is
  watchOS 10.0, so newer API fails the build unless wrapped in `#available`.

## Privacy

No network requests, no analytics, no crash-reporting or third-party SDKs. Health data leaves the
device only through the share sheet, by your explicit action. Exported files are written to the
system temporary directory (never Documents) and deleted after sharing.

The **iPhone app** never writes to HealthKit. Its export and logger request **read** access only;
since 2026-09-25 the watch link also asks for permission to share workouts, so the phone can start
the Watch's workout, but no phone code saves anything. It reads historical workout
routes from HealthKit and never starts location services, so it needs no Core Location permission and
no `NSLocation*` Info.plist key — none is present in the built app. GPS route data is nonetheless the
most sensitive part of this export: it reveals home, work, and habitual routes and times.

**The watchOS app is the one exception, and it is deliberate.** The watch target is provisioned to
**write workouts** to HealthKit, because recording a run means saving an `HKWorkout` and there is no
read-only way to do that. The scope is as narrow as the API permits — workouts and their GPS routes,
from the watch app only. **Since 2026-09-29 the watch app also uses location**: when-in-use only, and
only while a workout runs, to save the run's route with it — what Apple's Workout app does. A run
started from the phone is saved to Health when it finishes, tagged with the phone's execution id; a
run abandoned on the phone is discarded. Nothing about how this app
handles data moves without it being written down here first.

v1.1 changes none of this. Planner, logger, shoe and interval data live in a local SwiftData store
on the device; there is no account, no sync, no cloud database and no external weather API. The
subjective log is arguably more personal than the HealthKit data — it is a record of pain and
effort — and it leaves the device only in an export you share yourself.

## License

Apache License 2.0. See [LICENSE](LICENSE).
