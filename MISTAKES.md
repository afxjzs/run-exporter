# Mistakes

Diagnostic and process errors made while working on this project, kept so they are not repeated.
Findings themselves live in [LEARNINGS.md](LEARNINGS.md); this file is about **how the work went
wrong**, which is the part that generalizes.

Written plainly. The point is to be useful later, not to flagellate.

---

## 2026-08-12/13 — the "workouts won't reach the Watch" investigation

A single problem took most of two days. Almost none of that time was spent on the actual cause.

### Trusting the app's own UI as evidence

The Send to Watch screen said a queue count of 0 meant "the workout never reached the Watch". That
claim was **already recorded as false** in `docs/CUE_FEASIBILITY_TEST.md`, with a note that it should
be reworded. It was repeated back to the owner as fact.

**Rule: a UI string is not a measurement.** It is a claim someone wrote, and in this repo the same
screen carried three separate false claims about Watch state, all reading phone-side data.

### Not reading the project's own docs first

`docs/CUE_FEASIBILITY_TEST.md` contained the delivery-lag finding, the `Date()` critique, and the
watchOS-10 payload constraint. It was not read until well into the second day, after several
hypotheses had been invented that it would have settled or killed immediately.

The same happened with `~/.claude/docs/ios-xcode-project-playbook.md`, which already documented
`devicectl` timing out on a Watch listed as `available (paired)`, Series 5 being 2.4 GHz only, the
Watch drifting off Wi-Fi, and "ping it first" as the one-command discriminator. All of it was
rediscovered the slow way.

**Rule: read the existing docs before generating hypotheses, not after they fail.**

Both playbooks were listed in the global `CLAUDE.md` at session start, with paths and triggers. This
was not missing information. Two specific ways it was wasted:

- **Truncating the doc that was opened.** `head -80` on the device-testing playbook, to save tokens
  the owner has explicitly said he does not care about. The needed section began after the cut.
  **Read the whole file. There is no budget for this.**
- **Matching a trigger list too literally.** The Xcode playbook's triggers name Xcode targets,
  Info.plist keys and `project.pbxproj` — none of which applied — so it was skipped, while its §3
  held the paired-Watch answers. **A doc's trigger list is a hint about when it usually applies, not
  an exhaustive gate. When stuck on a subsystem, open every doc that touches it.**

### Declaring a thread closed while it was still broken

Said the Watch problem was "closed" because a workaround existed. It was not closed — the owner still
could not get a workout onto the Watch, which was the entire requirement. A workaround is not a fix,
and calling it one moved attention away from a live problem.

### Reasoning past the evidence

Several confident claims were wrong:

- **"Nothing has ever reached the wrist"** — inferred from `complete == false`. That flag tracks
  *completion*, not delivery. It says nothing about whether a workout arrived.
- **"`4/1 × 4` is your workout, relabeled from the block structure"** — a neat theory built on
  matching arithmetic. It was a workout the owner had made on the Watch himself.
- **"The preview sheet will put it in the main list"** — it delivered, and landed under Outdoor Run
  like everything else.

Each was stated more confidently than the evidence supported. Hypotheses are welcome; hypotheses
dressed as findings cost the owner trips to his wrist to check things that were never going to be
true.

### Giving instructions for a UI that was never checked

Told the owner to swipe up for Control Center (it is the side button on watchOS 10) and to read a
connection icon in its top-left (there isn't one). Two wrong instructions in one message, for a
screen that was never looked at.

### Proposing an expensive fix before establishing it was relevant

Recommended changing the home Wi-Fi network's configuration before establishing that Wi-Fi had
anything to do with the sync failure. The owner spotted the cost — it would have degraded every other
device on the network. Wi-Fi turned out to be irrelevant: the Watch talks to the phone over Bluetooth, and the Ping
test confirmed that link was alive.

**Rule: establish that a subsystem is implicated before proposing changes to it.**

### Testing on top of a jammed queue for a whole day

Every delivery test was run while a 26-hour-old undelivered entry sat at the head of the queue, with
more sends piled behind it. Clearing both ends and retrying with a single item — the standard first
move for a stuck sync — was not suggested until the owner pushed back on giving up.

### Destroying evidence, nearly

Told the owner to run "Remove all workouts from Watch" while the only two never-before-seen workouts
were the live experiment. Reversed it a message later. Think about what a cleanup step destroys
before recommending it.

*(That button existed under that name at the time. `8d145b9` renamed it to "Clear this iPhone's
queue" on 2026-09-07, because it only ever cleared the phone's queue and never reached the Watch —
so the advice was also describing a power the button did not have. Noted here because a reader today
would otherwise go looking for a control that is not there. The renamed button went too, with the
rest of the WorkoutKit screen, in the 2026-09-29 clean-out.)*

---

## Recurring shape

Most of the above is one failure wearing different clothes: **preferring a plausible explanation to a
cheap measurement.**

The measurements that actually moved this forward were all trivial:

- `devicectl device info lockState` against the phone and the Watch, minutes apart — one works, one
  times out.
- Sending two never-before-seen workouts instead of arguing about whether one was already there.
- Adding the same workout by both routes and seeing which arrived.
- Displaying "overdue by 1d" next to a queue entry, which turned "2 queued" into "2 queued, both dead".

None took more than a few minutes. All of them were available on day one.

---

---

## 2026-09-07 — masking a build's exit code with a trailing `echo`

The baseline test run was invoked as `xcodebuild test … > log 2>&1; echo "exit=$?"`. The harness
reported **exit code 0** for a run whose log ended in `** TEST FAILED **`, because the exit code
belonged to the `echo`, not to `xcodebuild`.

This is the same failure already recorded twice in this repo — "reporting a tool's exit code as its
outcome" below, and the handoff's warning about piping a build through `tail`. All three are one
rule:

**Rule: anything after a command in the same shell replaces its status. Run the command alone and
read its own exit code.**

What caught it was not the exit code but the *absence* of an `Executed N tests` line. That line, not
the banner and not the status, is what says whether tests ran — and here they had not: the runner
hung before connecting, after 487 seconds, against a simulator that was never booted.

**Second-order note:** the passcode-protected device errors that fill these logs are noise, and the
gotchas say so. That made it tempting to read the whole failure as noise. It was not — a real
failure was sitting in the same log, and "this log is usually noisy" is not a reason to stop
reading it.

---

## 2026-09-07 — a test that could not fail, quoted as evidence

`LoggerStoreMigrationTests` gained a test for the block schema change. Its "old" schema was
`LoggerStore.models` minus `PlannedWorkoutBlock`. That does not remove the entity: `PlannedWorkout`
declares a relationship whose destination is that type, and `Schema` resolves it in regardless. The
test wrote the current schema, read the current schema back, asserted the data survived, and passed
— measuring nothing.

It was then reported to the owner as evidence that his months of real data would migrate safely.

**What makes this worse than an untested change.** The test carried a carefully written paragraph
about what it did and did not prove, naming the `blockShape` attribute as the part it could not
isolate. That caveat made it read as rigorously scoped, and made the passing green look earned. A
missing test is visibly missing; a vacuous one is indistinguishable from a real one, and it is the
thing everybody points at.

**Rule: assert the premise, not just the conclusion.** A test that depends on a setup being a
certain way should check that it is. One line — "the old schema must not contain this entity" —
turned an invisible failure into a visible one, and it was the first thing that had ever actually
tested the setup rather than trusting it.

**Second lesson, on where the caveat went.** Effort was spent qualifying *what the result meant*
and none on *whether the mechanism worked*. Being careful about the interpretation of a measurement
is worth nothing if the measurement never happened. Check the apparatus before writing about the
findings.

## 2026-09-25 to 2026-09-29 — getting our own app onto the Watch

The good part first, because it is the part to repeat: every step forward came from reading a
**system log** or an **artifact**, not from theorizing. The phone's `appconduitd` log named both
install failures by code; decoding `embedded.mobileprovision` showed the missing device in one
command; the Watch's executable hash proved which build it ran. The missteps:

### Reporting a check that did not check what it was reported as checking

`codesign --verify --deep --strict` on the outer app said `valid on disk`, and was reported to the
owner as meaning the embedded watch app was sound. It was not — its signature no longer covered its
profile — and the Watch rejected it. **Verify the artifact the claim is about**: the nested bundle,
directly.

### Instrumentation that recorded only success

The first watch link screen appeared only once a session was running, so "the launch never arrived"
and "it arrived and stalled" looked identical. Then the breadcrumb added to fix that lived in memory,
so an app the system had closed could not have shown it either way. Two slow Watch installs went to
measurements that could not discriminate. **On a device the tools cannot reach, record the first step
of every path, before any `await`, to storage** — which is what the saved, forwarded event log does.

### A fix built on a hypothesis, before the discriminating measurement

A Health-permission stall was proposed as the cause of the failed launch and a build was made to fix
it. It was never the cause: watchOS was not launching the app at all, which the next, better-
instrumented build showed at once. It was labelled a hypothesis throughout, which is right; the
mistake was spending an install on the fix before spending one on the instrument.

### Losing evidence to a clear button

The owner cleared the watch's on-screen log before it was read — the log of the first launch that
ever worked. Nothing warned that it was the only copy. It is no longer the only copy: every line is
forwarded to the phone as it is recorded.

## 2026-10-02 — committing an explanation while the question that settled it was open

The Watch started a new build two minutes after a phone-only install. The explanation written into
`docs/INSTALLS.md` and committed was that the Watch had updated itself — labelled "inferred from
timing", which is right — while the owner had already been asked whether he installed it. He had:
by turning "Show App on Apple Watch" off and on. A second commit corrected the first.

The label was not the problem; the order was. The simplest explanation — the person did it — was
never listed beside the clever one, and the commit went in before the answer that decided between
them. **When a question to the owner would settle it, ask, wait, then write it down.** An inference
in a commit is cheap to make and costs a correction commit to unmake.

---

## Code-level slips

- **Markdown emphasis inside a concatenated SwiftUI `Text`.** `Text("a **b** c" + "d")` takes the
  non-localized overload and renders the asterisks literally. Only string *literals* get markdown.
- **Reporting a tool's exit code as its outcome.** `devicectl device sysdiagnose` printed `ERROR`,
  wrote zero bytes, and the wrapper reported exit code 0. Check the artifact, not the status.
