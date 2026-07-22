# execute-tickets Named Worker Slots Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `execute-tickets.sh`'s numeric `--worker <1..4>` / `lock:N` scheme with a fixed list of 10 names (`alice bob carol dave eve frank gordon hank isaac justin`), raising the concurrent-worker cap from 4 to 10 in the process.

**Architecture:** `MAX_WORKERS=4` becomes a fixed bash array `WORKER_NAMES`. `--worker <name>` (case-insensitive, normalized to lowercase) replaces `--worker <N>`; the normalized name is used verbatim everywhere a worker identifier appears today (lock label, worktree path, log prefix, needs-human comment text). The claim/race-detection logic in `claim_ticket` is untouched — it already only checks "is there any `lock:*` label that isn't mine," independent of what the suffix looks like. This is a clean rename: the skill has no production usage and no numeric `--worker N` alias needs to survive.

**Tech Stack:** Bash, `jq`, `gh` CLI, the existing offline test harness (`tests/lib.sh`, `tests/fake-gh`, `tests/fake-codex`, `tests/run.sh`).

**Spec:** `docs/superpowers/specs/2026-07-22-execute-tickets-named-worker-slots-design.md`

---

### Task 1: Migrate the test suite and script to named worker slots (TDD)

**Files:**
- Modify: `skills/coding/execute-tickets/tests/run.sh`
- Modify: `skills/coding/execute-tickets/scripts/execute-tickets.sh`

This is one task, not two, because a test-only commit would leave the repo in a failing state — tests and the implementation that makes them pass land together, same as every other fix in this file's history.

- [ ] **Step 1: Rewrite existing `--worker 1` invocations as `--worker alice`**

Every existing test invokes the script with `--worker 1 --plan ...`. Replace all 12 occurrences of the substring `--worker 1 --plan` with `--worker alice --plan` (they all appear in exactly that form — verify with the grep below before editing).

Run first to confirm the exact set you're changing:
```bash
grep -n -- '--worker 1 --plan' skills/coding/execute-tickets/tests/run.sh
```
Expected: 12 matches, at (approximately) lines 39, 59, 83, 114, 127, 154, 181, 204, 227, 252, 279, 319.

Then replace every occurrence (a single find-and-replace across the file — do not do this line-by-line, the string is identical at every call site):
```
old: --worker 1 --plan
new: --worker alice --plan
```

- [ ] **Step 2: Rewrite the lock-label assertions from numbers to names**

Two label assertions currently check for the numeric lock label of the primary worker:

```
skills/coding/execute-tickets/tests/run.sh:86:  jqok "$(cat "$state")" '(.issues["101"].labels | index("lock:1")) == null' "lock label released on merge"
skills/coding/execute-tickets/tests/run.sh:255:  jqok "$(cat "$state")" '(.issues["101"].labels | index("lock:1")) == null' "releases its own lock label after detecting a rival lock"
```

Replace every occurrence of the substring `lock:1` with `lock:alice` (2 occurrences — the pattern is `index("lock:1")` in both cases).

- [ ] **Step 3: Rewrite the rival-lock injection in the lock-race test from `lock:2` to `lock:bob`**

In `test_claim_ticket_releases_lock_on_rival_lock_race` (around line 251-256):

```
skills/coding/execute-tickets/tests/run.sh:251:  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" FAKE_GH_INJECT_RIVAL_LOCK="lock:2" \
skills/coding/execute-tickets/tests/run.sh:256:  jqok "$(cat "$state")" '(.issues["101"].labels | index("lock:2")) != null' "does not touch the rival lock label"
```

Replace every occurrence of the substring `lock:2` with `lock:bob` (2 occurrences).

- [ ] **Step 4: Fix the literal "(worker 1)" text in the push-failure test's log assertion**

`test_swallowed_push_failure_on_retry_is_flagged_needs_human` asserts on the literal text of the `needs-human` comment, which embeds `$WORKER` without the `--` prefix:

```
skills/coding/execute-tickets/tests/run.sh:157:  assert_contains "$(cat "$log")" "BODY_CONTENT(#101): Executor (worker 1) gave up: no new commits pushed on iteration 2" "needs-human reason names the real push failure, not a stale merge"
```

Change `"BODY_CONTENT(#101): Executor (worker 1) gave up: ..."` to `"BODY_CONTENT(#101): Executor (worker alice) gave up: ..."` (this one occurrence only — it's the sole remaining `worker 1` text after steps 1-3).

- [ ] **Step 5: Add an assertion that `ensure_lock_labels` creates all 10 labels, not 4**

`preflight()` calls `ensure_lock_labels()` unconditionally, and every test's `FAKE_GH_LABELS` is unset (no pre-existing labels), so every test already exercises "create every missing `lock:*` label" — this just adds the assertion that proves it covers all 10 names, not only the ones older tests happened to touch. Add one line to `test_green_path_merges_and_closes_issue` (it already sets `FAKE_GH_LOG`):

```
skills/coding/execute-tickets/tests/run.sh:82-88 (after Step 1's rename, this is the block that now reads):
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" FAKE_GH_LOG="$log" \
    -- --worker alice --plan plan1 --agent-cmd "$DEFAULT_AGENT_CMD" --once
  assert_eq "$RC" "0" "green path exits 0"
  jqok "$(cat "$state")" '.issues["101"].state == "closed"' "ticket issue is explicitly closed on merge"
  jqok "$(cat "$state")" '(.issues["101"].labels | index("lock:alice")) == null' "lock label released on merge"
  jqok "$(cat "$state")" '.prs["1"].merged == true' "PR is merged"
  assert_contains "$(cat "$log")" "issue close 101" "executor explicitly closes the ticket issue (Closes # keyword is a no-op against a non-default base branch)"
  rm -rf "$d"
}
```

Add this line immediately after the `assert_eq "$RC" "0" "green path exits 0"` line:

```bash
  assert_contains "$(cat "$log")" "label create lock:justin" "ensure_lock_labels creates all 10 named lock labels, not just 4"
```

- [ ] **Step 6: Add a test for an unrecognized worker name**

Append to the end of `skills/coding/execute-tickets/tests/run.sh`:

```bash

# --- An unrecognized --worker value is a hard error at argument-parsing
# time, before any GitHub mutation, listing the valid names -- not a silent
# fallback and not a generic "invalid argument" message.
test_invalid_worker_name_is_rejected() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json" log="$d/gh.log"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" FAKE_GH_LOG="$log" \
    -- --worker zack --plan plan1 --agent-cmd "$DEFAULT_AGENT_CMD" --once
  assert_eq "$RC" "2" "an unrecognized worker name exits 2"
  assert_contains "$ERR" "alice" "error lists a valid worker name"
  assert_contains "$ERR" "justin" "error lists the full set of valid worker names"
  assert_eq "$(cat "$log" 2>/dev/null)" "" "no gh calls happen before worker-name validation"
  rm -rf "$d"
}

test_invalid_worker_name_is_rejected

# --- --worker is case-insensitive: the name is normalized to lowercase
# wherever it's used (lock label, worktree path, log prefix), so "Carol" and
# "carol" produce the same lock label.
test_worker_name_is_case_insensitive() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" \
    -- --worker Carol --plan plan1 --agent-cmd "$DEFAULT_AGENT_CMD" --dry-run --once
  assert_eq "$RC" "0" "a mixed-case worker name is accepted"
  assert_contains "$ERR" "DRY RUN (worker carol):" "the worker name is normalized to lowercase everywhere it's used"
  rm -rf "$d"
}

test_worker_name_is_case_insensitive
```

- [ ] **Step 7: Run the suite and confirm it now fails (RED) against the unmodified script**

```bash
bash skills/coding/execute-tickets/tests/run.sh
```

Expected: every test that invokes `--worker alice`/`--worker Carol`/`--worker zack` now fails, because the current script still only accepts a numeric `--worker` (it'll reject `alice`/`Carol`/`zack` with "--worker must be a positive integer" instead of the behaviors under test). This is the RED you want — confirm the failures are all for that reason, not a typo in the edits above.

- [ ] **Step 8: Add the `WORKER_NAMES` array and remove `MAX_WORKERS`**

In `skills/coding/execute-tickets/scripts/execute-tickets.sh`, the constants block currently reads:

```bash
POLL_SECONDS=30
ONCE=false
DRY_RUN=false
VERBOSE=true
MAX_WORKERS=4
MAX_ITERATIONS=5
```

Change `MAX_WORKERS=4` to:

```bash
POLL_SECONDS=30
ONCE=false
DRY_RUN=false
VERBOSE=true
# Worker identity: a fixed, ordered list of names (not numbers) so lock
# labels read as text in a GitHub issue's label list instead of an
# easily-misread single digit next to priority:p3/complexity:small/etc.
# Order only matters for readability -- nothing depends on the list being
# sorted. Extend by editing this array; nothing else needs to change.
WORKER_NAMES=(alice bob carol dave eve frank gordon hank isaac justin)
MAX_ITERATIONS=5
```

- [ ] **Step 9: Add the `is_valid_worker_name` helper**

Immediately after the `req_val`/`die` helper definitions:

```bash
req_val() { [ $# -ge 2 ] || die 2 "Missing value for $1"; }
die() { local code="$1"; shift; echo "$*" >&2; exit "$code"; }
```

add:

```bash
is_valid_worker_name() {
  local w="$1" name
  for name in "${WORKER_NAMES[@]}"; do
    [ "$name" = "$w" ] && return 0
  done
  return 1
}
```

- [ ] **Step 10: Replace the numeric `--worker` validation in `parse_args`**

Current validation block:

```bash
  [ -n "$WORKER" ] || die 2 "Missing --worker <1..$MAX_WORKERS>"
  [[ "$WORKER" =~ ^[1-9][0-9]*$ ]] || die 2 "--worker must be a positive integer"
  [ "$WORKER" -le "$MAX_WORKERS" ] || die 2 "--worker must be <= $MAX_WORKERS"
  [ -n "$PLAN_SLUG" ] || die 2 "Missing --plan <slug>"
```

Replace the three `WORKER`-related lines with:

```bash
  [ -n "$WORKER" ] || die 2 "Missing --worker <name>. Valid names: ${WORKER_NAMES[*]}"
  WORKER="${WORKER,,}"
  is_valid_worker_name "$WORKER" || die 2 "--worker must be one of: ${WORKER_NAMES[*]} (got: $WORKER)"
  [ -n "$PLAN_SLUG" ] || die 2 "Missing --plan <slug>"
```

(`${WORKER,,}` is bash's built-in lowercase expansion, available since bash 4.0 — already relied on implicitly by this script's `#!/usr/bin/env bash` shebang and its use of `gh`/modern tooling.)

- [ ] **Step 11: Update `ensure_lock_labels` to loop over names instead of `1..MAX_WORKERS`**

Current:

```bash
ensure_lock_labels() {
  local existing name
  existing="$(gh label list --repo "$REPO" --json name -q '.[].name' 2>/dev/null || true)"
  local w
  for w in $(seq 1 "$MAX_WORKERS"); do
    name="lock:$w"
```

Change the loop line:

```
old: for w in $(seq 1 "$MAX_WORKERS"); do
new: for w in "${WORKER_NAMES[@]}"; do
```

- [ ] **Step 12: Update the header comment and `usage()` help text**

Top-of-file comment currently reads:

```bash
# execute-tickets.sh: pick ready plan-to-tickets issues, drive each through an
# agent -> codex review -> CI verification loop, then merge the PR back to the
# plan's epic branch. Designed to run as up to 4 parallel worker processes per
# repo; per-worker label locks (`lock:1..lock:4`) make ticket claim atomic.
```

Change to:

```bash
# execute-tickets.sh: pick ready plan-to-tickets issues, drive each through an
# agent -> codex review -> CI verification loop, then merge the PR back to the
# plan's epic branch. Designed to run as up to 10 parallel worker processes per
# repo; per-worker label locks (`lock:alice`..`lock:justin`) make ticket claim atomic.
```

In `usage()`, the synopsis and required-flag description currently read:

```
Usage:
  execute-tickets.sh --worker <1..4> --plan <plan-slug> --agent-cmd <cmd> [flags]

Required flags:
  --worker <N>          Worker slot ID (1..4). Distinct per concurrent process.
```

Change to:

```
Usage:
  execute-tickets.sh --worker <name> --plan <plan-slug> --agent-cmd <cmd> [flags]

Required flags:
  --worker <name>       Worker identity (case-insensitive), one of:
                          alice bob carol dave eve frank gordon hank isaac justin
                        Distinct per concurrent process.
```

- [ ] **Step 13: Syntax-check and run the full suite; confirm GREEN**

```bash
bash -n skills/coding/execute-tickets/scripts/execute-tickets.sh && echo "syntax OK"
bash skills/coding/execute-tickets/tests/run.sh
```

Expected: `syntax OK`, then every test passes, including the new label-count assertion from Step 5 and the two new test functions from Step 6.

- [ ] **Step 14: shellcheck**

```bash
shellcheck skills/coding/execute-tickets/scripts/execute-tickets.sh
```

Expected: no new warnings beyond the two pre-existing ones (`SC2016` on `REVIEWER_CMD_DEFAULT`, `SC2034` on `ticket_body` in `run_reviewer`) that predate this change.

- [ ] **Step 15: Commit**

```bash
git add skills/coding/execute-tickets/tests/run.sh skills/coding/execute-tickets/scripts/execute-tickets.sh
git commit -m "$(cat <<'EOF'
execute-tickets: replace numeric --worker N / lock:N with 10 named slots

Raises the worker cap from 4 to 10 and replaces the numeric scheme with a
fixed list of names (alice bob carol dave eve frank gordon hank isaac
justin) so lock labels read as text instead of a single digit easily
misread against other labels (priority:p3, complexity:small, etc.).
Case-insensitive input, normalized to lowercase. Clean rename -- no
production usage to stay backward compatible with, so no numeric
--worker N alias.

See docs/superpowers/specs/2026-07-22-execute-tickets-named-worker-slots-design.md.
EOF
)"
```

---

### Task 2: Update `SKILL.md`

**Files:**
- Modify: `skills/coding/execute-tickets/SKILL.md`

- [ ] **Step 1: Bump the description, hard-cap line, and version in the front matter**

```
skills/coding/execute-tickets/SKILL.md:6:  to the plan's epic branch. Runs as up to 4 concurrent worker processes per
skills/coding/execute-tickets/SKILL.md:15:  never merges the epic itself, and hard-caps at 4 workers per repo.
skills/coding/execute-tickets/SKILL.md:18:  version: "0.4.0"
```

Change:
```
old: to the plan's epic branch. Runs as up to 4 concurrent worker processes per
new: to the plan's epic branch. Runs as up to 10 concurrent worker processes per
```
```
old: never merges the epic itself, and hard-caps at 4 workers per repo.
new: never merges the epic itself, and hard-caps at 10 workers per repo.
```
```
old: version: "0.4.0"
new: version: "0.5.0"
```

- [ ] **Step 2: Update the intro paragraph's worker/lock-label description**

```
skills/coding/execute-tickets/SKILL.md:30-33:
Designed to run as up to **4 concurrent worker processes per repo**, each with
a distinct `--worker` slot ID (`1..4`) that becomes its lock label (`lock:N`).
The 4-slot cap is a hard limit — beyond that the label mutex stops being a
useful mental model.
```

Replace with:
```
Designed to run as up to **10 concurrent worker processes per repo**, each
with a distinct `--worker` name (`alice`, `bob`, `carol`, `dave`, `eve`,
`frank`, `gordon`, `hank`, `isaac`, `justin`) that becomes its lock label
(`lock:<name>`). The 10-slot cap is a hard limit — beyond that the label
mutex stops being a useful mental model.
```

- [ ] **Step 3: Update the "Claim" and "Worktree" steps in the per-ticket loop**

```
skills/coding/execute-tickets/SKILL.md:81: 1. **Claim** — add `lock:N` label, verify no other `lock:*` label is present.
skills/coding/execute-tickets/SKILL.md:85:    so 4 workers never collide on disk.
```

Change:
```
old: 1. **Claim** — add `lock:N` label, verify no other `lock:*` label is present.
new: 1. **Claim** — add `lock:<name>` label, verify no other `lock:*` label is present.
```
```
old:    so 4 workers never collide on disk.
new:    so all 10 workers never collide on disk.
```

- [ ] **Step 4: Update the dry-run example**

```
skills/coding/execute-tickets/SKILL.md:227-234:
### 3. Dry-run one worker first

\`\`\`bash
skills/coding/execute-tickets/scripts/execute-tickets.sh \
  --worker 1 --plan <plan-slug> \
  --agent-cmd '<your command>' \
  --dry-run --once
\`\`\`
```

Change:
```
old:   --worker 1 --plan <plan-slug> \
new:   --worker alice --plan <plan-slug> \
```

- [ ] **Step 5: Update the "Launch up to 4 workers" section (heading, loop, and prose)**

```
skills/coding/execute-tickets/SKILL.md:241-259:
### 4. Launch up to 4 workers

\`\`\`bash
for W in 1 2 3 4; do
  skills/coding/execute-tickets/scripts/execute-tickets.sh \
    --worker "$W" --plan <plan-slug> \
    --agent-cmd '<your command>' \
    > "logs/executor-w${W}.log" 2>&1 &
done
wait
\`\`\`

Each worker loops: pick highest-priority ready ticket → claim → run the per-ticket
loop above → release the lock (on merge) or set `needs-human` (on failure). If
no ticket is ready (all locked, all blocked by open dependencies, or backlog
empty), the worker sleeps `--poll` seconds (default 30) and tries again.
`--once` runs a single pick + full ticket loop and exits — useful for cron.
See `WARP.md` in this directory for running the 4-worker pattern as separate
Warp scheduled agents instead of a long-running daemon.
```

Replace the whole section with:

```
### 4. Launch up to 10 workers

\`\`\`bash
for W in alice bob carol dave eve frank gordon hank isaac justin; do
  skills/coding/execute-tickets/scripts/execute-tickets.sh \
    --worker "$W" --plan <plan-slug> \
    --agent-cmd '<your command>' \
    > "logs/executor-w${W}.log" 2>&1 &
done
wait
\`\`\`

Each worker loops: pick highest-priority ready ticket → claim → run the per-ticket
loop above → release the lock (on merge) or set `needs-human` (on failure). If
no ticket is ready (all locked, all blocked by open dependencies, or backlog
empty), the worker sleeps `--poll` seconds (default 30) and tries again.
`--once` runs a single pick + full ticket loop and exits — useful for cron.
See `WARP.md` in this directory for running the 10-worker pattern as separate
Warp scheduled agents instead of a long-running daemon.
```

(Only launch as many of the 10 names as you actually want running — the list is a cap, not a requirement to always use all 10.)

- [ ] **Step 6: Update the "do not run more than N workers" line**

```
skills/coding/execute-tickets/SKILL.md:268-269:
Do not run more than 4 workers against the same repo without extending the
lock label set. The script hard-caps `--worker` at 4 by design.
```

Replace with:
```
Do not run more than 10 workers against the same repo without extending the
`WORKER_NAMES` list in the script. The script hard-caps `--worker` at these
10 names by design.
```

- [ ] **Step 7: Update the flags table**

```
skills/coding/execute-tickets/SKILL.md:309:
| `--worker <N>` | Worker slot ID, 1..4 (required). Becomes lock label `lock:N`. |
```

Replace with:
```
| `--worker <name>` | Worker identity, case-insensitive (required). One of: alice, bob, carol, dave, eve, frank, gordon, hank, isaac, justin. Becomes lock label `lock:<name>`. |
```

- [ ] **Step 8: Update the "What this skill deliberately does not do" line**

```
skills/coding/execute-tickets/SKILL.md:332:
- **Scale past 4 workers per repo.** The 4-slot lock label set is the cap.
```

Replace with:
```
- **Scale past 10 workers per repo.** The 10-name lock label set is the cap.
```

- [ ] **Step 9: Grep-verify no stale references remain**

```bash
grep -n '\-\-worker <1\.\.4>\|--worker <N>\|lock:N\|lock:1\.\.lock:4\|for W in 1 2 3 4\|4 concurrent worker\|4 workers\|4-slot' skills/coding/execute-tickets/SKILL.md
```

Expected: no matches.

- [ ] **Step 10: Commit**

```bash
git add skills/coding/execute-tickets/SKILL.md
git commit -m "execute-tickets: document 10 named worker slots in SKILL.md"
```

---

### Task 3: Update `WARP.md`

**Files:**
- Modify: `skills/coding/execute-tickets/WARP.md`

- [ ] **Step 1: Update the daemon-mode callout**

```
skills/coding/execute-tickets/WARP.md:17:
That rules out the `while true` / 4-concurrent-worker daemon mode this skill's
```

Replace with:
```
That rules out the `while true` / 10-concurrent-worker daemon mode this skill's
```

- [ ] **Step 2: Update the example invocation's `--worker` placeholder**

```
skills/coding/execute-tickets/WARP.md:26-28:
\`\`\`bash
skills/coding/execute-tickets/scripts/execute-tickets.sh \
  --worker <N> --plan <plan-slug> --agent-cmd '<your command>' --once
\`\`\`
```

Change:
```
old:   --worker <N> --plan <plan-slug> --agent-cmd '<your command>' --once
new:   --worker <name> --plan <plan-slug> --agent-cmd '<your command>' --once
```

- [ ] **Step 3: Rewrite the "Emulating the N concurrent workers" section**

```
skills/coding/execute-tickets/WARP.md:35-42:
## Emulating the 4 concurrent workers

The lock-label claiming (`lock:1..lock:4`) was built for independent,
uncoordinated processes — that's exactly what separate scheduled agents are.
Create up to 4 scheduled agents (one per `--worker` slot, 1–4), each with its
own cron entry, each running the `--once` invocation above with its own
`--worker N`. Don't create a single schedule and try to fan it out to 4
concurrent runs some other way — the slot number is what makes claiming safe.
```

Replace with:

```
## Emulating the 10 concurrent workers

The lock-label claiming (`lock:alice`..`lock:justin`) was built for
independent, uncoordinated processes — that's exactly what separate
scheduled agents are. Create up to 10 scheduled agents (one per `--worker`
name), each with its own cron entry, each running the `--once` invocation
above with its own `--worker <name>`. Don't create a single schedule and
try to fan it out to several concurrent runs some other way — the name is
what makes claiming safe.
```

- [ ] **Step 4: Grep-verify no stale references remain**

```bash
grep -n '4 concurrent\|4 scheduled agents\|lock:1\.\.lock:4\|--worker <N>\|slot, 1' skills/coding/execute-tickets/WARP.md
```

Expected: no matches.

- [ ] **Step 5: Commit**

```bash
git add skills/coding/execute-tickets/WARP.md
git commit -m "execute-tickets: document 10 named worker slots in WARP.md"
```

---

### Task 4: Final verification

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite one more time**

```bash
bash skills/coding/execute-tickets/tests/run.sh
```

Expected: all tests pass (the pre-existing suite plus the two new ones from Task 1).

- [ ] **Step 2: Review the full diff across all three commits**

```bash
git log --oneline -4
git diff HEAD~3 -- skills/coding/execute-tickets docs/superpowers
```

Confirm: no leftover numeric worker references, no unrelated changes, `WORKER_NAMES` used consistently.

- [ ] **Step 3: Ask the user whether to push**

Do not push without being asked, per this repo's established pattern in this conversation (each prior fix was pushed only after an explicit "push to the PR" request).
