# watchOS companion — build plan

**Status (2026-09-29):** the plan of record below replaced the old stages. Its steps 1–3 are
**built**: step 1 is done and measured; step 2 was tested once on foot, and what that test found was
fixed; step 3 is built. **The first outdoor run driven from the phone has not happened yet**, and
it is the test for what remains unmeasured in steps 2 and 3. Written 2026-08-07; status corrected
2026-09-23, 2026-09-25 and 2026-09-29. The sections from §0 on predate the plan of record and are
kept for their reasoning; where they conflict with it, the plan of record wins.

## Plan of record — decided 2026-09-25

**This section supersedes §7a's `WCSession` design and makes the §7–§14 full recorder obsolete.**
Decided with the owner once stage 2 passed. Every API named here was checked against the watchOS
27.0 and iOS SDK headers for availability on **watchOS 10** — the Series 5's ceiling.

**Each device does what it is good at.** The iPhone 16 Pro is fast and holds all the logic; the
Series 5 is slow and has the sensors.

| | iPhone — decides | Watch — records |
|---|---|---|
| Owns | Plans, interval timer, cues to AirPods, open-interval logic, logs, notes, export | The `HKWorkoutSession`: heart rate, distance, energy, GPS route, and saving the workout |
| Decides | Every phase boundary, including when an open leg ends | Nothing. It records what the phone sends |
| Shows | The full run screen | **One screen, specified by the owner 2026-09-29:** phase, time left, heart rate, **leg pace** (the current leg's average), **mile pace — the current mile split**, i.e. pace since the last whole mile (decided 2026-09-29), and **total distance across all legs**. Zone later |
| Start | The one tap. The owner is fine starting on the phone *as long as it also starts the Watch* | Starts on its own |

**The saved workout is a real running workout.** Same `HKWorkout` type Apple's Workout app writes, in
Health and Fitness. **It must not carry less data than a standard Apple Workout run** — the owner's
requirement. The live data source collects heart rate, distance and energy on its own; the **GPS
route does not come for free** (needs `HKWorkoutRouteBuilder` fed from Core Location), and the export
already reads routes. Parity is checked by measurement: one run recorded each way, compared type by
type in the export.

**Mechanisms, all watchOS 10-legal:**

| Need | API | Availability |
|---|---|---|
| Phone launches the watch app | `HKHealthStore.startWatchApp(toHandle:)` → watch `WKApplicationDelegate.handle(_:)` | iOS 10 / watchOS 7 |
| Two-way link + live data on the phone | `HKWorkoutSession.startMirroringToCompanionDevice()`, phone's `workoutSessionMirroringStartHandler` | watchOS 10 / iOS 17 |
| Messages both ways | `sendToRemoteWorkoutSession(data:)`, `didReceiveDataFromRemoteWorkoutSession` | iOS 17 / watchOS 10 |
| Phase boundaries in the workout | `HKLiveWorkoutBuilder.addWorkoutEvents` with `.segment` / `.lap` | watchOS 4 |
| Join by id, not by time | `addMetadata` with the phone's execution id, then `finishWorkout` | watchOS 5 |

Wire format: `Shared/WatchLinkMessage.swift`, compiled into both apps, versioned, and fails loudly
on anything it does not know — `WatchLinkMessageTests`.

**Open intervals.** Every boundary the phone records is written into the Watch's workout as an event
at that instant, with no button press. This meets one of the two conditions `LEARNINGS.md` set for
reviving the withdrawn Lap request — "a record independent of the app's store" — and lands exactly
on the boundary rather than 3–49 s late. A leg-end tap on the Watch, forwarded to the phone to
decide, is a later option.

| Step | Work | The fact that ends it |
|---|---|---|
| 1 | Phone launches the Watch, the Watch mirrors back, ping/pong, heart-rate status. Test sessions are **discarded**. **DONE 2026-09-29.** Needed `WKBackgroundModes` (see [WATCH_DEVELOPMENT.md](WATCH_DEVELOPMENT.md)). Measured from the phone's diagnostic files: a **killed** watch app launched, running and mirrored **1.71 s after the tap**; first heart-rate status 3.3 s after; **ping round trip median 0.13 s** over 7 (0.06–0.21 s) | Measured on device: does it launch a closed watch app, how long to mirror, round-trip time |
| 2 | The real Start runs the phone's timer and the Watch together; boundaries become events; End saves with the execution id and the route; the Watch shows phase, time left, HR, leg pace, current mile split, total distance. **Built; tested once on foot.** Done: timing messages and `PhaseClock` (test-first); the phone side — Start launches the Watch, every engine phase change sends an anchor, finish asks the Watch to save, abandon asks it to discard, a 15 s launch timeout, and **Try again** on the run screen (the owner's ask, until the connection has a track record). Also done (build 202609291030): the watch side — the one-screen display counting down on its own clock, `PaceTracker` (test-first) for leg pace, the current mile split and total distance, each phase written into the workout as a `.segment` event, the phone's pause pausing the session, and **finish saving the workout with the execution id and the GPS route** (when-in-use location, no background-location flag — CLLocationManager.h calls setting it without that mode fatal). **The on-foot test** ([LEARNINGS.md](../LEARNINGS.md), "The first run driven from the phone"): end to end it works — the launch, every phase anchor arriving within about 0.1–0.2 s of being sent, the Watch's run screen, the save with a workout id, GPS points throughout, and the route reaching Health. Fixed after it: the latency estimate (now the smallest of three connect-time pings, `LatencyEstimate`), the Watch's countdown rounding down where the phone's rounds up, a `finishRoute` call that belongs to the workout builder, and the phone waiting out its timeout on an error the Watch had already reported. **Still unmeasured on device:** the `.segment` events in the saved workout, the join by execution id (step 3), pace and distance outdoors, and pausing. Next: an outdoor run | One real run, and a type-by-type parity check against an Apple Workout run |
| 3 | Join by execution id, the time window kept as fallback for old and Apple-Workout runs. Test-first. **Built 2026-09-29 (build 202609291331):** `WorkoutSummary.executionID` read from `WorkoutMetadataKeys.executionID`; both matcher directions let a tag win outright and never time-match a workout tagged for another run; 4 new tests. **Unmeasured:** no run has been joined this way yet — the first outdoor run is the test | A run joins with no time window involved |
| 4 | Optional: leg-end tap on the Watch | Owner's call after step 2 |

### History — the state before stage 2 ran (kept, not current)

Both paragraphs below were true when written and are not now: the watch target has grown well past
three files, and the probe **passed** on 2026-09-25 (§7a stage table, row 2).

The watch target exists and holds 449 lines across three files —
`RunExporterWatchApp.swift`, `ContentView.swift` and `BackgroundExecutionProbe.swift` — put there by
four commits (`b1cb2bc`, `ec311ac`, `87eeca9`, `46ab463`). The line above said "nothing built" for
seven weeks, contradicting `README.md`, which was right. A fresh session reading this first would
have concluded there was nothing on disk and started over.

**What has not happened is the measurement.** `BackgroundExecutionProbe` exists to answer the single
question everything after stage 2 rests on: does an `HKWorkoutSession` grant real background
execution, so a timer keeps firing with the wrist down? It has never run, because `devicectl` times
out on the paired Series 5 even when it lists as `available (paired)` — see the Xcode playbook's §3,
listed in the global `~/.claude/CLAUDE.md`. **If the probe fails, stop.** Building stages 3–6 on an
unverified assumption is the most expensive mistake available here.

---

**Audience:** a fresh session with no context from the session that wrote this. Everything needed is
in this document; the only other files worth reading first are `RUNNING_APP_V1_1_SPEC.md` §10.3 and
`docs/CUE_FEASIBILITY_TEST.md`.

---

## 0. What to build, in one paragraph

### The requirements, in the user's own words

> 1. listen to netflix on my phone
> 2. not mess with connecting airpods to watch manually every time
> 3. hear audio cues when i am running
> 4. one button, on either watch or phone, don't care…to start the workout

Point 4 means **both things at once**: the HealthKit *workout* (heart rate, GPS, recording) **and**
the interval *timer with its cues*. Today that is two presses on two devices, and because they are
two manual actions the two clocks start out of sync by however long the user took in between.
**Removing that is the entire point of this build.**

Points 1–3 are already satisfied and must not regress: the AirPods stay bound to the **phone**, so
the cues must keep coming from the phone. Do not move audio to the Watch — §1 explains why that
looks appealing and is wrong.

**Build §7a. Do not build §7–§14 by default.**

Device testing established that the audio must stay on the **iPhone**: that is where the AirPods are
during a real run, and no amount of watch-side code changes it. The Watch's job is to run an
`HKWorkoutSession` — heart rate, GPS, genuine background execution — and to **remove the second tap**
by telling the phone to start the audio timer that already works. Sections 7–14 describe a full
watch-side recorder with its own cue engine; that is a **fallback only**, and building it by default
would re-implement, on riskier ground, something the phone already does correctly.

§1 explains how that conclusion was reached. It reverses this plan's original premise, so read it
before deciding to deviate.

---

## 1. Where the feasibility tests landed — both paths have now been measured

**Both feasibility paths have now been measured on device. Do not re-run them.** Full write-ups in
`docs/CUE_FEASIBILITY_TEST.md`.

| Path | Result |
|---|---|
| **A — Apple's Workout app on the Watch** | ✅ **Speaks the phase.** Its voiceover announces both the interval just finished and the one being entered — verbatim: *"previous interval: zero feet … now cool down"* — plus a haptic. Audibility is not the problem. |
| **B — iPhone audio engine** | ✅ **Passes.** Test 3 confirmed on device: every cue fired through a locked screen, on schedule, phase and elapsed time correct on return. |

**Both paths deliver usable audio.** That is a very different starting point from the one this plan
was first drafted against, and it removes the strongest argument for building a recorder.

### ⚠️ The constraint that actually decides this: audio routing

**AirPods play from one source at a time.** The user's normal habit is a podcast from the **phone**,
which binds the AirPods to the phone. Under that condition:

- **Phone-originated cues work.** That is Path B, already built, already verified, already ducking.
- **Watch-originated cues are compromised** — Apple's voiceover *and* any custom watch app equally,
  because the limitation is the audio route, not the software.

**A watchOS recorder therefore does not improve cue audibility for the way this user actually runs.**
Moving the voice to the wrist only helps if the AirPods are serving the Watch, which they are not
when a podcast is playing from the phone.

**UNRESOLVED — measure this before committing to the build.** What happens when the Watch tries to
speak while the phone owns the AirPods? It may seize the route and pause the podcast, or it may not
play at all. Two-minute test: podcast from the phone, start the Watch workout, observe whether the
transition cue is audible and what happens to the podcast. Record the answer here.

### Confirmed by real use, not just theory

The user's own runs settle it: **the Watch cues were never heard on any previous run.** They only
became audible after manually moving the AirPods to the Watch, which is friction nobody will accept
before every run. Apple's Path A is not broken — it is *unreachable* in normal use.

**A full watch recorder would inherit exactly the same problem.** Cues spoken by our own watch code
still need the AirPods on the Watch. Moving the voice to the wrist cannot help when the wrist is not
where the AirPods are.

### ⇒ The build this project actually needs is much smaller

Audio stays on the **phone**, permanently, because that is where the AirPods live and it already
works. The Watch's job is not to speak — it is to **remove the second tap**.

| Benefit | Delivered by |
|---|---|
| Audible run/walk cues, locked screen, ducking media | **Phone** — already built and verified (Test 3) |
| Heart rate, GPS, HealthKit recording, background execution | **Watch** — `HKWorkoutSession` |
| Phase visible on the wrist | Apple's Workout app today, or a simple watch view |
| **One tap to start both** | **The only thing missing** |

**This deletes the riskiest and largest parts of the original plan.** No watch audio engine, no
watchOS `AVAudioSession` work, no cue vocabulary on the Watch, no shared interval engine — the timer
stays on the phone where it is proven. What was an eight-stage build with two make-or-break stages
becomes a much narrower one.

**See §7a for the revised architecture. The full-recorder stages that follow it are retained only as
a fallback**, for the case where the Watch genuinely must own the timer.

### One more thing worth knowing

`WorkoutStep.displayName` — the field that would let Apple's voiceover say "run"/"walk" rather than
its generic labels — is **watchOS 11+**, and setting it previously **crashed and rebooted the paired
Series 5** (see §3, gotcha 3). On a newer Watch, Path A would likely announce the intervals by name.

**⚠️ Do not test `displayName` on the Series 5 to check. That is what rebooted it.**

### What this means for scope

Spec §10.3 gates this recorder on *"if Path A and Path B cannot provide a reliable experience."*
**Path B still works**, so the spec's gate is strictly still not met — the phone can deliver correct
audio cues today, and that remains true whatever happens here.

What Path A's failure establishes is the **shape of the trade**:

- Spoken run/walk cues can only come from this project's own code. Apple's app will not provide them.
- Today that means **AirPods must be paired to the phone**, because the phone owns the voice.
- A watchOS recorder is the only way to move the voice to the wrist — letting AirPods pair to the
  Watch, showing the live phase on the wrist, and getting genuine background execution.

The second motivation is the **Live Activity display** (§12.1). iOS discards `Activity.update` from a
backgrounded app, so the Lock Screen card cannot show the current phase. That was investigated
exhaustively; see `docs/CUE_FEASIBILITY_TEST.md` for the three-run evidence and everything already
tried and disproven. The card was redesigned to show only self-correcting values, which is a real
fix but not a way to display the phase.

So this recorder is still a deliberate scope expansion beyond the spec's trigger — now a
better-informed one. Build it because the phone-tethered audio and the phase display are worth
solving, not because the spec demands it.

---

## 2. Project orientation

**Path:** the repository root (the owner's checkout lives at `~/dev/projects/run-exporter`)
**A git repo since 2026-08-07.** `e9d2755` is the baseline captured before any watch work, and each
stage since is its own commit — so there is something to roll back to, and a wizard's edits to
`project.pbxproj` are reviewable as a diff. Every stage should still leave the app in a working
state; version control makes a mistake recoverable, not free.

**Devices:**

| Device | Identifier | Note |
|---|---|---|
| iPhone 16 Pro | `<PHONE_COREDEVICE_ID>` | OS version in [INSTALLS.md](INSTALLS.md) |
| Apple Watch Series 5 | `<WATCH_COREDEVICE_ID>` | **watchOS 10.x — hard ceiling** |

**Commands:**

```bash
# Tests (run for the current count; a number written here goes stale)
xcodebuild test -project RunExporter.xcodeproj -scheme RunExporter \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

# Release build for device (the phone often reports "unavailable"; generic works).
# scripts/sideload.sh does this, clean, into the same ./build folder, and installs.
xcodebuild -project RunExporter.xcodeproj -scheme RunExporter -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath ./build \
  -allowProvisioningUpdates build

# Install, then force-relaunch (the phone must be unlocked to launch)
xcrun devicectl device install app --device <PHONE_COREDEVICE_ID> \
  ./build/Build/Products/Release-iphoneos/RunExporter.app
xcrun devicectl device process launch --device <PHONE_COREDEVICE_ID> \
  --terminate-existing is.doug.runexporter

# Pull files out of the app container — invaluable for on-device diagnosis
xcrun devicectl device copy from --device <PHONE_COREDEVICE_ID> \
  --domain-type appDataContainer --domain-identifier is.doug.runexporter \
  --source "Documents/<file>" --destination ./<file>

# The SwiftData store is readable this way too (pull .store, -wal AND -shm, then sqlite3)
```

---

## 3. Inherited gotchas — every one of these has already cost real time

1. **`INFOPLIST_KEY_*` silently does nothing for array/dictionary keys.** Xcode only maps an
   allowlist. The setting resolves under `-showBuildSettings` and produces **no key in the built
   app**, with no error. `UIBackgroundModes` and `NSSupportsLiveActivities` live in
   `Config/RunExporter-Info.plist` for this reason. **Always verify:**
   `plutil -extract UIBackgroundModes json -o - <built app>/Info.plist`

2. **The simulator's `AVAudioSession` is not the device's.** `.allowAirPlay` + `.allowBluetoothA2DP`
   on a `.playback` session is accepted by the simulator and rejected by the device with
   `paramErr (-50)`. One bad option fails the whole `setCategory`, leaving `.soloAmbient` — which
   still plays in the foreground, so cues sound fine while background playback is silently gone.

3. **`#available` describes *this* device, not the paired Watch.** `WorkoutStep.displayName` is
   watchOS 11+; guarding it with `#available(iOS 18.0, *)` compiled cleanly and **crashed and
   rebooted the Watch**. That WorkoutKit payload was removed in the 2026-09-29 clean-out, with
   `WorkoutKitServiceTests`; the watch app's own code is guarded by its watchOS 10.0 deployment
   target. **This is the single most dangerous trap for this project** — see §5.

4. **`Task { }` is not a sequential statement.** A detached cleanup `Task` scheduled before creating
   a Live Activity ran *after* it and destroyed the new activity.

5. **iOS keeps a running app on its old bundle after install.** Force-quit, or use
   `--terminate-existing`, and check Settings → Version before believing a change did not land.

6. **SwiftUI type-checker timeouts fail the Release build outright.** Long `+` chains of interpolated
   strings and stacked ternaries in view bodies have caused this three times. Extract to locals.

7. **The iPhone app never writes to HealthKit.** Its export reads only
   (`HealthKitManager.requestAuthorization`, `toShare: []`). Since 2026-09-25 `WatchLink` also
   *requests* workout share access, at the owner's direction (§6, amended); no phone code saves
   anything. The watch app writes: it saves the workout and its route.

8. **`Shared/` is a plain `PBXGroup`, not a synchronized one.** `RunExporter/` and
   `RunExporterTests/` are `PBXFileSystemSynchronizedRootGroup`s, so new files there are picked up
   automatically. **Files added to `Shared/` are not** — they need explicit `project.pbxproj`
   wiring, and the symptom is `cannot find X in scope` in the *widget* target only. Recipe in §7.

9. **Device availability flaps.** `xcrun devicectl list devices` often shows the phone as
   `unavailable`. Build with `-destination 'generic/platform=iOS'` and install when it returns.

---

## 4. What exists today

Relevant files, all currently iOS-only:

| File | Role |
|---|---|
| `RunExporter/Workout/WorkoutPhaseSchedule.swift` | Pure sequencing, incl. "no walk after the final run". `WorkoutPhaseScheduleTests` |
| `RunExporter/Workout/IntervalTimerEngine.swift` | Absolute-timestamp timer, cue emission. `IntervalTimerEngineTests` |
| `RunExporter/Audio/AudioCue.swift` | `enum AudioCue` — the cue vocabulary |
| `RunExporter/Audio/AudioCueEngine.swift` | `AVAudioSession` config. **Read the comment on `sessionOptions`** |
| `RunExporter/Models/Logger/PlannedWorkout.swift` | SwiftData plan model |
| `RunExporter/Models/Logger/LoggerEnums.swift` | `WorkoutPhase`, `WarmupMode`, `CooldownMode`, `IntervalAudioSettings` |
| `RunExporter/Views/ActiveWorkoutModel.swift` | Wires engine + audio + persistence |
| `Shared/RunWorkoutActivityAttributes.swift` | Live Activity state, compiled into app + widget |
| `Config/RunExporter-Info.plist` | The plist keys that must not be build settings |

Current signatures that matter:

```swift
// WorkoutPhaseSchedule
static func build(from plan: PlannedWorkout) throws -> WorkoutPhaseSchedule
let phases: [PlannedPhase]          // PlannedPhase: index, phase, repetition, plannedSeconds
let totalRepetitions: Int
let countdownSeconds: Int

// IntervalTimerEngine
func start(plan: PlannedWorkout, settings: LoggerDefaults, now: Date = Date()) throws
func tick(now: Date = Date())
func pause(now: Date = Date()) / resume(now:) / skip() / end() / finishCooldown()
var onCue: ((AudioCue) -> Void)?
var onIntervalCompleted: ((RecordedInterval) -> Void)?
var onFinished: (() -> Void)?
var onPhaseChanged: (() -> Void)?

// Already a value type — reuse as-is
struct IntervalAudioSettings: Sendable {
    var cueSource: String, cueMode: String
    var countdownSeconds: Int
    var fiveSecondWarning, finalRoundAnnouncement, halfwayAnnouncement: Bool
    var transitionCountdown, duckOtherAudio: Bool
}
```

---

## 5. Constraints

| Constraint | Consequence |
|---|---|
| **Watch is a Series 5 on watchOS 10.x** | Nothing newer than watchOS 10 may be used *or compiled into any payload sent to it*. `#available(iOS 18, *)` tests the **phone**. Check every watchOS API against 10.x by hand. Failure mode is a Watch reboot, not a compile error. |
| **watchOS deployment target** | Set to **10.0**. Do not let Xcode default it to 11 — that is how gotcha #3 happens again. |
| **iOS deployment target stays 17.0** | Decided: raising it deprecates `HKWorkout.totalEnergyBurned`, risking a silently blank export column. Do not change it. |
| **HealthKit write access** | **Decided and implemented** 2026-08-08 (`ec311ac`): workouts only, watch target only, iPhone stays read-only. See §6. |
| **v1.0 export is load-bearing** | `ExportBuilder`, `ZipService`, `CSVWriter`, `GPXWriter`, `RouteCSVWriter`, `WorkoutRouteExporter`, `WorkoutMetadataExporter`, `ShareSheet` stay byte-identical. |
| **Git, since 2026-08-07** | `e9d2755` is the pre-watch baseline. Commit before running any Xcode wizard — they rewrite the whole `project.pbxproj` silently. |

---

## 6. DECIDED 2026-08-08 — HealthKit write access, watch target only

The iPhone app has **never** requested HealthKit write permission, deliberately, and the README
records it as a privacy property. A custom recorder must call
`HKLiveWorkoutBuilder.finishWorkout()`, which writes.

**Approved and implemented in `ec311ac`:** write for **workouts only**, from the **watchOS target
only**; the iPhone target is unchanged and still requests `toShare: []`. Confirmed after the change
by reading the built product — the phone's Info.plist carries only `NSHealthShareUsageDescription`.
Disclosure shipped in the same commit as the capability: the README's Capabilities and Privacy
sections, and the export's own `README.txt`.

**The scoping is a standing constraint, not a one-off.** Do not add HealthKit write to the iPhone
target. The phone's read-only guarantee lives in `HealthKitManager.requestAuthorization`
(`requestAuthorization(toShare: [], read:)`), and anything that changes data handling ships its
disclosure in the same commit — the point of the rule is that nothing about it changes silently.

**Amended 2026-09-25, by the owner:** the phone may request workout share access, because the phone
now starts and controls the Watch's workout (see **Plan of record**) and the owner, the app's only
user, does not want privacy scoping to constrain that. `WatchLink.launchWatchWorkout` requests it.
Whether `startWatchApp` or mirroring strictly *needs* it is unmeasured. **The phone's code still
never writes**; the Watch saves. Disclosure shipped with the change: README Capabilities and Privacy,
the phone's `NSHealthUpdateUsageDescription`.

---

## 7a. THE RECOMMENDED BUILD — "one tap, two devices"

**Build this. The full-recorder plan in §7–§14 is the fallback, not the default.**

### Architecture

```
   Watch                                    iPhone
   -----                                    ------
   [ Start ]  ← one tap
       │
       ├── HKWorkoutSession.startActivity()      ← HR, GPS, background execution
       │    HKLiveWorkoutBuilder collects
       │
       └── WCSession.sendMessage("start", plan) ──▶  wakes the iOS app
                                                     IntervalTimerEngine starts
                                                     AudioCueEngine speaks cues
                                                     (AirPods are already here)
       ◀── "ended" ────────────────────────────────  phone finishes / user ends
       │
       └── builder.finishWorkout()               ← workout saved to HealthKit
```

**Division of labour, and why:**

- **Phone owns the timer and the audio.** Both are already built, tested, and verified through a
  locked screen. Nothing about the cue path changes, so nothing about it can regress.
- **Watch owns the workout session.** That is the one thing the phone genuinely cannot do:
  `HKWorkoutSession` is watchOS-only, and it is what produces heart rate and real background
  execution.
- **One clock.** The phone's. The Watch never runs the interval engine, so there is nothing to
  drift against.

### Why this is dramatically less work than §7–§14

| Dropped | Why |
|---|---|
| Watch audio engine + `AVAudioSession` (old stage 5) | Audio stays on the phone. **This was one of the two stages that could kill the project.** |
| Sharing `IntervalTimerEngine` / `WorkoutPhaseSchedule` to the Watch | The Watch never runs the timer |
| The `WorkoutPlanSpec` refactor (old stage 1) | Only a plan *identifier* needs to cross the wire, not the full schedule |
| Cue vocabulary on the Watch | No cues on the Watch |
| Interval logs returning from the Watch | The phone already writes them, exactly as it does today |

### Which device hosts the button — decide this before stage 4

The requirement says "either watch or phone, don't care", so pick on merit. The diagram above puts it
on the **Watch**, which is the certain option: a watchOS app can always start its own
`HKWorkoutSession`, and `WCSession` carries the start to the phone.

**But phone-initiated may be better and should be checked first.** The user is already holding the
phone to start Netflix, so a single tap there would fit the actual routine more naturally.

`HKHealthStore.startWatchApp(toHandle:)` exists for exactly this — launching the companion watch app
into a workout from iOS. Its availability has now been resolved (see **Stage 0 — resolved** below);
its *behavior* could not be measured until the watch app could receive a configuration.
*(Superseded 2026-09-29: `WatchAppDelegate.handle(_:)` receives it, and the phone launch is measured
— plan of record, step 1.)* If it works, the flow becomes:

```
iPhone [ Start ] ──▶ startWatchApp(toHandle:) ──▶ Watch launches, HKWorkoutSession starts
              └────▶ IntervalTimerEngine + cues start locally, same instant
```

That is strictly better: one tap, on the device already in hand, and both clocks start from the same
line of code rather than from two human actions. **If it does not work, fall back to the
Watch-hosted button** — the requirement is satisfied either way.

Whichever is chosen, **say in the UI which device starts what.** A button that silently starts only
one of the two is precisely the "system doing Y while the display says X" failure this project keeps
being bitten by.

### Stage 0 — resolved 2026-08-07 (availability half only)

Measured against **Xcode 26.6 / iPhoneOS26.5 + WatchOS26.5 SDKs**, by reading the framework headers
rather than the documentation. Stage 0 has two halves; only the first is answerable without a
watchOS target, and the distinction matters.

**Answered: the API is legal on this hardware. Nothing here blocks the phone-initiated design.**

| Question | Answer | Evidence |
|---|---|---|
| Does the phone-side API exist? | Yes | `HKHealthStore.h:342` |
| Correct Swift name | **`startWatchApp(toHandle:)`** — *not* `startWatchApp(with:)`, which this plan previously stated and which would not compile | `NS_SWIFT_ASYNC_NAME(startWatchApp(toHandle:))` |
| iOS availability | `API_AVAILABLE(ios(10.0))`, **not deprecated** in the iOS 26.5 SDK | `HKHealthStore.h:342` |
| Compatible with the iOS 17.0 deployment target? | Yes, comfortably — no `#available` guard needed | same |
| Does it report failure, or fail silently? | **Reports.** `completion(BOOL success, NSError *)`, and the async form is `NS_SWIFT_ASYNC_THROWS_ON_FALSE(1)`, so `try await` throws on failure | same |
| Does the watch-side receiver exist? | Yes — `handleWorkoutConfiguration(_:)` on `WKApplicationDelegate` | `WKApplication.h:69` |
| Is that receiver watchOS 10-legal? | **Yes.** `WKApplicationDelegate` is `WK_AVAILABLE_WATCHOS_ONLY(7.0)`; the method carries no later annotation | `WKApplication.h:57-69` |
| Reachable from a SwiftUI-lifecycle watch app? | Yes, via `@WKApplicationDelegateAdaptor`; no watchOS minimum beyond the protocol's | `SwiftUI.swiftinterface:7442` |

**Why the watchOS-10 row is the important one.** Gotcha #3 is exactly this class of mistake — an API
that exists on the phone and not on the Series 5's watchOS 10.6.1, guarded by an `#available` check
that interrogates the wrong device. `handleWorkoutConfiguration:` predates watchOS 10 by three major
versions, so this path clears that ceiling outright. The legacy `WKExtensionDelegate` spelling also
still exists (`WKExtension.h:86`, watchOS 3.0+), but a new target should use `WKApplicationDelegate`.

**NOT answered, and not answerable yet: does it actually work?**

Availability says the mechanism is *legal*; it does not say it *wakes a cold app on the wrist*, nor
how fast. That measurement is blocked on a precondition the stage table does not state.

**Corrected 2026-08-10.** This paragraph used to say the project had *no watchOS target at all*. That
stopped being true at `b1cb2bc`, and the target has shipped embedded at `RunExporter.app/Watch/` since
`46ab463`. What remained true then was the half that actually blocked the measurement:
`handleWorkoutConfiguration(_:)` was implemented **nowhere** in the watch target, so
`startWatchApp(toHandle:)` had nothing to receive the configuration. Implementing that handler was
the real precondition, not creating the target. *(Since done: `WatchAppDelegate.handle(_:)`.)*

Independently blocked on hardware: the paired Apple Watch measured **100% packet loss over 90
packets**, and `devicectl` cannot reach it even while it lists as `available (paired)`. Nothing in
stages 2–6 is testable until that changes.

**Therefore stage 0 cannot fully close before stage 1 — the stage table's ordering is wrong.** The
sequence that actually works is: build the stage 1 target with a trivial `handleWorkoutConfiguration`
that records receipt, *then* answer the behavioural half. Specifically still unmeasured:

- Whether it launches the app when it is **not already running**, with the Watch on the wrist.
- The **latency** from phone tap to the watch app becoming live — the same question stage 3 asks of
  `sendMessage`, and with the same consequence: a cue timer that starts eight seconds late is a
  different product, and the user must be told which one they have.
- Behaviour when the Watch is off-wrist, locked, or the app was force-quit.

**A dependency this surfaced early — and it is why §6 was decided before stage 2 rather than before
stage 5.** The header states the receiving app "can use this configuration object to create an
`HKWorkoutSession` and start it" — which is the entire point of the call. Whether starting a session
(as opposed to *saving* a workout) requires share authorization is not stated in the headers, so
rather than assume either way, write was granted to the watch target up front (`ec311ac`). **Resolved
— this no longer gates anything.** The iPhone's export still requests
`requestAuthorization(toShare: [], read: readTypes())` (`HealthKitManager.requestAuthorization`) —
**read-only**, per gotcha #7. Since 2026-09-25 `WatchLink` also requests workout share access (§6,
amended); no phone code writes.

**Recommendation: keep the Watch-hosted button as the plan of record for now.** It is the option the
architecture diagram already assumes and the one with no unmeasured launch path. Phone-initiated
remains preferred on merit and is cheap to test *once stage 1 exists* — add the call then, measure
it, and switch if it wins. Do not design stages 3–4 around it before that measurement.

**Also noted while in these headers, relevant to §7b:** `HKWorkoutSessionType.mirrored` is
`API_AVAILABLE(ios(17.0), watchos(10.0))` (`HKWorkoutSession.h:47`), so mirrored sessions *are*
available on this Series 5. That is a prerequisite for §7b's question, not an answer to it.

### Stages

**Status as of 2026-08-08:** stage 1 is done and verified, stage 2 is **built but has never run**,
and its ending fact is still outstanding. Stages 3–7 are untouched and gated on stage 2.

Note the ordering below is wrong as written and is kept for reference: stage 0 cannot fully close
before stage 1, because there was no watch app for `startWatchApp` to launch. See **Stage 0 —
resolved** above.

| # | Work | The fact that ends it |
|---|---|---|
| 0 | ~~Determine whether `startWatchApp(toHandle:)` can launch the workout from the phone on iOS 17 / watchOS 10~~ **Availability half resolved** 2026-08-07 | Available, iOS 10+, not deprecated; watch-side `handleWorkoutConfiguration(_:)` is watchOS 7+, so it clears the Series 5 ceiling. **The plan's old name `startWatchApp(with:)` does not exist and would not compile.** The latency half still needs stage 1 |
| 1 | ~~watchOS target, capabilities, plists (§8 applies unchanged)~~ **DONE** `b1cb2bc`, `031555a`, `46ab463` | Met: `plutil` confirms `UIBackgroundModes`, `WKCompanionAppBundleIdentifier` and `MinimumOSVersion 10.0` **in the signed, embedded product**. Needed an app icon before it would install at all |
| 2 | ~~Bare `HKWorkoutSession`~~ **PASSED 2026-09-25** on watchOS 10.6.2 | Read off the watch face by the owner. Wrist held still until the screen went off: **worst gap 1.1 s, 2:31 elapsed, 158 ticks, zero gaps > 2.5 s**. A second run of **over 5 minutes** with the screen going on and off: **worst gap 1.1 s, zero gaps > 2.5 s**. Two earlier runs: 1.1 s and 1.2 s. The session keeps the app executing with the screen off. It never needed Xcode to reach the Watch — the blocker was signing, see `docs/INSTALLS.md` |
| 3 | `WCSession` watch → phone: a "start" message carrying the plan id | **The phone starts its audio timer from a Watch tap while the phone is locked in a pocket** — this is the whole feature, and it is the one thing to verify before building any UI |
| 4 | Watch UI: pick a plan, Start / Pause / End | A full workout runs end to end from the wrist |
| 5 | `HKLiveWorkoutBuilder` recording and save (§6 decision made — write is granted to the watch target) | The workout appears in the Health app with sane duration and heart rate |
| 6 | Phone → watch "workout ended" so the session closes cleanly | Ending on the phone ends the Watch session; no orphaned sessions |
| 7 | **Bonus — live Lock Screen card.** See §7b. Attempt only after 1–6 work | A measured yes or no, recorded in `docs/CUE_FEASIBILITY_TEST.md` |

**Stage 3 is the make-or-break.** It rests on WatchConnectivity being able to wake the backgrounded
iOS app via `sendMessage`. That is documented behaviour, **but this project's rule is that documented
behaviour is not evidence** — the simulator accepted an audio configuration the device rejected, and
`Activity.update` returns success while doing nothing. **Prove stage 3 with the phone locked in a
pocket before building stages 4–6 on top of it.**

If `sendMessage` will not wake the app reliably, fall back to `transferUserInfo` (queued, higher
latency) and measure the delay — a cue timer that starts eight seconds late is a different product
from one that starts instantly, and the user must be told which they have.

---

## 7b. Bonus — can a Watch-owned workout make the Lock Screen card live?

**Attempt this last. Everything else must work first, and this may simply not be possible.**

### What is already known, and it is discouraging

iOS applies `Activity.update` **only while the app is in the foreground**. From the background the
call returns normally, throws nothing, and discards the content. This was established across three
instrumented device runs — see `docs/CUE_FEASIBILITY_TEST.md`, which also lists what was tried and
disproven (`NSSupportsLiveActivitiesFrequentUpdates` with `frequentPushesEnabled=true` changed
nothing; a `LiveActivityIntent` refresh button raised the passcode screen).

The card was therefore redesigned to need no updates: it carries the **whole schedule** and draws one
self-animating `ProgressView(timerInterval:)` per phase, plus an elapsed clock anchored to a fixed
start. **That already works on a locked screen and is not in question.** The only thing missing is
the *phase name in words*, because no iOS primitive swaps text on a schedule.

### The reason it is worth one attempt

A **mirrored `HKWorkoutSession`** (`startMirroringToCompanionDevice()`, watchOS 10+) delivers live
data to the iPhone app and comes with the **Workout Processing** background mode. It is plausible —
not established — that an app hosting a mirrored session is granted execution that ActivityKit
treats differently from an ordinary backgrounded app.

Apple's own Workout app does keep a live-updating Live Activity during a Watch workout, which shows
the capability exists. **It does not show that it is available to third-party apps**, and assuming so
is exactly the mistake that consumed a previous session.

### How to measure it — do not skip to a fix

The detector is already proven and takes minutes to re-instrument. `Activity.update` reports nothing,
so read the content back:

```swift
await activity.update(ActivityContent(state: state, staleDate: nil))
let landed = activity.content.state == state      // this is reliable — verified on device
```

Log `landed`, `UIApplication.shared.applicationState`, and `activity.activityState` at every push,
to a file in the app container, then pull it after a locked run:

```bash
xcrun devicectl device copy from --device <PHONE_COREDEVICE_ID> \
  --domain-type appDataContainer --domain-identifier is.doug.runexporter \
  --source "Documents/<log>" --destination ./<log>
```

**Pass:** `landed=true` with `app=background` during a mirrored session. That is the whole question.

**If it fails, stop and record it.** Do not add a push server — that requires network and contradicts
the app's local-only design — and do not re-try the ideas already listed as disproven. Write the
result into `docs/CUE_FEASIBILITY_TEST.md` either way, so the next person does not repeat it.

### If it works

Push a Live Activity update on every phase transition, and the phase name becomes live. Keep the
timeline bar regardless: it is correct with no updates at all, so it is the honest fallback for
every case where an update is dropped.

---

### Open question to resolve first (two minutes, no code)

**What happens when the Watch speaks while the phone owns the AirPods?** Start a podcast on the
phone, start a workout on the Watch, and observe whether the transition cue is audible and what
happens to the podcast. This determines whether Apple's Workout app can be left running alongside
the phone's cues without the two fighting over the route. Record the answer in
`docs/CUE_FEASIBILITY_TEST.md`.

---

## 7. FALLBACK ONLY — full recorder, stage 1: refactor the engine off SwiftData

The engine and schedule are the asset that makes this feasible, but they currently depend on
`PlannedWorkout` (SwiftData) and `LoggerDefaults` (UserDefaults), neither of which belongs on the
Watch. **This is a pure refactor with the existing test suite as the safety net** (138 tests when this was written), and it is worth doing
even if the watch app is later abandoned.

### 7.1 Introduce `WorkoutPlanSpec`

New file `Shared/WorkoutPlanSpec.swift`:

```swift
/// A plan as pure data — everything the interval engine needs and nothing it does not.
/// Crosses to the Watch and decouples the engine from SwiftData.
struct WorkoutPlanSpec: Codable, Equatable, Sendable {
    var name: String
    var activityType: String        // PlannedActivityType raw value
    var warmupMode: String          // WarmupMode raw value
    var warmupSeconds: Int?
    var runIntervalSeconds: Int
    var walkIntervalSeconds: Int
    var plannedRepetitions: Int
    var cooldownMode: String        // CooldownMode raw value
    var cooldownSeconds: Int?
    var countdownSeconds: Int
}
```

Raw strings rather than the enums so the type stays dependency-free; the schedule builder already
validates them and **throws** on an unrecognised value (`ScheduleError.unknownWarmupMode` etc.).
Keep that behaviour — it is deliberate, and silently substituting a default would be worse.

### 7.2 Change the seams

- `PlannedWorkout` gains `var spec: WorkoutPlanSpec` (a computed property mapping its fields).
- `WorkoutPhaseSchedule.build(from:)` takes `WorkoutPlanSpec` instead of `PlannedWorkout`.
- `IntervalTimerEngine.start(...)` takes `spec: WorkoutPlanSpec, settings: IntervalAudioSettings`.
  `LoggerDefaults` already exposes an `IntervalAudioSettings` — find the existing conversion and
  reuse it rather than writing a second one.
- Call sites to update: `ActiveWorkoutModel.start(plan:)` and the tests. (`WorkoutKitService` was
  one too, until the 2026-09-29 clean-out removed it.)

### 7.3 Move files to `Shared/`

Move `WorkoutPhaseSchedule.swift`, `IntervalTimerEngine.swift`, `AudioCue.swift`, and the
`WorkoutPhase` / `WarmupMode` / `CooldownMode` / `IntervalAudioSettings` declarations into `Shared/`.

`WorkoutPhase` etc. currently live in `LoggerEnums.swift` alongside logger-only types. Split the
shared enums into `Shared/WorkoutEnums.swift` and leave the rest.

**Then wire each moved file into every target that needs it** — `Shared/` is a plain group (gotcha
#8). For each new file, edit `RunExporter.xcodeproj/project.pbxproj`:

```
# 1. PBXFileReference section — one entry
AA00000000000000000000NN /* Foo.swift */ = {isa = PBXFileReference;
    lastKnownFileType = sourcecode.swift; path = Foo.swift; sourceTree = "<group>"; };

# 2. PBXBuildFile section — ONE PER TARGET, each with its own id, same fileRef
AA00000000000000000000N1 /* Foo.swift in Sources */ = {isa = PBXBuildFile;
    fileRef = AA00000000000000000000NN /* Foo.swift */; };
AA00000000000000000000N2 /* Foo.swift in Sources */ = {isa = PBXBuildFile;
    fileRef = AA00000000000000000000NN /* Foo.swift */; };

# 3. Add the fileRef to the `Shared` PBXGroup children
# 4. Add each build file id to the corresponding target's PBXSourcesBuildPhase `files` list
```

Ids in this project follow `AA00000000000000000000XX`; pick unused ones.

**Verification for stage 1:** the whole suite passes, and the iPhone app runs a full workout on device
with identical behaviour. No watch code exists yet.

---

## 8. Stage 2 — watchOS target and capabilities

- Add a **watchOS App** target, `RunExporterWatch`, bundle id `is.doug.runexporter.watchkitapp`.
- **Set the deployment target to watchOS 10.0 by hand.**
- Create `Config/RunExporterWatch-Info.plist` — **not** `INFOPLIST_KEY_*` build settings:

```xml
<key>UIBackgroundModes</key>
<array>
    <string>workout-processing</string>
    <string>audio</string>
</array>
<key>NSHealthShareUsageDescription</key>
<string>…</string>
<key>NSHealthUpdateUsageDescription</key>
<string>…</string>
<key>WKCompanionAppBundleIdentifier</key>
<string>is.doug.runexporter</string>
```

- Add the HealthKit capability and the **Workout Processing** background mode to the target's
  entitlements.
- Add the shared files from stage 1 to the watch target's sources.

**Verification for stage 2 — do not skip:**

```bash
plutil -extract UIBackgroundModes json -o - \
  "./build/Build/Products/Release-iphoneos/RunExporter.app/Watch/RunExporterWatch Watch App.app/Info.plist"
# must print ["workout-processing","audio"]
```

Plus a trivial view visible on the Watch. Gotcha #1 has bitten this project twice; a missing
background mode here would make stage 3 fail for a build-configuration reason that looks exactly
like a HealthKit problem.

---

## 9. Stage 3 — bare `HKWorkoutSession` (the foundational proof)

**Build nothing on top of this until it is verified.** Everything else assumes background execution
works; if it does not, stop and report.

```swift
let configuration = HKWorkoutConfiguration()
configuration.activityType = .running
configuration.locationType = .outdoor

let session = try HKWorkoutSession(healthStore: store, configuration: configuration)
let builder = session.associatedWorkoutBuilder()
builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)

session.startActivity(with: Date())
try await builder.beginCollection(at: Date())
```

Add a repeating timer that appends a timestamped line to a file in the watch app's container.

**Verification:** start it, **lower your wrist and let the screen sleep for five minutes**, then
confirm the log has entries spanning the whole period with no gaps. Pull it with `devicectl copy
from` against the watch app's container, the same way `docs/CUE_FEASIBILITY_TEST.md` did on iOS.

A gap here means background execution is not working and the entire premise fails.

---

## 10. Stage 4 — run the shared engine inside the session

Drive `IntervalTimerEngine` from a `RunLoop.main` timer inside the live session, exactly as
`IntervalTimerEngine.startTicker()` does on iOS. The engine is already drift-proof: it derives
everything from absolute timestamps, so a late tick cannot accumulate error.

`onIntervalCompleted` appends to an in-memory array for stage 7.

**Verification:** the logged transitions match the plan's boundaries, wrist down, for a full
`1/0:30 × 3` workout.

---

## 11. Stage 5 — watch audio and haptics (the second stage that can kill the project)

Two independent channels:

- **Haptics:** `WKInterfaceDevice.current().play(.notification)` — distinct types for run vs walk.
- **Audio:** an `AVAudioSession` on the Watch routed to AirPods paired **to the Watch**.

Re-read gotcha #2 before configuring the session. Reuse `AudioCueEngine.sessionOptions(ducking:)`
only after confirming each option is valid for watchOS — **the watch audio stack is not the phone's,
and the phone's own option set was already rejected by the phone once.** Write the watchOS
equivalent of `AudioSessionConfigurationTests`, which asserts the real session accepts the
configuration rather than trusting a reading of the documentation.

**Verification:** cues audible through AirPods paired to the Watch, wrist down, run vs walk vs
cooldown each unambiguous **by ear alone**. Same bar as spec §26 — a haptic that means run and a
haptic that means walk are the same haptic.

---

## 12. Stage 6 — recording and saving

The §6 gate is cleared: HealthKit write is granted to the watch target (`ec311ac`). Keep it scoped
there — do not extend it to the iPhone.

```swift
session.end()
try await builder.endCollection(at: Date())
let workout = try await builder.finishWorkout()
```

**Verification:** the workout appears in the Health app with plausible duration, distance and heart
rate, and the iPhone's existing export picks it up with no export-code changes.

---

## 13. Stage 7 — `WCSession` both directions

- **Plan out (phone → watch):** `transferUserInfo` with the `WorkoutPlanSpec` as JSON. Use
  `transferUserInfo`, not `sendMessage`: it is queued and delivered even when the Watch is
  unreachable.
- **Intervals back (watch → phone):** `transferUserInfo` at workout end, carrying the interval array
  keyed by an **execution UUID** so a re-delivery cannot double-insert. Idempotency matters —
  `transferUserInfo` can deliver more than once.
- On the phone, insert into the existing `WorkoutIntervalLog` table. **No export changes** —
  `workout_intervals.csv` already has the schema.

**Verification:** a plan created on the phone starts on the Watch; its intervals appear in the
phone's History and in an exported `workout_intervals.csv`.

---

## 14. Stage 8 — optional: mirroring and phone-side live UI

`session.startMirroringToCompanionDevice()` is **watchOS 10+**, so it is usable here. It is the only
plausible route to a live iPhone screen during a Watch-owned workout.

**Whether a mirrored session also grants the phone the right to update a Live Activity is unknown
and must be measured, not assumed.** Assuming exactly this kind of thing is what cost the previous
session repeatedly. Instrument it, put a locked run through it, read the log, and record the result
in `docs/CUE_FEASIBILITY_TEST.md` whichever way it goes.

---

## 15. Risks, ranked

**Risks 2, 3 and 5 apply mainly to the §7–§14 fallback. The §7a build carries far less of this**, and
that reduction is the main reason to prefer it.

0. **`WCSession.sendMessage` may not reliably wake the backgrounded iOS app** — §7a stage 3, the one
   thing the recommended build depends on. *Mitigation: prove it with the phone locked in a pocket
   before building anything on top; fall back to `transferUserInfo` and measure the added latency,
   which changes what the feature is.*
1. **watchOS 10 compatibility.** Most current sample code targets watchOS 11+. The failure mode is a
   Watch reboot, not a compile error. *Mitigation: for code on the Watch, the watch target's
   watchOS 10.0 deployment target makes newer API a compile error. (For the removed WorkoutKit
   payload, built on the phone, `WorkoutKitServiceTests` did this job.)*
2. **HealthKit write access.** Reverses a standing privacy decision. *Mitigation: §6, decided
   explicitly, documented in the README.*
3. **Two HealthKit workouts for one run.** If the user also starts Apple's Workout app out of habit,
   two overlapping workouts land in HealthKit and the export shows both. *Mitigation: detect
   overlap and surface it — never silently merge or drop.*
4. **Device-only verification.** Every meaningful claim needs the physical Watch. The simulator has
   already been shown to accept audio configuration the device rejects.
5. **Scope.** The largest single addition to the project so far, for a display problem the spec did
   not gate it on. Section 1 exists to make sure that trade is made knowingly.

---

## 16. Explicitly out of scope

- Any change to the v1.0 export pipeline.
- Independent (phone-free) Watch operation — plans still originate on the phone.
- Replacing the iPhone audio engine. It passed Test 3 and remains the phone-only path.
- Complications, Smart Stack, or a Watch-side plan editor.
- Raising the iOS deployment target.
