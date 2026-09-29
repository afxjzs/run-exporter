#!/usr/bin/env bash
# Tests for scripts/check-sensitive.sh, the pre-commit guard that keeps the owner's personal values
# (device IDs, team ID, anything listed in private/sensitive-patterns.txt) out of this public repo.
#
# Written before the guard. Each case is a way the guard could fail — and the dangerous failures are
# the quiet ones: a guard that passes everything because its pattern list is missing or empty looks
# exactly like a guard that found nothing.
#
# Run: scripts/test-check-sensitive.sh    (exit 0 = all passed; prints each case)
set -uo pipefail

GUARD="$(cd "$(dirname "$0")" && pwd)/check-sensitive.sh"
failures=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; failures=$((failures + 1)); }

# A scratch repo with one committed file, and a patterns file listing one fake device ID.
new_repo() {
    rm -rf "$work/repo"
    mkdir -p "$work/repo"
    git -C "$work/repo" init -q
    git -C "$work/repo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
    printf '# comment line\n\nABCD-1234-SECRET\n' > "$work/patterns.txt"
}

# Runs the guard inside the scratch repo; sets $out and $code.
run_guard() {
    out="$(cd "$work/repo" && SENSITIVE_PATTERNS_FILE="$work/patterns.txt" "$GUARD" "$@" 2>&1)"
    code=$?
}

# 1. A staged added line containing a pattern blocks, and names the file.
new_repo
echo "device = ABCD-1234-SECRET" > "$work/repo/notes.md"
git -C "$work/repo" add notes.md
run_guard --staged
if [[ $code -eq 1 && "$out" == *notes.md* ]]; then pass "staged pattern blocks and names the file"
else fail "staged pattern blocks and names the file (exit $code): $out"; fi

# 2. A clean staged change passes.
new_repo
echo "nothing personal here" > "$work/repo/notes.md"
git -C "$work/repo" add notes.md
run_guard --staged
if [[ $code -eq 0 ]]; then pass "clean change passes"
else fail "clean change passes (exit $code): $out"; fi

# 3. A missing patterns file fails loudly, never passes.
new_repo
rm "$work/patterns.txt"
echo "anything" > "$work/repo/notes.md"
git -C "$work/repo" add notes.md
run_guard --staged
if [[ $code -eq 2 && "$out" == *patterns* ]]; then pass "missing patterns file fails loudly"
else fail "missing patterns file fails loudly (exit $code): $out"; fi

# 4. A patterns file with only comments and blank lines is a disabled guard: fail.
new_repo
printf '# only a comment\n\n' > "$work/patterns.txt"
echo "anything" > "$work/repo/notes.md"
git -C "$work/repo" add notes.md
run_guard --staged
if [[ $code -eq 2 ]]; then pass "empty pattern list fails loudly"
else fail "empty pattern list fails loudly (exit $code): $out"; fi

# 5. Removing a line that holds a pattern is allowed — that is the fix, not the leak.
new_repo
echo "device = ABCD-1234-SECRET" > "$work/repo/notes.md"
git -C "$work/repo" add notes.md
git -C "$work/repo" -c user.name=t -c user.email=t@example.com commit -q --no-verify -m seed
echo "device = <PHONE_UDID>" > "$work/repo/notes.md"
git -C "$work/repo" add notes.md
run_guard --staged
if [[ $code -eq 0 ]]; then pass "removing a pattern is allowed"
else fail "removing a pattern is allowed (exit $code): $out"; fi

# 6. A commit message containing a pattern blocks — messages are where the old history leaked.
new_repo
printf 'Fix the thing on ABCD-1234-SECRET\n' > "$work/msg.txt"
run_guard --file "$work/msg.txt"
if [[ $code -eq 1 ]]; then pass "commit message with a pattern blocks"
else fail "commit message with a pattern blocks (exit $code): $out"; fi

# 7. Case does not matter: a lowercased identifier still leaks.
new_repo
echo "id: abcd-1234-secret" > "$work/repo/notes.md"
git -C "$work/repo" add notes.md
run_guard --staged
if [[ $code -eq 1 ]]; then pass "match is case-insensitive"
else fail "match is case-insensitive (exit $code): $out"; fi

# 8. A clean commit message passes.
new_repo
printf 'Add the leg pace readout\n' > "$work/msg.txt"
run_guard --file "$work/msg.txt"
if [[ $code -eq 0 ]]; then pass "clean commit message passes"
else fail "clean commit message passes (exit $code): $out"; fi

if [[ $failures -eq 0 ]]; then
    echo "All check-sensitive tests passed."
    exit 0
fi
echo "$failures check-sensitive test(s) FAILED."
exit 1
