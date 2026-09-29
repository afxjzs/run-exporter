# Audio cue feasibility tests — protocol and results

Spec §26, Tests 1–4. These are the two deliverables that **cannot be produced without the physical
hardware**: whether a cue is audible, unambiguous and correctly routed is a question only a person
wearing the AirPods can answer. Nothing in the automated suite can substitute for it.

## Status

| Test | Status |
|---|---|
| 1 — Native Apple Workout cues | **FAILED on this hardware 2026-08-07.** Apple's voiceover *does* speak at transitions, but announces the interval just finished ("previous interval: zero feet") and never names the phase you are entering. The field that would — `WorkoutStep.displayName` — is watchOS 11+ and rebooted this Series 5. May work on a newer Watch. |
| 2 — iPhone audio engine | **PASSED 2026-08-07** — cues audible; lock-screen continuity proven by Test 3; **ducking confirmed by ear against Netflix, and media never paused.** |
| 3 — Backgrounding / locked screen | **PASSED 2026-08-07** — every cue fired while locked; phase and elapsed time correct on return. Found a separate Live Activity defect (below). |
| 4 — Audio interruption | **not run** |

### Already found and fixed on device

Two faults that no simulator test could have caught, both from real runs:

1. **`setCategory` was failing with `paramErr (-50)`.** `.allowAirPlay` (play-and-record only) and
   `.allowBluetoothA2DP` (implicitly true and unsettable for `.playback`) were passed to a
   `.playback` session. One bad option fails the whole call, so the category was never applied and
   the session stayed on the default `.soloAmbient` — which does not play in the background, is
   silenced by the Ring/Silent switch, and interrupts other audio instead of ducking it.

   **Cues still sounded normally in the foreground**, so hearing them proved nothing. Settings ›
   Cue test now reports **Background capable** for exactly this reason.

   The simulator *accepts* the invalid option set the device rejects, which is why this survived
   to a real run. See `AudioSessionConfigurationTests`.

2. **The Live Activity was destroyed by its own cleanup.** Stale-activity clearing was a detached
   `Task` that ran *after* the new activity was created, then ended it. Fixed by doing both in one
   ordered task; orphan cleanup moved to app launch.

*Dated, and superseded by the Status table above, where Test 3 has passed. Kept as written:*
"Status of the underlying requirement: still unconfirmed. Test 3 below is what actually proves cues
survive a locked screen, and it has not been run since the audio fix. v1.1.0 is installed on the
iPhone and both it and the Watch are paired and available, so the protocol below can be run now."
For what is installed today, see [INSTALLS.md](INSTALLS.md).

Before starting, confirm the background audio mode actually shipped in the build you are testing —
it is declared in `Config/RunExporter-Info.plist`, and an earlier build silently lacked it:

```bash
plutil -extract UIBackgroundModes json -o - \
  build/Build/Products/Release-iphoneos/RunExporter.app/Info.plist
# must include "audio" (today it prints ["audio","workout-processing"])
```

If that prints nothing, Tests 2 and 3 will fail on lock/background for a build-configuration
reason, not an audio one.

Run both tests from **Settings › Cue test** in the app, which starts a real audio session (the same
configuration a workout uses) and logs every cue the app attempted, so what you heard can be
compared against what was requested.

---

## Test 1 — Native Apple Workout cues (spec §10.1, Path A)

Determines whether Apple's own Workout app is sufficient, in which case `Cue source` can be set to
**Apple Workout** and the app's own engine stays off.

> **Watch compatibility.** The paired Apple Watch Series 5 runs **watchOS 10.x** and cannot go
> beyond watchOS 10 — the exact version is in [INSTALLS.md](INSTALLS.md). The workout payload must
> therefore contain nothing newer than watchOS 10.
> An earlier build set `WorkoutStep.displayName` (watchOS 11+) behind an `#available(iOS 18, *)`
> check — which tests the *phone*, not the Watch — and **crashed and rebooted the Watch** on send.
> Fixed in v1.1.1; `WorkoutKitServiceTests` now fails if any step carries that field.
>
> If the Watch misbehaves after a sync, there is **no button that can help**. The one on that
> screen is **Send to Watch › Clear this iPhone's queue**, and it does exactly what it says: it
> clears entries this app scheduled, which live on this iPhone. Nothing this app can call reaches a
> workout already in the Watch's library — `removeAllWorkouts()` and `remove(_:at:)` only address
> what was *scheduled*, and the route that actually delivers is Apple's preview sheet, which puts
> the workout somewhere WorkoutKit cannot address. Delete it on the Watch by hand.
>
> This paragraph previously told you to press **"Remove all workouts from Watch"**. That button was
> real, and this instruction was correct, until `8d145b9` on 2026-09-07 renamed it to **"Clear this
> iPhone's queue"** — named for what it actually does, because it never could reach the Watch. The
> rename did not reach this file, so the step quietly stopped being followable.

### Setup

1. Settings › Cue test › **Create the 1/0:30 × 3 test workout**.
2. Plans › `Cue test 1/0:30 × 3` › **Add to Apple Watch**. This opens Apple's own preview sheet;
   complete it there. The app gets **nothing back** from that sheet and cannot confirm the workout
   arrived, so there is no success message to look for — check the Watch.

   Do not use **Schedule for a time** for this test. It reports "Queued on this iPhone", which is
   only a statement about the phone's queue, and on this hardware it has never delivered.
3. AirPods connected to the **Watch** (not the phone).
4. Start the workout from the Workout app on the Watch.
5. Lower your wrist so the display sleeps.

### Record

| Transition | Sound heard? | Spoken words (verbatim) | Haptic? | Run vs walk distinguishable? |
|---|---|---|---|---|
| Workout start | | | | |
| Run 1 → Walk 1 | | | | |
| Walk 1 → Run 2 | | | | |
| Run 2 → Walk 2 | | | | |
| Walk 2 → Run 3 | | | | |
| Run 3 → Cooldown | | | | |
| Workout complete | | | | |

Also record:

- Did cues route to **AirPods**, or only to the Watch speaker?
- Did cues fire with the **display asleep**?
- Was the **open cooldown** signalled at all?
- Did anything play through the **iPhone**?

### Pass criteria

Pass **only** if run, walk and cooldown are each unambiguous by ear alone, through AirPods, with the
display asleep. "A haptic happened" is not a pass: a buzz that means "run" and a buzz that means
"walk" are the same buzz.

**Result: ✅ Apple's voiceover DOES announce the upcoming phase — but see §Audio routing, which
decides whether that is usable at all.**

**Apple's Workout app speaks at interval transitions**, using its own built-in voiceover, and fires a
haptic. The announcement carries **both** a summary of the interval just completed **and the phase
being entered** — verbatim example at the final transition:

> *"previous interval: zero feet … now cool down"*

("zero feet" because the test was stationary.) So the phase name *is* spoken. This is a pass on the
audibility question that Test 1 was written to answer.

**Still to confirm:** the exact wording at the **run → walk** and **walk → run** boundaries. Since
`WorkoutStep.displayName` is not set (see below), Apple falls back to its own labels for
`IntervalStep.Purpose` — likely "work" and "recovery" rather than "run" and "walk". Those are still
unambiguous by ear, which is what the criteria require, but the wording should be recorded verbatim.

### Why, precisely — and why this is a hardware limit, not an API dead end

The field that would carry the phase name is **`WorkoutStep.displayName`**, and this project cannot
set it: it is **watchOS 11+**, and an earlier build that set it behind an `#available(iOS 18, *)`
check — which tests the *phone*, not the Watch — **crashed and rebooted this Series 5**. See the
warning at the top of this test. `WorkoutKitServiceTests` now fails if any step carries that field.

`WorkoutAlert` is not a substitute: it covers threshold conditions (heart rate, pace, cadence,
power), not step announcements.

So on **watchOS 10 there is no legal payload that makes Apple's Workout app name the phase.** On a
**watchOS 11+ Watch this may well work**, because `displayName` exists there and Apple's voiceover
already demonstrably speaks at transitions. That is worth knowing if the paired Watch is ever
replaced — but it is untestable here.

**⚠️ Do not "just try" setting `displayName` to check.** That is what rebooted the Watch.

### Two setup lessons that nearly produced a wrong result

1. **A first attempt heard nothing at all and looked like a clean fail.** The AirPods had gone
   dormant with no audio flowing; a cue fired into a route that was not live. Starting a Spotify
   track made the voiceover audible. **Silence measured against an idle audio route is not
   evidence.** Always run this test with media already playing — Test 2's protocol says so at step
   3, and Test 1's setup should say it too.
2. The haptic firing was genuine and useful throughout: it confirmed the payload arrived and the
   step structure was honoured, which is what made the silence worth questioning rather than
   accepting.

**Conclusion — Path A cannot satisfy the audio requirement on this Watch.** Spoken run/walk cues
must come from this project's own code: the iPhone engine (Path B, which passed Test 3), or a
watchOS recorder owning its own audio (Path C, §10.3).

**Known limitation of the payload, stated honestly.** `WorkoutKitService.step(goal:)` builds
`WorkoutStep(goal:)` and sets **no `WorkoutAlert`**, and `displayName` is deliberately omitted
because it is watchOS 11+ and previously crashed and rebooted this Watch (see §Test 1 warning). So
this was a minimal payload. It does not change the conclusion: `WorkoutAlert` covers threshold
conditions — heart rate, pace, cadence, power — and offers no mechanism to announce "run" or "walk"
at a step boundary. There is no watchOS 10-legal payload that would make Apple's Workout app speak
the intervals.

**Conclusion — Path A cannot satisfy the audio requirement.** Spoken run/walk cues have to come from
this project's own code: the iPhone engine today (Path B, which passed Test 3), or a watchOS
recorder that owns its own audio (Path C, §10.3).

### Also learned during this test

- **WorkoutKit scheduling reaches the Watch with a delay of minutes.** The workout was not visible on
  the Watch immediately, and **Send to Watch reported `Scheduled on Watch: 0` while it was in fact on
  its way** — it appeared on the wrist afterwards. That screen's footer currently claims a count of 0
  after a send means the workout never arrived; **that claim is wrong** and should be reworded to say
  the count can lag.

  **Fixed 2026-08-13.** The whole screen read the phone's schedule and described it as the Watch's.
  Three separate sentences did it — the status footer, the "No workouts are scheduled on the Watch"
  clear-confirmation, and the retry advice — and all three misled during a real diagnosis: the user
  hunted for a failed send that had in fact succeeded, and was told the Watch was clear while a
  stale workout was still on the wrist. The section is now "Schedule on this iPhone", the count
  reads "Queued on this iPhone", and every message states that delivery is separate and can lag in
  both directions. `WorkoutScheduler.scheduledWorkouts` is the phone's copy; nothing reachable from
  iOS observes the Watch, and no wording may imply otherwise.
- `send(plan:)` schedules at `Date()` — the current minute. Worth revisiting: an appointment for the
  minute already in progress is an odd thing to ask the scheduler for.

  **Changed 2026-08-13** to `Date() + WorkoutKitService.scheduleLeadSeconds` (5 minutes), and the
  scheduled time is now shown in the send confirmation so it can be compared against the wrist.
  **This is not claimed as a fix for delivery.** Whether watchOS declines to surface a past-dated
  scheduled workout is still unestablished — there is no documented rule and it has not been
  measured here. It removes a known-odd input and makes the question testable, nothing more.
- **Re-sending used to accumulate copies.** Every send built a fresh `WorkoutPlan` with a new id
  while the plan remembered only the newest, so earlier copies became unaddressable and piled up
  under the same display name until the schedule hit its cap. `send` now removes the plan's previous
  instance first, and reports in the UI when that removal fails.

### Test 5 — does `WorkoutScheduler` deliver at all? (2026-08-13)

Not planned. Run because sends stopped arriving on the wrist and the cause was not in the app.
**iPhone 16 Pro (iOS 26.6) ↔ Apple Watch Series 5 (watchOS 10.6.1).**

| Workout | Route | Radios at send | Result |
|---|---|---|---|
| `4/1 × 5` | `schedule(_:at:)` | on | **never arrived** (26 h) |
| `4/1 × 5` | `schedule(_:at:)` | on | **never arrived** |
| `5/1 × 4` | `schedule(_:at:)` | **Wi-Fi + BT off** | **never arrived** |
| `90/60 × 8` | `schedule(_:at:)` | on | **never arrived** |
| `90/60 × 8` | `.workoutPreview` sheet | on | **arrived** |
| `10/1 × 2` | `.workoutPreview` sheet | on | **arrived** |

`5/1 × 4` and `90/60 × 8` had never been on the Watch, so "it was already there" explains nothing.
The same `90/60 × 8` failed by one route and succeeded by the other minutes apart.

**Ruled out by measurement, not reasoning:** permission (`authorized` throughout); the Bluetooth link
(Ping iPhone reached the phone); connectivity at send time (the radios-off send behaved identically
to the radios-on ones); the payload (Apple's own sheet rendered the blocks correctly — Repeat ×7 of
Work 1:30 / Recovery 1:00, then a standalone Work 1:30, then open Cooldown).

**`removeAllWorkouts()` could not clear the queue either.** It stayed at 4 across refreshes. The
scheduler store accepts writes and then neither delivers nor forgets them — which is why this reads
as a wedged system component rather than a delivery lag.

**Consequences, already applied:**

- `SendToWatchView` makes **Add to Apple Watch** (the preview sheet) the primary action. Scheduling is
  demoted and labelled. Do not reverse this without re-running the table above.
- The schedule list now flags entries past their time as **overdue by 1d / 2h / 50m**, with a banner.
  Nothing surfaced this before, which is how an entry sat dead for 26 hours looking exactly like a
  fresh one, and every test that day ran on top of a queue nobody knew was jammed.

**Still unknown:** whether watchOS suppresses a past-dated scheduled workout. It is not the cause here
— future-dated sends failed identically — so the question is open but no longer load-bearing.

---

## Test 2 — iPhone audio engine (spec §26, Test 2)

The app-owned fallback. Implemented and shipping regardless of Test 1's outcome, per the brief.

### Setup

1. Settings › **Cue source: iPhone audio engine**, **Cues: Voice + beeps**.
2. AirPods connected to the **iPhone**.
3. Start music or a podcast.
4. Today › **Start Audio Timer** on the `1/0:30 × 3` workout. Since `e7f7b96` this only *opens* the
   screen, armed — no timer, no audio session, no Live Activity until you tap **Start** on it. The
   run begins on that second tap, so start counting from there. Since watch plan step 2
   (2026-09-29) that tap also launches a workout on the Watch, which is saved when the run
   finishes; abandon the run to have the Watch discard it.

### Record

| Check | Result (2026-08-07, v1.3.0, iPhone 16 Pro, AirPods on phone, **Netflix** playing) |
|---|---|
| "3, 2, 1" heard before the start | ✅ — reported as "exactly right" across the whole run |
| "Run" at each run transition | ✅ |
| "Walk" at each walk transition | ✅ |
| "Cooldown" after the final run | ✅ |
| "Workout complete" at the end | ✅ |
| Video **ducked** during a cue, then returned to full volume | ✅ **yes — this was the open question, and it passes** |
| Video **never permanently paused** | ✅ **yes — proven objectively, see below** |
| Cues continued with the **phone locked** | ✅ (also Test 3) |
| Cues continued with the **app backgrounded** | ✅ (also Test 3) |
| Timer drift after the full workout (compare to a stopwatch) | **not measured** — no stopwatch was run alongside |

### Known deviation from the spec's suggested audio configuration

Spec §9.4 suggests `[.duckOthers, .interruptSpokenAudioAndMixWithOthers, .allowBluetooth,
.allowAirPlay]`. Two changes were necessary and are documented in `AudioCueEngine`:

- **`.allowBluetooth` is deprecated** and its replacement `.allowBluetoothHFP` selects the *call*
  profile, which would drop AirPods to mono call quality for the entire workout. `.playback`
  already routes to A2DP, so `.allowBluetoothA2DP` is set and HFP deliberately is not.
- **`.interruptSpokenAudioAndMixWithOthers` pauses spoken audio** until the session is deactivated.
  The session must stay active for the whole workout to keep the timer running in the background,
  so that option would leave a podcast paused for the entire run — which the same spec section
  forbids. Cues **duck** instead, and ducking is applied **per cue** rather than for the session, so
  media plays normally between cues and dips only while a cue sounds.

The per-cue ducking behaviour is the single most important thing to confirm by ear in this test.

**Result: ✅ PASS (2026-08-07).** Run against **Netflix** — the exact scenario in requirement 1 — with
AirPods bound to the phone and the phone locked. Cues were reported as "exactly right": audible over
the video, dipping it and letting it return. **The per-cue `.duckOthers` cycling works on device.**

**This closes requirement 3** ("hear audio cues when i am running") for the phone-only path, and with
it the last unverified piece of the v1.1 audio brief. Combined with Test 1's conclusion, the decision
to keep cues on the phone is now backed by measurement at both ends: Apple's Watch cues are unusable
on this hardware, and the phone engine works while Netflix plays.

### The "never paused" row was proven objectively, not just by ear

Three Lock Screen captures during the run, comparing Netflix's own transport position against the
Live Activity's elapsed clock:

| Card elapsed | Netflix position | Δ elapsed | Δ media |
|---|---|---|---|
| 0:45 | 19:03 | — | — |
| 1:10 | 19:28 | +25 s | +25 s |
| 1:39 | 19:57 | +29 s | +29 s |

**Media time advanced exactly in step with wall-clock time**, across an interval boundary and the
cues either side of it. This is the strongest available evidence for the "never permanently paused"
criterion, and it does not depend on anyone's memory of what they heard: ducking attenuates the
output while the transport keeps running, so a matching delta is the signature of a duck. A pause,
or `.interruptSpokenAudioAndMixWithOthers` behaving as the spec suggested, would have left a visible
deficit. There is none — the two columns agree to the second.

**Method worth reusing:** for any future "did we interrupt other audio" question, photograph the Lock
Screen twice and compare the other app's transport delta against the elapsed delta. It converts a
subjective audio judgement into an arithmetic one.

### Observed during this test — two Live Activity findings, neither an audio fault

1. **"The phase label didn't update."** Correct, and **by design as of this session** — the phase
   word, round count and phase countdown were *removed* from the card because iOS discards
   background `Activity.update` calls and those elements went stale and contradicted the workout.
   There is no label left to update. The user-facing consequence is real, though: **the card no
   longer tells you which phase you are in in words.** Only the timeline bar's colour does. See
   §"What remains genuinely impossible" — the honest options are a watchOS companion or APNs.
2. **The plan summary `1:00 / 0:30 × 3` was misread as "1/0" and did not communicate 3 cycles.**
   A legibility defect in the summary line, not a data error: it means 1:00 run / 0:30 walk, three
   rounds. Reported by the user on first reading of a real card. Worth rewording.

---

## Test 3 — Backgrounding (spec §26, Test 3)

1. Start the timer, immediately background the app, leave the phone locked for a full workout.
2. Confirm every cue fired.
3. Return to the app and confirm the phase and elapsed time are correct.

The engine derives everything from absolute timestamps, so a late tick cannot accumulate drift; a
phase crossed while the app was asleep is recorded with its exact planned boundary and flagged
`wasInterrupted` in `workout_intervals.csv`.

> **`wasInterrupted` under-reports — do not treat a clean column as a pass.**
> In `IntervalTimerEngine.advanceThroughElapsedPhases`, the flag is `missed = crossedBoundary`,
> which starts `false`. The **first** boundary crossed in any single tick is therefore always
> recorded as *not* interrupted; only the second and later boundaries within one wake-up get
> flagged. Separately, `fireDueCues` **drops any cue more than 1.5 s stale** rather than replaying
> it late — by design, but it leaves no trace.
>
> So if background audio dies while the app still wakes about once per phase, the result is
> **no sound, no `wasInterrupted`, and no error**. A run of `true` values is strong evidence of
> failure; an absence of them is *not* evidence of success. The ear is the primary instrument here.

### Setup

Same as Test 2 — Cue source **iPhone audio engine**, AirPods on the **phone**, music or a podcast
playing. Use the `Cue test 1/0:30 × 3` plan (Settings › Cue test › create it if absent).

Before locking, on Settings › Cue test confirm **Session: active**, **Background capable: yes**, and
that **Output route** names the AirPods. Then open Today › **Start Audio Timer**, tap **Start** on
the armed screen — that second tap is what begins the run — press the side button immediately, and
leave the phone locked and screen-down for the full four minutes.

Since watch plan step 2 (2026-09-29), **Start** also launches and, at the finish, saves a workout on
the Watch — as in Test 2.

### Expected cue timeline

3 runs and 2 walks — the final run hands straight to cooldown (spec §11.1), so the timed portion is
**4:00**, not 4:30. With stock settings this is **30 cues**.

| Clock | Expected cue |
|---|---|
| −0:03 | "3", "2", "1" |
| 0:00 | "Run" — Run 1 |
| 0:55 | "Walk in 5 seconds" |
| 0:57–0:59 | "3", "2", "1" |
| 1:00 | "Walk" — Walk 1 |
| 1:25 | "Run in 5 seconds" |
| 1:27–1:29 | "3", "2", "1" |
| 1:30 | "Run" — Run 2 |
| 2:25 | "Walk in 5 seconds" |
| 2:27–2:29 | "3", "2", "1" |
| 2:30 | "Walk" — Walk 2 |
| 2:55 | "Run in 5 seconds" |
| 2:57–2:59 | "3", "2", "1" |
| 3:00 | "Final round", then "Run" — Run 3 |
| 3:55 | "Cooldown in 5 seconds" |
| 3:57–3:59 | "3", "2", "1" |
| 4:00 | "Cooldown" — open-ended, ends when you tap End |

### Record

| Check | Result (2026-08-07, v1.3.0, iPhone 16 Pro / iOS 26.5.2) |
|---|---|
| Every transition cue heard with the phone **locked** | ✅ yes |
| The 5-second warnings and 3-2-1 countdowns heard while locked | ✅ yes |
| "Final round" heard before the third run | ✅ yes |
| Cooldown entry announced at 4:00 | ✅ yes |
| Any cue **missing** | ✅ none |
| Any cue **late** or replayed | ✅ none |
| On unlock: phase and elapsed time correct | ✅ yes |
| Live Activity showed the correct phase on the Lock Screen throughout | ❌ **no — see defect below** |
| `wasInterrupted` — any `true`? | not checked (see caveat above: absence proves nothing) |

**Result: ✅ PASS** — background audio cue continuity is confirmed. This closes the headline v1.1
requirement, which had been unverified because every prior device check was made in the foreground.

### Defect found: Live Activity does not update while backgrounded (spec §12.1, not §26)

**Symptom.** With the phone locked, the Lock Screen card still read **"Run 1 of 3"** well past 1:30,
when the engine was already in Run 2 or Run 3. Opening the app and returning to the Lock Screen
showed the correct **"Run 3 of 3"**.

**What this rules out.** The engine was *not* suspended: every cue fired on schedule, so `tick()` was
running, `enter()` executed at each boundary, and `onPhaseChanged` → `refreshLiveActivity()` →
`LiveActivityController.update(_:)` was therefore called at every transition. The updates were
**issued and did not take effect**. This is a delivery/acceptance failure, not a scheduling one.

**Why nothing was reported.** `LiveActivityController.update(_:)` is fire-and-forget:

```swift
Task { await activity.update(ActivityContent(state: state, staleDate: ...)) }
```

It never inspects a result and never sets `lastError` — unlike `start()`, which does report failure.
So a dropped update is invisible to the user *and* to the diagnostics screen. **This is the
silent-deviation shape: the card asserts "Run 1 of 3" while the workout is demonstrably in Run 3,
and nothing anywhere says otherwise.** Whatever the root cause turns out to be, `update` should
surface a failure the way `start` already does.

**Note also.** `refreshFromClock()` is only `engine.tick()`, which reaches `onPhaseChanged` *only*
if a boundary is crossed at that instant. There is therefore **no code path that forces a Live
Activity refresh when the app returns to the foreground** — so the card cannot self-heal on unlock.
The corrected "Run 3 of 3" was almost certainly a genuine foreground transition landing, which is
consistent with the hypothesis that updates land in the foreground and are dropped in the background.

### Root cause — CONFIRMED 2026-08-07

**`Activity.update(_:)` applies its content only while the app is in the foreground.** Called from
a backgrounded app it returns normally, throws nothing, reports nothing, and discards the update.

Established by three instrumented device runs logging every update attempt (`[DEBUG-la01]`), with
the applied content read back from `activity.content.state` after each `await`:

| Run | Update | App state | Applied? |
|---|---|---|---|
| 3 | rep 1 run (3 s after start) | background | **yes** — still inside the backgrounding grace window |
| 3 | rep 1 walk | background | no |
| 3 | rep 2 run | background | no |
| 3 | rep 2 walk | background | no |
| 3 | rep 3 run (5 s after unlock) | **foreground** | **yes** |
| 3 | rep 3 cooldown | background | no |

This reproduces the user-visible behaviour exactly: unlocking the phone causes the *next* transition
to land, so the card corrects itself and then goes stale again at the following boundary.

**What was ruled out, and how:**

- **Not the timer.** Every phase boundary was crossed on time and all 30 audio cues fired; the
  SwiftData interval log shows all six phases at their planned durations with `wasInterrupted=0`.
- **Not the `Task`.** `task-enqueued` → `task-started` → `await-returned` completed in ~50 ms every
  time, in the background, with no burst on foregrounding.
- **Not a nil or stale activity handle.** `hasActivity=true` and `liveCount=1` throughout, and
  `activityState` changed on that same handle — proving it reflects live system state.
- **Not the widget.** The widget reads `context.state` correctly; content never reached it.
- **Not `NSSupportsLiveActivitiesFrequentUpdates`.** Added specifically to test this, with
  `frequentPushesEnabled` confirmed **true** — behaviour unchanged. **Do not re-run this
  experiment.** The key was kept because the declaration is accurate, not because it helped.
- **Not "only the first update applies".** A genuine competing hypothesis, since in the first two
  runs the only foreground update was also the first. Killed by run 3, where the *fifth* update of
  the session landed because it happened while the app was open.

### What was fixed

1. **The silent failure.** `update` now reads back `activity.content.state` and compares it with
   what it pushed. A discarded update sets `isCardStale`, increments `droppedUpdates`, and writes a
   `lastError` naming what the card still shows — surfaced on the workout screen, which already
   renders `liveActivity.lastError`. Locked down by `LiveActivityStalenessTests`.
2. **The card could not self-heal.** `refreshFromClock()` was only `engine.tick()`, which pushes an
   update *only* if a boundary falls on that exact instant — so returning to the foreground, the one
   moment iOS reliably accepts an update, pushed nothing. It now refreshes unconditionally.
3. **The stale date was too generous.** It was `phaseEnd + 30`, which assumed the only way to be
   wrong was the app dying. The ordinary locked case is worse, so it is now `phaseEnd` exactly: the
   system dims the card the moment it stops being true.

### The card was then redesigned so it does not need updates

Confirmed on device 2026-08-07: **`ProgressView(timerInterval:)` animates on a locked Lock Screen**
with no updates at all, exactly like `Text(timerInterval:)`. That is the way round the limitation.

`ContentState` now carries the **whole schedule** — an anchor plus one character and one duration
per phase — and the widget draws one self-filling progress view per phase. Phases behind read full,
the live one fills, the ones ahead sit empty, all on the system's own clock. A 20-repetition plan
is 41 phases, so it is encoded as durations rather than dates to stay inside the 4 KB budget.
`LiveActivityTimelineTests` pins the arithmetic, including that a pause shifts the anchor.

The headline was rebuilt on the same principle — **only show what stays true**:

| Element | Source | Stays correct? |
|---|---|---|
| Activity name ("RUNNING") | `ActivityAttributes` — immutable | yes |
| Workout name | `ActivityAttributes` | yes |
| Elapsed clock | `Text(timelineStart, style: .timer)` | yes |
| Timeline bar | `ProgressView(timerInterval:)` per phase | yes |
| Plan summary ("1:00 / 0:30 × 3") | derived from the timeline | yes |
| ~~Phase word, round, phase countdown~~ | last accepted update | **removed** |

The phase countdown was the tell: it froze at `0:00` beside a correctly-advancing bar. It was not
broken — it was aimed at a target that had passed. `Text(timerInterval:)` never needed updates, it
needed **bounds that do not move**, and a phase boundary moves every interval while the workout's
start does not.

**A card button was tried and removed.** A `LiveActivityIntent` refresh button runs in the app's
process with a foreground-equivalent window, which is the mechanism behind the buttons on Apple's
own timer Live Activity. On device it raised **the passcode screen**: iOS authenticates before
running that intent, which defeated the entire purpose of correcting the card *without* unlocking —
unlocking already refreshes it. `AudioPlaybackIntent` (exempt from that check, so Lock Screen media
controls work) was considered and dropped as well. **Do not re-attempt this** without new evidence.

Consequently `staleDate` is now `nil` whenever the state carries a timeline: nothing on the card can
go out of date, so expiring at the phase boundary would dim a *correct* card a minute into every
workout. The dropped-update count is still recorded and shown on the Cue test screen, but it no
longer raises a warning on the workout screen — with no stale-prone text left, a discarded update
changes nothing the user can see.

### What remains genuinely impossible

**A countdown to the next phase change cannot self-update.** It needs to know which phase is
current, which needs a re-render, which Live Activities do not do. Only two things break that
ceiling, both v1.2-scale:

- **watchOS companion** — `HKWorkoutSession` gets real background execution on the Watch.
- **APNs push updates** — the only way to update a backgrounded Live Activity, but it requires a
  server and network, contradicting the app's local-only design.

## Test 4 — Interruption (spec §26, Test 4)

1. Start the timer, take a phone call (or trigger Siri) mid-interval.
2. End the call.
3. Confirm the timer state is still correct and no cue was replayed.

If iOS does not permit automatic resumption, the app reports that explicitly rather than going
quiet — look for the warning banner on the workout screen.

**Result: ⬜ pass ⬜ fail**

---

## If both Path A and Path B fail

Per spec §10.3, **stop and report before expanding scope.** A custom watchOS recorder
(`HKWorkoutSession` + `HKLiveWorkoutBuilder` + watchOS audio/haptics) is v1.2 and is explicitly out
of scope until these two tests have been run and documented.
