# RunExporter: Add Aerobic Training and Heart-Rate Tracking

Implement a new aerobic-training measurement layer in RunExporter.

Read the existing project and understand the current workout, Watch, persistence, and export architecture before changing code. Reuse existing models and services where practical. Do not create parallel workout infrastructure when the existing infrastructure can support the feature.

## Product context

RunExporter is a single-user native iOS + watchOS app.

Hardware:

- iPhone 16 Pro
- Apple Watch Series 5
- Watch is limited to watchOS 10
- Do not use APIs that require a newer watchOS version.

The iPhone owns workout planning, interval timing, audio cues, persistence, and workout state.

The Watch:

- runs the HealthKit workout
- records heart rate
- records route/distance/pace where available
- displays current workout phase
- communicates with the phone during the workout
- does not make workout-plan decisions

If Watch connectivity fails, the phone workout continues.

Do not change this ownership model.

## Existing workout types

The app already supports:

1. Fixed intervals
2. Multi-block workouts
3. Open intervals

Aerobic tracking must work with all three.

Do not create a separate workout-recording pipeline for aerobic workouts.

---

# Primary goal

Add support for measuring easy aerobic training.

The first version is deliberately **measurement-first**.

Do NOT calculate a generic heart-rate Zone 2 from age.

Do NOT use formulas such as:

```text
220 - age
percentage of max HR
age-predicted max HR
```

Do NOT automatically infer that a particular BPM range is the user's Zone 2.

We are collecting enough real data to establish a personalized easy-aerobic range later.

The initial aerobic target is:

```text
RPE: 3.0–4.0
Talk test: comfortable conversation
Heart rate: observed, not prescribed
```

Heart rate should be displayed and recorded, but the app should not initially tell the runner to speed up or slow down based on HR.

---

# 1. Add workout intensity intent

Add an optional intensity/training-purpose field to a planned workout.

Use existing model conventions and naming if equivalent concepts already exist.

Conceptually:

```swift
enum WorkoutIntensityMode {
    case none
    case easyAerobicObservation
    case heartRateRange
}
```

`heartRateRange` is future-facing but should be supported by the model if doing so is clean.

An aerobic workout should be able to specify:

```text
intensityMode = easyAerobicObservation
targetRPEMin = 3.0
targetRPEMax = 4.0
targetHeartRateMin = nil
targetHeartRateMax = nil
```

Do not require an HR range for `easyAerobicObservation`.

Existing workouts must continue to behave exactly as they do now.

Migration must be safe for existing persisted data.

---

# 2. Live heart rate from Apple Watch

The Watch is already running the HealthKit workout.

Use the existing Watch workout session / live workout builder architecture to obtain current heart rate during the active workout.

Do not create a second HealthKit workout.

When a new HR value becomes available, send appropriate live telemetry to the phone through the existing Watch ↔ phone communication layer.

Conceptually, the telemetry should include:

```text
timestamp
heartRateBPM
```

If useful and already available without creating a second measurement system, also include:

```text
elapsedWorkoutTime
activeEnergy
distance
currentPace
```

Heart rate is the required metric.

## Important

The Watch's live HR telemetry is for:

- live display
- live status
- diagnostics

The post-workout HealthKit heart-rate samples remain the authoritative dataset for exported analysis.

Do not create a second permanent heart-rate database that competes with HealthKit.

---

# 3. Live HR smoothing

Raw Watch HR can jump between samples and can lag effort.

For display purposes, maintain:

```text
currentHR
smoothedHR
```

Use a simple, documented smoothing method.

For example, a short rolling time window or a small recent-sample average is acceptable.

Do not overengineer this.

The UI should make it clear which value is displayed.

Prefer the smoothed value as the large live number if it makes the display more stable.

Do not modify or smooth the underlying HealthKit data used for export.

---

# 4. Aerobic workout phone UI

When the current workout has:

```text
intensityMode = easyAerobicObservation
```

add an aerobic telemetry area to the active-workout screen.

At minimum show:

```text
Heart Rate
XXX bpm

Target effort
RPE 3–4
Conversational
```

If there is enough space without making the interface worse, also show:

```text
Current phase
Phase elapsed/remaining time
Total running time
Current pace
```

Use the existing active-workout design language.

Do not turn this into a dashboard full of tiny metrics.

Heart rate should be easy to read while running.

---

# 5. Aerobic Watch UI

Add live heart rate to the Watch workout screen.

The Watch should continue to prioritize:

- current phase
- phase timer
- workout state

Add HR without making the existing interval information difficult to read.

Something similar to:

```text
RUN
03:42

138 BPM
```

is sufficient.

Do not add HR-zone coaching or zone alerts yet.

---

# 6. Connection behavior

No silent failures.

If live Watch HR becomes unavailable during a workout:

- workout continues
- interval timer continues
- audio continues
- existing Watch connection status remains accurate
- HR display becomes clearly unavailable/stale
- do not continue displaying an old HR as if it were current

Track the timestamp of the most recent HR telemetry.

If the value becomes stale, show an appropriate state such as:

```text
HR --
```

or the project's equivalent unavailable state.

Do not show a stale BPM indefinitely.

If Watch connectivity returns, live HR should resume automatically.

---

# 7. Post-run talk test

For an aerobic-observation workout, add one lightweight subjective field to the existing post-run logging flow:

```text
Talk test
```

Options:

```text
Comfortable conversation
Short sentences
Few words
Very difficult
Not recorded
```

Use a persisted enum with stable export values.

Suggested machine values:

```text
comfortable
shortSentences
fewWords
veryDifficult
notRecorded
```

The default should be `notRecorded`.

Do not make this a long questionnaire.

Existing RPE and heat fields remain unchanged.

---

# 8. Preserve existing back/body-signal tracking

Aerobic tracking must coexist with the app's existing body-signal system.

Do not remove, simplify, or replace:

- lower-back severity
- ankle severity
- knee severity
- per-leg open-interval body signals
- baseline-reached timestamps
- workout notes

This is important because we want to analyze aerobic intensity against the back-fatigue response.

---

# 9. Post-run aerobic analysis

Add an analysis service that derives aerobic metrics from the authoritative post-workout HealthKit samples.

Do not require the live Watch telemetry to calculate these values.

Align HealthKit heart-rate samples with:

- workout start/end
- app interval boundaries
- run phases
- walk phases
- cooldown
- pauses

The app's own interval timestamps remain authoritative for determining which phase was active.

---

# 10. Per-running-interval HR metrics

For every running interval, calculate where data quality permits:

```text
hrSampleCount
averageHR
medianHR
minimumHR
maximumHR
startHR
endHR
```

Also calculate useful HR progression within the interval.

Prefer time-based calculations over simply dividing the number of HR samples.

For example:

```text
averageHRFirstHalf
averageHRSecondHalf
```

If an interval is too short or has insufficient HR data, return null rather than inventing a value.

No silent fallback values.

---

# 11. Walk/recovery HR metrics

For every walk interval, calculate:

```text
hrSampleCount
averageHR
maximumHR
minimumHR
startHR
endHR
```

Also calculate:

```text
heartRateDropAfter30Seconds
heartRateDropAfter60Seconds
heartRateDropAfter120Seconds
```

when the walk is long enough and samples are available.

Define these precisely.

For example:

```text
HR at end of preceding run
minus
HR nearest the requested recovery timestamp
```

Use a reasonable timestamp tolerance and document it.

If no suitable sample exists, export null.

This will let us compare cardiovascular recovery with the existing back-to-baseline recovery measurements.

---

# 12. Running-only workout metrics

For aerobic analysis, calculate statistics using **running phases only**.

Do not allow walk recoveries, cooldowns, or pauses to artificially lower the workout's aerobic metrics.

Calculate:

```text
totalRunningDuration
totalRunningDistance
runningAverageHR
runningMedianHR
runningMinHR
runningMaxHR
runningAveragePace
```

where data are available.

Keep whole-workout statistics too, but distinguish them clearly.

---

# 13. First-half versus second-half analysis

Calculate running-only first-half versus second-half statistics.

This must be based on **cumulative running time**, not wall-clock workout time.

Example:

If the workout contains 30 total running minutes separated by walks:

```text
first half = first 15 accumulated running minutes
second half = final 15 accumulated running minutes
```

Walk intervals must not count toward the split.

Calculate:

```text
firstHalfAverageHR
secondHalfAverageHR

firstHalfAveragePace
secondHalfAveragePace

heartRateDriftBPM
heartRateDriftPercent
paceDriftPercent
```

Clearly document the formulas.

At minimum:

```text
heartRateDriftBPM =
    secondHalfAverageHR - firstHalfAverageHR
```

Do not label HR drift alone as "aerobic decoupling."

---

# 14. Aerobic efficiency / HR-pace decoupling

Also calculate an exploratory aerobic-efficiency metric when data quality is sufficient.

We want to know whether pace relative to cardiovascular effort deteriorates during a run.

Use a documented pace/HR or speed/HR relationship.

Prefer **speed / HR** internally because speed is mathematically easier to aggregate than minutes-per-mile pace.

For example:

```text
efficiency = averageSpeed / averageHeartRate
```

Calculate:

```text
firstHalfEfficiency
secondHalfEfficiency
efficiencyChangePercent
```

Document the exact sign convention.

Do not present this as a medical measurement.

Do not call it VO2 max.

Do not make claims about aerobic fitness from one workout.

It is a longitudinal comparison metric.

---

# 15. HR data-quality metrics

We need to know when HR-derived conclusions are unreliable.

For the running portion calculate:

```text
runningHRCoveragePercent
largestHRSampleGapSeconds
hrSampleCount
```

Define coverage in a sensible way.

Also flag:

```text
insufficientHRData
```

when appropriate.

Do not generate confident drift/efficiency metrics from sparse data.

Document the threshold used.

---

# 16. Pace/GPS quality

Pace can be noisy, especially over short intervals.

Use the best existing distance/route data already available in the project.

Do not build a second GPS system solely for this feature.

Do not calculate second-by-second pace from raw GPS points unless the project already has a reliable implementation.

For aerobic efficiency, prefer stable aggregate pace/speed over each analysis window.

If distance data are insufficient, calculate the HR-only metrics and leave pace-dependent metrics null.

---

# 17. Export changes

Preserve all existing export files and columns.

Add columns where they naturally belong and add new files where this produces a cleaner schema.

## run_logs.csv

Add:

```text
intensityMode
targetRPEMin
targetRPEMax
targetHeartRateMin
targetHeartRateMax
talkTest
```

Use the project's existing conventions for planned versus completed workout fields.

## workout_intervals.csv

Add derived fields where available:

```text
hrSampleCount
averageHR
medianHR
minimumHR
maximumHR
startHR
endHR
heartRateDrop30s
heartRateDrop60s
heartRateDrop120s
```

Recovery-drop fields should be populated only where semantically appropriate.

## New aerobic_workout_summary.csv

Create one row per applicable workout.

Suggested columns:

```text
healthKitWorkoutUUID
runLogID
executionID
plannedWorkoutID
startDate

intensityMode
targetRPEMin
targetRPEMax
targetHeartRateMin
targetHeartRateMax

effortRPE
personalHeatRating
talkTest

totalRunningDurationSeconds
totalRunningDistanceMeters

runningHRSampleCount
runningHRCoveragePercent
largestHRSampleGapSeconds

runningAverageHR
runningMedianHR
runningMinimumHR
runningMaximumHR

runningAverageSpeedMetersPerSecond
runningAveragePaceSecondsPerMile

firstHalfAverageHR
secondHalfAverageHR
heartRateDriftBPM
heartRateDriftPercent

firstHalfAverageSpeed
secondHalfAverageSpeed
paceOrSpeedDriftPercent

firstHalfEfficiency
secondHalfEfficiency
efficiencyChangePercent

insufficientHRData
analysisVersion
```

Use blank/null values for unavailable data.

Do not write zero for unavailable physiological measurements.

---

# 18. JSON export

Add the same aerobic summary information to an appropriate JSON export.

Include an analysis-methodology section in the export metadata or manifest.

It should identify:

```text
analysisVersion
running-only split methodology
HR smoothing methodology for live display
HR drift formula
efficiency formula
HR data-quality thresholds
pace/distance source
```

This is important because formulas may evolve later.

---

# 19. Preserve raw data

Derived metrics must never replace raw data.

Continue exporting the underlying HealthKit heart-rate records.

The analysis should always be reproducible from:

```text
raw HR timestamps/values
workout timestamps
interval timestamps
distance/route data
subjective logs
```

---

# 20. Future personalized HR ranges

Design the data model so that later we can configure something like:

```text
Easy aerobic HR
135–145 bpm
```

but do not choose that range now.

Future `heartRateRange` mode should be able to support:

```text
targetHeartRateMin
targetHeartRateMax
```

Eventually we may add:

- Watch display of target range
- time below range
- time in range
- time above range
- delayed high/low alerts
- haptic alerts
- phone audio alerts

Do not implement HR coaching alerts in this task unless the infrastructure makes a dormant implementation trivial.

The current feature is observational.

---

# 21. Do not depend on Apple's zone definitions

Do not make this feature depend on Apple's automatic heart-rate-zone configuration.

If HealthKit exposes zone information on the deployed OS versions, it may be exported later as an additional independent data source.

For this feature, raw BPM is authoritative.

This is especially important because the Apple Watch Series 5 is limited to watchOS 10.

Verify API availability against the project's actual iOS/watchOS deployment targets before using any HealthKit API.

---

# 22. Live telemetry diagnostics

Add useful diagnostics for Watch HR telemetry.

We should be able to determine:

```text
Did Watch HR start?
When was first HR received?
When was last HR received?
How many live updates were received?
Were there connection gaps?
How long was the longest live telemetry gap?
Did Watch disconnect?
Did Watch reconnect?
```

These diagnostics can go into the existing export log or a dedicated diagnostic section.

Do not spam production logs with every HR sample unless debug logging is explicitly enabled.

---

# 23. Existing Watch failure behavior must remain intact

Regression-test:

- Watch unavailable at workout start
- Watch connects normally
- Watch disconnects mid-run
- Watch reconnects
- phone goes background
- phone locks
- pause
- resume
- skip phase
- end workout
- fixed interval workout
- multi-block workout
- open interval workout
- cooldown
- workout matching to HealthKit
- export

Aerobic tracking must not make the core workout timer dependent on Watch HR.

If HR fails, the run continues.

---

# 24. Tests

Add unit tests for the analysis layer using synthetic timestamped HR and interval data.

At minimum test:

### A. Continuous 30-minute run

Stable HR:

```text
first half 140
second half 141
```

Verify low drift.

### B. Clear HR drift

```text
first half 135
second half 150
```

Verify formulas.

### C. Interval workout

```text
5 min run
3 min walk
× 6
```

Verify that:

- only the 30 running minutes determine running HR metrics
- walks do not affect the first/second-half split
- running minute 15 is the split point

### D. Split inside an interval

If accumulated running minute 15 occurs halfway through a running interval, split that interval's HR/distance contribution correctly.

Do not simply assign the entire interval to one half.

### E. Paused workout

Paused time must not contaminate running analysis.

### F. Missing HR

Verify null metrics and `insufficientHRData`.

### G. Large HR gap

Verify coverage/gap diagnostics.

### H. Recovery HR

Verify 30/60/120-second recovery calculations.

### I. Missing GPS/distance

HR metrics should still work.

Pace/efficiency metrics should be null.

### J. Existing workout

A historical workout without any new aerobic fields must still export correctly.

---

# 25. UI regression constraint

Do not clutter the normal workout-planning UI.

A user creating an ordinary fixed/open/multi-block workout should not have to configure aerobic fields.

Intensity should default to:

```text
none
```

Aerobic configuration appears only when selected.

---

# 26. Historical analysis

Where possible, aerobic analysis should work retroactively on existing workouts.

If an old workout has:

- matched HealthKit workout
- HR samples
- app interval boundaries

the exporter should be able to calculate the new aerobic metrics even if that workout was created before this feature.

Its `intensityMode` can remain `none`.

This is important because there is already several months of useful running data.

Do not require a workout to have been labeled `easyAerobicObservation` to calculate objective HR/pace metrics.

---

# 27. Important interpretation boundary

RunExporter records and calculates.

It does not decide:

- whether the runner is fit
- whether the runner should run harder
- whether a particular HR is medically safe
- whether a BPM range is definitively Zone 2
- whether cardiac drift is good or bad
- what the next workout should be

Those decisions remain outside the app.

The app should provide high-quality measurements that make those decisions possible.

---

# 28. Documentation

Update the project's canonical documentation.

Document:

- aerobic workout intent
- live HR architecture
- authoritative data sources
- smoothing
- talk-test values
- derived metrics
- formulas
- data-quality rules
- CSV/JSON schema changes
- Watch behavior
- failure modes
- OS/hardware constraints

Make clear that:

```text
Live Watch HR = workout UI / telemetry

Post-workout HealthKit HR samples = authoritative analysis data
```

---

# 29. Implementation process

Before coding:

1. Inspect the current iPhone workout architecture.
2. Inspect the current Watch `HKWorkoutSession` / `HKLiveWorkoutBuilder` implementation.
3. Inspect Watch ↔ phone messaging.
4. Inspect current SwiftData models.
5. Inspect workout matching.
6. Inspect CSV/JSON export architecture.
7. Identify the smallest set of changes needed.

Then implement in coherent stages.

Do not rewrite working workout infrastructure merely to add aerobic tracking.

No silent failures.

If an assumption in this specification conflicts with the actual codebase, stop and document the conflict before changing architecture.

---

# Deliverables

When complete, provide:

1. Summary of the implementation
2. Files changed
3. Data-model changes and migrations
4. Live Watch HR data flow
5. Phone and Watch UI changes
6. Exact formulas used
7. Data-quality rules
8. Export schema changes
9. Tests added and results
10. Any APIs considered but rejected because of watchOS 10 compatibility
11. Known limitations
12. Example `aerobic_workout_summary.csv` row
13. Confirmation that old workouts and all three workout-plan shapes still work
14. Confirmation that Watch HR failure cannot stop or corrupt the phone interval workout

---

# Decisions

Everything above is the spec as received. This section records how its open choices were settled,
each approved by the owner, so the code, the export's methodology section (§18) and the tests all
answer to one place. Cite these as `aerobic spec, Decisions D<n>`.

## Data sources (2026-10-02 and 2026-10-03)

- **D1. Heart rate and distance come from HealthKit's samples associated with the matched
  workout**, not from a time window over every source. Measured on a real export: the iPhone writes
  a second, partial distance series inside most runs, which a window over all sources would add to
  the Watch's (LEARNINGS.md, "The iPhone writes a second distance series inside most runs").
- **D2. Legs are sliced by `RecordedRun.Leg.activeWindows`**, never by a leg's recorded start and
  end, which overlap any pause the leg absorbed (LEARNINGS.md, "A paused leg's recorded window is
  not its running time").
- **D3. Live `WatchStatus` heart rate is for display (§3–§6) and diagnostics (§22) only.** No live
  sample series is stored.
- **D4. Column and file names in §17 are final as written.** Tests assert them.

## Thresholds and formulas (2026-10-03)

Based on the Watch's sampling, measured on a real export: heart-rate samples arrive a median 5 s
apart, 99% within 9 s, and fewer than 0.5% of gaps exceed 10 s. Distance samples each span 3 s or
less.

- **D5. One tolerance, 5 s.** A heart-rate sample stands for the moments within 5 s either side of
  it. Used for coverage, for start and end readings, and for recovery readings.
- **D6. `runningHRCoveragePercent`** = the share of running time (pauses removed) that lies within
  5 s of a heart-rate sample.
- **D7. `largestHRSampleGapSeconds`** = the longest stretch of running time with no heart-rate
  sample, measured inside running legs only. A walk or pause between two runs is not a gap; the
  time from a leg's start to its first sample, and from its last sample to its end, is.
- **D8. `insufficientHRData` = true** when running coverage is under 80%, or either half's coverage
  is. Then the half-by-half heart rate, heart-rate drift and efficiency columns are blank. Running
  average, median, minimum and maximum are still written whenever any sample exists, and so are the
  speed and pace columns, which do not depend on heart rate.
- **D9. Per leg:** `hrSampleCount` is always written; 0 is a true count. The leg's other heart-rate
  columns are blank unless it has at least 2 samples and 80% coverage.
- **D10. `startHR` / `endHR`** = the sample nearest the leg's real start or end, within 5 s, from
  any leg — a point reading, like D11's; blank otherwise. A leg's real start and end are the first
  and last moments of its active windows (D2).
- **D11. Recovery drops** (`heartRateDrop30s`, `60s`, `120s`) = the preceding run's `endHR` minus
  the sample nearest 30, 60 or 120 s of wall-clock time after that run ended, within 5 s. Positive
  means heart rate fell. Written for a walk **or a cooldown** that directly follows a run. Blank if
  that moment is past the end of the walk or cooldown, if no sample is close enough, or if the run
  has no reading within 5 s of its end. Wall-clock, because recovery continues through a pause.
  These are point readings, so they use the nearest sample from any leg, and D9's gate does not
  apply to them.
- **D12. Averages are time-weighted:** every moment of the window is credited to the nearest
  heart-rate sample *inside the window* within 5 s, and a sample's weight is the time credited to
  it. A moment with no such sample is uncovered and counts toward no average. Median, minimum and
  maximum are over the samples inside the window. "Inside" is start-inclusive, end-exclusive, so a
  sample on the boundary between two legs belongs to the later one. Samples outside the window —
  a walk's, a pause's — never reach its metrics; coverage (D6) uses the same rule.
- **D13. The first and second halves split at half the cumulative running time**, pauses and walks
  excluded. The leg containing that moment is cut at it; its heart rate and distance go to each half
  by time.
- **D14. Distance in a window** = the distance samples overlapping it, each prorated by the share of
  its span inside the window. No samples means blank, never 0.
- **D15. Speed** = distance ÷ running seconds (m/s). **Pace** = 1609.344 ÷ speed (seconds per mile).
- **D16. Efficiency** = meters per heartbeat = speed ÷ (heart rate ÷ 60). This is §14's speed ÷ heart
  rate, scaled by 60 so it reads as a distance.
- **D17. Signs.** `heartRateDriftBPM` = second half − first half. Every `…Percent` change =
  (second − first) ÷ first × 100. `paceOrSpeedDriftPercent` is computed on speed, so negative means
  slower in the second half. Negative `efficiencyChangePercent` means fewer meters per beat in the
  second half.

## Which rows (2026-10-03, proposed; owner to confirm)

- **D18. A run log written before this feature exports `intensityMode`, the four target columns and
  `talkTest` blank**, not `none` and `notRecorded`. Blank means "not recorded", as `blockShape`
  does (LEARNINGS.md, "`blockShape == nil` means not recorded"). `none` and `notRecorded` are what
  a log written after the feature says.
- **D19. `aerobic_workout_summary.csv` has one row per exported workout that joins to recorded
  legs**, logged or not, aerobic or not (§26). A workout with no legs — recorded by another app, or
  before the app recorded legs — has no running phases to analyze and gets no row; the export log
  counts them.
