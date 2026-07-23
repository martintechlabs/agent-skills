# Repo-wide Discovery Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `--plan <slug>` optional on `execute-tickets.sh` and `epic-manager.sh`. When given, behavior is byte-identical to today. When omitted, both scripts discover and process work across every open plan in the repo — `execute-tickets` picks the globally highest-priority ready ticket across all plans; `epic-manager` round-robins one open epic per cycle, stalest first.

**Architecture:** In both scripts, `load_manifest()` becomes a parameterized function (`load_manifest <slug>`) that returns 1 instead of dying on a missing/malformed manifest — the caller decides whether that's fatal (`--plan` given: still fatal, unchanged) or a skip-this-candidate signal (repo-wide: log a warning, try the next candidate). A new `REPO_WIDE` boolean (true when `--plan` was omitted) gates every repo-wide-only code path; it is never inferred from whether `PLAN_SLUG` happens to be empty, because in repo-wide mode `PLAN_SLUG` gets *set* by `load_manifest` once a candidate resolves, and must not be mistaken for "a plan was passed on the CLI" on the next cycle. `execute-tickets`'s `pick_candidate()` changes its return contract from "single JSON object or empty" to "JSON array, already priority-sorted" — `run_one_cycle()` iterates it, skipping candidates whose own plan fails to resolve, trying claim+run on the first that does. `epic-manager` gets a new `discover_open_epics()` that ranks open epics by staleness using the *existing* `<!-- manager:lock-acquired:TS -->` comment marker (no new marker format needed) — `run_one_cycle()` iterates that list the same way.

**Tech Stack:** Bash, `jq`, the existing `tests/run.sh` + `tests/lib.sh` + `fake-gh`/`fake-codex`/`fake-yq` fixture harness in both skills (no changes to the harness itself — only new `test_*` functions appended).

---

### Task 1: `execute-tickets.sh` — `--plan` optional, `load_manifest()` parameterized

**Files:**
- Modify: `skills/delivery-pipeline/execute-tickets/scripts/execute-tickets.sh`
- Test: `skills/delivery-pipeline/execute-tickets/tests/run.sh`

- [ ] **Step 1: Write the failing tests**

Append to `skills/delivery-pipeline/execute-tickets/tests/run.sh` (before the final `printf '\n%d passed, %d failed\n' ...` line — check the file's actual tail first; every other task in this plan also appends before that line, so re-locate it each time rather than assuming line numbers):

```bash
# ---- Repo-wide discovery: Task 1 — --plan optional, load_manifest() parameterized ----

test_plan_flag_now_optional() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json"
  seed_state "$state" "[]"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" \
    -- --worker alice --agent-cmd echo --once
  assert_not_contains "$ERR" "Missing --plan" "--plan is no longer required"
  rm -rf "$d"
}
test_plan_flag_now_optional

test_repo_wide_no_manifest_loaded_at_startup() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json"
  seed_state "$state" "[]"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" \
    -- --worker alice --agent-cmd echo --once
  assert_eq "$RC" "0" "repo-wide with no tickets exits 0 (once mode always exits 0)"
  assert_not_contains "$ERR" "Manifest not found" "no manifest load is attempted at startup without --plan"
  assert_contains "$ERR" "No ready tickets" "empty repo-wide backlog behaves like today's empty-backlog case, not an error"
  rm -rf "$d"
}
test_repo_wide_no_manifest_loaded_at_startup

test_plan_given_manifest_missing_still_fatal() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$d/state.json" \
    -- --worker alice --plan does-not-exist --agent-cmd echo --once
  assert_eq "$RC" "1" "missing manifest with --plan given still exits 1"
  assert_contains "$ERR" "Manifest not found" "still reports the specific reason"
  rm -rf "$d"
}
test_plan_given_manifest_missing_still_fatal
```

- [ ] **Step 2: Run to verify failure**

```bash
bash skills/delivery-pipeline/execute-tickets/tests/run.sh 2>&1 | tail -20
```

Expected: `test_plan_flag_now_optional` and `test_repo_wide_no_manifest_loaded_at_startup` FAIL (today, omitting `--plan` still dies with "Missing --plan <slug>", exit code 2). `test_plan_given_manifest_missing_still_fatal` passes already (matches today's existing behavior) — that's fine, it's here as a regression pin for Step 3, not a new-behavior test.

- [ ] **Step 3: Implement**

In `skills/delivery-pipeline/execute-tickets/scripts/execute-tickets.sh`, add a new global near the other flags (after `PLAN_SLUG=""` at line 13):

```bash
REPO_WIDE=false   # true when --plan was omitted: discover across every open plan
```

In `parse_args()`, replace:

```bash
  [ -n "$PLAN_SLUG" ] || die 2 "Missing --plan <slug>"
```

with:

```bash
  if [ -z "$PLAN_SLUG" ]; then
    REPO_WIDE=true
  fi
```

Replace the entire `load_manifest()` function with:

```bash
# load_manifest <slug> -- populates MANIFEST_FILE/SOURCE_BRANCH/SPEC_FILE/PLAN_FILE/
# TICKET_MARKER_PREFIX/PLAN_SLUG for <slug>. Returns 1 (never dies) on a missing or
# malformed manifest -- the caller decides whether that's fatal (--plan given) or a
# skip-this-candidate signal (repo-wide mode). Globals are only assigned on full
# success, so a failed call never leaves partial state behind.
load_manifest() {
  local slug="$1"
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  local manifest_file="$root/docs/superpowers/tickets/$slug.md"
  if [ ! -f "$manifest_file" ]; then
    log "Manifest not found: $manifest_file (run plan-to-tickets first)"
    return 1
  fi
  local source_branch="" spec_file="" plan_file=""
  local in_fm=false key val line
  while IFS= read -r line; do
    if [ "$line" = "---" ]; then
      if [ "$in_fm" = false ]; then in_fm=true; continue; else break; fi
    fi
    [ "$in_fm" = true ] || continue
    key="${line%%:*}"; val="${line#*:}"; val="${val# }"
    val="${val#\"}"; val="${val%\"}"
    case "$key" in
      source_branch) source_branch="$val" ;;
      spec_file) spec_file="$val" ;;
      plan_file) plan_file="$val" ;;
    esac
  done < "$manifest_file"
  if [ -z "$source_branch" ] || [ -z "$spec_file" ] || [ -z "$plan_file" ]; then
    log "Manifest missing source_branch/spec_file/plan_file: $manifest_file"
    return 1
  fi
  PLAN_SLUG="$slug"
  MANIFEST_FILE="$manifest_file"
  SOURCE_BRANCH="$source_branch"
  SPEC_FILE="$spec_file"
  PLAN_FILE="$plan_file"
  TICKET_MARKER_PREFIX="<!-- plan-to-tickets:ticket:$PLAN_FILE:"
  vlog "manifest: $MANIFEST_FILE"
  vlog "  source_branch: $SOURCE_BRANCH"
  vlog "  spec_file:     $SPEC_FILE"
  vlog "  plan_file:     $PLAN_FILE"
  vlog "  reviewer model: $(reviewer_model)"
  return 0
}
```

In `main()`, replace:

```bash
main() {
  parse_args "$@"
  preflight
  load_manifest
```

with:

```bash
main() {
  parse_args "$@"
  preflight
  if [ "$REPO_WIDE" != true ]; then
    load_manifest "$PLAN_SLUG" || die 1 "Manifest not found or malformed for plan '$PLAN_SLUG' (run plan-to-tickets first)"
  fi
```

- [ ] **Step 4: Run tests, verify all pass**

```bash
bash skills/delivery-pipeline/execute-tickets/tests/run.sh 2>&1 | tail -30
```

Expected: all three new tests `ok`, and every pre-existing test in the file still `ok` (this is the regression guard — `--plan`-given mode must be untouched). `0` in the final `FAIL` count.

- [ ] **Step 5: Commit**

```bash
git add skills/delivery-pipeline/execute-tickets/scripts/execute-tickets.sh skills/delivery-pipeline/execute-tickets/tests/run.sh
git commit -m "execute-tickets: make --plan optional, parameterize load_manifest()"
```

---

### Task 2: `execute-tickets.sh` — `pick_candidate()` repo-wide filter + array contract

**Files:**
- Modify: `skills/delivery-pipeline/execute-tickets/scripts/execute-tickets.sh`
- Test: `skills/delivery-pipeline/execute-tickets/tests/run.sh`

This task changes `pick_candidate()`'s return shape from "single JSON object or empty string" to "JSON array, priority-sorted, `[]` when nothing is ready" — the array form is what Task 3's `run_one_cycle()` needs so it can skip a candidate and try the next. This task does *not* wire that iteration in yet (that's Task 3); it only lands the contract change plus the repo-wide marker filter, proven via a regression test (single-plan mode still selects correctly) and a same-plan repo-wide test (the generic prefix still matches real tickets).

- [ ] **Step 1: Write the failing tests**

Append to `skills/delivery-pipeline/execute-tickets/tests/run.sh`:

```bash
# ---- Repo-wide discovery: Task 2 — pick_candidate() repo-wide filter + array return ----

test_pick_candidate_single_plan_still_works() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" \
    -- --worker alice --plan plan1 --agent-cmd echo --dry-run --once
  assert_eq "$RC" "0" "single-plan dry-run still exits 0 after array-contract change"
  assert_contains "$ERR" "#101" "still finds and reports the ticket"
  rm -rf "$d"
}
test_pick_candidate_single_plan_still_works

test_repo_wide_matches_generic_prefix() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" \
    -- --worker alice --agent-cmd echo --dry-run --once
  assert_eq "$RC" "0" "repo-wide dry-run exits 0"
  assert_contains "$ERR" "#101" "repo-wide mode finds the ticket via the generic marker prefix"
  rm -rf "$d"
}
test_repo_wide_matches_generic_prefix
```

- [ ] **Step 2: Run to verify failure**

```bash
bash skills/delivery-pipeline/execute-tickets/tests/run.sh 2>&1 | tail -20
```

Expected: `test_repo_wide_matches_generic_prefix` FAILs (today `pick_candidate()` always filters on the plan-specific `TICKET_MARKER_PREFIX`, which is empty/unset in repo-wide mode since `load_manifest` hasn't run yet, so the jq filter matches nothing). `test_pick_candidate_single_plan_still_works` should already pass (it's a regression pin).

- [ ] **Step 3: Implement**

Add a new global near `TICKET_MARKER_PREFIX=""`:

```bash
TICKET_MARKER_GENERIC_PREFIX="<!-- plan-to-tickets:ticket:"
```

In `pick_candidate()`, change the top of the function from:

```bash
pick_candidate() {
  local raw ready dep_numbers closed_map
  raw="$(gh issue list --repo "$REPO" --state open --limit 200 \
          --json number,title,body,labels,assignees 2>/dev/null || echo '[]')"
  ready="$(jq --arg pfx "$TICKET_MARKER_PREFIX" '
```

to:

```bash
pick_candidate() {
  local pfx
  if [ "$REPO_WIDE" = true ]; then
    pfx="$TICKET_MARKER_GENERIC_PREFIX"
  else
    pfx="$TICKET_MARKER_PREFIX"
  fi
  local raw ready dep_numbers closed_map
  raw="$(gh issue list --repo "$REPO" --state open --limit 200 \
          --json number,title,body,labels,assignees 2>/dev/null || echo '[]')"
  ready="$(jq --arg pfx "$pfx" '
```

Change the empty-ready early return from:

```bash
  [ "$(jq 'length' <<<"$ready")" -gt 0 ] || return 0
```

to:

```bash
  [ "$(jq 'length' <<<"$ready")" -gt 0 ] || { echo '[]'; return 0; }
```

Change the final line of the function's trailing jq pipeline from:

```bash
    | map(select(.ready))
    | sort_by(._priority, ._complexity, .number)
    | .[0] // empty
  ' <<<"$ready"
```

to:

```bash
    | map(select(.ready))
    | sort_by(._priority, ._complexity, .number)
  ' <<<"$ready"
```

(Same sort, just no longer truncated to the first element — `pick_candidate()` now always prints a JSON array.)

- [ ] **Step 4: Run tests, verify pass**

```bash
bash skills/delivery-pipeline/execute-tickets/tests/run.sh 2>&1 | tail -30
```

Expected: `0` failed — including every pre-existing test. Pre-existing tests that consumed `pick_candidate()`'s old single-object output only do so *indirectly* through `run_one_cycle()`, which Task 3 updates to consume the new array shape — until Task 3 lands, `run_one_cycle()` still does `candidate="$(pick_candidate)"` expecting a single object, so at the end of *this* task `run_one_cycle()` is temporarily consuming an array where it expects an object. Verify this doesn't silently break existing single-candidate tests: with exactly one ready ticket, `pick_candidate()`'s array has exactly one element, and downstream `jq -r '.number' <<<"$candidate"` on a one-element *array* (not the element itself) will fail to extract `.number` correctly. **If Step 4 shows failures here**, this confirms `run_one_cycle()` must be updated in the same task rather than deferred to Task 3 — in that case, pull Task 3's `run_one_cycle()` array-indexing change (`candidate="$(jq -c '.[0]' <<<"$candidates")"` at minimum, without the full skip-and-retry loop yet) forward into this task so the suite is green before committing. Do not commit with a red suite.

- [ ] **Step 5: Commit**

```bash
git add skills/delivery-pipeline/execute-tickets/scripts/execute-tickets.sh skills/delivery-pipeline/execute-tickets/tests/run.sh
git commit -m "execute-tickets: pick_candidate() matches repo-wide, returns a sorted array"
```

---

### Task 3: `execute-tickets.sh` — per-candidate manifest resolution in `run_one_cycle()`

**Files:**
- Modify: `skills/delivery-pipeline/execute-tickets/scripts/execute-tickets.sh`
- Modify: `skills/delivery-pipeline/execute-tickets/tests/lib.sh`
- Test: `skills/delivery-pipeline/execute-tickets/tests/run.sh`

This is the task that makes repo-wide mode actually work end-to-end: `run_one_cycle()` iterates `pick_candidate()`'s array, resolving each candidate's own plan via a new `slug_from_candidate_marker()` helper, skipping (not dying on) a candidate whose manifest doesn't resolve, and proceeding with claim/run on the first one that does.

- [ ] **Step 1: Add a second-manifest test helper to `tests/lib.sh`**

Every other reusable test helper (`make_repo`, `issue_json`, `seed_state`, `bindir_for`, `run_et`) lives in `tests/lib.sh`, not inline in `run.sh` — add this one there too, right after `make_repo`:

Append to `skills/delivery-pipeline/execute-tickets/tests/lib.sh`:

```bash
# add_second_manifest <workdir> <slug> <plan_file> [source_branch]
# Writes a second manifest (a different plan than make_repo's default) directly
# into an already-initialized work tree, mirroring what plan-to-tickets' own
# create-tickets.sh would have produced for a second, independently-filed plan.
add_second_manifest() {
  local workdir="$1" slug="$2" plan_file="$3" source_branch="${4:-epic}"
  mkdir -p "$workdir/docs/superpowers/tickets"
  cat > "$workdir/docs/superpowers/tickets/$slug.md" <<EOF
---
source_branch: "$source_branch"
spec_file: "docs/superpowers/specs/test-spec-2.md"
plan_file: "$plan_file"
---

# Tickets filed for $plan_file
EOF
  git -C "$workdir" add "docs/superpowers/tickets/$slug.md"
  git -C "$workdir" commit -q -m "file tickets for $slug"
  git -C "$workdir" push -q origin epic
}
```

- [ ] **Step 2: Write the failing tests**

Append to `skills/delivery-pipeline/execute-tickets/tests/run.sh`:

```bash
# ---- Repo-wide discovery: Task 3 — per-candidate manifest resolution ----

test_repo_wide_picks_globally_highest_priority_across_plans() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan-a docs/superpowers/plans/test-plan.md
  # plan-b gets its own distinct source_branch ("epic-b", not "epic") --
  # deliberately different from plan-a's, so a bug that resolved the WRONG
  # plan's manifest (e.g. leaked plan-a's SOURCE_BRANCH via a stale global)
  # would be caught by the source_branch assertion below, not just the slug.
  add_second_manifest "$d/work" plan-b docs/superpowers/plans/plan-b.md epic-b
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json"
  # Ticket 101 belongs to plan-a at p2; ticket 102 belongs to plan-b at p1.
  # Repo-wide (no --plan) must pick #102 -- true cross-plan priority ranking,
  # not "whichever plan happens to be scanned first."
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Plan A ticket", body:"<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p2","complexity:small","model-tier:efficient"], assignees:[], state:"open"},
    {number:102, title:"Plan B ticket", body:"<!-- plan-to-tickets:ticket:docs/superpowers/plans/plan-b.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" \
    -- --worker alice --agent-cmd echo --dry-run --once
  assert_eq "$RC" "0" "repo-wide cross-plan dry-run exits 0"
  assert_contains "$ERR" "#102" "picked the p1 ticket from plan-b, not the p2 ticket from plan-a"
  assert_contains "$ERR" "plan:              plan-b" "dry-run report shows plan-b's own resolved slug"
  assert_contains "$ERR" "source_branch:     epic-b" "resolved plan-b's own source_branch, not plan-a's ('epic')"
  rm -rf "$d"
}
test_repo_wide_picks_globally_highest_priority_across_plans

test_repo_wide_skips_candidate_with_missing_manifest() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan-a docs/superpowers/plans/test-plan.md
  # Deliberately do NOT add a manifest for plan-missing -- ticket 101 references
  # a plan whose manifest was never committed (simulates a stale/broken marker).
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Broken ticket", body:"<!-- plan-to-tickets:ticket:docs/superpowers/plans/plan-missing.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"},
    {number:102, title:"Good ticket", body:"<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p2","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" \
    -- --worker alice --agent-cmd echo --dry-run --once
  assert_eq "$RC" "0" "repo-wide dry-run exits 0 despite one broken candidate"
  assert_contains "$ERR" "Skipping #101" "logs a warning for the unresolvable candidate"
  assert_contains "$ERR" "#102" "falls through to the next candidate and reports it"
  rm -rf "$d"
}
test_repo_wide_skips_candidate_with_missing_manifest

test_repo_wide_all_candidates_broken() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan-a docs/superpowers/plans/test-plan.md
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Broken ticket", body:"<!-- plan-to-tickets:ticket:docs/superpowers/plans/plan-missing.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" \
    -- --worker alice --agent-cmd echo --once
  assert_contains "$ERR" "No candidates resolved to a valid manifest" "clear message when every candidate is broken"
  rm -rf "$d"
}
test_repo_wide_all_candidates_broken
```

- [ ] **Step 3: Run to verify failure**

```bash
bash skills/delivery-pipeline/execute-tickets/tests/run.sh 2>&1 | tail -40
```

Expected: all three new tests FAIL — `run_one_cycle()` doesn't yet resolve per-candidate manifests, so `#102` never gets correctly attributed to `plan-b`, and there's no skip-and-retry behavior yet.

- [ ] **Step 4: Implement**

Add a new function, placed after `pick_candidate()`:

```bash
# slug_from_candidate_marker <candidate_json> -> the plan slug embedded in the
# candidate's own ticket marker, or empty if unparseable. Only meaningful in
# repo-wide mode, where pick_candidate() matched on the generic marker prefix
# and doesn't already know which plan this specific ticket belongs to.
slug_from_candidate_marker() {
  local candidate="$1" rest plan_file
  rest="$(jq -r '
    .body // ""
    | capture("<!-- plan-to-tickets:ticket:(?<rest>[^\\n]+) -->"; "g").rest // empty
  ' <<<"$candidate" 2>/dev/null)"
  [ -n "$rest" ] || return 0
  plan_file="${rest%:*}"
  [ -n "$plan_file" ] || return 0
  basename "$plan_file" .md | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//'
}
```

Replace `run_one_cycle()` entirely with:

```bash
run_one_cycle() {
  local candidates total
  candidates="$(pick_candidate)"
  total="$(jq 'length' <<<"$candidates")"
  if [ "$total" -eq 0 ]; then
    log "No ready tickets."
    return 1
  fi
  local i=0
  while [ "$i" -lt "$total" ]; do
    local candidate n
    candidate="$(jq -c ".[$i]" <<<"$candidates")"
    n="$(jq -r '.number' <<<"$candidate")"
    if [ "$REPO_WIDE" = true ]; then
      local slug
      slug="$(slug_from_candidate_marker "$candidate")"
      if [ -z "$slug" ] || ! load_manifest "$slug"; then
        log "Skipping #$n: could not resolve manifest for its plan (marker slug: ${slug:-<unparseable>})."
        i=$((i + 1))
        continue
      fi
    fi
    log "Candidate: #$n ($(jq -r '.title' <<<"$candidate"))"
    if [ "$DRY_RUN" = true ]; then
      dry_run_report "$candidate"
      return 0
    fi
    if ! claim_ticket "$n"; then
      log "Lost claim race on #$n; will retry."
      return 1
    fi
    # Bare statement + explicit rc capture, not `if run_ticket ...; then` --
    # run_ticket is a subshell with its own ERR trap for unexpected failures,
    # and calling it as an if/&&/||/! test would suppress that trap for its
    # entire execution (see main()'s comment for the underlying bash behavior).
    set +e
    run_ticket "$candidate"
    local ticket_rc=$?
    set -e
    if [ "$ticket_rc" -eq 0 ]; then
      log "Completed #$n."
    else
      log "Failed #$n; marked needs-human."
    fi
    return 0
  done
  log "No candidates resolved to a valid manifest."
  return 1
}
```

- [ ] **Step 5: Run tests, verify pass**

```bash
bash skills/delivery-pipeline/execute-tickets/tests/run.sh 2>&1 | tail -40
```

Expected: `0` failed, including every pre-existing single-plan test (which never sets `REPO_WIDE`, so the `if [ "$REPO_WIDE" = true ]` block never runs for them — the `while` loop's first iteration always succeeds immediately, identical observable behavior to before).

- [ ] **Step 6: Commit**

```bash
git add skills/delivery-pipeline/execute-tickets/scripts/execute-tickets.sh skills/delivery-pipeline/execute-tickets/tests/lib.sh skills/delivery-pipeline/execute-tickets/tests/run.sh
git commit -m "execute-tickets: resolve each repo-wide candidate's own plan, skip broken ones"
```

---

### Task 4: `execute-tickets.sh` — docs and version bump

**Files:**
- Modify: `skills/delivery-pipeline/execute-tickets/SKILL.md`

- [ ] **Step 1: Bump the version**

In `skills/delivery-pipeline/execute-tickets/SKILL.md`, find the frontmatter:

```yaml
metadata:
  author: stephen-martin
  version: "0.6.0"
```

Change to:

```yaml
metadata:
  author: stephen-martin
  version: "0.7.0"
```

- [ ] **Step 2: Document repo-wide mode**

In the same file, find the `--plan <slug>` row in the `## Flags` table:

```markdown
| `--plan <slug>` | Plan slug: basename of `docs/superpowers/tickets/<slug>.md` (required). |
```

Change to:

```markdown
| `--plan <slug>` | Plan slug: basename of `docs/superpowers/tickets/<slug>.md`. Optional — omit for repo-wide mode (see below). |
```

Find the `## When this applies` section and add a paragraph after its existing content:

```markdown
**Repo-wide mode.** Omit `--plan` entirely to have a worker consider every open
plan's ready tickets at once, ranked by true cross-plan priority (a `priority:p1`
ticket in one plan outranks a `priority:p2` ticket in another). Each ticket's own
plan is resolved from its own hidden marker — no manifest is loaded upfront. A
candidate whose plan's manifest can't be resolved (missing or malformed) is
skipped with a logged warning; the worker tries the next-highest-priority
candidate instead of dying, since in repo-wide mode there's usually other good
work available. This is the mode a fixed, long-running worker pool should use
(e.g. deployed continuously via systemd) so new plans get picked up as soon as
`plan-to-tickets` files them — no per-plan process to start. Use `--plan` when
you want a worker (or pool) dedicated to one specific plan instead.
```

- [ ] **Step 3: Commit**

```bash
git add skills/delivery-pipeline/execute-tickets/SKILL.md
git commit -m "execute-tickets: document repo-wide mode, bump to 0.7.0"
```

---

### Task 5: `epic-manager.sh` — `--plan` optional, `load_manifest()`/epic lookup parameterized

**Files:**
- Modify: `skills/delivery-pipeline/epic-manager/scripts/epic-manager.sh`
- Test: `skills/delivery-pipeline/epic-manager/tests/run.sh`

Mirrors Task 1, on the epic-manager side. `epic-manager.sh`'s `load_manifest()` also looks up the epic issue internally (via the now-renamed `find_epic_issue_by_marker()`) — that lookup gets the same "return 1, don't die" treatment.

- [ ] **Step 1: Write the failing tests**

Append to `skills/delivery-pipeline/epic-manager/tests/run.sh` (locate the actual final two lines — `printf '\n%d passed, %d failed\n' ...` / `[ "$FAIL" -eq 0 ]` — and insert before them; per the note in this skill's own AGENTS.md, this file also has a stray early `printf`/exit-check right after `source lib.sh` at its top — that's a known pre-existing harness quirk, not something to fix here):

```bash
# ---- Repo-wide discovery: Task 5 — --plan optional, load_manifest() parameterized ----

test_em_plan_flag_now_optional() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  seed_state "$d/state" "[]"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" -- --once
  assert_not_contains "$ERR" "Missing --plan" "--plan is no longer required"
  rm -rf "$d"
}
test_em_plan_flag_now_optional

test_em_repo_wide_no_manifest_loaded_at_startup() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  seed_state "$d/state" "[]"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" -- --once
  assert_not_contains "$ERR" "Manifest not found" "no manifest load is attempted at startup without --plan"
  rm -rf "$d"
}
test_em_repo_wide_no_manifest_loaded_at_startup

test_em_plan_given_manifest_missing_still_fatal() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" -- --plan does-not-exist --dry-run
  assert_eq "$RC" "1" "missing manifest with --plan given still exits 1"
  assert_contains "$ERR" "Manifest not found" "still reports the specific reason"
  rm -rf "$d"
}
test_em_plan_given_manifest_missing_still_fatal

test_em_plan_given_no_epic_still_fatal() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  seed_state "$d/state" "[$(issue_json 100 'Not the epic' 'no marker here' '[]')]"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" -- --plan test-plan --dry-run
  assert_eq "$RC" "1" "missing epic issue with --plan given still exits 1"
  assert_contains "$ERR" "No epic issue" "still reports the specific reason (regression pin -- must match this exact wording)"
  rm -rf "$d"
}
test_em_plan_given_no_epic_still_fatal
```

- [ ] **Step 2: Run to verify failure**

```bash
bash skills/delivery-pipeline/epic-manager/tests/run.sh 2>&1 | tail -20
```

Expected: `test_em_plan_flag_now_optional` and `test_em_repo_wide_no_manifest_loaded_at_startup` FAIL (today, omitting `--plan` dies with "Missing --plan <slug>"). The other two are regression pins for pre-existing fatal behavior and should already pass.

- [ ] **Step 3: Implement**

Add a new global near `PLAN_SLUG=""`:

```bash
REPO_WIDE=false   # true when --plan was omitted: discover across every open epic
```

In `parse_args()`, replace:

```bash
  [ -n "$PLAN_SLUG" ] || die 2 "Missing --plan <slug>"
```

with:

```bash
  if [ -z "$PLAN_SLUG" ]; then
    REPO_WIDE=true
  fi
```

Rename `find_epic_issue()` to accept the marker as a parameter — replace:

```bash
find_epic_issue() {
  # The epic issue carries the plan-to-tickets:epic marker. Search all states
  # (a completed epic may be closed; a human may have re-opened it for rework).
  gh issue list --repo "$REPO" --state all --limit 500 \
    --json number,body 2>/dev/null \
    | jq -r --arg marker "$EPIC_MARKER" '.[] | select(.body // "" | contains($marker)) | .number' \
    | head -1
}
```

with:

```bash
find_epic_issue_by_marker() {
  # The epic issue carries the plan-to-tickets:epic marker. Search all states
  # (a completed epic may be closed; a human may have re-opened it for rework).
  local marker="$1"
  gh issue list --repo "$REPO" --state all --limit 500 \
    --json number,body 2>/dev/null \
    | jq -r --arg marker "$marker" '.[] | select(.body // "" | contains($marker)) | .number' \
    | head -1
}
```

Replace `load_manifest()` entirely with:

```bash
# load_manifest <slug> -- populates MANIFEST_FILE/SOURCE_BRANCH/SPEC_FILE/PLAN_FILE/
# EPIC_MARKER/TICKET_MARKER_PREFIX/EPIC_NUMBER/PLAN_SLUG for <slug>. Returns 1
# (never dies) on a missing/malformed manifest or a missing epic issue -- the
# caller decides whether that's fatal (--plan given) or a skip signal (repo-wide).
load_manifest() {
  local slug="$1"
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  local manifest_file="$root/docs/superpowers/tickets/$slug.md"
  if [ ! -f "$manifest_file" ]; then
    log "Manifest not found: $manifest_file (run plan-to-tickets first)"
    return 1
  fi
  local source_branch="" spec_file="" plan_file=""
  local in_fm=false key val line
  while IFS= read -r line; do
    if [ "$line" = "---" ]; then
      if [ "$in_fm" = false ]; then in_fm=true; continue; else break; fi
    fi
    [ "$in_fm" = true ] || continue
    key="${line%%:*}"; val="${line#*:}"; val="${val# }"; val="${val#\"}"; val="${val%\"}"
    case "$key" in
      source_branch) source_branch="$val" ;;
      spec_file) spec_file="$val" ;;
      plan_file) plan_file="$val" ;;
    esac
  done < "$manifest_file"
  if [ -z "$source_branch" ] || [ -z "$spec_file" ] || [ -z "$plan_file" ]; then
    log "Manifest missing source_branch/spec_file/plan_file: $manifest_file"
    return 1
  fi
  local epic_marker="<!-- plan-to-tickets:epic:$plan_file -->"
  local epic_number
  epic_number="$(find_epic_issue_by_marker "$epic_marker")"
  if [ -z "$epic_number" ]; then
    log "No epic issue found with marker $epic_marker. Run plan-to-tickets first."
    return 1
  fi
  PLAN_SLUG="$slug"
  MANIFEST_FILE="$manifest_file"
  SOURCE_BRANCH="$source_branch"
  SPEC_FILE="$spec_file"
  PLAN_FILE="$plan_file"
  EPIC_MARKER="$epic_marker"
  TICKET_MARKER_PREFIX="<!-- plan-to-tickets:ticket:$PLAN_FILE:"
  EPIC_NUMBER="$epic_number"
  vlog "manifest: $MANIFEST_FILE"
  vlog "  source_branch: $SOURCE_BRANCH"
  vlog "  spec_file:     $SPEC_FILE"
  vlog "  plan_file:     $PLAN_FILE"
  vlog "  epic issue:    #$EPIC_NUMBER"
  return 0
}
```

In `main()`, replace:

```bash
main() {
  parse_args "$@"
  preflight
  load_manifest
```

with:

```bash
main() {
  parse_args "$@"
  preflight
  if [ "$REPO_WIDE" != true ]; then
    load_manifest "$PLAN_SLUG" || die 1 "Manifest not found or malformed for plan '$PLAN_SLUG', or no epic issue found for it (run plan-to-tickets first)"
  fi
```

- [ ] **Step 4: Run tests, verify pass**

```bash
bash skills/delivery-pipeline/epic-manager/tests/run.sh 2>&1 | tail -30
```

Expected: `0` failed, including every pre-existing test — in particular `test_no_epic_issue_errors` and `test_load_manifest` from the existing suite, which pin the exact fatal-path wording this refactor must preserve.

- [ ] **Step 5: Commit**

```bash
git add skills/delivery-pipeline/epic-manager/scripts/epic-manager.sh skills/delivery-pipeline/epic-manager/tests/run.sh
git commit -m "epic-manager: make --plan optional, parameterize load_manifest()"
```

---

### Task 6: `epic-manager.sh` — `discover_open_epics()` with staleness ranking

**Files:**
- Modify: `skills/delivery-pipeline/epic-manager/scripts/epic-manager.sh`
- Test: `skills/delivery-pipeline/epic-manager/tests/run.sh`

Adds the discovery + staleness-ranking function on its own, tested directly through a repo-wide `--dry-run` cycle (not wired into the full `run_one_cycle()` state machine yet — that's Task 7). To make this independently observable before Task 7 exists, this step temporarily calls `discover_open_epics()` from `main()` in repo-wide mode and logs the ranked result, then Task 7 replaces that temporary call site with the real per-cycle integration.

- [ ] **Step 1: Write the failing tests**

Append to `skills/delivery-pipeline/epic-manager/tests/run.sh`:

```bash
# ---- Repo-wide discovery: Task 6 — discover_open_epics() staleness ranking ----

test_discover_never_visited_epic_sorts_first() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan-a
  local bin; bin="$(bindir_for "$d")"
  local epic_a epic_b
  epic_a="$(issue_json 100 'Epic A' '<!-- plan-to-tickets:epic:docs/superpowers/plans/plan-a.md -->' '[]')"
  epic_b="$(issue_json 200 'Epic B' '<!-- plan-to-tickets:epic:docs/superpowers/plans/plan-b.md -->' '[]')"
  seed_state "$d/state" "[$epic_a,$epic_b]"
  # Epic A has a prior visit marker; Epic B has never been visited.
  jq '.issues["100"].comments = [{databaseId:1, body:"progress\n<!-- manager:lock-acquired:2026-01-01T00:00:00Z -->", createdAt:"2026-01-01T00:00:00Z"}]' \
    "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
  run_em "$d/work" "$bin" FAKE_GH_STATE="$d/state" -- --dry-run --once
  assert_contains "$ERR" "discovered epics (stalest first): #200 #100" "never-visited epic B sorts before visited epic A"
  rm -rf "$d"
}
test_discover_never_visited_epic_sorts_first

test_discover_older_visit_sorts_first_among_visited() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan-a
  local bin; bin="$(bindir_for "$d")"
  local epic_a epic_b
  epic_a="$(issue_json 100 'Epic A' '<!-- plan-to-tickets:epic:docs/superpowers/plans/plan-a.md -->' '[]')"
  epic_b="$(issue_json 200 'Epic B' '<!-- plan-to-tickets:epic:docs/superpowers/plans/plan-b.md -->' '[]')"
  seed_state "$d/state" "[$epic_a,$epic_b]"
  jq '.issues["100"].comments = [{databaseId:1, body:"<!-- manager:lock-acquired:2026-01-05T00:00:00Z -->", createdAt:"2026-01-05T00:00:00Z"}]
      | .issues["200"].comments = [{databaseId:2, body:"<!-- manager:lock-acquired:2026-01-01T00:00:00Z -->", createdAt:"2026-01-01T00:00:00Z"}]' \
    "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
  run_em "$d/work" "$bin" FAKE_GH_STATE="$d/state" -- --dry-run --once
  assert_contains "$ERR" "discovered epics (stalest first): #200 #100" "epic B (older visit, Jan 1) sorts before epic A (newer visit, Jan 5)"
  rm -rf "$d"
}
test_discover_older_visit_sorts_first_among_visited

test_discover_ignores_non_epic_issues() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan-a
  local bin; bin="$(bindir_for "$d")"
  local epic_a not_an_epic
  epic_a="$(issue_json 100 'Epic A' '<!-- plan-to-tickets:epic:docs/superpowers/plans/plan-a.md -->' '[]')"
  not_an_epic="$(issue_json 101 'A ticket' '<!-- plan-to-tickets:ticket:docs/superpowers/plans/plan-a.md:001-a -->' '[]')"
  seed_state "$d/state" "[$epic_a,$not_an_epic]"
  run_em "$d/work" "$bin" FAKE_GH_STATE="$d/state" -- --dry-run --once
  assert_contains "$ERR" "discovered epics (stalest first): #100" "only the epic-marker issue is discovered"
  assert_not_contains "$ERR" "#101" "the ticket issue is not mistaken for an epic"
  rm -rf "$d"
}
test_discover_ignores_non_epic_issues
```

- [ ] **Step 2: Run to verify failure**

```bash
bash skills/delivery-pipeline/epic-manager/tests/run.sh 2>&1 | tail -30
```

Expected: all three FAIL (`discover_open_epics()` doesn't exist yet, and nothing logs "discovered epics").

- [ ] **Step 3: Implement**

Add a new function after `find_epic_issue_by_marker()`:

```bash
# discover_open_epics -> JSON array of {number, slug, last_visited}, sorted
# stalest-first. "Last visited" reuses the existing lock-acquired comment
# marker (see acquire_lock/detect_stale_lock) rather than inventing a new
# marker format -- it's already posted on every successful cycle via
# post_progress_comment, so staleness ranking needs no new local or GitHub
# state, just a different read of what's already there. Never-visited epics
# have last_visited="", which sorts before any ISO-8601 timestamp string.
discover_open_epics() {
  local raw epics_with_pf total
  raw="$(gh issue list --repo "$REPO" --state open --limit 500 \
          --json number,body 2>/dev/null || echo '[]')"
  epics_with_pf="$(jq -c '
    map(select(.body // "" | contains("<!-- plan-to-tickets:epic:")))
    | map({
        number,
        plan_file: (.body | capture("<!-- plan-to-tickets:epic:(?<pf>[^\\n]+) -->"; "g").pf // empty)
      })
    | map(select(.plan_file != null and .plan_file != ""))
  ' <<<"$raw")"
  total="$(jq 'length' <<<"$epics_with_pf")"
  if [ "$total" -eq 0 ]; then
    echo '[]'
    return 0
  fi
  local result="[]" i=0
  while [ "$i" -lt "$total" ]; do
    local n plan_file slug comments last_visited
    n="$(jq -r ".[$i].number" <<<"$epics_with_pf")"
    plan_file="$(jq -r ".[$i].plan_file" <<<"$epics_with_pf")"
    slug="$(basename "$plan_file" .md | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//')"
    comments="$(gh issue view "$n" --repo "$REPO" --json comments -q '.comments' 2>/dev/null || echo '[]')"
    last_visited="$(jq -r '
      [.[] | select(.body // "" | test("<!-- manager:lock-acquired:")) | (.body | capture("<!-- manager:lock-acquired:(?<ts>[^>]+) -->").ts)]
      | last // ""
    ' <<<"$comments" 2>/dev/null || echo "")"
    result="$(jq --argjson n "$n" --arg slug "$slug" --arg lv "$last_visited" \
      '. + [{number: $n, slug: $slug, last_visited: $lv}]' <<<"$result")"
    i=$((i + 1))
  done
  jq 'sort_by(.last_visited)' <<<"$result"
}
```

In `main()`, add a temporary discovery-logging call (Task 7 will replace this with the real per-cycle integration) right after the `if [ "$REPO_WIDE" != true ]; then load_manifest ...; fi` block:

```bash
  if [ "$REPO_WIDE" = true ]; then
    local discovered
    discovered="$(discover_open_epics)"
    log "discovered epics (stalest first): $(jq -r '[.[] | "#\(.number)"] | join(" ")' <<<"$discovered")"
  fi
```

- [ ] **Step 4: Run tests, verify pass**

```bash
bash skills/delivery-pipeline/epic-manager/tests/run.sh 2>&1 | tail -30
```

Expected: `0` failed. Note the log line prints an empty list (`discovered epics (stalest first): `) when nothing is found — none of this task's tests exercise that case, but it's consistent with the `[]` return.

- [ ] **Step 5: Commit**

```bash
git add skills/delivery-pipeline/epic-manager/scripts/epic-manager.sh skills/delivery-pipeline/epic-manager/tests/run.sh
git commit -m "epic-manager: add discover_open_epics() staleness ranking"
```

---

### Task 7: `epic-manager.sh` — per-cycle epic resolution in `run_one_cycle()`

**Files:**
- Modify: `skills/delivery-pipeline/epic-manager/scripts/epic-manager.sh`
- Modify: `skills/delivery-pipeline/epic-manager/tests/lib.sh`
- Test: `skills/delivery-pipeline/epic-manager/tests/run.sh`

Wires `discover_open_epics()` into the real per-cycle flow (round-robin: process exactly one epic per cycle), replacing Task 6's temporary logging-only call site in `main()`. Skips (doesn't die on) a discovered epic whose manifest fails to resolve, trying the next-stalest instead.

- [ ] **Step 1: Add a second-manifest test helper to `tests/lib.sh`**

Mirrors `add_second_manifest` from `execute-tickets/tests/lib.sh` — epic-manager's fixtures are a separate, independent copy (per this repo's convention of no shared runtime state between skills), so this is a local addition, not a cross-skill import. Append to `skills/delivery-pipeline/epic-manager/tests/lib.sh`, right after `make_repo`:

```bash
# add_second_manifest_em <workdir> <slug> <plan_file> [source_branch]
# Writes a second manifest (a different plan than make_repo's default) directly
# into an already-initialized work tree, mirroring what plan-to-tickets' own
# create-tickets.sh would have produced for a second, independently-filed plan.
add_second_manifest_em() {
  local workdir="$1" slug="$2" plan_file="$3" source_branch="${4:-epic}"
  mkdir -p "$workdir/docs/superpowers/tickets"
  cat > "$workdir/docs/superpowers/tickets/$slug.md" <<EOF
---
source_branch: "$source_branch"
spec_file: "docs/superpowers/specs/test-spec-2.md"
plan_file: "$plan_file"
---

# Tickets filed for $plan_file
EOF
  git -C "$workdir" add "docs/superpowers/tickets/$slug.md"
  git -C "$workdir" commit -q -m "file tickets for $slug"
  git -C "$workdir" push -q origin epic
}
```

- [ ] **Step 2: Write the failing tests**

Append to `skills/delivery-pipeline/epic-manager/tests/run.sh`:

```bash
# ---- Repo-wide discovery: Task 7 — per-cycle epic resolution ----

test_repo_wide_processes_stalest_epic() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan-a docs/superpowers/plans/plan-a.md
  add_second_manifest_em "$d/work" plan-b docs/superpowers/plans/plan-b.md
  local bin; bin="$(bindir_for "$d")"
  local epic_a epic_b
  epic_a="$(issue_json 100 'Epic A' '<!-- plan-to-tickets:epic:docs/superpowers/plans/plan-a.md -->' '[]')"
  epic_b="$(issue_json 200 'Epic B' '<!-- plan-to-tickets:epic:docs/superpowers/plans/plan-b.md -->' '[]')"
  seed_state "$d/state" "[$epic_a,$epic_b]"
  # Epic A already visited; Epic B never visited -> B is stalest, must be chosen.
  jq '.issues["100"].comments = [{databaseId:1, body:"<!-- manager:lock-acquired:2026-01-01T00:00:00Z -->", createdAt:"2026-01-01T00:00:00Z"}]' \
    "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
  run_em "$d/work" "$bin" FAKE_GH_STATE="$d/state" -- --dry-run --once
  assert_eq "$RC" "0" "repo-wide dry-run exits 0"
  assert_contains "$ERR" "epic issue:    #200" "resolved the stalest epic (B, #200), not epic A"
  rm -rf "$d"
}
test_repo_wide_processes_stalest_epic

test_repo_wide_skips_epic_with_missing_manifest() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan-a docs/superpowers/plans/plan-a.md
  # No manifest committed for plan-missing -- epic 200's marker references a
  # plan that was never filed with a manifest.
  local bin; bin="$(bindir_for "$d")"
  local epic_missing epic_a
  epic_missing="$(issue_json 200 'Broken epic' '<!-- plan-to-tickets:epic:docs/superpowers/plans/plan-missing.md -->' '[]')"
  epic_a="$(issue_json 100 'Epic A' '<!-- plan-to-tickets:epic:docs/superpowers/plans/plan-a.md -->' '[]')"
  seed_state "$d/state" "[$epic_missing,$epic_a]"
  # Both never-visited; #200 sorts first only by number-stability of jq's sort,
  # which is not guaranteed -- assert on behavior (skip + fallthrough), not order.
  run_em "$d/work" "$bin" FAKE_GH_STATE="$d/state" -- --dry-run --once
  assert_eq "$RC" "0" "repo-wide dry-run exits 0 despite one broken epic"
  assert_contains "$ERR" "epic issue:    #100" "fell through to the resolvable epic"
  rm -rf "$d"
}
test_repo_wide_skips_epic_with_missing_manifest

test_repo_wide_all_epics_broken() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan-a docs/superpowers/plans/plan-a.md
  local bin; bin="$(bindir_for "$d")"
  local epic_missing
  epic_missing="$(issue_json 200 'Broken epic' '<!-- plan-to-tickets:epic:docs/superpowers/plans/plan-missing.md -->' '[]')"
  seed_state "$d/state" "[$epic_missing]"
  run_em "$d/work" "$bin" FAKE_GH_STATE="$d/state" -- --once
  assert_contains "$ERR" "No discovered epics resolved to a valid manifest" "clear message when every discovered epic is broken"
  rm -rf "$d"
}
test_repo_wide_all_epics_broken

test_repo_wide_no_open_epics() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan-a docs/superpowers/plans/plan-a.md
  local bin; bin="$(bindir_for "$d")"
  seed_state "$d/state" "[]"
  run_em "$d/work" "$bin" FAKE_GH_STATE="$d/state" -- --once
  assert_contains "$ERR" "No open epics found" "clear message when nothing is discovered"
  rm -rf "$d"
}
test_repo_wide_no_open_epics
```

- [ ] **Step 3: Run to verify failure**

```bash
bash skills/delivery-pipeline/epic-manager/tests/run.sh 2>&1 | tail -40
```

Expected: all four FAIL — `run_one_cycle()` doesn't yet consume `discover_open_epics()`'s ranked list for real processing (Task 6 only logs it).

- [ ] **Step 4: Implement**

In `main()`, replace the temporary Task-6 logging block:

```bash
  if [ "$REPO_WIDE" = true ]; then
    local discovered
    discovered="$(discover_open_epics)"
    log "discovered epics (stalest first): $(jq -r '[.[] | "#\(.number)"] | join(" ")' <<<"$discovered")"
  fi
```

with nothing (delete it — this logic moves into `run_one_cycle()` below, since it must run fresh every cycle in loop mode, not once at startup).

At the very top of `run_one_cycle()`, before its existing first line (`local labels held`), insert:

```bash
  if [ "$REPO_WIDE" = true ]; then
    local candidates total
    candidates="$(discover_open_epics)"
    total="$(jq 'length' <<<"$candidates")"
    if [ "$total" -eq 0 ]; then
      log "No open epics found."
      return 1
    fi
    local i=0 resolved=false
    while [ "$i" -lt "$total" ]; do
      local slug
      slug="$(jq -r ".[$i].slug" <<<"$candidates")"
      if load_manifest "$slug"; then
        resolved=true
        break
      fi
      log "Skipping discovered epic (slug: $slug): manifest/epic lookup failed."
      i=$((i + 1))
    done
    if [ "$resolved" != true ]; then
      log "No discovered epics resolved to a valid manifest."
      return 1
    fi
  fi
```

- [ ] **Step 5: Run tests, verify pass**

```bash
bash skills/delivery-pipeline/epic-manager/tests/run.sh 2>&1 | tail -40
```

Expected: `0` failed, including every pre-existing single-plan test (which never sets `REPO_WIDE`, so this whole block is skipped and `run_one_cycle()` behaves exactly as before).

- [ ] **Step 6: Commit**

```bash
git add skills/delivery-pipeline/epic-manager/scripts/epic-manager.sh skills/delivery-pipeline/epic-manager/tests/lib.sh skills/delivery-pipeline/epic-manager/tests/run.sh
git commit -m "epic-manager: process one discovered epic per cycle, skip broken ones"
```

---

### Task 8: `epic-manager.sh` — docs and version bump

**Files:**
- Modify: `skills/delivery-pipeline/epic-manager/SKILL.md`

- [ ] **Step 1: Bump the version**

In `skills/delivery-pipeline/epic-manager/SKILL.md`, find:

```yaml
metadata:
  author: stephen-martin
  version: "0.2.0"
```

Change to:

```yaml
metadata:
  author: stephen-martin
  version: "0.3.0"
```

- [ ] **Step 2: Document repo-wide mode**

Find the `--plan <slug>` row in the `## Flags` table:

```markdown
| `--plan <slug>` | Plan slug (required). Same as `execute-tickets`. |
```

Change to:

```markdown
| `--plan <slug>` | Plan slug. Same as `execute-tickets`. Optional — omit for repo-wide mode (see below). |
```

Find `## When this applies` and add a paragraph after its existing content:

```markdown
**Repo-wide mode.** Omit `--plan` entirely to have the manager discover every
open epic and process one per cycle, stalest-first (ranked by each epic's own
comment history — no new state, nothing to configure). A discovered epic whose
manifest can't be resolved is skipped with a logged warning; the manager tries
the next-stalest epic instead of dying. This is the mode a long-running manager
process should use (e.g. deployed continuously via systemd, one instance for
the whole repo) so new epics get supervised as soon as `plan-to-tickets` files
them — no per-plan process to start. Use `--plan` to dedicate an invocation to
one specific epic instead.
```

- [ ] **Step 3: Commit**

```bash
git add skills/delivery-pipeline/epic-manager/SKILL.md
git commit -m "epic-manager: document repo-wide mode, bump to 0.3.0"
```

---

### Task 9: Final verification

**Files:** none (verification only)

- [ ] **Step 1: Full regression run, both skills**

```bash
bash skills/delivery-pipeline/execute-tickets/tests/run.sh 2>&1 | tail -5
bash skills/delivery-pipeline/epic-manager/tests/run.sh 2>&1 | tail -5
```

Expected: both end in `... passed, 0 failed`.

- [ ] **Step 2: Syntax-check both scripts**

```bash
bash -n skills/delivery-pipeline/execute-tickets/scripts/execute-tickets.sh
bash -n skills/delivery-pipeline/epic-manager/scripts/epic-manager.sh
echo "exit: $?"
```

Expected: no output from the `bash -n` calls, `exit: 0`.

- [ ] **Step 3: Confirm the third pipeline skill's suite is untouched and still passes**

```bash
bash skills/delivery-pipeline/plan-to-tickets/tests/run.sh 2>&1 | tail -5
```

Expected: unchanged pass count — this task never modified `plan-to-tickets`, this is a pure regression guard.

- [ ] **Step 4: Review the full diff and commit history**

```bash
git status --short
git log --oneline -10
```

Expected: clean working tree, 8 new commits on top of the spec commit (`24fd1b5`) — one skill's four commits (Tasks 1–4), then the other's four (Tasks 5–8).
