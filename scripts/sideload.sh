#!/usr/bin/env bash
# Build (Release) + install + launch RunExporter on the connected iPhone.
# Release is intentional: it launches standalone without a debugger attach.
set -euo pipefail

cd "$(dirname "$0")/.."

# The phone's device id is required. `xcrun devicectl list devices` prints it.
if [[ $# -lt 1 || -z "$1" ]]; then
  echo "usage: $0 <device-id>   (find it with: xcrun devicectl list devices)" >&2
  exit 64
fi
UDID="$1"
BUNDLE_ID="is.doug.runexporter"
SCHEME="RunExporter"
DERIVED="./build"
APP="$DERIVED/Build/Products/Release-iphoneos/RunExporter.app"

# Built against a generic device rather than `id=$UDID`, deliberately. With an id= destination
# xcodebuild waits for that phone to become "available", and a passcode-locked phone refuses to
# mount the developer disk image — so instead of saying the phone is locked it spends a couple of
# minutes and then reports "Timed out waiting for all destinations matching the provided
# destination specifier to become available", which sends you looking at the wrong thing. Observed
# 2026-09-07. A generic build needs no device at all; the phone is required only from the install
# step down, where a locked phone reports itself plainly.
# ONE-WAY DOOR: installing a build from before 3069029 over this app destroys every multi-block
# plan on the phone, silently. Such a build's schema has no PlannedWorkoutBlock, SwiftData drops the
# table without erroring, and the plan is left reading 0/0x0 with no way back. The only record of the
# lost shape is planned_workout_blocks.csv in the last export. See LEARNINGS.md.
echo "==> Note: installing a pre-3069029 build over this one destroys multi-block plans (LEARNINGS.md)"

# Every build gets its own build number, so the phone (Settings → Version) and the watch app (bottom
# of its first screen) each say which build they are running. Matching numbers mean matching builds.
# Without this both said "1" forever, and "is the new build on the Watch?" had no answer by looking.
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

# Clean, deliberately. On 2026-09-25 an incremental build copied a new provisioning profile into the
# watch app WITHOUT re-signing it; the Watch rejected it with 0xe8008017 and gave no error on screen.
# `codesign --deep` on the outer app still passed. A clean build signs every bundle afresh.
echo "==> Building Release for iOS device, clean, build number $BUILD_NUMBER"
xcodebuild -project RunExporter.xcodeproj -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD_NUMBER" clean build

# Checked on the NESTED watch app itself — verifying the outer app does not catch a broken one.
echo "==> Verifying the embedded watch app's signature"
codesign --verify --strict "$APP/Watch/RunExporterWatch Watch App.app"

echo "==> Installing $APP"
xcrun devicectl device install app --device "$UDID" "$APP"

echo "==> Launching $BUNDLE_ID (phone must be UNLOCKED)"
xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID"

echo "==> Done. Build number $BUILD_NUMBER — the watch app shows it once its install finishes."
