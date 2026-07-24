# Repo-wide discovery mode for execute-tickets and epic-manager — Design

**Date:** 2026-07-23
**Category:** `delivery-pipeline`
**Status:** Approved design, pending spec review

## Purpose

Make `--plan <slug>` **optional** on both `execute-tickets` (currently v0.6.0) and
`epic-manager` (currently v0.2.0). When given, behavior is unchanged — today's
single-plan scoping. When omitted, both scripts operate across every open plan in the
repo, so a fixed pool of long-running workers (e.g. 3 `execute-tickets` workers + 1
`epic-manager`, deployed continuously via systemd on a VPS, no `--once`/cron) can start
processing tickets and epics "as they come in" without a new process needing to be
activated per new plan.

Today, standing up execution for a new plan means starting a whole new set of
`--plan`-scoped processes for it — real operational overhead that falls on whatever
creates the epic (a human, `plan-to-tickets`, or some other system) remembering to also
trigger activation. A worker pool that's already running and polling won't pick up a
brand-new plan's tickets just because they now exist; it's still filtering by a plan it
was told about at startup. This closes that gap.

## Non-goals

- **Coordinating across repos.** One invocation, one repo — unchanged from today. Only
  the "one plan" half of the existing non-goal is being revisited; "one repo" stays.
- **Removing `--plan`.** It remains a fully-supported narrowing filter — e.g. for
  dedicating a worker pool to one sensitive or high-priority feature. Repo-wide is what
  happens when it's *absent*, not the only mode.
- **A safety cap on concurrent plans/epics under management.** Considered and
  deliberately not added: each ticket cycle does the same bounded amount of work
  regardless of how many plans are open, and the two GitHub queries that scale with
  "how much is open" (`gh issue list --limit 200` for tickets, `--limit 500` for epics)
  are already bounded today. Nothing about this change introduces new unbounded
  concurrency — YAGNI on a cap with no concrete failure mode motivating it.
- **New local state.** Both scripts already coordinate purely through GitHub state
  (labels, comments, issue bodies) with no shared filesystem — that stays true here.
  "Which epic to visit next" is derived from GitHub comment history, not a state file.

## Verified facts this design relies on

Confirmed against the actual source before designing against it, not assumed:

- Every ticket issue body carries `<!-- plan-to-tickets:ticket:<plan_file>:<slug> -->`
  (`plan-to-tickets/scripts/create-tickets.sh`).
- Every epic issue body carries `<!-- plan-to-tickets:epic:<plan_file> -->` (same file,
  `file_epic()`).
- `execute-tickets.sh`'s `pick_candidate()` already calls `gh issue list --state open
  --limit 200` with **no plan filter at the API level** — it fetches every open issue in
  the repo, then filters client-side via a jq `contains($pfx)` check against
  `TICKET_MARKER_PREFIX`. The raw data is already repo-wide; only the filter is
  plan-scoped today.
- In both scripts, `load_manifest()` (which sets `SOURCE_BRANCH`/`SPEC_FILE`/
  `PLAN_FILE` from `docs/superpowers/tickets/<slug>.md`) runs **exactly once**, inside
  `preflight()`, called once from `main()`. It is not re-resolved per ticket or per
  cycle today — the values are process-lifetime globals.
- `epic-manager.sh`'s `acquire_lock()` calls `gh issue edit "$EPIC_NUMBER" --add-label
  "$LOCK_LABEL"` — scoped to that specific issue number. GitHub labels live on the
  issue they're attached to, not as repo-wide mutex state, so the existing flat
  `lock:manager` label already works correctly across multiple different epics with
  zero collision. No renaming to a per-epic label is needed.

## Design

### `execute-tickets.sh`

1. Drop the `[ -n "$PLAN_SLUG" ] || die 2 "Missing --plan <slug>"` requirement.
2. When `--plan` **is** given: unchanged. `TICKET_MARKER_PREFIX` is built from that
   plan's file as today, `load_manifest()` still runs once in `preflight()`.
3. When `--plan` is **absent**: `pick_candidate()`'s `ready` filter matches the generic
   `<!-- plan-to-tickets:ticket:` prefix (no specific `plan_file` baked in), so `ready`
   spans every open, unlocked, non-`needs-human`, unassigned ticket across every plan.
   The existing priority/dependency selection logic downstream of `ready` requires **no
   changes** — it already just picks the best candidate from whatever's in that array,
   so true cross-plan priority ranking falls out of loosening the filter, for free.
4. Once `run_one_cycle()` has a chosen candidate, extract *its own* `plan_file` from
   *its own* marker (same regex-capture style already used for parsing the `Depends
   on:` line), derive its slug, and resolve *that* ticket's manifest —
   `docs/superpowers/tickets/<slug>.md`. This replaces the startup-time
   `load_manifest()` call for the repo-wide path: manifest resolution happens once per
   *selected* candidate, not once per process.
5. `SOURCE_BRANCH` (and `SPEC_FILE`/`PLAN_FILE`) become values threaded through
   `claim_ticket()`/`run_ticket()` as parameters for the repo-wide path, rather than
   globals read implicitly. The `--plan`-given path can continue reading them as
   globals set once, since they're genuinely fixed for that path's whole process
   lifetime.

### `epic-manager.sh`

1. Drop the equivalent `--plan` requirement.
2. When given: unchanged.
3. When absent: a new discovery step (one `gh issue list` call, same shape as the
   existing `find_epic_issue()`) finds every open issue carrying the generic
   `<!-- plan-to-tickets:epic:` marker.
4. Rank discovered epics by staleness: oldest "last visited by epic-manager" first,
   never-visited epics sort first (infinitely stale). "Last visited" is read from a
   small marker epic-manager's own progress comments already carry (consistent with
   how tickets/epics are already self-describing — no new local state; everything
   stays derivable from GitHub issue/comment history).
5. Process exactly **one** epic per cycle (confirmed: round-robin, not "all discovered
   epics per firing") — the winner's manifest resolves the same way as tickets: once
   per selected epic, not once at startup.
6. Everything downstream of "which epic is this cycle about" — checklist gate, epic PR,
   final review, command parsing, `lock:manager` — is **unchanged**. It already only
   ever operates on `$EPIC_NUMBER`/manifest-derived values for whichever epic is
   current; making those per-cycle instead of per-process is the entire change.

### Error handling

One real behavior difference from single-plan mode: today, a missing or malformed
manifest is a hard `die` — correct when there's only one plan to work on anyway, since
there's nothing else to fall back to. In repo-wide mode that would kill the *entire*
process over one bad candidate while other good candidates sit idle. So: a candidate
(ticket or epic) with a missing/malformed manifest is logged as a warning and
**skipped** — execute-tickets tries the next-highest-priority ticket, epic-manager
tries the next-stalest epic — rather than dying. This applies **only** to the
repo-wide path; with `--plan` given, a missing/malformed manifest is still fatal
(unchanged), since there's no "next candidate" to fall back to.

Zero-candidates-found in repo-wide mode (no open tickets/epics anywhere) behaves like
today's empty-backlog case: log and return, so the caller's poll-sleep or `--once` exit
happens exactly as it does today.

## Files and components

- `skills/delivery-pipeline/execute-tickets/scripts/execute-tickets.sh` —
  `pick_candidate()`, `load_manifest()` (split into a repo-wide per-candidate variant),
  `claim_ticket()`/`run_ticket()` (accept `SOURCE_BRANCH` etc. as parameters on the
  repo-wide path), `preflight()` (the `--plan` requirement removed), flag parsing/usage
  text.
- `skills/delivery-pipeline/execute-tickets/SKILL.md` — document repo-wide mode,
  version bump.
- `skills/delivery-pipeline/epic-manager/scripts/epic-manager.sh` — new
  `discover_open_epics()` + staleness-ranking function, `load_manifest()` (same split
  as above), `preflight()` (requirement removed), flag parsing/usage text.
- `skills/delivery-pipeline/epic-manager/SKILL.md` — document repo-wide mode, version
  bump.

## Tests

All existing single-plan-mode tests in both skills' `tests/run.sh` must keep passing
unchanged — the regression guard that matters most here, since `--plan` given must stay
byte-identical to today.

New coverage:

1. **execute-tickets, repo-wide priority ranking.** Two fake plans/manifests, each with
   open tickets of different priority; running without `--plan` picks the globally
   highest-priority ticket regardless of which plan it belongs to.
2. **execute-tickets, per-candidate manifest resolution.** The picked ticket's worktree
   is created against *its own* plan's `source_branch`, not some other open plan's.
3. **execute-tickets, missing manifest is skipped, not fatal.** A repo-wide candidate
   whose manifest file doesn't exist is skipped with a logged warning; the next
   candidate is tried and succeeds.
4. **execute-tickets, empty repo-wide backlog.** No open tickets anywhere → behaves
   like today's empty-backlog case (log, return), not an error.
5. **epic-manager, staleness ranking.** Two open epics, one with a recent
   epic-manager comment and one never visited; running without `--plan` picks the
   never-visited one.
6. **epic-manager, staleness ranking among visited epics.** Two open epics both
   previously visited; the one with the older last-visited marker is picked.
7. **epic-manager, missing manifest is skipped, not fatal.** Same shape as #3.
8. **epic-manager, empty repo-wide backlog.** No open epics anywhere → behaves like
   today's no-epic case.
9. **Both scripts, `--plan` given still works exactly as today.** Existing single-plan
   tests are the proof; no new test needed beyond confirming they still pass.

## Versioning

`execute-tickets` 0.6.0 → 0.7.0, `epic-manager` 0.2.0 → 0.3.0 — new capability, not a
patch, per this repo's semver-ish convention.

## Open questions deferred to implementation

- **Exact "last visited" marker format** for epic-manager's staleness ranking (e.g. a
  hidden HTML comment appended to progress comments, `<!-- epic-manager:visited:<ISO
  timestamp> -->`). The mechanism (derive staleness from GitHub comment history, no new
  local state) is fixed by this spec; the literal marker string is an implementation
  detail.
- **Exact slug-derivation regex** from a marker's embedded `plan_file` path. Must match
  `plan-to-tickets`'s own slug convention (the `<feature>` portion of
  `docs/superpowers/plans/YYYY-MM-DD-<feature>.md`) exactly, since it's looking up a
  manifest `plan-to-tickets` already wrote under that same slug.
