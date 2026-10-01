# Learnings

Durable facts about this project that cost real time to establish. Each entry says what was
**measured**, not what was assumed, and dates it — several of these are true of a specific hardware
pairing and may stop being true when that changes.

Companion file: [MISTAKES.md](MISTAKES.md) — process errors worth not repeating.

---

## WorkoutKit

**The app no longer uses WorkoutKit.** Its "Send to Apple Watch" screen (`SendToWatchView`,
`WorkoutKitService`) was removed in the 2026-09-29 clean-out, because the phone's Start now
launches this app's own watch workout and using both records two workouts
([docs/BACKLOG.md](docs/BACKLOG.md)). The measurements below stay as the record of why, and as the
starting point if WorkoutKit is ever brought back.

### `WorkoutScheduler` does not deliver on iOS 26.6 ↔ watchOS 10.6.1 (2026-08-13)

Measured on iPhone 16 Pro (iOS 26.6) paired to Apple Watch Series 5 (watchOS 10.6.1):

- **Four workouts scheduled through `WorkoutScheduler.schedule(_:at:)` never reached the Watch.**
  One sat undelivered for 26 hours. Two were workouts the Watch had never seen, so "it was already
  there" cannot explain anything.
- **Radio state at send time made no difference.** One was sent with Wi-Fi and Bluetooth off, one
  with both on. Neither arrived. The queue does not flush when connectivity returns.
- **`removeAllWorkouts()` could not clear them either.** The count stayed at 4 across refreshes and a
  restart. The store accepts writes and then neither delivers nor forgets them.
- Permission was `authorized` throughout, the Bluetooth link was alive (Ping iPhone worked), and the
  payload was valid — see below.

This **worked in early August** (see `docs/CUE_FEASIBILITY_TEST.md`, Test 1) with the same code, so
it is a state or OS-version failure, not a logic one. The send path has not changed since the initial
commit.

### `WorkoutPlan` via `.workoutPreview` **does** deliver (2026-08-13)

The same `90/60 × 8` that never arrived via `schedule(_:at:)` arrived when added through Apple's own
preview sheet, minutes apart, same phone and Watch. Apple documents these as distinct: `WorkoutPlan`
is "a wrapper around a workout object that your app can use to **open the object in Workout** or
schedule it for later."

**This is why `SendToWatchView` made "Add to Apple Watch" the primary action** and demoted
scheduling. The screen and that button went in the 2026-09-29 clean-out, along with the whole
WorkoutKit route; the measurement below is why, and still stands if it ever comes back. Do not
reverse it without re-measuring.

The cost is real and is stated in the UI: Apple's sheet reports nothing back, so the app cannot
confirm the outcome. An unverifiable action that works beats a verified one that does not.

**The add route has no matching remove.** A workout added through the sheet lands in the Watch's own
library, not in this app's WorkoutKit schedule, so `removeAllWorkouts()` and `remove(identifier:)`
cannot reach it — they only touch what the app *scheduled*. Everything added this way has to be
deleted on the Watch by hand (three-dot menu → custom workouts). Do not add a "clear what I sent"
button for this route; there is no API behind it.

### The payload was never the problem

Apple's preview sheet rendered `90/60 × 8` exactly as `makeCustomWorkout` builds it — **Repeat ×7
(Work 1:30 / Recovery 1:00), then a standalone Work 1:30, then open Cooldown.** That is visual
confirmation of the block structure *and* of the "no walk after the final run" rule (spec §11.1).

### Where a delivered workout actually appears

Under **Outdoor Run**, behind the three-dot menu, filtered to custom workouts. **Never** on the main
list you get when pressing the workout button.

The only workout on that main list was one **created on the Watch itself**. WorkoutKit exposes no API
for placement — the entire surface is `schedule`, `markComplete`, `remove`, `removeAllWorkouts`. So
an app most likely **cannot** put a workout on the Watch's main screen at all. Editing a Watch-native
workout by hand is not a workaround; it may be the only mechanism that does that.

### `scheduledWorkouts` is the phone's list, not the Watch's

`WorkoutScheduler.shared.scheduledWorkouts` is documented as "all the workouts scheduled by **your
app**". Three consequences, all of which have already caused bugs here:

1. **It cannot see the Watch.** Reading it back proves the phone recorded the schedule and nothing
   more. No UI may describe it as Watch state — that mistake shipped in three separate sentences and
   sent the owner hunting for a failed send that had succeeded.
2. **It cannot reach another app's workouts, or ones created on the Watch.** `removeAllWorkouts()`
   will never delete those, so "try again" is the wrong advice for a non-zero remainder.
3. **`complete` means completed, not delivered.** A workout that arrived and was never performed
   stays `complete == false` forever. Do not read it as a delivery signal.

### `date` is an appointment, not a marker

Apple documents `ScheduledWorkoutPlan.date` as "when the workout should begin". The app originally
scheduled at `Date()` — the minute already in progress, in the past before the Watch could receive
it. Now `Date() + scheduleLeadSeconds`, and the chosen time is shown in the UI.

**Whether watchOS suppresses a past-dated workout is still unverified.** It was not the cause of the
delivery failure, since future-dated sends failed identically.

---

## Our own watch app (2026-09-25 to 2026-09-29)

Watch: Series 5, watchOS 10.6.2. The procedure is [docs/WATCH_DEVELOPMENT.md](docs/WATCH_DEVELOPMENT.md);
these are the facts it rests on.

### The watch app never installed, for seven weeks, because the Watch was not in the profile

From 2026-08-08 every build's watch app was signed with a profile whose `ProvisionedDevices` listed
two iPhones and not the Watch. Xcode registers a device when it connects to it, and this Watch has
never held a connection. The iPhone's Watch app listed the app under Available Apps; Install filled
the ring and turned back into "Install" **with no message**. The Watch's reason was in the phone's
`appconduitd` log: `0xe8008015 (A valid provisioning profile for this executable was not found.)`.

Registering the Watch on the portal was not enough: `-allowProvisioningUpdates` kept using the cached
profile, which was still valid. Removing it from Xcode's cache made the next build fetch one that
listed the Watch. The app icon fix of `46ab463` was real but was not why installs failed.

### An incremental build can leave a nested app with a stale signature

After the profile changed, an incremental build copied the new `embedded.mobileprovision` into the
watch app and did not re-sign it — the build log has no `CodeSign` step for the watch target. The
Watch refused it: `0xe8008017 (A signed resource has been added, modified, or deleted.)`.
`codesign --verify --deep --strict` on the **outer** iPhone app reported `valid on disk`. Only
verifying the nested bundle itself showed `file modified: …/embedded.mobileprovision`. A clean build
fixed it; `scripts/sideload.sh` now builds clean and checks the nested bundle.

### Developer Mode appears only after a development app is installed

There was no Developer Mode row on the Watch until the first successful install. Launching the app
then asked for it, and the row was there. Xcode never connected to the Watch.

### An `HKWorkoutSession` keeps the watch app running with the screen off (stage 2)

Worst gap between one-second ticks: 1.1 s over 2:31 with the wrist still and the screen off; 1.1 s
over more than 5 minutes with the screen going on and off; zero gaps over 2.5 s in any run.

### A phone launch needs `WKBackgroundModes`, not just `UIBackgroundModes`

With `workout-processing` only under `UIBackgroundModes`, `startWatchApp(toHandle:)` reached the
Watch — the phone's `healthd` logged `Starting workout app is.doug.runexporter on watch`, sent it to
`My Watch (active)` (the device name, changed here), and received the Watch's `Start Workout App response` 0.38 s later — and watchOS
**never launched the app**: the watch's saved event log recorded no process start and no
`handle(_:)`. Adding `WKBackgroundModes` = `["workout-processing"]` was the only change in the next
build, and that build launched. WatchKit exports `_SPInfoPlistWKBackgroundModesKey` and
`…WorkoutProcessingValue`, and Xcode's watch Background Modes capability writes that key — the plist
here had been written by hand. A session started from the watch's own screen (the probe) worked
without it.

### `startWatchApp` succeeding means "sent"

The phone's completion arrived before the Watch's reply did, and reported success on every attempt,
including all the ones where the Watch launched nothing. Same lesson as `WorkoutScheduler.schedule`
above: a paired-device API returning cleanly has said nothing about the other device.

### Watch installs are slow, and one hung with the Watch asleep

The copy is quick — 317 KB in about 4 s — and the Watch's own install step is not. Once, started with
the Watch asleep on its charger, the phone logged `Install … was not acknowledged in 60 seconds` and
the Watch stuck on "Uninstalling…" after a cancel. A restart and a reinstall on the wrist worked.
Sleep as the cause is not established.

### The installed watch build is provable

`appconduitd` logs `watchKitAppExecutableHash` on a finished install. It is the SHA-256 of the watch
executable: `813dfe89…` matched `shasum -a 256` of the local build exactly on 2026-09-25.

### The first run driven from the phone (2026-09-29, build 202609291030)

A short test on foot, read from the phone's `watch-events.log` and `watch-link-phone.log`:

- **It works end to end.** Launch, six phase anchors each arriving within about 0.1–0.2 s of being
  sent, the Watch's run screen, the save with a workout id, and GPS points recorded throughout.
- **The first ping on a fresh link is slow.** 1.71 s, against a 0.13 s median once warm — the first
  message waits for the channel. Taking the median of that one sample made the Watch subtract 0.86 s
  it should not have. The estimate is now the *minimum* of three connect-time pings
  (`LatencyEstimate`).
- **Two countdowns disagreed by rounding.** The phone's `Display.countdown` rounds up; the Watch's
  screen rounded down — up to a second apart on their own. Both round up now.
- **A route builder from `seriesBuilder(for:)` is finished by the workout builder.** Calling
  `finishRoute` on it fails with "This route builder is attached to a workout builder and will be
  finished with the workout builder". The header says as much; the call was ours to drop. **The
  route reached Health regardless** — the owner saw it on the workout in the Health app — so the
  error was about our call, not the route.
- **A new Health type means a new permission, in the foreground.** Adding route sharing made the
  Watch's launch-time check report "would prompt"; it stopped and said so, as designed. The phone
  still waited out its 15 s timeout, although the Watch's error reached it 2.5 s after the tap —
  the phone now shows that error as soon as it arrives.

### The first outdoor run driven from the phone (2026-09-30, build 202609291331)

Read from both logs; specifics in `private/run-notes.md`. The run worked — launch, every phase but
one, the save with its GPS route — and found three things:

- **The watch's own launch error can arrive too late to use.** Forwarded log lines travel by
  `WCSession.transferUserInfo`, which the system queues: the watch's "Health access not granted yet"
  reached the phone **35 s** after the tap, long after the 15 s timeout had fired with no reason. The
  2026-09-29 fix (show the watch's error as soon as it arrives) works only when it arrives in time.
  The timeout message now names the likely cause and fix itself. **Try again** then connected in
  about 2 s — the button earned its keep on the first real run.
- **A phase message can fail to send, and nothing retried it.** One "Remote device is unreachable"
  left the watch showing the previous walk through an entire run leg, and the saved workout's walk
  segment covers that run. The phone's screen still said the Watch was recording. The phone now
  marks the phase unsent, says so on the run screen, and resends the current phase when the next
  watch status proves the link is back (`WatchLink.phaseUnsent`). Watch → phone sends failed
  several more times in the run's last 15 minutes; **why the link was patchy then is not known.**
- **A saved workout's screen kept counting.** The watch saved and stopped its session, but its run
  screen stayed up and counted the open cooldown up, so it read as a workout still in progress.
  It now freezes and says "Workout saved" (`WatchWorkoutController.outcome`).

### The install after it, and a short test (2026-09-30, build 202609301411)

Read from both logs; specifics in `private/run-notes.md`.

- **The Watch needed Health access again after this install.** The first two launches from the
  phone stopped at status 1 ("would prompt"). The owner allowed it on the Watch, and the next Try
  again connected in about half a second. This build added no Health type; its watch plist's
  `NSHealthUpdateUsageDescription` wording changed. Which of the two — the reinstall or the new
  wording — caused the re-prompt is **not established**. Expect it after a watch install until
  it is.
- **The watch's refusal reached the phone within about a second** this time, so the run screen
  showed the watch's own reason, not the timeout. The first outdoor run's took 35 s. Delivery by
  `transferUserInfo` varies that widely; the timeout's wording is still untested on the devices.
- **"Workout saved" works on the Watch**: the save completed a few seconds after Finish, with its
  route, and the screen said so.
- **Walks recorded as walks: not tested.** The test plan's Activity was Running; both logs agree
  (the phone's `activity running`, the watch's activity 37, which is `HKWorkoutActivityType.running`).

---

## Audio cues

### Cues drift off their seconds because speech queues and the scheduler doesn't know (2026-08-14)

Heard during a run: cues near the end of each interval arrive unevenly spaced, and it is worse the
more of them there are.

**Mechanism.** `AVSpeechSynthesizer.speak()` **queues serially** — it never drops or interrupts an
utterance to play a newer one. But `IntervalTimerEngine.scheduledCues(for:start:)` lays cues out on a
timeline that assumes playback is instantaneous. That assumption holds for a 200 ms beep and fails
for speech. When an utterance runs longer than the gap to the next cue, everything behind it shifts,
and a cue scheduled for T−3 is heard at T−3.4.

**The density that exposes it.** With the shipped defaults, the last five seconds of *every* timed
interval carry five cues:

| Time | Cue | Spoken |
|---|---|---|
| T−5 | `.nextPhase(next, 5)` | "Walk in 5" |
| T−3 / −2 / −1 | `.countdown(3/2/1)` | "3" "2" "1" |
| T−0 | entry cue | "Walk" |

The final run is worse: `entryCues` returns `[.finalRound, .run]` back to back with no gap, so
"Final round" and "Run" are enqueued in the same instant.

**Why the drift is invisible in the logs.** `fireDueCues` drops a cue only when its `fireDate` is
more than 1.5 s in the past. That guards a late *timer*, not a backed-up *synthesizer* — the engine
hands the cue to the audio layer on time and considers it fired. Every cue looks punctual in the
timing log while sounding late in the ears. **A timing log that cannot observe the output stage is
not measuring what the user hears.**

**What was changed (2026-08-14):** the default `cueMode` is now `.voice` rather than
`.voiceAndBeeps`. The combined mode plays a tone *and* an utterance per cue, with a 0.14 s
`preUtteranceDelay` on the speech so the tone lands first — doubling the audio events and
lengthening each one. The voice already carries the whole meaning; the tone only adds queue pressure.

**This reduces the problem and does not fix it.** Five utterances in five seconds still queue. The
real fix is to make the engine aware of the synthesizer's backlog and drop a cue that would arrive
late instead of enqueuing it. Until that exists, turning **transition countdown** off removes the
"3, 2, 1" and leaves two well-separated cues per boundary.

**Careful with defaults.** `LoggerDefaults.readEnum` returns the stored `UserDefaults` value whenever
one exists, so changing a default in code only reaches installs that have never touched that setting.
Changing a default is not the same as changing behavior for an existing user, and saying otherwise
would be exactly the kind of silent deviation this project is built to avoid.

---

## Plans of several shapes

### A half-block-aware app is worse than a single-shape one (2026-09-07)

`PlannedWorkoutBlock` and `resolvedBlocks` landed in `3069029` with the schedule and the duration
properties reading them. **Eight other places still read the flat `runIntervalSeconds` /
`walkIntervalSeconds` / `plannedRepetitions` fields**, found by grepping for those three names
before building the editor. Every one was wrong for a plan of several segments, and none would have
crashed:

| Where | What it did |
|---|---|
| `WorkoutPhaseSchedule.build` | Validated the flat fields, so a segment of 0 seconds passed and became a 0-second run phase |
| `WorkoutKitService.makeCustomWorkout` | Sent the Watch a plain repeat of the first segment |
| `PlannedWorkout.intervalSummary` | Named the plan after its first segment |
| `ActiveWorkoutView.plannedShape` | A third, independent copy of that string |
| `PlannedWorkoutCard` | "Run 5:00" for a workout that also runs 8:00 |
| `duplicate` in two views | Silently flattened a copied plan to one segment |
| `ActiveWorkoutModel` | Recorded the first segment as the run's shape |
| `LoggerExportSnapshot` | Exported it as though it applied to the whole run |

**The lesson is about where a data-model change stops.** Making `resolvedBlocks` the single source
of truth was the right design and it was done — but *validation and display* were left reading the
raw fields, and those are exactly the layers a user judges the app by. The model was block-aware
while the app was not, and nothing failed to say so.

**Grep the field names, not the type names.** The flat fields are plain `Int`s with no compiler
relationship to `PlannedWorkoutBlock`, so nothing in the type system connects them. The only way to
find the eight was to search for the three property names directly.

### What a multi-segment plan stores in the flat fields (2026-09-07)

**Zero, deliberately**, once a plan carries blocks — not the first segment's numbers. A run interval
of zero is a value `WorkoutPhaseSchedule.build` refuses outright, so any reader that forgets to go
through `resolvedBlocks` gets something obviously broken rather than something plausible and wrong.
`PendingWorkoutExecution` does the same for the same reason, with `blockShape` carrying the truth.

The trade is deliberate: a plausible-but-wrong `300` survives a sanity check, and a `0` cannot.

### `blockShape == nil` means "not recorded", never "simple" (2026-09-07)

`PendingWorkoutExecution.blockShape` is written for **every** new session, single-shape runs
included (`"240/60x5"`). That is what keeps `nil` meaning only "recorded before this column
existed", whose own interval columns are the truth about it. Writing the descriptor only for
multi-segment runs would collapse "old record" and "simple plan" into one value, and every historical
row would then be blanked in the export. `testASessionRecordedBeforeShapesWereStoredKeepsItsColumns`
guards it.

### Installing an older build destroys every multi-block plan, silently (2026-09-07)

**Measured.** A store holding a plan whose `PlannedWorkoutBlock` rows exist, opened by an app whose
schema lacks that model:

- **It opens.** No error, no `containerError`. CoreData logs only `Persistent History (1) has to be
  truncated due to the following entities being removed: (PlannedWorkoutBlock)` and drops the table.
- The plan then reads `run=0 walk=0 reps=0`, because `writeShape` zeroes the flat fields for a
  multi-block plan on the assumption its block rows will always be there.
- Reopening under the current schema does not recover it. `blocks` is empty, so `hasMultipleBlocks`
  is **false**, and the plan looks like an ordinary single-shape plan that runs for no time.

`scripts/sideload.sh` installs over the same bundle id and preserves the container, so checking out
a commit from before `3069029` and running it once is enough. **There is no undo.** The only record
of the lost shape is `planned_workout_blocks.csv` in the last export, which is why every plan writes
its segments there, including plans of a single segment.

**What the app does about it.** `PlannedWorkout.hasDamagedShape` recognizes the state — a resolved
shape that runs for no time, which no saveable plan can have — and the plan list, the card and the
export all report it instead of rendering or exporting a `0`. The data is still gone; the app just
stops pretending the zero is a measurement.

**The general lesson.** Zeroing a field because "nothing reads it any more" is only true inside the
build that stopped reading it. A downgrade is a reader you did not consider, and on iOS it is one
command away.

### `Schema(models)` includes types you did not list (2026-09-07)

`Schema([...])` pulls in the destination of any relationship a listed model declares. `PlannedWorkout`
declares `@Relationship(inverse: \PlannedWorkoutBlock.plan)`, so `Schema` built from a list with
`PlannedWorkoutBlock` **omitted** still contains that entity, and a store written with it has the
`ZPLANNEDWORKOUTBLOCK` table.

This silently invalidated the first version of `LoggerStoreMigrationTests`'s block migration test:
its "old" schema was byte-identical to the new one, so it wrote and read the same schema and passed
while measuring nothing. A migration test that cannot fail is worse than no migration test, because
it is quoted as evidence.

**Assert the premise.** The test now checks that the old schema really lacks the entity and the
attribute before it proves anything with them, and declares the previous shape of each model in a
`VersionedSchema` rather than by omission. Nested types keep their entity names, so
`PreBlocksSchema.PlannedWorkout` is still the `PlannedWorkout` table.

### Reassigning a SwiftData to-many relationship orphans the old records (2026-09-07)

`deleteRule: .cascade` on `PlannedWorkout.blocks` fires when the **plan** is deleted, not when a
block leaves the relationship. So `plan.blocks = newBlocks` does not remove the previous rows — it
sets their inverse to nil and leaves them in the store. Since every reader goes through
`resolvedBlocks`, those orphans appear in no screen and no CSV: each edit of a three-block plan
would silently add three dead rows. `PlannedWorkoutEditorView.writeShape` deletes them explicitly
first.

## Stale proxies

### Two bugs, one shape: a cheap flag standing in for the real question (2026-09-07)

Both found in review, both silent, both live in the owner's build until today.

**`ActiveWorkoutModel.hasPendingLog`** stood in for "does a log exist for this session?" and was
never set true anywhere in the repo — declared `false`, assigned `false`, read once. The cooldown
button therefore spent every run offering "Log this run now" even for a run already logged
mid-workout, which is the same misreading `existingLog(forExecution:)` was added to fix on the
Finish path. It now asks the store when the log sheet closes: `onDismiss` fires for a cancel as well
as a save, and only the store can tell those apart.

**`LoggerExportSnapshot.pendingJoinCount`** stood in for "is there anything left to reconcile?" and
counted orphaned `RunLog`s only. `reconcilePendingCaptures` had already been widened to sweep notes
as well — "the subject of reconciliation is the execution, not the run log" — but the gate in front
of it kept the old assumption. So the run this file calls ordinary, three notes and no run log,
scored zero, the sweep never ran at export time, and the notes exported unjoined with no line in
`export_log.json`. Now `pendingCaptureCounts` counts both and the message names both.

**The shape.** A proxy for a question is fine until the question changes, and then it does not fail
— it quietly answers the old question forever. Neither of these could produce an error, a crash or a
failing test. What they produce is a screen or a file that is confidently wrong.

**The tell:** a stored boolean or count that duplicates something the store already knows. If the
authoritative answer is one query away, ask it, and pay the query at a moment that happens once
rather than every render.

## Run logging

### The mid-workout log join used to be one-shot, and lost data (2026-08-12)

A log written during cooldown has no `healthKitWorkoutUUID` — the workout does not exist yet — so it
is invisible to `runLog(forWorkout:)`. The join was attempted **once**, from
`ActiveWorkoutView.findWorkoutToLog()`, only on its `.matched` branch. HealthKit routinely does not
have the Watch's workout at that instant, so the log was orphaned permanently: counted as unlogged
forever, and then **silently overwritten with nil** when the user re-logged from the blank form.

Fixed three ways, all covered by tests in `RunLoggerModelTests`:

- `reconcilePendingCaptures(among:)` runs on every `refresh()`, making the join eventually consistent.
- `RunLogFormView.loadDraft()` consults `pendingLog(forWorkout:)` before falling back to a blank draft.
- The `.ambiguous` picker path attaches too.

**Reconciliation deliberately only considers unlogged workouts.** Sweeping all recent workouts would
let a pending log attach to one that already has a log, producing two logs for one workout.

### Reconciliation verified in production

Two exports of the same run, no code change between them, prove the fix works. In the earlier
export, taken during cooldown, the run log had a blank `healthKitWorkoutUUID`, the execution status
was `completed`, `workoutStartDate` held the timer's start, and distance was blank. In the later
export the same log carried the workout's UUID, the execution status was **`matched`**,
`workoutStartDate` held HealthKit's start, and distance was filled in. Both records carried the same
`updatedAt`, from `reconcilePendingCaptures` joining them on a later refresh.

**The cause was not a matcher tolerance problem, and worth remembering because it looks like one.**
The log was written during cooldown, and the workout had not yet ended. No query could have found
it — the run was still happening. The timer and HealthKit start times differed by under half a minute,
which looks suspicious in the data and is irrelevant: `RecentWorkoutMatcher.startToleranceSeconds`
is 120, and the match succeeded on the first attempt that ran *after the workout existed*.

**Diagnostic lesson:** a snapshot taken before reconciliation runs is indistinguishable from a
matching bug. An external review of the earlier export concluded the matcher was rejecting a valid
candidate and specified a scored matcher, a retry lifecycle and six tests to fix it. All of it was a
sound fix for a failure that had not happened. **Check whether the state is merely young before
concluding it is wrong.**

**Fixed at the source 2026-08-19.** `ExportViewModel.retryPendingJoins` now reconciles immediately
before serializing, so an export can no longer capture a log that would have joined moments later.
Reconciliation still runs on `refresh()`; this closes the case where someone exports without
visiting a screen that refreshes. It also writes a line into `export_log.json` either way — the
number of logs it joined, or the number still waiting and why that is normal — because an export
that silently repairs its own data is still changing something without saying so.

### Ending a run must ask "did I log this?", not "is this workout unlogged?" (2026-08-19)

`ActiveWorkoutView` decided what to show at the end of a workout by searching `unloggedWorkouts`.
That list answers no for a run already logged **and** no for a run whose workout has not synced, so
both produced "No Apple Watch workout found" — and its "Log it anyway" button opened a fresh form
that would have written a second log for the same run.

`existingLog(forExecution:)` answers the real question from the execution alone, without HealthKit,
the matcher, or the queue — none of which can answer it at the moment the timer stops, because the
Watch's workout usually does not exist yet. Deliberately not filtered on `healthKitWorkoutUUID`:
pending and joined both mean "you already did this" to the user.

### Interval records do not exist while their interval is happening (2026-08-19)

`ActiveWorkoutModel.persist(_:)` is wired to `IntervalTimerEngine.onIntervalCompleted`, which fires
from `completeCurrentPhase(at:…)` — the phase **boundary**. So during walk 3 of 5 there is no
`WorkoutIntervalLog` row for walk 3; it is written when walk 3 ends.

This is why the capture-anytime notes feature stores a separate `WorkoutNote` rather than a field on
the interval record, despite the interval being the right way to *read* a note. Attaching a note to
a row that does not exist yet would mean holding the user's writing in memory until the interval
ended, and this project has already lost a set of notes once.

The engine also does not expose the current sequence index — `sequenceCounter` is private. What is
readable mid-interval is `phase`, `currentRepetition` and `elapsedWorkoutSeconds`, which is what a
note is stamped with. Those stamps are the authoritative link; the interval a note falls inside is
recovered afterwards by time, subject to the pause correction in the next entry.

**Stamping happens at capture, not at save.** The note sheet freezes the phase when it opens. Typing
for 40 seconds in a walk that ends mid-sentence would otherwise file the thought under the run that
followed, and would put `createdAt` outside the interval that `phaseType` names — making the
export's own two columns contradict each other.

### `sequenceIndex` is write order, and a paused phase's `startDate` is shifted (2026-08-22)

Both measured in a real export, both by design, neither previously written down. Anyone
analysing `workout_intervals.csv` — or joining `workout_notes.csv` to it — will hit them.

**A pause gets a lower `sequenceIndex` than the phase it interrupted.** `IntervalTimerEngine.resume()`
emits the pause record on resume, while the interrupted phase is not emitted until it completes. So
the index is write order, not phase-start order. In one measured run, a pause taken during cooldown
carried a `sequenceIndex` one lower than the cooldown containing it, even though the cooldown
started first. Sorting by `sequenceIndex` does not give chronology; sort by `startDate`.

**A paused phase's recorded `startDate` is later than its true start**, by the time spent paused.
`resume()` shifts `phaseStartDate` forward so `actualDurationSeconds` counts only running time. In
the same run, a pause right after the countdown pushed run 1's recorded `startDate` later by exactly
the paused time, and run 1 still recorded its full planned duration. Consequence: phases do not tile
the workout end to end. The gaps are the pauses, which appear as their own rows.

Three such orderings exist across the 176 interval records in that export, so this is ordinary, not
an edge case.

**What it costs the notes join.** A note taken in the first *n* seconds of a phase later paused for
*n* seconds has a `createdAt` earlier than that phase's recorded `startDate`, so a plain
`startDate ≤ createdAt ≤ endDate` test drops it into the gap. The note's own `phaseType` and
`repetitionNumber` are stamped at capture and do not have this problem — prefer them.

### Reconcile captures, not logs (2026-08-19)

The mid-workout join is a staging pattern: a record is written immediately with a null
`healthKitWorkoutUUID` and keyed by `executionID`, then stamped once the Watch's workout arrives.
`RunLog` has worked that way since the cooldown-log fix; `WorkoutNote` uses the same shape.

The sweep that does the stamping was named and written for logs, and that was the flaw. It fetched
orphaned `RunLog`s, returned early when there were none, and only considered an execution that owned
one. Notes rode along as passengers. So "captured three notes, never opened the log form" — an
ordinary run, since a note asks for no RPE — produced records that waited for a trigger the user
never pulled.

**The subject of reconciliation is the execution, not the run log.** `reconcilePendingCaptures(among:)`
now asks which executions have *anything* unjoined. Interval records are deliberately excluded from
that question: every run produces them, so counting them would make every unlogged workout eligible,
and `attach` marks an execution matched — the sweep would link runs the user never asked to link.
What the user *typed* is the signal; the intervals come along with it.

The first fix attempted was a read-time lookup in `WorkoutDetailView`, which treated the symptom.
That lookup survives, but only for the case the sweep structurally cannot reach: the sweep considers
`unloggedWorkouts`, which is filtered to `unloggedPromptDays` (7 by default), so a run noted and
never logged drops out of the candidate list after a week.

### A blank form no longer erases the plan shape (2026-08-22)

The earlier loss had a second half that outlived the notes. Re-logging the run from a blank form
wrote `plannedWorkoutID` and the whole interval shape back as nil, because `save(draft:for:)` copied
the draft's fields straight through and the draft had none.

**It was never unrecoverable.** A later export showed two damaged rows with a blank plan and blank
shape in `run_logs.csv`, while `pending_workout_executions.csv` still held, for both, the plan's ID
and its full shape (run, walk and repetitions). The data sat one join away the entire time.

`backfillPlanShape(on:fromExecution:)` now fills any of those five fields the draft leaves nil from
the resolved execution, on both write paths. It fills gaps only — a draft that states a value keeps
it, including where it disagrees with the execution, because someone editing the form is a better
authority than a match is. With no execution it fills nothing: a blank column is visibly unknown,
and an invented number is not.

**There is no migration.** The two existing rows repair themselves the next time either run is saved
— open it in History, tap **Edit log**, Save. Same reasoning as the `b55974a` linking fix: a
permanent code path to serve two rows is worse than two taps.

### An orphaned log is still in the export

`LoggerExportSnapshot` fetches every `RunLog` with no filter and writes
`healthKitWorkoutUUID?.uuidString ?? ""`. A log invisible to every screen in the app still appears in
the export with a blank UUID column. That is the only recovery route for data orphaned before the fix.

### Pressing Lap on the Watch adds nothing to the data

Measured on an outdoor open-interval run. Lap was pressed at only some of the transitions —
`workoutEventsJSON` held fewer `type: 4` marker events than there were app-recorded phase
boundaries — and the export lost nothing by it.

Per-leg physiology reconstructs entirely from the app's own leg boundaries and sample timestamps.
Slicing `records.csv` by the `workout_intervals.csv` start and end dates and averaging heart rate per
leg separated running from walking clearly: every running leg averaged higher than
the walks on either side of it.

The app's boundaries are also the *better* record: they are written at the instant the phase ends,
whereas the observed markers landed seconds to most of a minute late, at whenever the runner got to
the button.

**So do not build a reminder to press Lap.** It was asked for, and withdrawn the same day once the
owner confirmed he pressed it only so the run would segment for later analysis — which it already
does without him. This is recorded because the ask is a reasonable one to have again, and
the reasoning against it is a measurement rather than an opinion. It would change if the Lap press
were ever wanted for something the phone cannot supply: a split shown on the wrist mid-run, or a
record independent of the app's store.

## Adding a kind to an existing model

### A sum type only protects the readers that look at it (2026-09-23)

`PlannedWorkout.shape` was introduced so that adding open-interval plans could not silently break
anything: an enum with a case per kind, switched on exhaustively, so a reader that had not
considered the new kind would fail to compile. That reasoning is sound and it worked — for every
reader written as a `switch`.

It caught none of these, all found by grepping for readers instead:

- **`hasDamagedShape`** computed `resolvedBlocks.allSatisfy { $0.runSeconds <= 0 || … }` directly.
  An open-interval plan satisfies that predicate *by design* — no run interval, no repetitions — so
  every healthy one reported itself as destroyed data. That flag raises the plan-list warning and
  blanks three export columns. **The alarm that guards silent block-plan destruction was about to
  start crying wolf**, which is worse than not having it.
- **`singleShape`** handed back a `0/0` block, which the Today card rendered as a workout.
- **`blockShapeDescriptor`** would have written `"0/0x0"` onto the execution — byte-identical to
  what a destroyed block plan writes, in the one column kept so the truth about a run survives.
- **`PlannedWorkoutDetailView`'s Edit link** routed every plan to the block editor, which writes an
  ordered list of blocks on save. No crash: just a plan that afterwards means two things at once.
- **The Today card** showed "Rounds 0" and a main set short by every walk in the workout.

**The shape.** An exhaustive `switch` is a claim about the code that reads the type. It says nothing
about code that derives the same answer some other way, and a codebase that predates the new kind is
made almost entirely of that. The compiler cannot help, because nothing is ill-typed.

**The tell:** a property whose body reads storage the new kind does not use. Before adding a case,
grep every existing derivation of the thing the case changes, and convert the ones with a live
reader. `git grep` on the property name found all five of these in about a minute.

## Testing

### One HealthKit test dominates a full run after cycling the simulator (2026-09-23)

**Resolved 2026-09-30:** the test was removed in a test-suite trim — it passed on success and on
any error, so it could not fail. It had taken 0.4 s to 466 s across runs that day. The suite now
runs in about 4–7 s. What follows is kept as the record of the measurement.

`ExportPipelineTests.testBuildSurfacesHealthKitFailure` took **348.7 seconds** against a freshly
cycled iPhone 17 Pro simulator, against ~7 seconds for the other 315 tests put together. Measured
repeatedly across a day's work: a full suite runs in 7–10 seconds when the simulator is warm and
around 4½–6 minutes when it has just been cycled.

This interacts directly with the standing advice to cycle the simulator before every run, which
exists because the test runner otherwise hangs for ~400 seconds and reports
`The test runner hung before establishing connection` with no `Executed N tests` line. Both cost
about the same wall clock, so cycling is still right — the difference is that one of them produces
results and the other does not.

**While iterating**, `-only-testing:` on the suites being changed avoids it entirely. Run the whole
suite before committing, not between red and green.

**Amended 2026-09-24: the 4½–6 minute figure did not reproduce.** Across four full-suite runs that
day, each preceded by the documented shutdown/`bootstatus` cycle, the suite took **95.5s**, then
**6.0s**, then **7.2s**. Only the first was slow. The 348.7-second test was not skipped — the same
321 and then 325 tests ran each time.

No mechanism is claimed here; this is an observation that the original number is not reliable, not a
replacement for it. The experiment this paragraph used to ask for — timing
`testBuildSurfacesHealthKitFailure` alone after a cold boot versus after one suite run — **can no
longer be run: that test was removed on 2026-09-30**, which is also why the suite now finishes in
seconds. The question is moot rather than answered, and the slow figure stays unexplained.

**Treat "cycling costs you five minutes" as unproven** and do not skip the cycle to avoid a cost
that is now demonstrably not there — the hang it prevents is real. **Hit again 2026-10-01**, on a
run started without the cycle: `xcodebuild` sat at 0.0% CPU for nearly three minutes after
`PruneExplicitPrecompiledModules`, never reached the test runner, and wrote no `Executed` line. A
`grep` for the result returned nothing, which reads exactly like a clean run. Cycling first and
re-running worked. The cost of the cycle is about ten seconds; the cost of skipping it was three
minutes and a result that could have been misread as success.
