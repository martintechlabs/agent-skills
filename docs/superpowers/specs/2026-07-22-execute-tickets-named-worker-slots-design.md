# execute-tickets named worker slots — Design

**Date:** 2026-07-22
**Status:** Approved

## Purpose

Raise `execute-tickets.sh`'s worker cap from 4 to 10, and replace the numeric
`--worker N` / `lock:N` scheme with a fixed list of 10 names, so lock labels
read as text instead of single digits that are easy to misread against other
labels (`priority:p3`, `complexity:small`, etc.) in a GitHub issue list.

The numeric `--worker N` cap of 4 was never a technical constraint — nothing
in the claim/race-detection logic depends on the slot count or on the
identifier being numeric, it only checks "is there any other `lock:*` label
present." The cap and the numeric scheme were both just the original
author's arbitrary choice.

## Worker identity

`--worker <name>` replaces `--worker <N>`. Valid names, in slot order:

```
alice bob carol dave eve frank gordon hank isaac justin
```

A fixed, ordered bash array replaces `MAX_WORKERS=4`. Input is
case-insensitive and normalized to lowercase; the normalized name is used
verbatim everywhere a worker identifier appears today:

- Lock label: `lock:<name>` (e.g. `lock:carol`) instead of `lock:<N>`.
- Worktree path suffix: `wt-<repo>-w<name>-i<issue>` instead of `w<N>`.
- Log line prefix: `[... worker=<name>]` instead of `worker=<N>`.
- The `needs-human` comment text: "Executor (worker <name>) gave up: ...".

An unrecognized name is a hard error at argument-parsing time (before
`preflight`), listing the 10 valid names — no attempt to guess or fall back
to a default.

## What does not change

The claim/race-detection logic in `claim_ticket` (add the lock label, read
labels back, check for any `lock:*` label that isn't its own) is already
agnostic to what the label suffix looks like. Raising the cap and renaming
the scheme touches identity and validation only, not the locking mechanism
itself.

## Backward compatibility

None needed. This skill has not been used in production — there is no
installed base of issues carrying `lock:1`..`lock:4` labels, and the
numeric `--worker N` flag does not need to survive as a deprecated alias.
This is a clean rename, not a migration.

## Files and components

- `skills/coding/execute-tickets/scripts/execute-tickets.sh` — the worker
  name array and validation, `ensure_lock_labels()` (pre-creates all 10
  `lock:<name>` labels instead of looping `1..4`), and every place `$WORKER`
  is interpolated (label, worktree path, log prefix, needs-human comment).
- `skills/coding/execute-tickets/SKILL.md` — "4 concurrent worker processes"
  → 10, the `--worker <1..4>` references, and the
  `for W in 1 2 3 4; do ... done` launch-loop example → the name list.
- `skills/coding/execute-tickets/WARP.md` — the "one scheduled agent per
  `--worker` slot 1–4" section → 10 named slots.
- `skills/coding/execute-tickets/tests/run.sh` — existing `--worker 1`
  invocations and the lock-race test's injected rival label (currently
  `lock:2`) switch to names.

## Tests

The shell test suite will prove that:

1. All existing scenarios (green path, dependency gating, red path,
   max-iterations, merge failure, lock-race, ERR-trap, stale-fetch) still
   pass with a named `--worker` argument.
2. `ensure_lock_labels()` creates all 10 `lock:<name>` labels, not 4.
3. An unrecognized `--worker` value exits with a clear error listing the 10
   valid names, before any GitHub mutation.
4. Input is case-insensitive: `--worker Carol` and `--worker carol` produce
   the same lock label.

## Non-goals

- Making the worker list configurable or extensible beyond editing the
  script's fixed array.
- Supporting a numeric `--worker N` alias alongside names.
- Any change to the claim/race-detection mechanism itself.
- Any change to how many workers a repo can realistically run concurrently
  beyond the 10-slot cap (GitHub API rate limits scale with worker count
  the same way they already did at 4; this is an operational consideration
  for whoever launches the workers, not something the script enforces).
