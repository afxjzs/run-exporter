#!/usr/bin/env bash
# End-to-end smoke test: drives the real app through every tab and the run screen in the simulator
# (RunExporterUITests/SmokeTests.swift) and exports a screenshot of each step.
#
#   scripts/smoke-test.sh                 # uses the "iPhone 17 Pro" simulator
#   SIMULATOR="iPhone 16" scripts/smoke-test.sh
#
# Starts from a clean install every time, so the result does not depend on what an earlier run
# left behind. Output: build/smoke-test/<timestamp>/ with the .xcresult bundle and a screenshots/
# folder (git-ignored). Exit code is xcodebuild's; the last line says PASSED or FAILED from it.
#
# What it cannot test: the Watch. The simulator has no Watch to launch, so the run screen is
# expected to report that the run continues on the phone only.
set -uo pipefail

simulator="${SIMULATOR:-iPhone 17 Pro}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
out="$repo/build/smoke-test/$(date +%Y%m%d-%H%M%S)"
result="$out/SmokeTests.xcresult"
mkdir -p "$out"

echo "Simulator: $simulator"
echo "Output:    $out"

# Cycling the simulator first: skipping it has hung the test runner in this project
# ("hung before establishing connection").
xcrun simctl shutdown "$simulator" 2>/dev/null   # already shut down is fine; the boot below reports real problems
if ! xcrun simctl bootstatus "$simulator" -b > "$out/boot.log" 2>&1; then
    echo "FAILED: the simulator \"$simulator\" did not boot. See $out/boot.log" >&2
    exit 2
fi

# A clean install: not installed yet is fine, anything else is reported.
uninstall_output="$(xcrun simctl uninstall "$simulator" is.doug.runexporter 2>&1)" || \
    echo "note: uninstall reported: $uninstall_output"

xcodebuild test \
    -project "$repo/RunExporter.xcodeproj" \
    -scheme RunExporterUITests \
    -destination "platform=iOS Simulator,name=$simulator" \
    -resultBundlePath "$result" \
    > "$out/xcodebuild.log" 2>&1
status=$?

grep -E "Test Case .*(passed|failed)|error:|Executed [0-9]+ test" "$out/xcodebuild.log"

if [[ -d "$result" ]]; then
    if xcrun xcresulttool export attachments --path "$result" --output-path "$out/screenshots" > /dev/null; then
        echo "Screenshots: $out/screenshots ($(find "$out/screenshots" -name '*.png' | wc -l | tr -d ' ') PNGs; manifest.json names each step)"
    else
        echo "FAILED to export screenshots from $result" >&2
        [[ $status -eq 0 ]] && status=3
    fi
else
    echo "No result bundle was written; see $out/xcodebuild.log" >&2
    [[ $status -eq 0 ]] && status=3
fi

if [[ $status -eq 0 ]]; then
    echo "SMOKE TEST PASSED"
else
    echo "SMOKE TEST FAILED (exit $status). Full log: $out/xcodebuild.log" >&2
fi
exit $status
