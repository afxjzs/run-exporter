# **Running Health App v1.1: Workout Planner, Interval Audio and Post-Run Logger**

> **Scope.** This is the v1.1 brief, and it is what every `spec §…` citation in the source refers
> to — 55 of them across 30 files. It is live in that sense, and **not** a complete statement of
> what the app now does.
>
> **It does not cover open-interval runs.** That feature was asked for and built well after this
> document was written. No section has been
> backfilled for it, deliberately: a spec records what was asked for *before* the work, and writing
> one now would invent a requirements history that did not happen. The reasoning for open intervals
> lives next to the code and in [docs/BACKLOG.md](docs/BACKLOG.md); `README.md` describes the
> behaviour.
>
> The code also diverges from this document deliberately in five places. `README.md` has the table,
> including the two that are explained in `docs/CUE_FEASIBILITY_TEST.md` rather than in the README.

## **1. Product objective**

Expand the existing native iOS HealthKit export app into a lightweight running companion that replaces the current combination of:

- Apple Watch Workout app
- TimerPlus interval timer
- Manual Notion workout log
- Periodic HealthKit data export

The app should support this end-to-end flow:

1. Define or select the planned run/walk workout on iPhone.
2. Send the structured workout to Apple Watch.
3. Start the workout.
4. Receive reliable audio cues for:
  - countdown
  - run interval
  - walk interval
  - cooldown
  - workout completion
5. Record the workout with Apple Watch and HealthKit.
6. Open the iPhone app after the workout.
7. Detect the newly completed workout.
8. Attach a quick subjective run log to the HealthKit workout.
9. Export objective HealthKit data, weather, GPS routes and subjective logs together.

The most important requirements are:

- Reliable audio cues through AirPods or the currently selected audio route.
- A fast post-run logging workflow.
- Continued use of Apple Watch for heart rate, GPS and workout recording.
- No external server.
- No account.
- No analytics.
- No manual Apple Health export.

---

# **2. Scope strategy**

Implement v1.1 using two layers.

## **2.1 Preferred workout execution path**

Use WorkoutKit to create a structured `CustomWorkout` and sync it to Apple’s native Workout app on Apple Watch.

The structured workout must contain:

- Warmup, optional
- Repeating run and walk interval steps
- Open cooldown
- Workout name and notes
- Planned interval durations and repetitions

Example:

```text
Running 4/1 × 5

Warmup:
None

Repeat 5 times:
Run 4:00
Walk 1:00

Cooldown:
Open
```

## **2.2 Audio guarantee**

Do not assume that WorkoutKit or Apple’s Workout app provides sufficiently clear spoken transition cues.

The coding agent must first test native behavior on the developer’s actual iPhone, Apple Watch and AirPods.

Required cues:

- “Starting in 3, 2, 1”
- “Run”
- “Walk”
- “Cooldown”
- Optional halfway or final-round cue
- Optional completion cue

If the native Workout app provides reliable cues with acceptable wording and routing through AirPods, use the native cues.

If native cues are absent, inconsistent or insufficient, implement the app-owned interval cue engine described below.

The finished v1.1 must provide reliable cues regardless of which implementation path is selected.

---

# **3. Existing app functionality to preserve**

Do not regress any current features.

The app currently supports:

- Fixed running-program start date of June 18, 2026
- Dynamic end date of now
- HealthKit read authorization
- Running and walking workout export
- Full-date-range export mode
- Workout-window-only export mode
- Heart rate
- Distance
- Steps
- Energy
- Running speed
- Walking metrics
- HRV
- Resting heart rate
- VO2 max
- Workout weather metadata
- HealthKit workout routes
- Route CSV files
- Route GPX files
- Route summary CSV
- ZIP generation
- Native iOS share sheet
- Temporary file cleanup
- Complete manifest file inventory
- Source diagnostics
- Valid ZIP timestamps

All existing file names and columns should remain backward-compatible.

---

# **4. Target platforms**

## **iOS app**

- Swift
- SwiftUI
- SwiftData
- HealthKit
- WorkoutKit
- AVFAudio
- Minimum deployment target: iOS 18 unless the existing app has a newer required target

## **Apple Watch**

For the initial WorkoutKit implementation:

- No custom watchOS workout recorder is required if Apple’s native Workout app meets all requirements.

If native cues fail acceptance testing:

- Add a watchOS companion target or use the iPhone-owned timer fallback described below.
- Prefer the smallest reliable implementation.

---

# **5. Primary user experience**

## **5.1 Home screen**

The home screen should contain:

```text
Running

Next Workout
4 min run / 1 min walk × 5

[Start / Send to Watch]

Recent Workout
Yesterday, X.XX mi
Log incomplete
[Log Run]

[Export Data]
```

Sections:

1. Next planned workout
2. Recent unlogged workout
3. Recent workouts
4. Export
5. Shoes/settings

## **5.2 Planned workout card**

Show:

- Workout name
- Run interval
- Walk interval
- Repetitions
- Total planned run time
- Total planned walk time
- Warmup
- Cooldown mode
- Estimated main-set duration

Example:

```text
4/1 × 5

Run: 4:00
Walk: 1:00
Rounds: 5
Main set: 24:00
Cooldown: Open
```

Actions:

- Start or send to Watch
- Edit
- Duplicate
- Mark as next workout

---

# **6. Workout plan data model**

Create a SwiftData model named `PlannedWorkout`.

Suggested fields:

```swift
@Model
final class PlannedWorkout {
    @Attribute(.unique) var id: UUID
    var name: String

    var activityType: String

    var warmupMode: String
    var warmupSeconds: Int?

    var runIntervalSeconds: Int
    var walkIntervalSeconds: Int
    var plannedRepetitions: Int

    var cooldownMode: String
    var cooldownSeconds: Int?

    var countdownSeconds: Int
    var createdAt: Date
    var updatedAt: Date

    var isNextWorkout: Bool
    var workoutKitIdentifier: String?
}
```

Supported values:

```text
warmupMode:
none
timed
open

cooldownMode:
none
timed
open
```

Default configuration:

```text
Warmup: none
Countdown: 3 seconds
Cooldown: open
```

---

# **7. Workout editor**

The user must be able to create and edit a workout in under 30 seconds.

Fields:

- Name
- Run duration
- Walk duration
- Repetitions
- Warmup:
  - None
  - Timed
  - Open
- Cooldown:
  - None
  - Timed
  - Open
- Countdown:
  - Off
  - 3 seconds
  - 5 seconds
  - 10 seconds

Presets:

```text
1/1 × 8
90/60 × 8
2/1 × 8
3/1 × 5
3/1 × 6
4/1 × 5
5/1 × 4
8/1 × 3
10/1 × 2
20 min continuous
```

Presets should be editable after selection.

---

# **8. WorkoutKit integration**

> **Implementation note, not part of the original spec:** this section was built, and then removed
> in the 2026-09-29 clean-out (`docs/BACKLOG.md`). The phone's Start now launches the app's own
> watch workout instead (`docs/WATCHOS_RECORDER_PLAN.md`). Kept as written, since this file records
> the v1.1 requirements. The §8.1 confirmation "Workout sent to Apple Watch." had already been
> dropped in `8d145b9`.

Create a `WorkoutKitService`.

Responsibilities:

- Convert `PlannedWorkout` into a WorkoutKit `CustomWorkout`.
- Create work and recovery interval steps.
- Add a repeating interval block.
- Add optional warmup.
- Add open or timed cooldown.
- Preview the workout.
- Sync or schedule it for Apple Watch.
- Persist the mapping between the local workout and the WorkoutKit object.

Conceptual mapping:

```text
PlannedWorkout
    runIntervalSeconds
    walkIntervalSeconds
    repetitions

becomes:

CustomWorkout
    warmup
    IntervalBlock:
        work step: run duration
        recovery step: walk duration
        iterations
    cooldown
```

Use the current WorkoutKit APIs available in the installed SDK.

Do not hardcode deprecated APIs.

## **8.1 Send to Apple Watch**

> **Where it went:** this button was removed in the 2026-09-29 clean-out with the rest of §8. Kept
> as written, because this file records the v1.1 requirements rather than the app.

Provide a clear action:

```text
[Send to Apple Watch]
```

After successful sync:

```text
Workout sent to Apple Watch.

Open the Workout app on your Watch and select:
4/1 × 5
```

If the current SDK supports a cleaner preview/add flow, use it.

## **8.2 Pending workout record**

When the workout is sent or started, save a `PendingWorkoutExecution`.

Suggested fields:

```swift
@Model
final class PendingWorkoutExecution {
    @Attribute(.unique) var id: UUID
    var plannedWorkoutID: UUID
    var expectedActivityType: String
    var createdAt: Date
    var expectedDurationSeconds: Int
    var status: String
    var matchedHealthKitWorkoutUUID: UUID?
}
```

Statuses:

```text
prepared
sentToWatch
started
completed
matched
cancelled
expired
```

This record will later help match the HealthKit workout to the plan.

---

# **9. Audio cue requirements**

Audio cues are a hard requirement.

The app must provide unambiguous cues for:

- countdown
- run
- walk
- cooldown
- workout complete

## **9.1 Default cue set**

Default spoken cues:

```text
3
2
1
Run

Walk

Cooldown

Workout complete
```

Optional final-round cue:

```text
Final round
```

Optional midway cue:

```text
Halfway
```

## **9.2 Cue modes**

Provide three modes:

```text
Voice
Beeps
Voice + beeps
```

Default:

```text
Voice + beeps
```

## **9.3 Suggested sounds**

Use clearly distinguishable sounds:

- Run: higher-pitched double beep
- Walk: lower-pitched single beep
- Cooldown: descending tone
- Complete: completion chime

Do not use copyrighted or bundled third-party sounds without an appropriate license.

Programmatically generated tones or original bundled assets are acceptable.

## **9.4 Audio routing**

Cues must route through:

- AirPods
- Bluetooth headphones
- Wired headphones
- iPhone speaker when no headphones are connected

Use `AVAudioSession`.

Recommended starting configuration:

```swift
let session = AVAudioSession.sharedInstance()

try session.setCategory(
    .playback,
    mode: .voicePrompt,
    options: [
        .duckOthers,
        .interruptSpokenAudioAndMixWithOthers,
        .allowBluetooth,
        .allowAirPlay
    ]
)
```

Use the current valid SDK options. Adjust if an option is unavailable or inappropriate.

Requirements:

- Cue audio must briefly duck music or podcasts.
- Music should resume after the cue.
- Audio should not permanently pause the user’s media.
- Audio should continue while the iPhone screen is locked.
- The timer should continue when the app is backgrounded.
- AirPods routing must be tested on device.

## **9.5 Speech synthesis**

Use `AVSpeechSynthesizer` for spoken cues unless prerecorded audio proves more reliable.

Configure:

- Short utterances
- Clear English voice
- Slightly elevated volume
- Moderate speech rate
- No long pre-utterance delay

Do not attempt cloud speech generation.

## **9.6 Preloaded cues**

To reduce latency:

- Prepare the speech synthesizer before the workout starts.
- Preload short sound assets.
- Avoid loading files or initializing expensive objects at the transition boundary.

Cue timing should be accurate within approximately 250 milliseconds under normal device conditions.

---

# **10. Cue architecture and fallback strategy**

The agent must complete a feasibility spike before finalizing implementation.

## **10.1 Path A: Native WorkoutKit cues**

Test whether Apple’s native Workout app:

- Clearly signals each work/recovery transition
- Routes cues to AirPods
- Works while the Watch display is asleep
- Distinguishes run from walk
- Clearly announces or signals cooldown

If native behavior passes all acceptance tests, allow a setting:

```text
Cue source:
Apple Workout
```

The iPhone cue engine can remain available as an optional override.

## **10.2 Path B: iPhone companion cue engine**

If native cues are insufficient, the iPhone app should run the interval timer and audio engine while Apple Watch’s native Workout app records the workout.

Flow:

1. User sends/selects the structured workout on Apple Watch.
2. User starts the Apple Watch workout.
3. User taps Start Timer in the iPhone app.
4. The iPhone app runs cues in the background through AirPods.
5. At completion, the app transitions to open cooldown.
6. User ends the Apple Watch workout when finished.

This is close to the existing TimerPlus workflow but removes TimerPlus and preserves the app’s planned-workout linkage.

> **Where it went:** the button below was renamed **Start Workout** in the 2026-09-29 clean-out,
> and the two-tap sequence is gone with it — one Start now launches the Watch's workout and the
> phone's timer together (`docs/WATCHOS_RECORDER_PLAN.md`). Kept as written, because this file
> records the v1.1 requirements rather than the app.

UI:

```text
Workout ready on Apple Watch

1. Start the workout on your Watch.
2. Tap Start Audio Timer.

[Start Audio Timer]
```

## **10.3 Path C: Future custom watchOS recorder**

Do not implement a full custom HealthKit watchOS workout recorder unless required to satisfy the audio acceptance criteria.

If Path A and Path B cannot provide a reliable experience, stop and report the specific limitation before expanding scope.

A future custom implementation may use:

- `HKWorkoutSession`
- `HKLiveWorkoutBuilder`
- watchOS audio
- watchOS haptics
- mirrored workout sessions
- Watch Connectivity or HealthKit mirroring

That is considered v1.2 unless absolutely necessary.

---

# **11. Interval timer engine**

Create an `IntervalTimerEngine`.

The timer must use absolute timestamps rather than only decrementing a counter once per second.

Reason:

- Background execution
- Timer drift
- Audio interruptions
- Screen locking
- App lifecycle events

Suggested state:

```swift
enum WorkoutPhase {
    case idle
    case countdown
    case warmup
    case run
    case walk
    case cooldown
    case paused
    case completed
}
```

Track:

```swift
struct IntervalTimerState {
    var phase: WorkoutPhase
    var currentRepetition: Int
    var totalRepetitions: Int
    var phaseStartDate: Date
    var phaseEndDate: Date?
    var elapsedWorkoutSeconds: TimeInterval
    var isPaused: Bool
}
```

At each update, derive remaining time from:

```text
phaseEndDate - current Date
```

Do not trust a simple decrementing integer as the source of truth.

## **11.1 State sequence**

Example `4/1 × 5`:

```text
Countdown
Run 1
Walk 1
Run 2
Walk 2
Run 3
Walk 3
Run 4
Walk 4
Run 5
Cooldown
Completed
```

There should be no walk interval after the final run unless the plan explicitly includes one.

The open cooldown begins immediately after the final run cue.

## **11.2 Pause and resume**

Support:

- Pause
- Resume
- Skip current interval
- End workout
- Restart current interval

On pause:

- Stop phase progression.
- Preserve elapsed phase time.
- Do not replay transition cues unless appropriate.

## **11.3 Countdown**

Before the workout starts:

```text
3
2
1
Run
```

For subsequent transitions, do not count down by default.

Optional setting:

```text
Transition countdown:
Off
Last 3 seconds
```

Default:

```text
Off
```

A short warning beep at five seconds remaining can be offered as an option.

---

# **12. Active workout screen on iPhone**

Show:

```text
RUN

3:42 remaining

Round 2 of 5

Next: Walk 1:00

Total elapsed: 7:18

[Pause] [Skip] [End]
```

During walk:

```text
WALK

0:42 remaining

Round 2 of 5

Next: Run 4:00
```

During cooldown:

```text
COOLDOWN

5:12 elapsed

[Finish]
```

The UI should be readable outdoors:

- Large typography
- High contrast
- Minimal controls
- Dark and light mode
- Prevent accidental destructive taps

## **12.1 Lock Screen and Live Activity**

If practical within v1.1, add a Live Activity showing:

- Current phase
- Remaining interval time
- Current repetition
- Next phase

This is useful but secondary to reliable audio.

Do not delay the core release solely for Live Activity support.

---

# **13. Interval split storage**

Store every planned and actual interval locally.

Create `WorkoutIntervalLog`.

Suggested fields:

```swift
@Model
final class WorkoutIntervalLog {
    @Attribute(.unique) var id: UUID
    var executionID: UUID

    var sequenceIndex: Int
    var phaseType: String

    var repetitionNumber: Int?
    var plannedDurationSeconds: Int?
    var actualDurationSeconds: Double

    var startDate: Date
    var endDate: Date

    var wasSkipped: Bool
    var wasInterrupted: Bool
}
```

Phase types:

```text
countdown
warmup
run
walk
cooldown
pause
```

These locally recorded interval boundaries should later be attached to the matched HealthKit workout.

This is important because HealthKit may not preserve every desired interval boundary in a form that is easy to query later.

---

# **14. Post-workout detection**

After a workout ends, the app should detect recent HealthKit workouts that have no attached run log.

Create `RecentWorkoutMatcher`.

Query:

- Running workouts
- Walking workouts
- Recent 48 hours by default

Matching priorities:

1. Pending execution expected activity type
2. Workout start time
3. Workout duration
4. WorkoutKit/local planned duration
5. Nearest unmatched workout
6. Manual user selection if ambiguous

Never silently attach a log to an uncertain workout.

If there are multiple candidates:

```text
Which workout did you just complete?

h:mm AM · Outdoor Run · X.XX mi
h:mm AM · Outdoor Walk · X.XX mi
```

---

# **15. Post-run logging flow**

After detecting an unlogged workout, display a concise log screen.

The default workflow must take about 15–20 seconds.

## **15.1 Auto-populated objective section**

Display:

- Date
- Start time
- Distance
- Main workout duration
- Cooldown duration
- Total duration
- Pace
- Average HR
- Peak HR
- Temperature
- Humidity
- Workout interval plan
- Completed repetitions
- Shoe

Do not require manual entry for values already available.

## **15.2 Required subjective fields**

### **Effort RPE**

Scale:

```text
1 = extremely easy
10 = maximum effort
```

Allow half points:

```text
5
5.5
6
6.5
```

Required field.

### **Personal heat rating**

This is separate from objective weather.

Scale:

```text
1 = felt cold
5 = thermally neutral
10 = severely overheated
```

Allow half points.

Required field.

Display objective weather nearby:

```text
Weather:
72°F · 59% humidity

How hot did it feel to you?
[1–10]
```

Call the exported field:

```text
personalHeatRating
```

Do not call it temperature RPE.

## **15.3 Body signals**

Default all to zero:

- Lower back
- Left ankle
- Right ankle
- Left knee
- Right knee

Scale:

```text
0–10
```

Use compact chips or steppers.

Example:

```text
Lower back   0
Left ankle   1
Right ankle  0
Left knee    0
Right knee   0
```

Allow tapping an area to add details:

- Beginning
- Middle
- End
- After
- Next day
- Brief/transient
- Stable
- Worsening
- Improved during walk
- Changed stride
- Free-text note

The detailed layer is optional.

## **15.4 Shoes**

Shoes must default to the most recently used running shoe.

Current expected default:

```text
On Cloudmonster 2
```

User can change it for the current workout.

When a shoe is selected:

- Persist as the default for the next relevant workout.
- Add workout distance to shoe mileage.
- Allow correcting the assignment later.

## **15.5 Notes**

Optional free text.

Example:

```text
Full sun, no shade. Felt steady throughout.
```

## **15.6 Save**

After saving:

```text
Run logged
```

The workout should disappear from the unlogged-workouts queue.

---

# **16. Run log data model**

Create `RunLog`.

Suggested fields:

```swift
@Model
final class RunLog {
    @Attribute(.unique) var id: UUID

    var healthKitWorkoutUUID: UUID
    var plannedWorkoutID: UUID?
    var executionID: UUID?

    var createdAt: Date
    var updatedAt: Date

    var runIntervalSeconds: Int?
    var walkIntervalSeconds: Int?
    var plannedRepetitions: Int?
    var completedRepetitions: Int?

    var effortRPE: Double
    var personalHeatRating: Double

    var lowerBackSeverity: Double
    var leftAnkleSeverity: Double
    var rightAnkleSeverity: Double
    var leftKneeSeverity: Double
    var rightKneeSeverity: Double

    var shoeID: UUID?
    var notes: String?
}
```

Add a separate symptom-detail model if necessary.

---

# **17. Recovery logging**

Recovery logging is optional and lightweight.

Keep it secondary to the run log: do not create a burdensome workflow.

Add an optional next-day field:

```text
Recovery today:
1–10
```

Define:

```text
10 = completely recovered / indistinguishable from a non-running day
1 = severely affected
```

Default should not be automatically selected.

Optional lingering symptoms:

- Back
- Left ankle
- Right ankle
- Left knee
- Right knee

Default zero.

Do not require a daily notification in v1.1.

---

# **18. Shoe management**

Create `Shoe`.

Suggested fields:

```swift
@Model
final class Shoe {
    @Attribute(.unique) var id: UUID
    var brand: String
    var model: String
    var displayName: String
    var firstUseDate: Date?
    var retiredDate: Date?
    var startingMileage: Double
    var isDefault: Bool
    var notes: String?
}
```

Features:

- Add shoe
- Edit shoe
- Retire shoe
- Set default
- Automatically calculate assigned workout mileage
- Show first-use date
- Show total mileage

Initial shoe:

```text
Brand: On
Model: Cloudmonster 2
Display name: On Cloudmonster 2
First use: July 17, 2026
Default: true
```

Do not hardcode this globally. Seed it only for this user’s build or let the user create it during migration.

---

# **19. Recent workouts screen**

Display:

```text
<date>
3/1 × 6
X.XX mi
RPE <rating>
Heat <rating>
<shoe name>

<date>
3/1 × 5
X.XX mi
RPE <rating>
Heat <rating>
<shoe name>
```

Filters:

- All
- Logged
- Unlogged
- Running
- Walking

Tapping a workout opens:

- Objective HealthKit data
- Weather
- Route summary
- Interval splits
- Run log
- Recovery log
- Shoe assignment
- Notes

---

# **20. Export changes**

Continue creating the existing ZIP.

Add:

```text
planned_workouts.csv
run_logs.csv
recovery_logs.csv
shoes.csv
workout_intervals.csv
```

Optional:

```text
pending_workout_executions.csv
```



## **20.1 Add subjective columns to**

`workouts.csv`

Add:

```text
plannedWorkoutID
plannedWorkoutName
runIntervalSeconds
walkIntervalSeconds
plannedRepetitions
completedRepetitions

effortRPE
personalHeatRating

lowerBackSeverity
leftAnkleSeverity
rightAnkleSeverity
leftKneeSeverity
rightKneeSeverity

shoeID
shoeName
shoeMileageAtWorkoutMiles

userNotes
nextDayRecovery
```

Leave blank when a workout has not been logged.



## **20.2**

`run_logs.csv`

Columns:

```text
runLogID
healthKitWorkoutUUID
plannedWorkoutID
executionID
createdAt
updatedAt

runIntervalSeconds
walkIntervalSeconds
plannedRepetitions
completedRepetitions

effortRPE
personalHeatRating

lowerBackSeverity
leftAnkleSeverity
rightAnkleSeverity
leftKneeSeverity
rightKneeSeverity

shoeID
shoeName
notes
```



## **20.3**

`workout_intervals.csv`

Columns:

```text
intervalLogID
healthKitWorkoutUUID
executionID
sequenceIndex
phaseType
repetitionNumber
plannedDurationSeconds
actualDurationSeconds
startDate
endDate
wasSkipped
wasInterrupted
```



## **20.4**

`shoes.csv`

Columns:

```text
shoeID
brand
model
displayName
firstUseDate
retiredDate
startingMileage
assignedWorkoutMileage
totalMileage
isDefault
notes
```

## **20.5 Manifest additions**

Add:

```json
"run_logger": {
  "planned_workout_count": 0,
  "run_log_count": 0,
  "recovery_log_count": 0,
  "shoe_count": 0,
  "interval_log_count": 0,
  "unlogged_workout_count": 0
}
```

Add:

```json
"interval_audio": {
  "cue_source": "apple_workout",
  "cue_mode": "voice_and_beeps",
  "countdown_seconds": 3
}
```

Possible `cue_source` values:

```text
apple_workout
iphone_audio_engine
watch_companion
none
```

> **Implementation note, not part of the original spec:** since the 2026-09-29 clean-out the app
> writes only `iphone_audio_engine` and `none` (Settings' "Play cues" toggle). `apple_workout` and
> `watch_companion` appear only in exports made before then.

---

# **21. Migration and existing workouts**

Existing HealthKit workouts from June 18, 2026 onward will not initially have RunLog records.

Do not require the user to backfill every prior workout.

Allow:

- Logging any historical workout
- Marking historical workouts as intentionally unlogged
- Hiding old unlogged workouts before a configurable date

Default unlogged-workout prompt window:

```text
Last 7 days
```

The user can browse older workouts manually.

---

# **22. Settings**

Add:

## **Workout cues**

- Cue source
- Voice / beeps / both
- Voice selection
- Cue volume
- Duck other audio
- Countdown duration
- Five-second warning
- Final-round announcement

## **Defaults**

- Default shoe
- Default cooldown mode
- Default activity type
- Default run interval
- Default walk interval
- Default repetitions

## **Logging**

- Show body signals
- Show recovery prompt
- Heat-rating scale explanation
- RPE scale explanation

## **Export**

Preserve existing export settings.

---

# **23. Permissions and capabilities**

## **iOS**

Required:

- HealthKit
- Audio background mode if the iPhone interval engine runs in background
- Live Activities capability if implemented
- Appropriate HealthKit read descriptions

Potential HealthKit write permission:

WorkoutKit syncing itself may not require HealthKit write access, but verify against the actual APIs used.

Do not request unnecessary write permissions.

## **watchOS**

Only required if a companion target is added.

Potential capabilities:

- HealthKit
- Workout Processing
- Audio background mode

The agent must document every new entitlement or capability.

---

# **24. Privacy**

Requirements:

- All logger data stays on device.
- Use SwiftData local storage.
- No analytics.
- No external API.
- No cloud backend.
- No account.
- No ad SDK.
- No health-data upload.
- Export occurs only through explicit share-sheet action.
- Temporary export files remain deleted after sharing or cancellation.

If iCloud sync is considered later, treat that as separate scope.

---

# **25. Error handling**

Handle:

- HealthKit unavailable
- WorkoutKit unavailable
- Watch not paired
- Watch app unavailable
- Workout sync failure
- No recent workout found
- Multiple candidate workouts
- Audio route lost
- AirPods disconnect
- Audio interruption
- App moves to background
- Device locks
- Timer resumes after interruption
- HealthKit workout sync delay
- User ends workout early
- User skips an interval
- User starts cooldown early
- User talks for 20 minutes during cooldown
- User forgets to stop the Watch workout

Do not let unusually long cooldown or pause time corrupt the stored main-set interval data.

---

# **26. Testing requirements**

## **Test 1: Native WorkoutKit cue feasibility**

Using actual iPhone, Apple Watch and AirPods:

- Create `1 min run / 30 sec walk × 3`.
- Sync to Apple Watch.
- Start in native Workout app.
- Verify every transition.
- Verify AirPods routing.
- Verify behavior with screen asleep.
- Verify open cooldown.
- Document exact native cues.

Pass only if run, walk and cooldown are unambiguous.

## **Test 2: iPhone audio fallback**

- Start the interval timer.
- Lock iPhone.
- Play music or podcast.
- Verify countdown.
- Verify run cue.
- Verify walk cue.
- Verify cooldown cue.
- Verify music resumes.
- Verify timer does not drift materially.

## **Test 3: Backgrounding**

- Start workout timer.
- Background app for full workout.
- Verify all cues.
- Return to app.
- Verify correct phase and elapsed time.

## **Test 4: Audio interruption**

- Receive a phone call or Siri interruption.
- Resume afterward.
- Verify timer state is still correct.
- Verify no duplicate cues.

## **Test 5: Post-workout matching**

- Complete workout on Apple Watch.
- Open app.
- Verify recent workout is detected.
- Verify planned workout is matched.
- Verify interval data attaches to HealthKit UUID.

## **Test 6: Logger defaults**

- Previous shoe defaults automatically.
- Body signals default to 0.
- RPE requires selection.
- Personal heat rating requires selection.
- Planned repetitions default correctly.
- Save takes less than 20 seconds.

## **Test 7: Export**

- Subjective data appears in `workouts.csv`.
- New CSV files are included.
- Manifest counts match.
- Manifest recursively lists every file.
- Existing exports remain parseable.

## **Test 8: Open cooldown**

- Complete work intervals.
- Enter open cooldown.
- Walk for five minutes.
- Stop to talk for 20 minutes.
- Finish workout.
- Main-set metrics and interval boundaries remain intact.
- Cooldown is separately identifiable.

---

# **27. Acceptance criteria**

The feature is complete when:

1. User can create `4 min run / 1 min walk × 5`.
2. The workout can be sent to Apple Watch.
3. User receives reliable audio cues through AirPods for run, walk and cooldown.
4. Audio works with phone locked and app backgrounded.
5. Apple Watch records HR, distance, GPS and workout duration.
6. The app detects the completed workout.
7. The app links it to the planned workout.
8. The user can log RPE and personal heat rating.
9. The last-used shoe defaults automatically.
10. Pain/body-signal fields default to zero.
11. The user can save the post-run log in approximately 20 seconds.
12. Interval boundaries and cooldown remain separately identifiable.
13. All objective and subjective data appears in the export ZIP.
14. Existing export behavior continues to work.
15. No external server or analytics are introduced.

---

# **28. Recommended implementation order**

## **Phase 1: Logger foundation**

1. Add SwiftData.
2. Add shoe model.
3. Add run-log model.
4. Detect unlogged HealthKit workouts.
5. Build quick post-run logging screen.
6. Add RPE.
7. Add personal heat rating.
8. Add body signals.
9. Add last-used shoe default.
10. Add logger data to export.

## **Phase 2: Workout planning**

1. Add planned-workout model.
2. Add editor and presets.
3. Convert plans to WorkoutKit.
4. Sync and preview on Apple Watch.
5. Save pending execution records.
6. Match completed workouts.

## **Phase 3: Audio feasibility and engine**

1. Test native Apple Workout transition cues.
2. Document results.
3. If sufficient, expose native-cue setting.
4. Build iPhone audio engine as reliable fallback.
5. Add background audio support.
6. Add speech and beep modes.
7. Add interval-state persistence.
8. Test AirPods, media ducking and screen lock.

## **Phase 4: Interval logs**

1. Record actual phase timestamps.
2. Store cooldown separately.
3. Export interval CSV.
4. Associate intervals with HealthKit workout UUID.

## **Phase 5: Polish**

1. Recent-workout list.
2. Settings.
3. Error states.
4. Optional Live Activity.
5. README and implementation notes.

---

# **29. Deliverables**

Provide:

1. Updated Xcode project
2. iOS SwiftUI source
3. SwiftData models
4. WorkoutKit integration
5. Workout planner and presets
6. Interval timer engine
7. Spoken and beep audio cues
8. AirPods/background-audio handling
9. Post-run logger
10. Personal heat rating
11. RPE logging
12. Body-signal logging
13. Shoe profiles and mileage
14. HealthKit workout matcher
15. Expanded export files
16. Updated manifest
17. Updated README
18. Test results for native WorkoutKit cues
19. Test results for iPhone audio fallback
20. A list of all new capabilities, entitlements and `Info.plist` entries
21. Brief implementation summary by changed file

Before building a custom watchOS workout recorder, complete and report the WorkoutKit cue feasibility test. The final v1.1 must include reliable run/walk/cooldown audio, either from Apple’s Workout app or from the app-owned iPhone cue engine.