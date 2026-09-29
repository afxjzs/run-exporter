# RunExporter — agent instructions

Pointers only. The content lives in the files named below; duplicating it here would let the two
copies drift, which this project already has a documented history of.

## THIS REPOSITORY IS PUBLIC — nothing personal goes in a commit

Published at github.com/afxjzs/run-exporter since 2026-09-29. **Committed files and commit messages
carry the engineering lesson; the owner's specifics live in git-ignored local files.** See
[private/README.md](private/README.md).

- **Never commit:** device IDs or names, the Team ID, the owner's run dates/times, heart rates,
  distances, body-signal ratings, health details, export filenames with real dates. Write "heart
  rate per leg separated running from walking" in a document; put the numbers in
  `private/run-notes.md`. The same goes for **commit messages** — the pre-public repository could
  never be published because its messages held exactly these.
- **Where the specifics live:** `Config/Local.xcconfig` (Team ID), `scripts/local.env` (device IDs),
  `private/` (run notes, the guard's pattern list, and `private/archive-docs/` — the full-detail
  docs as they stood before going public). The full old history is the private repository
  `afxjzs/run-exporter-archive`.
- **The guard** (`scripts/check-sensitive.sh`, hooks in `.githooks/`) blocks listed values and refuses
  to run without its list. It cannot recognize prose about the owner's health — that part is on you.
- **Commands in documents use placeholders.** `scripts/local.env` holds the CoreDevice ids —
  `PHONE_DEVICE_ID` for `<PHONE_COREDEVICE_ID>`, `WATCH_DEVICE_ID` for `<WATCH_COREDEVICE_ID>` — and
  you may read it to run them. Hardware UDIDs (`<PHONE_UDID>`, `<WATCH_UDID>`) are not stored there;
  find them with `xcrun devicectl list devices`.

## The documentation, and which file answers what

Twelve committed files (counted 2026-09-29), plus the git-ignored material `private/README.md` indexes. **This table is the index.** Until 2026-09-25 four of these were
reachable from nothing that loads automatically — 71% of the words in the repo — including the spec
that 67 `spec §…` citations across 39 Swift files point at (counted 2026-09-29).

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
| [private/README.md](private/README.md) | What is kept out of this public repo and where — and the git-ignored files beside it: `run-notes.md` (real run measurements), `archive-docs/` (pre-public docs with every detail) | Before writing anything about the owner's runs or devices, and when a public doc says a detail is private |

## Citing code from a document

**Name the symbol, never the line.** `RecentWorkoutMatcher.startToleranceSeconds`, not
`RecentWorkoutMatcher.swift:74`. Line citations in this repo have gone wrong within the hour of
being written, because fixing the code a citation points at is exactly what moves it.

Commit hashes older than `610fdd2`, the first commit here, refer to the private pre-public archive
and are not in this repository.

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
  real workout unmatchable. The defect that entry was written about — a miss reported as a
  different problem, with a remedy that could not work — is fixed. Since watch plan step 3, a
  workout saved by the watch app carries the execution id (`WorkoutMetadataKeys.executionID`) and
  joins by it before any time window; the window is the fallback for untagged workouts.

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

The rule that would have saved the most time: **`WorkoutScheduler.shared.scheduledWorkouts` is the
phone's list, not the Watch's.** Any sentence describing it as Watch state is wrong, and three
shipped that way. Since 2026-09-29 the phone does see some Watch state, through this app's own watch
link (`WatchLink`, during a run or the link test): the mirrored session's state, the heart rate the
watch sends, and the watch's forwarded event log. It still cannot see the Watch save a workout.

## Wanted but not built

[docs/BACKLOG.md](docs/BACKLOG.md), with the reasoning behind each item recorded alongside it.

## Non-negotiable constraint

**The Watch payload must never use API newer than watchOS 10.** The paired Series 5 caps there,
`#available` describes the *phone* and cannot express this, and setting a watchOS 11 field once
crashed and rebooted the Watch. `WorkoutKitServiceTests` fails if `WorkoutStep.displayName` is ever
set again — that test is the enforcement, not a formality.
