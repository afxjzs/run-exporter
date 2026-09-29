#!/usr/bin/env python3

import csv
import json
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

# Usage:
# python3 extract_running_health.py /path/to/apple_health_export/export.xml

if len(sys.argv) != 2:
    print("Usage: python3 extract_running_health.py /path/to/export.xml")
    sys.exit(1)

EXPORT_XML = Path(sys.argv[1]).expanduser().resolve()

# Fixed start date for the beginning of the running program.
# End date is dynamic: whenever you run the script, it extracts through "now".
LOCAL_TIMEZONE = datetime.now().astimezone().tzinfo

PROGRAM_START_DATE = datetime.fromisoformat("2026-06-18T00:00:00-07:00")

# One-day buffer before the program start helps catch timezone/export boundary weirdness.
START_DATE = PROGRAM_START_DATE - timedelta(days=1)

# One-day buffer after now helps catch same-day records with timezone/export boundary weirdness.
END_DATE = datetime.now(LOCAL_TIMEZONE) + timedelta(days=1)

OUT_DIR = Path(
    f"running_health_extract_{PROGRAM_START_DATE.date().isoformat()}_to_now"
)
OUT_DIR.mkdir(exist_ok=True)

# Keep these workout types.
# Important: includes Walking because a couple run/walk sessions were likely mislabeled.
WORKOUT_TYPES_TO_KEEP = {
    "HKWorkoutActivityTypeRunning",
    "HKWorkoutActivityTypeWalking",
}

# Core Apple Health record types that matter for this running analysis.
RECORD_TYPES = {
    # Heart / recovery
    "HKQuantityTypeIdentifierHeartRate",
    "HKQuantityTypeIdentifierRestingHeartRate",
    "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
    "HKQuantityTypeIdentifierWalkingHeartRateAverage",
    "HKQuantityTypeIdentifierVO2Max",

    # Distance / steps / energy
    "HKQuantityTypeIdentifierDistanceWalkingRunning",
    "HKQuantityTypeIdentifierStepCount",
    "HKQuantityTypeIdentifierActiveEnergyBurned",
    "HKQuantityTypeIdentifierBasalEnergyBurned",

    # Running dynamics
    "HKQuantityTypeIdentifierRunningSpeed",
    "HKQuantityTypeIdentifierRunningCadence",
    "HKQuantityTypeIdentifierRunningPower",
    "HKQuantityTypeIdentifierRunningStrideLength",
    "HKQuantityTypeIdentifierRunningGroundContactTime",
    "HKQuantityTypeIdentifierRunningVerticalOscillation",

    # Walking metrics, useful when run/walks are mislabeled as walks
    "HKQuantityTypeIdentifierWalkingSpeed",
    "HKQuantityTypeIdentifierWalkingStepLength",
    "HKQuantityTypeIdentifierWalkingDoubleSupportPercentage",
    "HKQuantityTypeIdentifierSixMinuteWalkTestDistance",
}

def parse_dt(value):
    if not value:
        return None

    value = value.strip()

    # Apple Health dates usually look like:
    # 2026-06-26 14:03:12 -0700
    for fmt in ("%Y-%m-%d %H:%M:%S %z", "%Y-%m-%d %H:%M:%S %Z"):
        try:
            return datetime.strptime(value, fmt)
        except ValueError:
            pass

    # Fallback for ISO-like strings.
    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None

def in_window(dt):
    if dt is None:
        return False

    # Compare in UTC to avoid local offset weirdness.
    dt_utc = dt.astimezone(timezone.utc)
    start_utc = START_DATE.astimezone(timezone.utc)
    end_utc = END_DATE.astimezone(timezone.utc)
    return start_utc <= dt_utc <= end_utc

def activity_summary_in_window(date_components):
    """
    ActivitySummary dateComponents often looks like:
    2026-07-10
    """
    if not date_components:
        return False

    try:
        d = datetime.fromisoformat(date_components.strip()).date()
    except ValueError:
        return False

    return START_DATE.date() <= d <= END_DATE.date()

def clean_attrs(elem):
    return dict(elem.attrib)

workouts = []
records = []
activity_summaries = []

workout_type_counts_all = Counter()
workout_type_counts_kept = Counter()
record_type_counts_all = Counter()
record_type_counts_kept = Counter()

print(f"Reading: {EXPORT_XML}")
print(f"Window: {START_DATE.isoformat()} to {END_DATE.isoformat()}")
print("This may take a few minutes for a large Apple Health export...")

context = ET.iterparse(EXPORT_XML, events=("end",))

count = 0
for event, elem in context:
    count += 1

    if elem.tag == "Workout":
        attrs = clean_attrs(elem)

        workout_type = attrs.get("workoutActivityType", "")
        workout_type_counts_all[workout_type] += 1

        start = parse_dt(attrs.get("startDate"))
        end = parse_dt(attrs.get("endDate"))

        is_target_type = workout_type in WORKOUT_TYPES_TO_KEEP
        is_in_window = in_window(start) or in_window(end)

        if is_target_type and is_in_window:
            workout_type_counts_kept[workout_type] += 1

            workout = attrs.copy()

            # Pull nested workout statistics, events, and metadata.
            stats = []
            events = []
            metadata = []

            for child in elem:
                if child.tag == "WorkoutStatistics":
                    stats.append(clean_attrs(child))
                elif child.tag == "WorkoutEvent":
                    events.append(clean_attrs(child))
                elif child.tag == "MetadataEntry":
                    metadata.append(clean_attrs(child))

            workout["WorkoutStatistics"] = json.dumps(stats)
            workout["WorkoutEvents"] = json.dumps(events)
            workout["MetadataEntries"] = json.dumps(metadata)

            workouts.append(workout)

    elif elem.tag == "Record":
        attrs = clean_attrs(elem)
        record_type = attrs.get("type", "")

        record_type_counts_all[record_type] += 1

        start = parse_dt(attrs.get("startDate"))
        end = parse_dt(attrs.get("endDate"))

        if record_type in RECORD_TYPES and (in_window(start) or in_window(end)):
            record_type_counts_kept[record_type] += 1
            records.append(attrs)

    elif elem.tag == "ActivitySummary":
        attrs = clean_attrs(elem)
        date_components = attrs.get("dateComponents", "")

        if activity_summary_in_window(date_components):
            activity_summaries.append(attrs)

    # Important for huge XML files: free memory as we stream.
    elem.clear()

    if count % 1_000_000 == 0:
        print(f"Processed {count:,} XML elements...")

def write_csv(path, rows):
    if not rows:
        print(f"No rows for {path.name}")
        return

    # Union of keys across rows.
    fieldnames = sorted({k for row in rows for k in row.keys()})

    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    print(f"Wrote {path} with {len(rows):,} rows")

def write_json(path, payload):
    with path.open("w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, sort_keys=True)
    print(f"Wrote {path}")

write_csv(OUT_DIR / "workouts.csv", workouts)
write_csv(OUT_DIR / "records.csv", records)
write_csv(OUT_DIR / "activity_summaries.csv", activity_summaries)

write_json(
    OUT_DIR / "workout_type_counts.json",
    {
        "all_workout_types": dict(workout_type_counts_all),
        "kept_workout_types": dict(workout_type_counts_kept),
        "workout_types_to_keep": sorted(WORKOUT_TYPES_TO_KEEP),
    },
)

write_json(
    OUT_DIR / "records_by_type.json",
    {
        "all_record_types": dict(record_type_counts_all),
        "kept_record_types": dict(record_type_counts_kept),
        "record_types_requested": sorted(RECORD_TYPES),
    },
)

manifest = {
    "source_file": str(EXPORT_XML),
    "program_start_date": PROGRAM_START_DATE.isoformat(),
    "start_date": START_DATE.isoformat(),
    "end_date": END_DATE.isoformat(),
    "end_date_mode": "dynamic_now_plus_one_day",
    "workout_types_to_keep": sorted(WORKOUT_TYPES_TO_KEEP),
    "record_types_requested": sorted(RECORD_TYPES),
    "workout_count": len(workouts),
    "record_count": len(records),
    "activity_summary_count": len(activity_summaries),
    "output_dir": str(OUT_DIR),
}

write_json(OUT_DIR / "manifest.json", manifest)

print("Done.")
print(f"Zip and upload this folder: {OUT_DIR}")