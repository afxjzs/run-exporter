#!/usr/bin/env bash
# Blocks a commit that would put one of the owner's personal values into this PUBLIC repository.
#
#   check-sensitive.sh --staged        check the lines being added in the staged change (pre-commit)
#   check-sensitive.sh --file <path>   check a file, e.g. the commit message (commit-msg)
#
# The values themselves live in private/sensitive-patterns.txt — git-ignored, so the list of what
# must not be published is never published. One value per line, matched as a fixed string,
# case-insensitively; lines starting with # and blank lines are ignored. Template:
# private/sensitive-patterns.example.
#
# Exit codes: 0 clean · 1 a listed value was found (the commit is blocked) · 2 the guard cannot
# run. **A missing or empty pattern list is exit 2, never 0**: a guard with nothing to look for
# would pass every commit and look exactly like one that found nothing.
#
# Why commit messages too: the repository this one replaced could never be published, because the
# owner's personal details were in its commit messages, where no later edit reaches them.
set -uo pipefail

usage() {
    echo "usage: $0 --staged | --file <path>" >&2
    exit 2
}

[[ $# -ge 1 ]] || usage
mode="$1"

if ! root="$(git rev-parse --show-toplevel 2>&1)"; then
    echo "check-sensitive: not inside a git repository: $root" >&2
    exit 2
fi
patterns_file="${SENSITIVE_PATTERNS_FILE:-$root/private/sensitive-patterns.txt}"

if [[ ! -f "$patterns_file" ]]; then
    echo "check-sensitive: no patterns file at $patterns_file." >&2
    echo "  The guard cannot check anything without it, so it refuses to pass the commit." >&2
    echo "  Create it from private/sensitive-patterns.example." >&2
    exit 2
fi

patterns="$(mktemp)"
trap 'rm -f "$patterns"' EXIT
grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$patterns_file" > "$patterns"
if [[ ! -s "$patterns" ]]; then
    echo "check-sensitive: $patterns_file lists no values (only comments or blank lines)." >&2
    echo "  An empty list would pass every commit, so the guard refuses." >&2
    exit 2
fi

found=0
case "$mode" in
    --staged)
        # Only ADDED lines: removing a personal value is the fix, not the leak.
        current=""
        while IFS= read -r line; do
            case "$line" in
                "+++ b/"*) current="${line#+++ b/}" ;;
                "+++ "*)   current="" ;;
                "+"*)
                    if printf '%s\n' "${line#+}" | grep -q -i -F -f "$patterns"; then
                        echo "check-sensitive: ${current:-<unknown file>}: ${line#+}" >&2
                        found=1
                    fi
                    ;;
            esac
        done < <(git diff --cached --no-color --no-ext-diff -U0)
        ;;
    --file)
        [[ $# -ge 2 ]] || usage
        if matches="$(grep -n -i -F -f "$patterns" "$2")"; then
            printf 'check-sensitive: %s:%s\n' "$2" "$matches" >&2
            found=1
        fi
        ;;
    *)
        usage
        ;;
esac

if [[ $found -eq 1 ]]; then
    echo "check-sensitive: BLOCKED — a value from $patterns_file is in this commit." >&2
    echo "  Move it into a git-ignored local file (Config/Local.xcconfig, scripts/local.env," >&2
    echo "  or private/) and refer to it from the committed file instead." >&2
    exit 1
fi
exit 0
