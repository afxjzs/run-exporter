# private/ — the owner's personal material, kept out of this public repository

Everything in this folder except this README and `sensitive-patterns.example` is git-ignored. It holds
what is specific to the owner and must not be published:

| File | Holds |
|---|---|
| `sensitive-patterns.txt` | The values the commit guard blocks — device IDs, the Team ID, anything personal. **Required**: without it every commit is refused. Template: `sensitive-patterns.example` |
| `run-notes.md` | Measurements from the owner's real runs: dates, times, heart rates, body-signal ratings, export filenames |
| `archive-docs/` | A frozen copy of the documents from before the repository went public (2026-09-29), with every real detail intact. Read it; do not maintain it |

The full pre-public history, commit messages included, is the private repository
`afxjzs/run-exporter-archive`.

## The rule

**Committed files carry the lesson; `private/` carries the specifics.** A committed document says
"heart rate per leg separated running from walking clearly"; `private/run-notes.md` holds the numbers.
The same goes for commit messages — the old repository could never be published because personal
details were in its messages.

Personal *settings* have their own local files, each with a committed template:
`Config/Local.xcconfig` (Team ID) and `scripts/local.env` (device IDs).

## The guard

`scripts/check-sensitive.sh` runs as a pre-commit and a commit-msg hook (`.githooks/`, enabled with
`git config core.hooksPath .githooks`). It blocks any added line or commit message containing a
value from `sensitive-patterns.txt`, and refuses to run — blocking the commit — if that file is
missing or empty. Tests: `scripts/test-check-sensitive.sh`.

It catches the **listed values** only. Prose about the owner's health or runs has no fixed string to
match, so keeping it in `private/` is a rule to follow, not something the guard can enforce.
