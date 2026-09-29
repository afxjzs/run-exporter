# Backlog

Wanted, not yet built. Each entry records the *reasoning* as well as the ask, so a future session
can tell whether a design still serves the intent behind it.

---

## WorkoutKit — removed in the 2026-09-29 clean-out

This section used to list WorkoutKit capabilities kept on purpose although they did not work on the
owner's hardware. The clean-out removed the whole route instead (see *Decisions* in "Clean out the
leftovers" below): the phone's Start now launches this app's own watch workout, and using both
records two workouts. The measurements are in [../LEARNINGS.md](../LEARNINGS.md#workoutkit).

What was learned, for whoever brings WorkoutKit back:

- **`WorkoutScheduler.schedule(_:at:)` did not deliver** — four workouts over 26+ hours, both radio
  states — though it worked in early August. Apple's preview sheet (`.workoutPreview`) did deliver.
- **A stuck queue could not be cleared.** `removeAllWorkouts()` left four entries untouched;
  restarting the iPhone was the only known remedy.
- **A workout added through the preview sheet cannot be removed by any API.** It lands in the
  Watch's own library, which WorkoutKit cannot address. Do not build a "remove what I added" button.
- **Placement on the Watch's main workout list is not controllable.** Delivered workouts landed under
  Outdoor Run, behind the three-dot menu; WorkoutKit exposes nothing about placement.
- **Nothing in the payload may be newer than watchOS 10** while the Series 5 is paired —
  `WorkoutStep.displayName` rebooted the Watch.

---

## Capture-anytime notes during a workout — **built 2026-08-19**

Requested 2026-08-12, shipped as the `WorkoutNote` model plus an **Add note** button in every phase
of `ActiveWorkoutView`. Kept here only as a pointer, so nobody rebuilds it: the reasoning now lives
next to the code, in `WorkoutNote`'s type comment and `ActiveWorkoutModel.NoteContext`.

One thing the original design note got wrong, worth recording because it is not visible from the
model definitions. It named `WorkoutIntervalLog` as the natural owner of a mid-run note. That record
**cannot** own one: its rows are written from `IntervalTimerEngine.onIntervalCompleted`, at the phase
boundary, so during walk 3 there is no row for walk 3 to write to. Storing the note there would mean
holding the user's writing in memory for up to a whole interval. `WorkoutNote` carries the phase and
repetition instead, and the interval it falls inside stays recoverable by timestamp. See
[../LEARNINGS.md](../LEARNINGS.md#run-logging).

### Still wanted here

- **Editing or deleting a note after the fact.** Notes are append-only today. History shows them and
  the export carries them, but there is no way to fix a typo or remove one written by accident. Not
  built because capture speed was the whole point and an edit affordance on the workout screen costs
  taps; the right home is probably the History detail, not mid-run.

---

## Open-interval runs — **built 2026-09-23**

A plan whose running bouts end when the runner ends them, repeated until a total of accumulated
running. Built as `OpenIntervalShape`, `OpenIntervalSequencer`/`Schedule`, and its own editor. The
reasoning lives next to the code; only the parts that are *not* visible from the types are here.

### Still wanted here

- ~~**Send an open-interval workout to the Watch.**~~ **Withdrawn 2026-09-29.** The idea was a
  WorkoutKit send, and the 2026-09-29 clean-out removed WorkoutKit. The need behind it — the
  Watch's data lined up with each leg — is what watch plan step 2 does instead: the phone's Start
  launches this app's own watch workout, which writes each phase as a `.segment` event. Whether
  those events land in the saved workout is not yet measured on device.

- **History does not show an open-interval run's shape.** Same omission, and the same reason, as a
  multi-block run: the shape lives on the execution's `blockShape` (written as `open:1800/180`), and
  joining through `executionID` would mean a store fetch per row in a list.

- **From the first outdoor run.** The owner's verdict was *"it worked great for a v1 of
  that feature"*, and the export backs it: leg caps chained exactly, `targetReached` fired on the
  final leg, and every rated leg recorded its body-signal reading. Three notes, all about the
  recovery walk:

  **Notes 1 and 2 are built**; note 3 is still open and is waiting on an answer, not on
  time. The headline now counts the floor down, the button always reads "Start next leg", and the
  floor arrives behind a 3-2-1. Two tests in `IntervalTimerEngineTests` pin both. The elapsed branch
  was also re-keyed from `.cooldown` to `phaseEndDate == nil`, because every open phase had the same
  defect and the cooldown was only the one that had been noticed.

  1. ~~**The walk's countdown is in the wrong place.**~~ **Built.** A function called
     `startLegButtonTitle` carried the floor countdown *in the button label*: it read "Walk 1:23
     more" and became "Start next leg" only at the floor. It ended up there because the headline
     renders `phaseRemainingSeconds`, which an open walk has no answer for — so `Display.countdown`
     rendered "—" as the largest number on the screen, and the floor had nowhere else to go.
     `IntervalTimerEngine.walkFloorRemainingSeconds` now feeds the headline, the function is
     deleted, and past the floor the display falls through to elapsed.

  2. ~~**No countdown into the end of the walk.**~~ **Built.** The five-second warning and the 3-2-1
     both sit inside the `plannedSeconds` branch of `scheduledCues(for:start:)`, which an open walk
     never enters, so the floor arrived announced by `.recoveryFloorReached` alone. The 3-2-1 is now
     scheduled from the open-walk branch. The five-second warning deliberately is **not**: it names
     the phase that follows and says it is seconds away, which is true at a timed boundary and false
     at a floor, since the floor does not start the next leg.

     *(No line numbers here on purpose — the ones this entry originally carried were wrong within
     the hour, because fixing the thing they pointed at moved them.)*

  3. ~~**A reminder to press Lap on the Watch at each mode swap.**~~ **Withdrawn the day it was
     asked for — do not build it.** The owner confirmed he presses Lap only so the run
     segments for later analysis, and the measurement shows it already does without him. See
     [../LEARNINGS.md](../LEARNINGS.md#run-logging), *"Pressing Lap on the Watch adds nothing to the
     data"*, which has the measurement and the two conditions that would revive the ask.

- **The remaining derived properties still answer from blocks.** `totalWalkSeconds`,
  `walkIntervalCount`, `expectedTotalSeconds` and `totalRepetitions` return `0` for an open-interval
  plan, which is honest for the round count — it genuinely is not knowable in advance — and merely
  unknown for the rest. `singleShape`, `blockShapeDescriptor`, `totalRunSeconds` and
  `hasDamagedShape` were converted because each had a reader that said something false. The rest
  have no such reader today. If one appears, convert the property rather than teaching the caller.

---

## Clean out the leftovers, and simplify the UI

**Asked for 2026-09-29.** Swept and decided the same day (see *Decisions* below); nothing removed
yet. The owner's words: the app is *"pretty cluttered"* with things
left over from trials and learnings; clean it out, and treat it as a UI update — *"it's all to the same
effect… making the app easier to use."*

**Candidates, verified to exist on 2026-09-29 — each needs a decision, not an automatic delete:**

- **Test harnesses in Settings:** "Cue test" (`CueTestView`) and "Watch link test"
  (`WatchLinkTestView`). The watch link screen was to exist only until the real Start button (watch
  plan step 2) replaced it; that has now happened — the run screen's Start launches the Watch — so
  the link test is a diagnostic only. `WatchLinkTestView`'s own comment still calls the real Start
  "step 2, once this proves the mechanism".
- **CueTestView's Live Activity test buttons**, as a candidate alongside the cue test itself.
- **The Watch cue-source options** in Settings ("Apple Workout app" and "Watch companion"), as candidates.
  Cues stay on the phone (watch plan §1), and see the `.watchCompanion` footer below.
- **Open-interval wording left over from before the Watch was driven by the phone.** The plan
  screen's line for an open-interval plan (`PlannedWorkoutDetailView`) still reads "Runs on this
  iPhone. Start a workout on your Watch and use Lap to keep its data lined up with these legs." Both
  halves are now wrong: Start launches the Watch's workout itself, so starting one by hand records
  **two** workouts; and pressing Lap contradicts [../LEARNINGS.md](../LEARNINGS.md#run-logging),
  *"Pressing Lap on the Watch adds nothing to the data"* — "do not build a reminder to press Lap".
  README's matching advice has been corrected. Other text that still describes the two-tap start,
  grepped 2026-09-29: the comment on `LoggerDefaults`' countdown default ("The run is started on the
  Watch and the timer on the phone as two separate taps") and a comment in `AudioAndShoeTests`.
- **The `.watchCompanion` cue-source footer in Settings** (`SettingsView.cueSourceExplanation`) says
  "A Watch companion app is not part of this version" — false since the watch app shipped.
- **The watch's link screen says "Test session: not saved to Health."** (`WatchLinkView`) for every
  session it shows, including a phone-driven run before its first phase arrives, which *is* saved.
- **Two ways to use the Watch on the Today screen:** "Send to Apple Watch" (WorkoutKit) alongside
  "Start Audio Timer". Now that the phone starts the Watch's workout itself (watch plan step 2), the
  WorkoutKit route may be redundant.
- **The "Kept but known-broken" section** (now "WorkoutKit — removed", at the top) — scheduling,
  clearing a stuck queue. Those were kept
  *deliberately*, with reasons; removing them means reversing that decision on purpose, not tidying.
- **Export Data appears twice** — on Today and in Settings.
- **The watch app's probe screen** (`BackgroundExecutionProbe`) — stage 2 passed; it is kept only as
  an instrument.

**How to go about it:** list every screen and control, decide keep / merge / remove for each with the
owner, and grep for readers before deleting anything — `LEARNINGS.md` records what happened the last
time derived code was missed. `DocumentationDriftTests` will name every document that quotes a
removed label; update them in the same change.

### Found by the sweep (2026-09-29), outside the keep-or-go list

- **A walking plan records a running workout on the Watch.** `WatchLink.launchWatchWorkout` always
  sets `activityType = .running` and never reads the plan's `PlannedActivityType`, so a Walking
  plan's Start saves an Outdoor Run to Health and nothing says so. **Owner, 2026-09-29: fix after the
  interview, test-first.**
- **A finished run with no execution id discards the Watch's workout.** When the logger database
  is unavailable, `ActiveWorkoutModel.recordExecution` returns nil, and `WatchLink.finishRun` then
  sends `.endWorkout`: the heart rate and GPS route are thrown away. Its comment says the phone
  "could never join" an untagged workout, but the two-minute window is still the fallback for
  exactly that. The finish alert then tells the runner to end a Watch workout they started
  themselves, which is wrong here. **Owner, 2026-09-29: save it untagged instead** — the Watch
  saves without the id and the phone joins by the two-minute window; the finish alert says the
  Watch was asked to save. Test-first, in the batched Watch build.
- **`WatchWorkoutOrigin.watch` is never produced.** The only start passes `.phone`; the controller's
  comment on `shared` still mentions "a local start" from the screen.
- **More text still describing the two-tap start:** the header comment of `ActiveWorkoutModelTests`
  and the doc comment on `ActiveWorkoutView.armed`.

### Decisions (interview started 2026-09-29)

Nothing is removed until every decision below is made. Afterwards, the owner asked for `/simplify`
on the removal diff and `/code-review` once on the watch-flow diff (`610fdd2..HEAD`).

1. **[Done]** **The open-interval line on the plan screen** ("Start a workout on your Watch and use Lap…",
   `PlannedWorkoutDetailView`) — **delete it.** It only explained the missing Send button, and the
   run screen's READY hint already says Start launches the Watch.
2. **[Done]** **The WorkoutKit "Send to Apple Watch" route** — `SendToWatchView`, `WorkoutKitService`, the
   links on Today and the plan screen, "Add to Apple Watch", "Schedule for a time", "Clear this
   iPhone's queue" — **remove it.** Start launches this app's own Watch workout, and using both on
   one run records two workouts. This reverses the "Kept but known-broken" section on purpose; that
   section is replaced by "WorkoutKit — removed" at the top, and CLAUDE.md's watchOS 10 payload
   rule becomes moot for the phone (the watch app's own API ceiling still applies).
3. **[Done]** **`PlannedWorkout.workoutKitIdentifier`** — **keep the stored field and the `planned_workouts`
   export column; stop writing them.** Dropping a stored attribute is a schema change against a
   store of real runs, for no gain. Old values stay as true history; the export's README.txt gains
   a line saying the column is no longer written. The plan-delete code that clears a queue entry
   (`PlannedWorkoutDetailView`, `PlannedWorkoutViews`) and the Delete plan footer go with item 2.
   **Owner, during the removal:** deleting a plan now just deletes it. An entry a plan once queued
   stays in this iPhone's WorkoutKit queue, unreachable; those entries never delivered, and a
   restart already clears a wedged queue.
4. **[Done]** **Cue source** — **remove "Apple Workout app" and "Watch companion"; replace the picker with a
   "Play cues" toggle** (on = iPhone audio engine, off = No cues). The first only made sense with
   item 2; the second was never built and its footer was false. The export's `cue_source` keeps its
   existing values. A phone with a removed value stored reports it once under "Settings that could
   not be read" — by design, not a regression. `CueSourceExplanationTests` changes first.
5. **Cue test** (`CueTestView`, including its Live Activity test buttons) — **remove it.** The
   on-hardware tests it served are recorded in `CUE_FEASIBILITY_TEST.md`, its Test 1 needs the
   route removed in item 2, and its create button writes a real plan into Plans. Goes with it:
   `latencyDescription` and `CueLatencyTests`, and `AudioCueEngine.playbackLog`, which has no
   other reader.
6. **Watch link test** (`WatchLinkTestView`) — **remove it, and move `WatchLink.fileError` to the run
   screen's Watch status.** A real Start and End Workout do the same and log to the same files.
   `fileError` (a diagnostic file could not be written) is shown nowhere else, so dropping the
   screen without moving it would make those failures silent. `reset`, `endWatchWorkout`,
   `clearLog` and the in-memory `events` list serve only this screen and go with it.
7. **Export Data** — **Today only, removed from Settings, and made one of the more prominent
   buttons on Today** (owner's words). Placement: its own section directly below Next Workout, a
   full-width headline button styled like Start, above Needs a log and Recent Workouts. Shoes stays
   at the bottom of Today.
8. **"Start Audio Timer"** (Today, plan screen) — **rename to "Start Workout".** Start now launches
   the Watch workout too, and the name matches "End Workout". Move the `DocumentationDriftTests`
   entry to the new label; update README and `CUE_FEASIBILITY_TEST.md`; the v1.1 spec gets a note
   rather than a rewrite, since it records requirements as written.
9. **The watch probe** (`ContentView`, `BackgroundExecutionProbe`) — **remove it; the root shows a
   small idle screen instead:** "Start a workout from your iPhone" and the Health access status.
   Must keep: `prepareHealthAccess` running when the app is opened by hand (a phone launch stops
   until access is granted from the foreground), the build label, the event log page. Batched with
   the other watch changes into one Watch install.
10. **The watch's link screen** (`WatchLinkView`) — **keep it; delete "Test session: not saved to
    Health."** It is the only place a failed Watch start explains itself, and its End is the way out
    of a session the phone lost.
11. **The Live Activity** (Lock Screen card) — **keep it.** Redesigned 2026-08-07 to show only what
    stays true while locked; tapping it returns to the run. Unverified: the timeline stops at the
    first open-ended phase, so an open-interval run's card may show little beyond the elapsed
    clock. Removing the cue test (item 5) leaves `LiveActivityController.droppedUpdates` with no
    reader — it was shown only there — so it goes with item 5 or gets a new home.
12. **Countdown default** — **3 seconds, the spec §6 value, for new plans.** The reason for 0 (two
    separate taps) is gone, and the Watch usually connects within the countdown. Existing plans and
    a stored Settings value are unchanged. Change the assertion in `AudioAndShoeTests` first (it
    pins 0 with the two-tap reasoning), then `LoggerDefaults`; update README's deviation note and
    LEARNINGS "Run logging".
13. **The watch's `audio` background mode** — **leave it.** Unused but invisible, and changing
    background-mode keys on this Watch has cost a day before (`WKBackgroundModes`).
14. **Corrections, all approved:** the watch's `NSHealthUpdateUsageDescription` and the export's
    README.txt say "only workouts" — make them say workouts and their GPS routes; correct every
    comment still describing the two-tap start (`LoggerDefaults` countdown, `AudioAndShoeTests`,
    `ActiveWorkoutModelTests` header, `ActiveWorkoutView.armed`, `WatchLinkTestView` and `WatchLink`
    headers — some go away with items 6 and 12); remove `WatchWorkoutOrigin.watch` and the
    controller's "local start" comment; register "Try again", "Slide to pause" and "Slide to skip"
    in `DocumentationDriftTests`, which README quotes.

**All decisions made 2026-09-29.** Removal order: phone-only changes first with the full suite
after each; the watch changes (items 9, 10, 14's `.watch` case, and the untagged-save fix above)
batched into one Watch install at the end; never install while a run is in progress.

---

## Sync non-Health data to the owner's server, on demand

**Asked for 2026-09-29.** A bigger project, unrelated to the watch work, and not started.

The ask, in the owner's words: *"sync non-health data to my server on demand."* Non-Health data means
what the app itself creates and stores in its local SwiftData store — plans, run logs, notes, interval
records, shoes — as opposed to what it reads from HealthKit.

**This reverses a property the app states in three places.** The README's Privacy section, the
Settings screen's footer, and the export's own `README.txt` all say the app makes no network requests
and has no server. Building this means changing all three in the same change, per the rule the watch
work already follows: nothing about data handling moves without being written down first.

**Not yet decided, and not to be guessed:** which server and how it authenticates; exactly which
records go; whether "on demand" means a button, the export, or both; and whether it is one-way.

---

## Swift 6 language mode

**Status:** builds clean today, with warnings that become errors on the move.

**Update, 2026-09-29 clean-out:** the two warnings below were in `WorkoutKitService`, which is now
deleted, so they are gone. An incremental build afterwards still showed one in test code —
`AbandonedTimerTests` reads the main-actor `RunLoggerModel.abandonedTimerThreshold` from a
nonisolated context. An incremental build does not re-emit warnings for unchanged files, so a
**clean** build is needed for a complete list before starting the move.

The original two: `WorkoutKitService.swift:207` and `:340` both read
`WorkoutScheduler.authorizationState` from a main-actor-isolated context:

```
warning: non-Sendable type 'WorkoutScheduler.AuthorizationState' of nonisolated property
'authorizationState' cannot be sent to main actor-isolated context; this is an error in the
Swift 6 language mode
```

Not urgent and not a defect in the current language mode — recorded because it is the kind of thing
discovered at the worst moment, part-way through an unrelated toolchain upgrade. Whoever moves this
project to Swift 6 should expect these two first.

**Note the location.** Both were in the `WorkoutScheduler` path, which
[../LEARNINGS.md](../LEARNINGS.md) records as not delivering on this hardware. If WorkoutKit comes
back, expect them back with it.

---

## Controls that fire on a bump — **built**

**Asked for after hitting both by accident on real runs.** Shipped as `SlideToConfirm`: the run
screen's Pause and Skip are "Slide to pause" and "Slide to skip" (`ActiveWorkoutView`). The ask is
kept below for its reasoning.

The phone is carried in the left hand with the app in front, so the screen takes knocks for the
whole workout. **Pause** and **Skip** are both single taps, both irreversible in the sense that
matters — a pause that goes unnoticed costs an interval before it is spotted, and a skip cannot be
un-skipped — and both sit under a thumb that is not always deliberate.

**Wanted:** a slide gesture rather than a tap for both. "Slide to pause", "slide to skip". A
confirmation dialog would also work, but it is the wrong shape for the moment: a dialog needs
reading, and the whole problem is a control operated without looking.

Note that the existing cues already cover the *detection* half of this — `.paused` and `.skipped`
are `isControlConfirmation`, so they sound in every cue mode precisely because "a tap with no
audible response is indistinguishable from a missed tap". What they cannot do is prevent the tap.

### Skip on an open-interval run — **built**

Shipped as proposed below: Skip is hidden when `IntervalTimerEngine.endsLegsByHand` is true, and
"Start next leg" can be tapped before the floor behind a confirmation.

Related, and worth deciding at the same time. Skip and "End this leg" both end the phase and
advance, but Skip writes `wasSkipped: true`, no `endReason` and no body readings — a row that
describes an abandoned leg rather than a measured one. It is a worse version of the correct button,
sitting beside it.

Its one real use today is during the recovery walk, where it is the only way to start the next leg
before the floor, since "Start next leg" is gated on it. The proposal that removes the ambiguity
without removing the capability: hide Skip on open-interval runs entirely, and let "Start next leg"
be tappable early behind a confirmation that names the number — "You have walked 1:20 of 3:00.
Start anyway?" One button per action, and the walk is still recorded honestly as cut short.

---

## Export filenames say when the data starts, not when it was taken — **built 2026-09-23**

**Shipped the same day it was asked for, in `b3f5164`.** `ExportBuilder.build` now builds
`running_health_extract_\(startYMD)_to_\(takenYMD)`, so an export carries the date it was taken.

One way the result deliberately differs from the ask below: **date only, no clock time**, at the
owner's request, because exports are a once-a-day thing outside of testing. Two exports on the same
day therefore still share a name and are told apart by the download itself.

Anything in `~/Downloads` still named `..._to_now.zip` predates this build rather than showing it
broken — the two exports taken the day this shipped were written minutes before the commit
landed.

**Everything below is the original ask, kept for the reasoning.**

`ExportBuilder` names every export from its start date and the literal word "now":

```swift
let extractName = "running_health_extract_\(startYMD)_to_now"
```

So an export made today and one made next month are both
`running_health_extract_2026-06-18_to_now.zip`. Two consequences, and the second is the one that
bites:

- **Nothing in the name says when it was taken.** "to_now" was true at the moment of writing and is
  the only part that dates the file, which means it dates it to whenever you happen to be reading.
- **They collide.** Same name every time, so a folder of exports is a folder of files that look
  identical, and saving a second one over a first is a matter of whichever dialog you tapped
  through. The manifest inside records the real span, but a name that has to be opened to be told
  apart is not a name.

**Wanted:** the export's own timestamp in the filename, to the minute — something like
`running_health_extract_2026-06-18_to_YYYY-MM-DD_HHMM.zip`. End date rather than "now", and enough
precision that two exports on one day are still distinguishable, which matters exactly on the days
something is being debugged and several are taken in a row.

**Note for whoever does it:** `extractName` is used three times in `ExportBuilder` — the folder, the
zip, and the manifest's own record of what it produced — so it needs changing in one place and
checking in three. `ExportPipelineTests` asserts the manifest's inventory matches the zip's contents
exactly, which will catch a mismatch between them.

---

## A missed two-minute join window is reported as the wrong problem — **built**

**Found while briefing the owner before his first outdoor run, deliberately left alone
until after it** — the join path was exactly what that run exercised — and fixed the same day it
finished. All three parts shipped. The run itself did **not** hit this: the owner started the two
within seconds and `export_log.json` recorded the join with zero warnings.

What the fix looks like now, so nobody re-derives it: `Outcome.outsideWindow` carries the near
misses nearest-first with the closest offset; `RecentWorkoutMatcher.nearMissWindowSeconds` bounds
what is worth offering at 90 minutes; the run screen offers the nearest workout with the gap named
and links it through the same `attach` the automatic path uses; and the export reports unjoined
interval legs at `info`. Four tests in `RecentWorkoutMatcherTests` pin the behaviour, including that
a near miss is never claimed for the wrong activity.

**The window itself was not touched, and must not be** — see "Do not widen the window" below, which
is still live guidance rather than history.

**Since watch plan step 3 the window is the fallback.** A workout saved by this app's watch app
carries the execution id (`WorkoutMetadataKeys.executionID`), and both matcher directions join on
it before looking at start times (`RecentWorkoutMatcher`, "Priority 0"). The window applies only to
untagged workouts: older runs and Apple's Workout app.

**Everything below is the original write-up, kept for the reasoning. Its `file:line` citations were
accurate when written and are not any more** — fixing the code they pointed at moved them. The
symbol names still hold; chase those instead.

### What is verified

`RecentWorkoutMatcher.startToleranceSeconds = 120` (`RecentWorkoutMatcher.swift:74`). The window is
anchored on `timerStartedAt ?? createdAt` (`PendingWorkoutExecution.swift:134`), and `timerStartedAt`
is set in `ActiveWorkoutModel.recordExecution`, reached only from the Start button
(`ActiveWorkoutView.swift:245`). So the clock starts at the **Start tap**, and arming the screen
early costs nothing.

Miss the window and the failure is loud once, in a misleading way, then silent:

- The end-of-run alert is **"No Apple Watch workout found"** (`ActiveWorkoutView.swift:76-83`). It
  names two causes — a phone-only run, or a Watch still syncing — and neither is "the two starts
  were more than two minutes apart."
- Its advice, *"log it from Today in a minute or two"*, **cannot work.** The reverse direction
  applies the same gate: `resolvedExecution` filters on
  `isMatchCandidate(now: workout.startDate, window: RecentWorkoutMatcher.startToleranceSeconds)`
  (`RunLoggerModel.swift:826-828`). Waiting does not widen it, and there is no free-form picker —
  the only one is fed from inside the window.
- The export then says nothing at all. `row(for: WorkoutIntervalLog)` writes a blank
  `healthKitWorkoutUUID` and checks only `phaseType` for issues
  (`LoggerExportSnapshot.swift:243-251`), and `pendingCaptureCounts` fetches only `RunLog` and
  `WorkoutNote`, so unjoined legs are never counted.

The run is not lost — the legs stay and HealthKit keeps the workout. What is permanently lost is the
**join**, so distance, pace and heart rate never reach the legs.

### The fix, in dependency order

1. **Let the matcher distinguish "nothing there" from "something there that just missed".** At
   `.noCandidates` the caller is already holding `logger.unloggedWorkouts` and throws it away. Add a
   case — `outsideWindow(workoutUUIDs:closestOffsetSeconds:)` — returned when the activity-type pool
   was non-empty but every entry fell outside 120s.

   **Blast radius, grepped rather than assumed:** exactly one production reader switches on
   `Outcome` (`ActiveWorkoutView.swift:679-705`). `RunLoggerModel` reads the *other* enum,
   `ExecutionMatch`. That is unusually contained for this repo — compare `LEARNINGS.md`, *"A sum
   type only protects the readers that look at it"*.

2. **Offer the repair, and let the user be the one to confirm it.** The machinery already exists:
   `RunLoggerModel.linkIntervals(ofExecution:to:)` (`:922`) backs the ambiguous-candidates picker,
   and its comment notes a hand-made link is indistinguishable from an automatic one afterwards,
   including in the export. The alert becomes true and actionable: "A running workout started 4m 12s
   after your timer, outside the two-minute window. Use it anyway?"

   This follows the matcher's own doctrine rather than bending it. Its opening comment says an
   uncertain match is never made *silently*, and that ambiguity is escalated to the user instead of
   resolved by a tiebreak. A near miss is an uncertain match.

3. **Stop the export going quiet — carefully.** Count `WorkoutIntervalLog` rows with a nil
   `healthKitWorkoutUUID` in the pre-flight, and drop the existing line's claim that an unjoined
   capture is "normal if the Watch has not finished syncing", which asserts a cause it never checked.

   **The trap:** a phone-only run is supported and its legs *always* carry a nil UUID, so counting
   them naively fires a warning on every one. This repo already hit that exact shape —
   `RunLoggerModel.swift:113-116` records why joining to nothing is deliberately not an error. Report
   the count as fact; escalate to a warning only when a near-miss workout is actually detectable.

### Do not widen the window

It is the first idea that comes to mind and the measurements say no.
`RecentWorkoutMatcher.swift:60-72` records that across the owner's 23 real workouts, every window
from 30s to 90min produced the same single automatic match, while 60min and above pulled in
abandoned timers and turned one real workout into an unresolvable ambiguity. Widening buys no
matches and costs a link, trading a diagnosable miss for a silent mis-attachment.

Related: `startScoreReferenceSeconds` is held at 90 minutes deliberately and must not be refactored
to follow the window. Fusing the two once scaled every start score by 45 and quietly converted "too
close to call, so ask" into a confident pick.

### Until it is fixed — superseded

The mitigation this section gave, starting the workout on the Watch and then tapping Start on the
phone within two minutes, **no longer applies and must not be followed**: since watch plan step 2 the
phone's Start launches the Watch's workout itself, and a workout started by hand as well records
two. The run screen now says so (`ActiveWorkoutView.startOrderHint`).
