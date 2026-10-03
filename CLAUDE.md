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

Thirteen committed files (counted 2026-10-03), plus the git-ignored material `private/README.md` indexes. **This table is the index.** Until 2026-09-25 four of these were
reachable from nothing that loads automatically — 71% of the words in the repo — including the spec
that 67 `spec §…` citations across 39 Swift files point at (counted 2026-09-29).

| File | Answers | Read it when |
|---|---|---|
| [README.md](README.md) | What the app does, produces, and cannot do; architecture; known limitations | Orienting, or before describing the app to anyone |
| [RUNNING_APP_V1_1_SPEC.md](RUNNING_APP_V1_1_SPEC.md) | **What `spec §…` means.** The v1.1 requirements, and only those — it does **not** cover open-interval runs, which were built later and specified nowhere | Any time source cites a bare `spec §` number |
| [docs/AEROBIC_TRACKING_SPEC.md](docs/AEROBIC_TRACKING_SPEC.md) | **What `aerobic spec §…` means.** The aerobic training and heart-rate tracking requirements (added 2026-10-03): intensity intent, live HR, post-run analysis, export. Its § numbers are its own — cite them as `aerobic spec §N`, never bare `spec §N`, which already means v1.1 | Before any aerobic, heart-rate or analysis work |
| [LEARNINGS.md](LEARNINGS.md) | Measured facts, each dated | Before trusting any claim about this hardware |
| [MISTAKES.md](MISTAKES.md) | How past investigations went wrong | Before diagnosing anything |
| [docs/BACKLOG.md](docs/BACKLOG.md) | Wanted but not built, and things deliberately **not** to build, with reasoning | Before building anything that sounds new |
| [docs/INSTALLS.md](docs/INSTALLS.md) | Every install; the single home for hardware and OS versions | Before installing, or quoting any version |
| [docs/CUE_FEASIBILITY_TEST.md](docs/CUE_FEASIBILITY_TEST.md) | Cue feasibility test procedures and their dated results | Before changing cues or the Lock Screen card |
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
touched, so for eighteen days they told readers to press buttons that were no longer there. (The
whole WorkoutKit screen, "Clear this iPhone's queue" included, was later removed in the 2026-09-29
clean-out — see docs/BACKLOG.md.)

Nobody invented anything, and that is the point: ordinary renaming is enough.
`RunExporterTests/DocumentationDriftTests.swift` now fails when a quoted UI string is gone from the
source, and names every document that quotes it. Add an entry there when a doc starts quoting a new
label — that test is the enforcement, not a formality. **When you remove a control**, move its
entry to `retiredLabels`; any document that still names it must then say where it went.

## Read before you touch these areas

- **Anything about getting a workout onto the Watch** → the phone's Start launches this app's own
  watch workout (`WatchLink`); see [docs/WATCHOS_RECORDER_PLAN.md](docs/WATCHOS_RECORDER_PLAN.md).
  The older WorkoutKit route (`WorkoutKitService`, `SendToWatchView`) was removed in the 2026-09-29
  clean-out. **Before bringing WorkoutKit back**, read [LEARNINGS.md](LEARNINGS.md): on the owner's
  hardware `WorkoutScheduler.schedule(_:at:)` never delivered, Apple's preview sheet did, and a
  watchOS 11 field in the payload once crashed and rebooted the Watch.

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

- **Slicing anything by a run's legs, or touching `RecordedRun`, the `actual*` export columns or
  `ShapeZeroRepair`** → read two [LEARNINGS.md](LEARNINGS.md#adding-a-kind-to-an-existing-model)
  entries first: *"A paused leg's recorded window is not its running time"* and *"The readers kept
  coming because the zeros were stored"*. A paused leg's recorded `startDate`/`endDate` overlap
  the pause and miss its real first seconds, so anything asking what happened **between** two
  timestamps — heart rate per leg, for one — must use `RecordedRun.Leg.activeWindows`. Shape
  fields are `Int?` and never store a sentinel zero; a continuous run's walk of 0 is real.

- **Anything involving the paired Apple Watch — installing, launching, payloads, reachability,
  `devicectl`** → [docs/WATCH_DEVELOPMENT.md](docs/WATCH_DEVELOPMENT.md) for this project's
  procedure, then the global Xcode playbook's §3 (listed in `~/.claude/CLAUDE.md`; its title does not
  suggest it). **The Mac cannot reach this Watch**; everything goes through the phone, and the watch
  app's event log is readable from `Documents/watch-events.log` on the phone. **Any install, phone
  or Watch, can turn the Watch's Workout Routes off** (WATCH_DEVELOPMENT.md §2); the Watch's
  per-type Health check and launch decision are `WatchHealthAccess`.

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
link (`WatchLink`, during a run): the mirrored session's state, the heart rate the
watch sends, and the watch's forwarded event log. It still cannot see the Watch save a workout.

## Wanted but not built

[docs/BACKLOG.md](docs/BACKLOG.md), with the reasoning behind each item recorded alongside it.

## Non-negotiable constraint

**Nothing that runs on the Watch may use API newer than watchOS 10.** The paired Series 5 caps
there, and a watchOS 11 field once crashed and rebooted the Watch. That field was in a WorkoutKit
payload the phone built, where `#available` describes the *phone* and could not guard it; that
route was removed in the 2026-09-29 clean-out, along with `WorkoutKitServiceTests`, which enforced
it. The watch app's own code is now guarded by the compiler: its target's
`WATCHOS_DEPLOYMENT_TARGET` is `10.0`, so newer API fails the build unless wrapped in `#available`.
**Do not raise that setting.** Anything the phone sends the Watch is this app's own
`WatchLinkMessage`, not an Apple payload.
