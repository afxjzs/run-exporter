# Developing on the Apple Watch — runbook

How to get this project's own code running on the owner's Apple Watch, launched from the phone, and
how to see what it did. Written 2026-09-29 from the sessions of 2026-09-25 and 2026-09-29, which
took the watch app from "never installed" to "launched by the phone". Every step below was done on
this hardware; anything not measured says so.

Hardware and OS versions live in [INSTALLS.md](INSTALLS.md). This repository is public, so the
identifiers below are placeholders (see [../private/README.md](../private/README.md)). The CoreDevice
ids are in the git-ignored `scripts/local.env` as `PHONE_DEVICE_ID` and `WATCH_DEVICE_ID`; the
hardware UDIDs are not stored there — find them with `xcrun devicectl list devices`. Identifiers
used below:

| Device | Hardware UDID (portal, provisioning) | CoreDevice id (`devicectl`) |
|---|---|---|
| iPhone 16 Pro | `<PHONE_UDID>` | `<PHONE_COREDEVICE_ID>` |
| Apple Watch Series 5 | `<WATCH_UDID>` | `<WATCH_COREDEVICE_ID>` |

**The one fact that shapes everything here: the Mac cannot talk to this Watch.** `devicectl` lists it
as `available (paired)` and times out on every command (`CoreDeviceError 4000`), and Xcode has never
prepared it. None of the steps below need it to. The Watch is reached **through the phone**.

---

## 1. One-time setup

### Register the Watch with the developer team

A development-signed app installs only on devices listed in its provisioning profile. Xcode adds a
device to the team the first time it connects to it — which never happens with this Watch — so it
has to be added by hand.

1. developer.apple.com → Certificates, IDs & Profiles → Devices → **+** → Apple Watch, UDID
   `<WATCH_UDID>`. Done 2026-09-25, with the name `My Watch`.
2. **Delete Xcode's cached profile for the watch app**, or Xcode keeps using it.
   `-allowProvisioningUpdates` reuses any cached profile that is still valid and does not compare
   its device list with the portal. Cached profiles live in
   `~/Library/Developer/Xcode/UserData/Provisioning Profiles/<UUID>.mobileprovision`; the UUID is
   in the profile (step 3). Move it aside rather than deleting it.
3. Build (§2), then confirm the Watch is in the profile **embedded in the built watch app**:

   ```bash
   security cms -D -i "build/Build/Products/Release-iphoneos/RunExporter.app/Watch/RunExporterWatch Watch App.app/embedded.mobileprovision" -o /tmp/p.plist
   plutil -extract ProvisionedDevices json -o - /tmp/p.plist    # must include <WATCH_UDID>
   ```

### Turn on Developer Mode on the Watch

**The switch does not exist until a development-signed app is on the Watch.** Before the first
successful install, Settings → Privacy & Security had no Developer Mode row. After it, opening the
app said Developer Mode was needed, and the row had appeared. Turn it on; the Watch restarts. Xcode
never connected to the Watch at any point, so it is not needed for this.

---

## 2. Build, install, confirm

```bash
scripts/sideload.sh   # device id from scripts/local.env; clean Release build, stamped build number, installs + launches on the phone
```

The script builds **clean** on purpose, stamps `CFBundleVersion` with a timestamp, and verifies the
**nested** watch app's signature. Then:

1. **The phone installs; the Watch does not install itself.** On the iPhone: Watch app → My Watch →
   RunExporterWatch → Install (or update). **Wear the Watch, awake, while it installs.** It is slow —
   minutes.
2. **Confirm the build by looking.** The watch app shows `build 1.0 (<number>)` at the bottom of its
   first screen; the phone shows `1.3.0 (<number>)` in Settings → Version. Same number, same build.
   Do not test until they match.
3. **After every install — phone or Watch — open RunExporterWatch and allow Health access, with
   every type on.** Measured: a **phone-only** install, the Watch app untouched, turned the Watch's
   Workout Routes sharing from authorized to **denied** and its sheet back to unanswered; workout
   sharing survived, and an app restart changed nothing. Removing and reinstalling the Watch app
   (the "Show App on Apple Watch" toggle) did the same. Left like that, every run loses its GPS
   route — the cause, most likely, of the first route lost. Why an install does this is not known;
   the Watch app and the iPhone app keep separate Health grants (single-target Watch apps; reported
   by developers, not documented by Apple), so the iPhone's own Allow does not cover the Watch.
   The app asks whenever it comes on screen, and a phone launch with the Watch screen on asks too;
   with the screen off a launch stops and says so, and with routes off it runs without a route and
   says that, in orange, before the run. The sheet that returned after an install offered Workout
   Routes again, though it had been denied; if it does not, turn it on in the Watch's Settings →
   Health → Apps → RunExporterWatch. The idle screen's "Health access" line says which: "granted",
   "granted, but Workout Routes is off", "Workouts is off".

**If the install hangs** (spinner never finishes, or it sticks on "Uninstalling…"): collect the
phone's log first (§4), *then* restart the Watch and install again with it on the wrist. Seen once,
2026-09-25, when the install began with the Watch asleep on its charger; whether sleep caused it is
not established.

**If Install turns back into "Install" with no message**, the Watch rejected the app. The reason is
only in the phone's log (§4). Codes seen so far:

| Code | Meaning here | Fix |
|---|---|---|
| `0xe8008015` "A valid provisioning profile for this executable was not found" | The Watch is not in the profile | §1 |
| `0xe8008017` "A signed resource has been added, modified, or deleted" | An incremental build put a new profile in without re-signing | Build clean. Verify the **nested** app with `codesign --verify --strict "<…>/Watch/RunExporterWatch Watch App.app"` — checking the outer app with `--deep` passed this broken build |
| "This app could not be installed at this time" | Missing app icon | See the Xcode playbook, `~/.claude/docs/ios-xcode-project-playbook.md` §3 |

---

## 3. Launching the watch app from the phone

**Start** on the run screen does this for every run (watch plan step 2): the phone calls
`HKHealthStore.startWatchApp(toHandle:)`; watchOS launches the watch app and calls
`WatchAppDelegate.handle(_:)`, which starts the workout session and mirrors it back. Finishing the
run asks the Watch to save its workout; abandoning it asks the Watch to discard.

**To test a launch without a real run**, start any plan, read the Watch status line on the run
screen, then **End Workout**: an abandoned run asks the Watch to discard its session, and both logs
(§4) record the launch. Settings' **Watch link test** — **Start watch workout**, ping and end
buttons, the link's log on screen — did this as a separate diagnostic until the 2026-09-29
clean-out removed it.

**What it needs, measured:**

- **`WKBackgroundModes` = `["workout-processing"]` in the watch app's Info.plist.** Without it the
  request reaches the Watch — the phone's `healthd` logs the send and the Watch's reply — and watchOS
  silently never launches the app. The app had the mode only under `UIBackgroundModes`, which was
  enough for a session started on the Watch (the stage 2 probe) but not for a launch from the phone.
  Adding the key was the only change in the build that first launched (2026-09-29).

**What the phone's "success" means: sent, nothing more.** `startWatchApp` returned before the Watch's
reply arrived. Whether the app launched is visible only on the Watch, or in its event log (§4).

A launch that never answers is reported as failed after `WatchLink.launchTimeoutSeconds` (15 s),
and the run screen offers **Try again**. (The link test's **Reset this screen**, for a screen stuck
with every button disabled, went with it in the 2026-09-29 clean-out.) A session left running on
the Watch is ended by restarting the Watch.

**Open, found 2026-09-29, and not tracked by any plan step:**

- **A launch arriving while a session is already running** is refused: `WatchWorkoutController.start`
  records "a session is already running" as an error and returns. What the phone's run then shows
  has not been measured.
- **The app being killed mid-session** is not recovered. `WatchAppDelegate.handleActiveWorkoutRecovery`
  only writes a line to the event log.

---

## 4. Seeing what happened

### The watch app's own event log — readable without the Watch

The watch app records every launch, `handle(_:)` call, step and error to a log **saved on the Watch**
(swipe left in the app) and **forwarded to the phone** over `WCSession.transferUserInfo`. The phone
appends it to a file. Clearing the log on the Watch does not touch the phone's copy.

```bash
xcrun devicectl device copy from --device <PHONE_COREDEVICE_ID> \
  --domain-type appDataContainer --domain-identifier is.doug.runexporter \
  --source Documents/watch-events.log --destination ./watch-events.log
```

`Documents/watch-link-phone.log` holds the phone's side of every run. If either file cannot be
written, the run screen says so. Forwarded lines are queued
by the system, so they can arrive late; an empty file right after a test is not yet evidence.

### The phone's system log — install errors and the launch handoff

```bash
sudo log collect --device-udid <PHONE_UDID> --last 30m --output ./phone.logarchive
command log show ./phone.logarchive --predicate 'process == "appconduitd" AND eventMessage CONTAINS "runexporter.watchkitapp"' --style compact
command log show ./phone.logarchive --predicate 'process == "healthd" AND eventMessage CONTAINS[c] "Start Workout App"' --style compact
```

- Needs `sudo`, so the owner runs the first line.
- It failed with `Device not configured (6)` while the phone was connected only over Wi-Fi, and
  worked with it on a cable. That USB is required is inferred from that one pair of attempts.
- `command log` because in zsh `log` is a shell builtin.
- **The installed watch build can be proven from this log.** `appconduitd` records
  `watchKitAppExecutableHash=<hex>` on a finished install; it equals `shasum -a 256` of the built
  watch executable.
