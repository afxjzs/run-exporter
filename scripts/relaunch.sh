#!/usr/bin/env bash
# Launch the already-installed RunExporter (no rebuild). Phone must be unlocked.
set -euo pipefail

cd "$(dirname "$0")/.."

# The phone's device id: the first argument, else PHONE_DEVICE_ID from scripts/local.env
# (git-ignored; template scripts/local.env.example). Which one was used is printed.
source scripts/device-id.sh
UDID="$(resolve_phone_device_id "${1:-}")"
BUNDLE_ID="is.doug.runexporter"

xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID"
