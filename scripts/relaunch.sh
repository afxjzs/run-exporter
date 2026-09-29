#!/usr/bin/env bash
# Launch the already-installed RunExporter (no rebuild). Phone must be unlocked.
set -euo pipefail

# The phone's device id is required. `xcrun devicectl list devices` prints it.
if [[ $# -lt 1 || -z "$1" ]]; then
  echo "usage: $0 <device-id>   (find it with: xcrun devicectl list devices)" >&2
  exit 64
fi
UDID="$1"
BUNDLE_ID="is.doug.runexporter"

xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID"
