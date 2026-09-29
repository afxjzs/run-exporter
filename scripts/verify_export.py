#!/usr/bin/env python3
"""Verify a REAL export produced on device, against the properties unit tests cannot reach.

    scripts/verify_export.py <export.zip | extracted_folder>

## What this is for, and what it deliberately does not do

`ExportPipelineTests` and `ExportSchemaTests` already pin the export's *structure*: the file
inventory, the manifest's v1 keys, ZIP well-formedness, per-entry CRCs, and that `workouts.csv`'s
header matches the declared columns. Re-checking those here would duplicate a contract and create a
second place for it to drift, so this script does not.

What those tests cannot do is run against real HealthKit data. They build synthetic or empty
datasets, so every one of them passes on inputs that are small, clean, and free of the things that
actually break exporters:

  * a `deviceJSON` or metadata blob containing a comma or a double quote, which turns a CSV row into
    the wrong number of fields
  * ~100k records rather than a handful
  * text that is not ASCII
  * workouts that cross midnight or a DST boundary

So the checks below are all properties of the *bytes that came off the phone*.

## Reporting rule

Every line printed is derived from a check that actually ran. The exit code and the summary come
from the same collected results, so a summary can never claim a pass for a step that failed. Exit
is 0 only when zero checks failed.
"""

from __future__ import annotations

import csv
import io
import json
import sys
import zipfile
from datetime import datetime
from pathlib import Path

# Required as of v1.1. This is a FLOOR, not the full contract: check_manifest_matches_contents()
# asserts the manifest lists exactly what the archive holds, so a file added later is still
# verified even before someone remembers to add it here.
REQUIRED_FILES = [
    # v1.0
    "workouts.csv", "records.csv", "activity_summaries.csv", "routes_summary.csv",
    "manifest.json", "export_log.json", "workout_type_counts.json",
    "records_by_type.json", "README.txt",
    # v1.1
    "planned_workouts.csv", "run_logs.csv", "recovery_logs.csv", "shoes.csv",
    "workout_intervals.csv", "pending_workout_executions.csv", "body_signal_details.csv",
]


class Results:
    """Collects outcomes so the summary is derived from what happened, never from intent."""

    def __init__(self) -> None:
        self.failures: list[str] = []
        self.notes: list[str] = []
        self._section = ""
        self._emitted = 0

    def section(self, title: str) -> None:
        """Open a section, first asserting the previous one actually did something.

        A section whose inputs are missing runs no checks, prints its header, and then prints
        nothing — which on screen is indistinguishable from a section where everything passed.
        That happened on the first real export (every lookup missed because the archive nested its
        contents under a folder) and the run still reported a single unrelated failure. Silence is
        never allowed to read as success, so an empty section is itself a failure.
        """
        self._close()
        self._section = title
        self._emitted = 0
        print(f"\n{title}")

    def _close(self) -> None:
        if self._section and self._emitted == 0:
            message = (f"{self._section}: ran ZERO checks — its inputs were not found, so this "
                       f"section verified nothing")
            print(f"  FAIL  {message}")
            self.failures.append(message)
        self._section = ""

    def finish(self) -> None:
        self._close()

    def check(self, ok: bool, label: str, detail: str = "") -> bool:
        self._emitted += 1
        if ok:
            print(f"  PASS  {label}")
        else:
            print(f"  FAIL  {label}" + (f" — {detail}" if detail else ""))
            self.failures.append(label if not detail else f"{label}: {detail}")
        return ok

    def note(self, line: str) -> None:
        self._emitted += 1
        self.notes.append(line)
        print(f"  ....  {line}")


def strip_common_root(raw: dict[str, bytes]) -> tuple[dict[str, bytes], str]:
    """Drop a single shared top-level folder, if every member sits inside one.

    The on-device export nests its files under `<export name>/`, so member keys arrive as
    `running_health_extract_.../workouts.csv`. Returning the stripped prefix lets the caller
    *report* the normalisation instead of applying it invisibly.
    """
    if not raw or any("/" not in name for name in raw):
        return raw, ""
    roots = {name.split("/", 1)[0] for name in raw}
    if len(roots) != 1:
        return raw, ""
    return {name.split("/", 1)[1]: data for name, data in raw.items()}, roots.pop()


def load_members(target: Path) -> tuple[dict[str, bytes], list[str], str, bool]:
    """Return {relative name: bytes}, structural failures, any stripped top-level folder, and
    whether CRCs were genuinely verified.

    That last value exists because the caller used to print "every entry re-read, CRCs verified"
    whenever nothing had gone wrong — including for the documented folder input, where no archive is
    opened and there are no CRCs to check at all. Printing proof of a check that never ran is the
    precise failure this script exists to be immune to.
    """
    problems: list[str] = []

    if target.is_dir():
        raw: dict[str, bytes] = {}
        for path in sorted(target.rglob("*")):
            if not path.is_file():
                continue
            try:
                raw[str(path.relative_to(target))] = path.read_bytes()
            except OSError as error:
                # Gives the folder path a real check of its own rather than an assumed pass.
                problems.append(f"could not read {path.relative_to(target)}: {error}")
        crc_verified = False
    else:
        with zipfile.ZipFile(target) as zf:
            # testzip() re-reads every entry and verifies its CRC. On a real export this is the
            # only check that exercises compression over ~100 MB rather than a few synthetic rows.
            bad = zf.testzip()
            if bad is not None:
                problems.append(f"CRC failed for archive member {bad}")
            raw = {i.filename: zf.read(i.filename) for i in zf.infolist() if not i.is_dir()}
        crc_verified = True

    members, root = strip_common_root(raw)
    return members, problems, root, crc_verified


def parse_csv(raw: bytes) -> tuple[list[str], list[list[str]]]:
    """Decode and parse, preserving ragged rows so the field-count check can see them."""
    text = raw.decode("utf-8")
    rows = list(csv.reader(io.StringIO(text, newline="")))
    rows = [r for r in rows if r]
    if not rows:
        return [], []
    return rows[0], rows[1:]


def iso(value: str) -> datetime | None:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    target = Path(sys.argv[1]).expanduser()
    if not target.exists():
        print(f"FAIL  no such export: {target}")
        return 2

    r = Results()
    print(f"Verifying {target}\n")

    r.section("Container")
    members, problems, root, crc_verified = load_members(target)
    detail = "; ".join(problems)
    # The label names the mode that actually ran. It used to claim CRC verification unconditionally,
    # so pointing this script at a folder printed evidence of a check that had not happened — and a
    # reader has no way to tell that apart from a genuine pass.
    if crc_verified:
        r.check(not problems, "archive integrity (every entry re-read, CRCs verified)", detail)
    else:
        r.check(not problems,
                "every file in the folder was readable "
                "(folder input, so there is no archive and no CRC to verify)", detail)
    r.note(f"{len(members)} members, {sum(len(v) for v in members.values()):,} bytes uncompressed")
    if root:
        r.note(f"stripped shared top-level folder {root!r} from every member path")

    r.section("Inventory")
    missing = [f for f in REQUIRED_FILES if f not in members]
    r.check(not missing, "all required files present", f"missing {missing}")

    manifest = None
    if "manifest.json" in members:
        try:
            manifest = json.loads(members["manifest.json"].decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            r.check(False, "manifest.json parses", str(exc))

    if isinstance(manifest, dict):
        listed = manifest.get("files")
        if isinstance(listed, list):
            names = {f if isinstance(f, str) else f.get("name") for f in listed}
            extra_in_zip = sorted(set(members) - names)
            extra_in_manifest = sorted(names - set(members))
            r.check(not extra_in_zip and not extra_in_manifest,
                    "manifest inventory matches archive contents exactly",
                    f"only in archive: {extra_in_zip}; only in manifest: {extra_in_manifest}")
        else:
            r.note("manifest has no 'files' list under that key; inventory cross-check skipped")

    r.section("Encoding")
    undecodable = []
    for name, raw in members.items():
        try:
            raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            undecodable.append(f"{name} ({exc})")
    r.check(not undecodable, "every member decodes as UTF-8", "; ".join(undecodable))

    r.section("CSV field counts (catches quoting/escaping failures)")
    for name in sorted(n for n in members if n.endswith(".csv")):
        try:
            header, rows = parse_csv(members[name])
        except UnicodeDecodeError:
            continue  # already reported above
        if not header:
            r.check(False, f"{name} has a header row", "file is empty")
            continue
        ragged = [(i + 2, len(row)) for i, row in enumerate(rows) if len(row) != len(header)]
        r.check(not ragged,
                f"{name}: {len(rows):,} rows x {len(header)} cols",
                f"{len(ragged)} ragged row(s), first at line {ragged[0][0]} "
                f"with {ragged[0][1]} fields" if ragged else "")

    r.section("Workout time sanity")
    if "workouts.csv" in members:
        header, rows = parse_csv(members["workouts.csv"])
        idx = {c: i for i, c in enumerate(header)}
        if {"startDate", "endDate", "duration"} <= set(idx):
            backwards, unparsable, ratios = [], 0, []
            bad_duration = 0
            for i, row in enumerate(rows):
                start, end = iso(row[idx["startDate"]]), iso(row[idx["endDate"]])
                if start is None or end is None:
                    unparsable += 1
                    continue
                if end < start:
                    backwards.append(i + 2)
                try:
                    declared = float(row[idx["duration"]])
                except ValueError:
                    # Counted, not silently skipped. A bare `continue` here meant a file whose every
                    # duration was unreadable printed nothing at all about it — four lines below a
                    # timestamp check that does assert its failures. The inconsistency was the tell.
                    bad_duration += 1
                    continue
                elapsed = (end - start).total_seconds()
                if declared > 0:
                    ratios.append(elapsed / declared)
            r.check(not backwards, "every workout ends at or after it starts",
                    f"rows {backwards[:5]}")
            r.check(unparsable == 0, "every start/end timestamp parses",
                    f"{unparsable} unparsable")
            r.check(bad_duration == 0, "every duration parses as a number",
                    f"{bad_duration} unparsable")
            if ratios:
                lo, hi = min(ratios), max(ratios)
                # Reported, not asserted: the unit of `duration` is not pinned anywhere this script
                # can read, so measure it rather than guess. ~1 means seconds, ~60 means minutes.
                r.note(f"elapsed/duration ratio across {len(ratios)} workouts: "
                       f"{lo:.3f}–{hi:.3f} (~1 = seconds, ~60 = minutes)")
        else:
            r.check(False, "workouts.csv has startDate/endDate/duration", f"header is {header}")

    r.section("Join integrity: can interval records reach a workout?")
    # The app's whole reason for storing interval boundaries separately is so they can be
    # correlated with the HealthKit workout. A real export once contained 98 interval records and
    # 23 workouts with NOTHING joining them: the link was only ever written when the subjective log
    # was filled in mid-run, and logging afterwards silently left every interval orphaned.
    #
    # Historical rows stay orphaned even after the fix, so this does not demand a perfect ratio.
    # It fails on the signature of the bug: intervals and workouts both present, and not one
    # interval reachable.
    if {"workout_intervals.csv", "workouts.csv"} <= set(members):
        iv_header, iv_rows = parse_csv(members["workout_intervals.csv"])
        wk_header, wk_rows = parse_csv(members["workouts.csv"])
        iv_col = {c: i for i, c in enumerate(iv_header)}
        wk_col = {c: i for i, c in enumerate(wk_header)}

        # Asserted before the join verdict below, because a renamed or missing column produces
        # exactly the same zero count as a genuinely broken join — and that verdict names the
        # mid-run-log-only linking bug by name. Confidently blaming the wrong cause is worse than
        # reporting nothing, and it would send the next reader to the matcher instead of the schema.
        r.check("uuid" in wk_col, "workouts.csv has a uuid column to join against",
                f"header is {wk_header}")
        r.check(bool({"healthKitWorkoutUUID", "executionID"} & set(iv_col)),
                "workout_intervals.csv has a column that can name a workout "
                "(healthKitWorkoutUUID or executionID)",
                f"header is {iv_header}")

        workout_uuids = {row[wk_col["uuid"]] for row in wk_rows} if "uuid" in wk_col else set()

        # executionID -> the workout it was matched to, for intervals that only link indirectly.
        execution_workout: dict[str, str] = {}
        if "pending_workout_executions.csv" in members:
            ex_header, ex_rows = parse_csv(members["pending_workout_executions.csv"])
            ex_col = {c: i for i, c in enumerate(ex_header)}
            if {"executionID", "matchedHealthKitWorkoutUUID"} <= set(ex_col):
                for row in ex_rows:
                    uuid = (row[ex_col["matchedHealthKitWorkoutUUID"]] or "").strip()
                    if uuid:
                        execution_workout[row[ex_col["executionID"]]] = uuid

        def workout_for(row: list[str]) -> str:
            """The workout an interval row names, directly or through its execution."""
            if "healthKitWorkoutUUID" in iv_col:
                direct = (row[iv_col["healthKitWorkoutUUID"]] or "").strip()
                if direct:
                    return direct
            if "executionID" in iv_col:
                return execution_workout.get(row[iv_col["executionID"]], "")
            return ""

        reached = [workout_for(row) for row in iv_rows]
        naming = sum(1 for uuid in reached if uuid)
        resolving = sum(1 for uuid in reached if uuid in workout_uuids)

        r.note(f"{len(iv_rows)} interval records: {naming} name a workout, "
               f"{resolving} resolve to a row in workouts.csv")
        if iv_rows and wk_rows:
            r.check(naming > 0,
                    f"{naming}/{len(iv_rows)} interval records reach a workout",
                    "not one interval record names a workout, directly or through its execution "
                    "— the signature of the mid-run-log-only linking bug")
            r.check(naming == resolving,
                    "every workout named by an interval exists in workouts.csv",
                    f"{naming - resolving} name a workout absent from the export")
        else:
            r.note("no interval records or no workouts; nothing to join")

    r.section("What the real data actually contains")
    if "workouts.csv" in members:
        header, rows = parse_csv(members["workouts.csv"])
        idx = {c: i for i, c in enumerate(header)}
        for col in ("workoutActivityTypeName", "sourceName", "deviceName", "reclassifiedAsRunning"):
            if col in idx:
                vals = sorted({(row[idx[col]] or "").strip() for row in rows})
                shown = ", ".join(repr(v[:40]) for v in vals[:5])
                r.note(f"{col}: {len(vals)} distinct — {shown}")
        blank_cols = [c for c in header
                      if all(not (row[idx[c]] or "").strip() for row in rows)] if rows else []
        r.note(f"{len(blank_cols)}/{len(header)} workout columns are blank in every row"
               + (f": {blank_cols[:8]}" if blank_cols else ""))
        # Quoted fields are exactly where escaping bugs hide; confirm real data exercises the path.
        quoted = sum(1 for row in rows for v in row if "," in v or '"' in v)
        r.note(f"{quoted} field(s) contain a comma or quote — the escaping path "
               + ("IS exercised" if quoted else "is NOT exercised by this export"))

    r.finish()

    print("\n" + "=" * 72)
    if r.failures:
        print(f"FAILED — {len(r.failures)} check(s) did not pass:")
        for f in r.failures:
            print(f"  - {f}")
        return 1
    print("All checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
