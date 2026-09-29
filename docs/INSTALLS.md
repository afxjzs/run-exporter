# Install log

Every build put on real hardware, with the commit and branch it came from. Without this, the
question "is what I am holding the same as what is on disk?" is answered from memory, and the
answer has already been wrong once.

This is also the **one place current hardware and OS versions are recorded**. Other documents point
here instead of restating them — five files drifted out of date at once because each kept its own
copy.

## Current hardware

| Device | Identifier | OS | Notes |
|---|---|---|---|
| iPhone 16 Pro (`My iPhone`) | `<PHONE_COREDEVICE_ID>` | iOS 27.2 | The sideload target. `devicectl list devices` prints the hardware UDID `<PHONE_UDID>` for the same phone; both address it. Version read from `devicectl device info details` on 2026-09-25; this table said "iOS 27" until then. |
| Apple Watch Series 5 (`My Watch`) | `<WATCH_COREDEVICE_ID>` | watchOS 10.6.2 | Cannot go beyond watchOS 10. The payload ceiling is unchanged by the point release. |
| Mac toolchain | — | Xcode 27.0 (27A266a) | |

A **measurement** recorded in `LEARNINGS.md` or `docs/CUE_FEASIBILITY_TEST.md` names the OS version
it was taken on. Those are history and must never be updated to match this table; if the hardware
has moved on, the measurement may simply need re-running.

## Before installing anything older

Installing a build from before `3069029` over a later one **destroys every multi-block plan**,
silently: that schema has no `PlannedWorkoutBlock`, SwiftData drops the table without erroring, and
the plan is left reading `0/0×0`. Check the commit against the log below before going backwards.
`scripts/sideload.sh` prints the same warning. Recorded in `LEARNINGS.md`.

## Never install while a workout is running

`devicectl device install app` **terminates the app** to replace it. Doing that during a workout
kills the run: the phases already completed survive, because `ActiveWorkoutModel.persist` writes each
interval to the store as it ends, but the phase in progress is lost, the session cannot be resumed,
and an abandoned `PendingWorkoutExecution` is left behind for the matcher to trip over later.

Ask whether a run or a test is in progress before installing. "Is the phone unlocked?" is not the
same question — a phone can be unlocked, in a pocket, and eleven minutes into a workout.

Done once, to an owner who had said he was mid-test two messages earlier.

## How to add an entry

Write the row at install time, from the output of the install and launch commands — not from the
intent to install. **Verified** means a command's output was read and said so. Anything else says
what was actually confirmed and what was not.

## Log

| Date | Commit | Branch | Config | Device | What it carries | Verified |
|---|---|---|---|---|---|---|
| 2026-09-07 | `673106f` | `mid-workout-notes` | Release | iPhone 16 Pro | Block plan editor; mid-workout notes; armed start; no default countdown | Installed and launched per the 2026-09-23 handoff. Not verified by the session that wrote this row. |
| 2026-09-23 | `1b03a3e` | `open-interval-runs` | Release | iPhone 16 Pro, iOS 27 | Open-interval plans: their own editor, bout/recovery controls on the run screen, the bout-end reading and note, two new cues, three new columns in `workout_intervals.csv` | **Yes.** `scripts/sideload.sh` reported `BUILD SUCCEEDED`, `App installed` for `is.doug.runexporter`, and `Launched application with is.doug.runexporter bundle identifier`. Built against Xcode 27.0. |

| 2026-09-23 | `9340aa3` | `open-interval-runs` | Release | iPhone 16 Pro, iOS 27 | The same, with "leg" in place of "bout", all five body areas asked at the end of a leg instead of one the plan named, and `targetReached` actually recorded | **Yes.** `BUILD SUCCEEDED`, `App installed`, `Launched application with is.doug.runexporter bundle identifier`. |

| 2026-09-23 | `d8e8985` | `open-interval-runs` | Release | iPhone 16 Pro, iOS 27 | Legs end on the tap so the walk starts with the runner; end-of-leg sheet optional and satisfied by a note alone; half-point body signals; remaining-time cue matches the clock; slide-to-confirm pause and skip; skip hidden on open runs | **Yes.** `BUILD SUCCEEDED`, `App installed`, `Launched application with is.doug.runexporter bundle identifier`. Installed after the owner's test finished, at his go-ahead. |

| 2026-09-23 | `b3f5164` | **`main`** | Release | iPhone 16 Pro, iOS 27 | Open intervals merged. Adds duration wheels in both plan editors and exports named for the day they were taken rather than "now" | **Yes.** `BUILD SUCCEEDED`, `App installed`, `Launched application with is.doug.runexporter bundle identifier`. First install from `main` since open intervals began. |

| 2026-09-25 | `da40774` | **`main`** | Release | iPhone 16 Pro, iOS 27.2 | Everything from the first outdoor run: the recovery walk's countdown moves from the button label to the headline and the button always reads "Start next leg"; a 3-2-1 into the walk floor; and a workout that misses the two-minute join window is now diagnosed and offered instead of reported as "No Apple Watch workout found" | **Yes.** `BUILD SUCCEEDED`, then `App installed` with `bundleID: is.doug.runexporter`, then `Launched application with is.doug.runexporter bundle identifier`. Built against Xcode 27.0 (27A266a). 329 tests, 0 failures, before installing. |

| 2026-09-25 | `497e163` | **`main`** | Release | iPhone 16 Pro, iOS 27.2 | Same code as `da40774` (the two commits since touch only docs), with a new watch profile that lists the Apple Watch. **This build's watch app was broken**: an incremental build swapped the profile in without re-signing the bundle — see below | Phone: `App installed`. The Watch refused it with `0xe8008017 (A signed resource has been added, modified, or deleted.)`. `codesign --verify --deep --strict` on the **outer** app reported `valid on disk` and did not catch it. |

| 2026-09-25 | `497e163` | **`main`** | Release | iPhone 16 Pro, iOS 27.2 | The same, from a **clean** build, so the watch app is signed together with its new profile | **Phone: yes.** `BUILD SUCCEEDED` with a separate `CodeSign` step for the watch app; `codesign --verify --strict` run **on the nested watch app itself**: `valid on disk`; its profile's `ProvisionedDevices` includes the Watch; `App installed` with `bundleID: is.doug.runexporter`. Not launched by command. **Watch: installed** (owner, from the iPhone's Watch app — the first watch install ever to succeed). On launch the Watch asked for Developer Mode; the **Developer Mode row appeared in Privacy & Security only after this install**, with Xcode never having reached the Watch. Enabled by the owner, Watch restarted. |

| 2026-09-25 | **uncommitted**, on `497e163` | `watch-link` | Release, clean | iPhone 16 Pro, iOS 27.2 | Watch link step 1: Settings → **Watch link test** launches the watch app via `startWatchApp`, the watch mirrors its session back, ping/pong and heart-rate status. Phone now requests workout share access and declares `workout-processing` | **Phone: yes.** `BUILD SUCCEEDED`; nested watch app `codesign --verify --strict` valid; built plist carries `NSHealthUpdateUsageDescription` and `UIBackgroundModes` `["audio","workout-processing"]`; 336 tests, 0 failures; `App installed`. **Watch: installed on the second attempt.** The first, started with the Watch asleep on its charger, hung: the phone's `appconduitd` log shows the 317,256-byte transfer finish at 10:40:27, then `Install of is.doug.runexporter.watchkitapp was not acknowledged in 60 seconds`, no error code, and the Watch stuck on "Uninstalling…" after the owner cancelled. After a Watch restart, installed from the Watch app with the Watch on the wrist — "REALLY slow", but it completed. Whether sleep caused the hang is **not established**. **Result:** `startWatchApp` returned success on the phone in about 0.09 s and nothing happened on the Watch — no session, no link screen, and no Health sheet on either device. |

| 2026-09-25 | **uncommitted**, on `497e163` | `watch-link` | Release, clean | iPhone 16 Pro, iOS 27.2 | Watch side only: asks for all link Health types when the Watch app opens; a phone launch checks `statusForAuthorizationRequest` and **stops with a message** instead of waiting on a permission sheet that cannot appear; the link screen now shows when a launch *arrives*, with the last step reached. Suspect for the failure above: the link asked for `distanceWalkingRunning`, which the probe never had | **Phone: yes.** `BUILD SUCCEEDED`, separate `CodeSign` for the watch app, nested `codesign --verify --strict` valid, `App installed`. Tests not re-run: only watch files changed, and none are tested. **Watch: installed** — the phone's `appconduitd` log shows `Finished install` at 11:24:30 with `watchKitAppExecutableHash=813dfe89…`, which **equals the SHA-256 of the local build's watch executable**. **Result:** one launch at 11:30:10; the phone's `healthd` logged `Starting workout app is.doug.runexporter on watch`, sent it to `My Watch (active)`, and got the Watch's response at 11:30:11.295 (0.38 s). The phone app's `startWatchApp` returned success *before* that response. The Watch showed no link screen — but the breadcrumb lived in memory only, so this does not prove the launch never reached the app. |

| 2026-09-25 | **uncommitted**, on `497e163` | `watch-link` | Release, clean, **build `202609251338`** | iPhone 16 Pro, iOS 27.2 | Watch side only: a **saved** event log (process start, `didFinishLaunching`, `handle(workoutConfiguration)`, every step and error, screen state) shown on a second page, and the build number on the first. `sideload.sh` now stamps a timestamp build number, builds clean, and verifies the nested watch signature | **Phone: yes.** `BUILD SUCCEEDED`; both apps' `CFBundleVersion` = `202609251338`; nested `codesign --verify --strict` valid; no warnings in watch files; `App installed`. **Watch: installed**; owner confirmed the second page (event log) is present. **Result:** two launches from the phone (the phone's `startWatchApp` returned "success" after 4.13 s, then 0.19 s). The Watch's saved log showed **no process start and no `handle(workoutConfiguration)`** after either — watchOS never launched the app. |

| 2026-09-29 | **uncommitted**, on `497e163` | `watch-link` | Release, clean, **build `202609290842`** | iPhone 16 Pro, iOS 27.2 | Watch plist gains `WKBackgroundModes` = `["workout-processing"]` — watchOS's own key; the app had the mode only under `UIBackgroundModes`. Hypothesis: watchOS declines a phone-requested workout launch without it | **Phone: yes.** `BUILD SUCCEEDED`; **built** watch plist: `WKBackgroundModes` `["workout-processing"]`, `UIBackgroundModes` `["workout-processing","audio"]`; nested `codesign --verify --strict` valid; `CFBundleVersion` `202609290842`; `App installed`. **Watch: installed. Result: the phone launched the watch app** — the first time `startWatchApp` has ever reached this app's code, and the only change from the build before was this plist key. The owner reported the app started (it was already running, not frontmost). Killing it mid-session then left the phone test screen with every button disabled. The watch's event log of the launch was cleared by accident before it was read, so no step-by-step record of this run exists. |

| 2026-09-29 | **uncommitted**, on `497e163` | `watch-link` | Release, clean, **build `202609290857`** | iPhone 16 Pro, iOS 27.2 | Diagnostics readable without a screen: the watch forwards every event-log line over `WCSession.transferUserInfo`; the phone appends them to `Documents/watch-events.log` and its own link events to `Documents/watch-link-phone.log` (`DiagnosticLogFile`, 4 new tests). Phone test screen gains **Reset this screen** | **Phone: yes.** `BUILD SUCCEEDED`; 340 tests, 0 failures; nested `codesign --verify --strict` valid; `CFBundleVersion` `202609290857`; `WKBackgroundModes` still present; `App installed`. **Watch: installed** (owner confirmed the build on the watch screen). **Result — step 1's launch works from cold**, read from the phone's `Documents/watch-events.log` and `watch-link-phone.log`: owner killed the watch app; tap at 16:05:23.701 UTC; watch process started 09:05:24.3 PDT; `handle(workoutConfiguration)` 24.6; Health status 2 (granted); session running and iPhone link connected 25.2; phone logged **mirrored 1.71 s after the tap** and the first status at 16:05:27.015. Forwarded watch-log lines arrived within seconds. Ping round trip not yet measured. |

| 2026-09-29 | `e08bb50` | `main` | Release, clean, **build `202609291030`** | iPhone 16 Pro, iOS 27.2 | Watch plan step 2, both sides: Start launches the Watch; phases, pause and finish reach it; the Watch's run screen (phase, time left, heart rate, leg pace, mile split, distance); phase segments written into the workout; finish **saves** the workout with the execution id and the GPS route. First build from the public repository | **Phone: yes.** `BUILD SUCCEEDED`; 366 tests, 0 failures; built watch plist carries `NSLocationWhenInUseUsageDescription` and `WKBackgroundModes`; nested `codesign --verify --strict` valid; `App installed`. **Watch: installed. Result — a short test on foot works end to end** (LEARNINGS.md, "The first run driven from the phone"). Found: timers about 1 s apart (rounding + an inflated latency estimate), a spurious route error, and the phone waiting out its timeout on a permission error the Watch had already reported. |

| 2026-09-29 | `91cb17d` | `main` | Release, clean, **build `202609291316`** | iPhone 16 Pro, iOS 27.2 | Fixes from that test: Watch countdown rounds up like the phone's; latency is the minimum of three connect-time pings, with the phase re-sent as it improves; no `finishRoute` call, and an honest route line; the phone shows a Watch error reported during a launch at once | **Phone: yes.** `BUILD SUCCEEDED`; 370 tests, 0 failures; nested `codesign --verify --strict` valid; `App installed`. **Watch: installed** (owner). |

| 2026-09-29 | (see commit) | `main` | Release, clean, **build `202609291331`** | iPhone 16 Pro, iOS 27.2 | Watch plan step 3: the phone joins a run to the Watch's workout by the execution id saved in the workout's metadata, before any time window; the metadata key moves to shared code | **Phone: pending.** `BUILD SUCCEEDED`; 374 tests, 0 failures; nested `codesign --verify --strict` valid. |

### Why the watch app never installed (2026-09-25)

From 2026-08-08 until this row, every build's watch app was signed with Xcode-managed profile
(created 2026-08-08) whose `ProvisionedDevices` held the old and current iPhones and
**not the Watch**. The Watch had never been registered with the team, because Xcode registers a
device when it connects to it, and this Watch has never held a connection. The Watch app on the
phone listed RunExporterWatch under Available Apps; tapping Install filled the progress ring and
reverted to "Install" with **no error**.

Fix: register the Watch by hand at developer.apple.com (UDID `<WATCH_UDID>`), then
**remove the cached profile** from `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` —
`-allowProvisioningUpdates` kept reusing it, since it was still valid, and does not compare device
lists. The next build fetched a new profile, which lists the Watch. Check with:
`security cms -D -i "<App>.app/Watch/<Watch App>.app/embedded.mobileprovision"`.

**Then build clean.** The incremental build after the profile change copied the new
`embedded.mobileprovision` into the watch app and did not re-sign it — the log has no `CodeSign`
step for the watch target. `codesign --verify --deep --strict` on the outer iPhone app still said
`valid on disk`; only verifying the nested watch app directly showed `file modified: …/embedded.mobileprovision`.
**Verify the nested bundle itself**, not the host.

The Watch gives no error on screen. The reason is in the **iPhone's** log, from `appconduitd`:
`sudo log collect --device-udid <phone UDID> --last 30m --output <path>`, then `log show` that
archive and search for the watch app's bundle id and `0xe800`.

### What the `da40774` code has not done

Two open-interval sessions were run indoors and exported. The data is in the owner's exports
(`running_health_extract_<start>_to_now.zip`), and it holds: leg caps chain down
to the target exactly, the final leg records `targetReached`, `baselineReachedAt` is present on the
walks where it was tapped and blank where it was not, and the walks started early under the new
confirmation record as short walks rather than skipped ones.

**The first outdoor run** used `b3f5164`, and open intervals worked: leg caps chained to the
target exactly, the final leg recorded `targetReached`, each rated leg recorded its body-signal
reading, and the two-minute join held with zero warnings in `export_log.json`. The owner's verdict
was *"it worked great for a v1 of that feature"*. Data in the export for that day
(`running_health_extract_<start>_to_<end>.zip`).

**What `da40774` has not done: any run at all.** Everything installed on 2026-09-25 was written in
response to that run and has never been used during one. Specifically unmeasured:

- Whether the floor countdown in the headline reads better at a glance than the old button label
  did. It was built because the headline showed an em-dash for the entire walk, which is plainly
  worse — but "not plainly worse" is not the same as measured.
- Whether the 3-2-1 into the walk floor lands usefully, or just adds noise to a boundary the runner
  is already waiting for.
- **The near-miss join offer has never fired**, and cannot be made to fire on purpose without
  deliberately starting the phone and Watch more than two minutes apart. Four tests cover the
  matcher's decision; nothing covers the screen that presents it.

Still true, and still the gap the tests cannot close: they cover the model, the sequencing, the
migration and the export, and none of the screens, which have no seam to test at.

The app does not embed its commit SHA, so an installed build cannot be traced back to a commit by
querying the phone. This table is the only link, which is why the row goes in at install time.
