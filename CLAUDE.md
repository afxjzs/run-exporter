# RunExporter — agent instructions

Pointers only. The content lives in the files named below; duplicating it here would let the two
copies drift, which this project already has a documented history of.

## The documentation, and which file answers what

Eleven files, about 6,300 lines (counted 2026-09-29). **This table is the index.** Until 2026-09-25 four of these were
reachable from nothing that loads automatically — 71% of the words in the repo — including the spec
that 55 `spec §…` citations across 30 source files point at.

| File | Answers | Read it when |
|---|---|---|
| [README.md](README.md) | What the app does, produces, and cannot do; architecture; known limitations | Orienting, or before describing the app to anyone |
| [RUNNING_APP_V1_1_SPEC.md](RUNNING_APP_V1_1_SPEC.md) | **What `spec §…` means.** The v1.1 requirements, and only those — it does **not** cover open-interval runs, which were built later and specified nowhere | Any time source cites a `§` number |
| [LEARNINGS.md](LEARNINGS.md) | Measured facts, each dated | Before trusting any claim about this hardware |
| [MISTAKES.md](MISTAKES.md) | How past investigations went wrong | Before diagnosing anything |
| [docs/BACKLOG.md](docs/BACKLOG.md) | Wanted but not built, and things deliberately **not** to build, with reasoning | Before building anything that sounds new |
| [docs/INSTALLS.md](docs/INSTALLS.md) | Every install; the single home for hardware and OS versions | Before installing, or quoting any version |
| [docs/CUE_FEASIBILITY_TEST.md](docs/CUE_FEASIBILITY_TEST.md) | Cue test procedures and their dated results | Before changing cues or the Send to Watch screen |
| [docs/WATCHOS_RECORDER_PLAN.md](docs/WATCHOS_RECORDER_PLAN.md) | The watch plan of record: phone decides, watch records; its steps and what ends each | Before any watch app work |
| [docs/WATCH_DEVELOPMENT.md](docs/WATCH_DEVELOPMENT.md) | **How** to get the watch app installed, launched from the phone, and its logs read — Developer Mode, the profile, error codes, `WKBackgroundModes` | Before installing on, launching, or diagnosing the Watch |
| [docs/Native-iOS-Health-Running-Export.md](docs/Native-iOS-Health-Running-Export.md) | The **historical** v1.0 spec | Rarely. It is superseded, and says so at the top |

## Citing code from a document

**Name the symbol, never the line.** `RecentWorkoutMatcher.startToleranceSeconds`, not
`RecentWorkoutMatcher.swift:74`. Line citations in this repo have gone wrong within the hour of
being written, because fixing the code a citation points at is exactly what moves it.

**A document may not quote a control that no longer exists.** Two did. Both were real and correct
when written: `8d145b9` (2026-09-07) renamed **"Remove all workouts from Watch"** to **"Clear this
iPhone's queue"** — named for what it actually does, since it never could reach the Watch — and
dropped the **"Workout sent to Apple Watch."** confirmation. The documents quoting them were not
touched, so for eighteen days they told readers to press buttons that were no longer there.

Nobody invented anything, and that is the point: ordinary renaming is enough.
`RunExporterTests/DocumentationDriftTests.swift` now fails when a quoted UI string is gone from the
source, and names every document that quotes it. Add an entry there when a doc starts quoting a new
label — that test is the enforcement, not a formality.

## Read before you touch these areas

- **`WorkoutKitService`, `SendToWatchView`, or anything about getting workouts onto the Watch** →
  read [LEARNINGS.md](LEARNINGS.md) first. It records what has been **measured** on the owner's
  actual hardware (iPhone 16 Pro ↔ Apple Watch Series 5), including the
  fact that `WorkoutScheduler.schedule(_:at:)` does not deliver at all and Apple's preview sheet
  does. The button order on that screen is a deliberate consequence of two days of measurement — do
  not "tidy" it back without re-running Test 5 in
  [docs/CUE_FEASIBILITY_TEST.md](docs/CUE_FEASIBILITY_TEST.md).

- **The run-logging join** (`RunLoggerModel`, `RunLogFormView`, `ActiveWorkoutView`) → read
  [LEARNINGS.md](LEARNINGS.md#run-logging). A log written during cooldown carries no
  `healthKitWorkoutUUID`, so any screen offering to log a workout must consult
  `pendingLog(forWorkout:)` as well as `runLog(forWorkout:)`. Skipping that silently destroyed a
  user's notes once already.

- **`RecentWorkoutMatcher`, or anything about the two-minute join window** → read the
  *"missed two-minute join window"* entry in [docs/BACKLOG.md](docs/BACKLOG.md) first.
  `startToleranceSeconds = 120` is a measured value, and **widening it is the one change
  measurement has already ruled out** — 60 minutes and above pulled in abandoned timers and made a
  real workout unmatchable. The same entry records the known defect: a miss is reported as a
  different problem entirely, and the remedy the app suggests cannot work.

- **Adding a new kind of plan, or touching `PlannedWorkout.shape`** → read
  [LEARNINGS.md](LEARNINGS.md#adding-a-kind-to-an-existing-model) first. The `Shape` enum makes a
  `switch` exhaustive and protects nothing else: five existing readers derived a plan's shape
  straight from its blocks and each said something false about an open-interval plan, including the
  flag that guards against silent data loss. Grep every derivation before adding a case.

- **Anything involving the paired Apple Watch — installing, launching, payloads, reachability,
  `devicectl`** → [docs/WATCH_DEVELOPMENT.md](docs/WATCH_DEVELOPMENT.md) for this project's
  procedure, then the global Xcode playbook's §3 (listed in `~/.claude/CLAUDE.md`; its title does not
  suggest it). **The Mac cannot reach this Watch**; everything goes through the phone, and the watch
  app's event log is readable from `Documents/watch-events.log` on the phone.

- **Before putting a build on the phone, and before quoting a device or OS version** →
  [docs/INSTALLS.md](docs/INSTALLS.md). It logs every install with its commit and branch, and it is
  the single home for current hardware and OS versions — other files point here rather than keeping
  their own copy, which is how five of them went stale at once. Add a row at install time.

## Before diagnosing anything

Read [MISTAKES.md](MISTAKES.md). It is a record of how previous investigations in this repo went
wrong, and the failures repeat: trusting a UI string as evidence, generating hypotheses before
reading the repo's own docs, and stating inferences with the confidence of measurements.

The rule that would have saved the most time: **this app cannot observe the Watch.**
`WorkoutScheduler.shared.scheduledWorkouts` is the phone's list. Any sentence describing it as Watch
state is wrong, and three shipped that way.

## Wanted but not built

[docs/BACKLOG.md](docs/BACKLOG.md), with the reasoning behind each item recorded alongside it.

## Non-negotiable constraint

**The Watch payload must never use API newer than watchOS 10.** The paired Series 5 caps there,
`#available` describes the *phone* and cannot express this, and setting a watchOS 11 field once
crashed and rebooted the Watch. `WorkoutKitServiceTests` fails if `WorkoutStep.displayName` is ever
set again — that test is the enforcement, not a formality.
