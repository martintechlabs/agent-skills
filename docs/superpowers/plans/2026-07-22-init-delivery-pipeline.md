# init-delivery-pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new `init-delivery-pipeline` skill to `skills/delivery-pipeline/` that interactively scaffolds a project-aware `.execute-tickets/agents.yml` + `.execute-tickets/checklist.yml` for a repo running `plan-to-tickets` + `execute-tickets` + `epic-manager`, and prints the exact ready-to-paste cron/Warp commands for both loops.

**Architecture:** The detection/drafting procedure (repo inspection, tailoring `agents.yml`/`checklist.yml`) lives entirely in `SKILL.md` prose — carried out by the invoking Claude session itself, no subprocess call. The only code artifact is `scripts/print-commands.sh`, a pure deterministic templating script (no `gh`/`codex` calls) that renders the two ready-to-paste loop commands from `--plan`/`--repo`/`--workers` — kept separate from the prose so the exact flag syntax can't drift or get hallucinated, and so there's something fixture-testable.

**Tech Stack:** Bash (matching every other skill in this repo), plain-bash test harness (`ok`/`bad`/`assert_eq`/`assert_contains`, mirroring `plan-to-tickets/tests/run.sh`).

---

### Task 1: Skill skeleton + SKILL.md

**Files:**
- Create: `skills/delivery-pipeline/init-delivery-pipeline/SKILL.md`

- [ ] **Step 1: Create the directory and write SKILL.md**

```bash
mkdir -p skills/delivery-pipeline/init-delivery-pipeline/scripts
mkdir -p skills/delivery-pipeline/init-delivery-pipeline/tests
```

Write `skills/delivery-pipeline/init-delivery-pipeline/SKILL.md`:

````markdown
---
name: init-delivery-pipeline
description: >-
  Interactively scaffold .execute-tickets/agents.yml and .execute-tickets/checklist.yml
  for a repo that has plan-to-tickets, execute-tickets, and epic-manager installed —
  detecting the repo's actual language, package manager, and test/lint/build commands
  so the drafted config is tailored to this project, not a generic template. Preflights
  gh/codex/claude auth, shows both drafts for confirmation before writing, and prints the
  exact ready-to-paste execute-tickets worker loop and epic-manager --once commands for
  a given plan and repo. Use when deploying the delivery pipeline to a new repo for the
  first time, or when asked to set up/scaffold the ticket-pipeline config. Not for
  tweaking a single existing tier's command — use execute-tickets' own init-agents.sh
  --force for that.
metadata:
  author: stephen-martin
  version: "0.1.0"
---

# Set up the delivery pipeline for a new repo

A one-time, interactive setup companion for `plan-to-tickets` + `execute-tickets` +
`epic-manager`. Detects this repo's language/tooling, drafts a tailored
`.execute-tickets/agents.yml` and `.execute-tickets/checklist.yml`, and — once you confirm
and it writes them — prints the exact commands to paste into cron or Warp to run the
`execute-tickets` worker pool and the `epic-manager` singleton loop.

This skill never runs headless or on cron. It never touches GitHub. It doesn't replace
`execute-tickets/scripts/init-agents.sh` — that stays for re-scaffolding just `agents.yml`
later.

## When this applies

Use when: a repo has (or is about to have) `plan-to-tickets`, `execute-tickets`, and
`epic-manager` installed and needs `.execute-tickets/agents.yml` +
`.execute-tickets/checklist.yml` set up for the first time; the user asks to "set up the
delivery pipeline," "deploy execute-tickets/epic-manager to this repo," or "scaffold the
ticket pipeline config."

Not for: a repo that already has both files and just wants one tier's command tweaked —
use `execute-tickets/scripts/init-agents.sh --force` instead. Not for repos that will run
only a subset of the three pipeline skills — this skill assumes all three.

## Dependencies

Reads (never writes) two files that must exist in sibling skill directories:

- `execute-tickets/references/agents.example.yml`
- `epic-manager/references/checklist-schema.json`

If either can't be found, stop immediately and name which skill is missing and the
install command to fix it (e.g. `npx skills add martintechlabs/agent-skills --skill
execute-tickets,epic-manager`). Never fall back to a hardcoded copy — that would drift
from the real templates.

## Procedure

### 1. Preflight tooling

- `gh auth status` — **hard stop** if not authenticated.
- `codex` on `PATH` and authenticated — warn, don't block.
- `claude` on `PATH` — warn, don't block.
- Whether `superpowers` is enabled for the current account (check `enabledPlugins` in
  `~/.claude/settings.json` if readable; skip silently if not) — informational only. This
  is an account-level setting, not a project one — workers may run under a different
  account than this session.

### 2. Detect project facts

Read, in order of precedence, whichever exist: `package.json`, `pyproject.toml`,
`Cargo.toml`, `go.mod`, `Makefile`, `.github/workflows/*.yml`. Determine:

- Language + package manager.
- Real test/lint/build commands — prefer what's already wired into CI
  (`.github/workflows/*.yml`) over guessing; fall back to package-manager convention
  (`npm test`, `pytest -q`, `cargo test`, `go test ./...`) if no CI config exists.
- Whether the project looks like a long-running server (a start/serve script, listens on
  a port) — relevant for a boot-and-respond checklist item.

Check whether `.execute-tickets/agents.yml` and/or `.execute-tickets/checklist.yml`
already exist. Never silently overwrite — see step 5.

### 3. Draft `agents.yml`

Start from `execute-tickets/references/agents.example.yml`'s four tiers
(lite/efficient/standard/flagship, `claude -p` with per-tier `--model`). Tailor
`--allowedTools` to what step 2 found — e.g. `Bash(git *) Bash(npm *)` for Node,
`Bash(git *) Bash(pytest *)` for Python. Keep the underlying CLI and prompt bodies as the
vendored default.

### 4. Draft `checklist.yml`

Propose `run:` items directly from the test/lint/build commands found in step 2. Where
the project looks like a server, propose a boot-and-respond check. Propose one or two
`judge:` items only where grounded in something specific about this repo (e.g. "no TODO
left in shipped code" scoped to the actual source directories found) — not a generic
unscoped template.

### 5. Show drafts, confirm, write

Present both drafted files in full. If either target file already exists, say so and ask
before overwriting. Only write after confirmation.

### 6. Print the ready-to-paste commands

Ask for (or infer via `gh repo view`) `--repo`, the plan slug (`--plan`), and how many
`execute-tickets` workers to include (1–10). Render via:

```bash
skills/delivery-pipeline/init-delivery-pipeline/scripts/print-commands.sh \
  --plan <plan-slug> --repo <owner/repo> --workers <N>
```

This prints the exact `execute-tickets` worker loop and the `epic-manager --once`
command — kept as a separate deterministic script rather than free-form output so the
flag syntax can't drift or get hallucinated. Point at
`execute-tickets/references/warp-setup.md` and `epic-manager/references/warp-setup.md`
for wiring either into Warp specifically.

## Flags (`scripts/print-commands.sh`)

| Flag | Effect |
|--|--|
| `--plan <slug>` | Plan slug (required). |
| `--repo <owner/repo>` | Target repo (required). |
| `--workers <N>` | Number of `execute-tickets` workers to include, 1–10 (default: 10). |
| `--help` | Show help. |

## What this skill deliberately does not do

- **Create GitHub labels.** Each of the three pipeline skills already self-heals its own
  required labels on first real run.
- **Run headless or on cron.** Always interactive, once, by a human in a live session.
- **Guarantee the drafted config is correct.** It's a grounded starting point, shown for
  confirmation before anything is written — not a substitute for review.
- **Change the flag surface or behavior of `plan-to-tickets`, `execute-tickets`, or
  `epic-manager`.** Purely additive.
````

- [ ] **Step 2: Commit**

```bash
git add skills/delivery-pipeline/init-delivery-pipeline/SKILL.md
git commit -m "init-delivery-pipeline: add skill skeleton and SKILL.md"
```

---

### Task 2: Write the failing test suite for `print-commands.sh`

**Files:**
- Create: `skills/delivery-pipeline/init-delivery-pipeline/tests/run.sh`

- [ ] **Step 1: Write the full test file**

Write `skills/delivery-pipeline/init-delivery-pipeline/tests/run.sh`:

```bash
#!/usr/bin/env bash
# Plain-bash test runner for print-commands.sh. No network, no gh/codex faking needed —
# the script is pure string templating.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/print-commands.sh"
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

assert_eq()            { [ "$1" = "$2" ] && ok "$3" || bad "$3" "expected [$2] got [$1]"; }
assert_contains()      { case "$1" in *"$2"*) ok "$3";; *) bad "$3" "[$1] did not contain [$2]";; esac; }
assert_not_contains()  { case "$1" in *"$2"*) bad "$3" "[$1] contained [$2]";; *) ok "$3";; esac; }

# run_pc <args...> -- captures stdout->$OUT, stderr->$ERR, exit->$RC
run_pc() {
  local outf errf
  outf="$(mktemp)"; errf="$(mktemp)"
  bash "$SCRIPT" "$@" >"$outf" 2>"$errf"
  RC=$?
  OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

test_help() {
  run_pc --help
  assert_eq "$RC" "0" "help exits 0"
  assert_contains "$OUT" "print-commands.sh" "help mentions the script"
  assert_contains "$OUT" "--workers" "help lists the --workers flag"
}

test_help

test_missing_plan() {
  run_pc --repo acme/widgets
  assert_eq "$RC" "2" "missing --plan exits 2"
  assert_contains "$ERR" "--plan" "error mentions --plan"
}

test_missing_plan

test_missing_repo() {
  run_pc --plan demo
  assert_eq "$RC" "2" "missing --repo exits 2"
  assert_contains "$ERR" "--repo" "error mentions --repo"
}

test_missing_repo

test_workers_above_ten_rejected() {
  run_pc --plan demo --repo acme/widgets --workers 11
  assert_eq "$RC" "2" "--workers 11 exits 2"
  assert_contains "$ERR" "--workers" "error mentions --workers"
}

test_workers_above_ten_rejected

test_workers_zero_rejected() {
  run_pc --plan demo --repo acme/widgets --workers 0
  assert_eq "$RC" "2" "--workers 0 exits 2"
}

test_workers_zero_rejected

test_workers_non_numeric_rejected() {
  run_pc --plan demo --repo acme/widgets --workers abc
  assert_eq "$RC" "2" "--workers abc exits 2"
}

test_workers_non_numeric_rejected

test_default_workers_is_ten() {
  run_pc --plan demo --repo acme/widgets
  assert_eq "$RC" "0" "default run exits 0"
  assert_contains "$OUT" "for W in alice bob carol dave eve frank gordon hank isaac justin; do" "default includes all ten worker names"
}

test_default_workers_is_ten

test_workers_one_still_uses_loop_form() {
  run_pc --plan demo --repo acme/widgets --workers 1
  assert_eq "$RC" "0" "--workers 1 exits 0"
  assert_contains "$OUT" "for W in alice; do" "single worker still uses the for-loop form"
  assert_not_contains "$OUT" "bob" "only the first worker name is included"
}

test_workers_one_still_uses_loop_form

test_epic_manager_line_always_present() {
  run_pc --plan demo --repo acme/widgets --workers 3
  assert_contains "$OUT" "epic-manager.sh \\" "epic-manager command is printed"
  assert_contains "$OUT" "--plan demo --repo acme/widgets --once" "epic-manager command has plan/repo/--once"
}

test_epic_manager_line_always_present

test_exact_output_for_two_workers() {
  run_pc --plan demo --repo acme/widgets --workers 2
  assert_eq "$RC" "0" "two-worker run exits 0"
  local expected
  expected="$(cat <<'EOF'
# execute-tickets: launch 2 worker(s)
for W in alice bob; do
  skills/delivery-pipeline/execute-tickets/scripts/execute-tickets.sh \
    --worker "$W" --plan demo --repo acme/widgets \
    > "logs/executor-${W}.log" 2>&1 &
done
wait

# epic-manager: singleton, run --once per cron firing
skills/delivery-pipeline/epic-manager/scripts/epic-manager.sh \
  --plan demo --repo acme/widgets --once

# Wiring either into Warp specifically, see:
#   execute-tickets/references/warp-setup.md
#   epic-manager/references/warp-setup.md
EOF
)"
  assert_eq "$OUT" "$expected" "full output matches byte-for-byte for a 2-worker case"
}

test_exact_output_for_two_workers

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Make it executable and run it to verify it fails**

```bash
chmod +x skills/delivery-pipeline/init-delivery-pipeline/tests/run.sh
bash skills/delivery-pipeline/init-delivery-pipeline/tests/run.sh
```

Expected: every assertion fails — `bash "$SCRIPT" ...` errors with something like `bash:
.../scripts/print-commands.sh: No such file or directory` (`$RC=127`, `$OUT` empty), so
every `assert_eq`/`assert_contains` in every one of the 10 test functions fails. There
are 20 individual assertions across the 10 functions (test_help has 3, test_missing_plan
has 2, test_missing_repo has 2, test_workers_above_ten_rejected has 2,
test_workers_zero_rejected has 1, test_workers_non_numeric_rejected has 1,
test_default_workers_is_ten has 2, test_workers_one_still_uses_loop_form has 3,
test_epic_manager_line_always_present has 2, test_exact_output_for_two_workers has 2) —
ending in `0 passed, 20 failed` and a non-zero exit.

- [ ] **Step 3: Commit**

```bash
git add skills/delivery-pipeline/init-delivery-pipeline/tests/run.sh
git commit -m "init-delivery-pipeline: add failing test suite for print-commands.sh"
```

---

### Task 3: Implement `print-commands.sh`

**Files:**
- Create: `skills/delivery-pipeline/init-delivery-pipeline/scripts/print-commands.sh`

- [ ] **Step 1: Write the script**

Write `skills/delivery-pipeline/init-delivery-pipeline/scripts/print-commands.sh`:

```bash
#!/usr/bin/env bash
# print-commands.sh — render the ready-to-paste execute-tickets worker loop and the
# epic-manager singleton command for a given plan/repo/worker-count. Pure templating:
# no gh/codex calls, no file writes, no network.
set -euo pipefail

WORKER_NAMES=(alice bob carol dave eve frank gordon hank isaac justin)
PLAN=""
REPO=""
WORKERS=10

usage() {
  cat <<'EOF'
print-commands.sh — print the execute-tickets worker loop and the epic-manager
singleton command, ready to paste into cron or Warp.

Usage:
  print-commands.sh --plan <slug> --repo <owner/repo> [--workers <N>]

Flags:
  --plan <slug>        Plan slug (required).
  --repo <owner/repo>  Target repo (required).
  --workers <N>        Number of execute-tickets workers, 1-10 (default: 10).
  --help                Show this help.
EOF
}

die() { local code="$1"; shift; echo "$*" >&2; exit "$code"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --plan) [ $# -ge 2 ] || die 2 "Missing value for --plan"; PLAN="$2"; shift 2 ;;
    --repo) [ $# -ge 2 ] || die 2 "Missing value for --repo"; REPO="$2"; shift 2 ;;
    --workers) [ $# -ge 2 ] || die 2 "Missing value for --workers"; WORKERS="$2"; shift 2 ;;
    --help) usage; exit 0 ;;
    *) die 2 "Unknown flag: $1" ;;
  esac
done

[ -n "$PLAN" ] || die 2 "Missing --plan <slug>"
[ -n "$REPO" ] || die 2 "Missing --repo <owner/repo>"

case "$WORKERS" in
  ''|*[!0-9]*) die 2 "--workers must be a number between 1 and 10 (got: $WORKERS)" ;;
esac
[ "$WORKERS" -ge 1 ] && [ "$WORKERS" -le 10 ] || die 2 "--workers must be between 1 and 10 (got: $WORKERS)"

SELECTED=("${WORKER_NAMES[@]:0:$WORKERS}")

echo "# execute-tickets: launch $WORKERS worker(s)"
echo "for W in ${SELECTED[*]}; do"
echo "  skills/delivery-pipeline/execute-tickets/scripts/execute-tickets.sh \\"
echo "    --worker \"\$W\" --plan $PLAN --repo $REPO \\"
echo "    > \"logs/executor-\${W}.log\" 2>&1 &"
echo "done"
echo "wait"
echo
echo "# epic-manager: singleton, run --once per cron firing"
echo "skills/delivery-pipeline/epic-manager/scripts/epic-manager.sh \\"
echo "  --plan $PLAN --repo $REPO --once"
echo
echo "# Wiring either into Warp specifically, see:"
echo "#   execute-tickets/references/warp-setup.md"
echo "#   epic-manager/references/warp-setup.md"
```

- [ ] **Step 2: Make it executable and syntax-check it**

```bash
chmod +x skills/delivery-pipeline/init-delivery-pipeline/scripts/print-commands.sh
bash -n skills/delivery-pipeline/init-delivery-pipeline/scripts/print-commands.sh
```

Expected: no output, exit 0.

- [ ] **Step 3: Run the test suite and verify it passes**

```bash
bash skills/delivery-pipeline/init-delivery-pipeline/tests/run.sh
```

Expected: every line reads `  ok   ...`, ending in `20 passed, 0 failed` and exit 0.

- [ ] **Step 4: Commit**

```bash
git add skills/delivery-pipeline/init-delivery-pipeline/scripts/print-commands.sh
git commit -m "init-delivery-pipeline: implement print-commands.sh"
```

---

### Task 4: Register the new skill in README.md and skills.sh.json

**Files:**
- Modify: `README.md`
- Modify: `skills.sh.json`

- [ ] **Step 1: Add the row to README.md's Delivery pipeline table**

In `README.md`, find the `### Delivery pipeline` table (currently ending with the
`epic-manager` row) and add a new row immediately after it:

```markdown
| [`init-delivery-pipeline`](skills/delivery-pipeline/init-delivery-pipeline/SKILL.md) | Interactively scaffolds a project-aware `.execute-tickets/agents.yml` + `checklist.yml` for a repo running the other three skills, then prints the exact ready-to-paste `execute-tickets`/`epic-manager` cron commands. One-time setup companion — never runs headless, never touches GitHub. |
```

- [ ] **Step 2: Add the skill to skills.sh.json's Delivery pipeline grouping**

In `skills.sh.json`, find the `"Delivery pipeline"` grouping's `"skills"` array
(currently `["plan-to-tickets", "execute-tickets", "epic-manager"]`) and add the new
skill:

```json
      "skills": [
        "plan-to-tickets",
        "execute-tickets",
        "epic-manager",
        "init-delivery-pipeline"
      ]
```

- [ ] **Step 3: Validate the JSON and commit**

```bash
python3 -m json.tool skills.sh.json > /dev/null && echo "valid JSON"
git add README.md skills.sh.json
git commit -m "init-delivery-pipeline: register in README and skills.sh.json"
```

Expected: `valid JSON` printed, commit succeeds.

---

### Task 5: Final verification

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite one more time from a clean shell**

```bash
bash skills/delivery-pipeline/init-delivery-pipeline/tests/run.sh
echo "exit: $?"
```

Expected: `20 passed, 0 failed`, `exit: 0`.

- [ ] **Step 2: Confirm the other three skills' test suites are untouched and still pass**

```bash
for s in plan-to-tickets execute-tickets epic-manager; do
  echo "=== $s ==="
  bash skills/delivery-pipeline/$s/tests/run.sh 2>&1 | tail -3
done
```

Expected: no `FAIL` lines for any of the three (this task never modified their files, so
this is a regression guard, not expected to find anything).

- [ ] **Step 3: Confirm git status is clean and review the full diff**

```bash
git status --short
git log --oneline -6
```

Expected: clean working tree, 4 new commits on top of `a2c2bab` (the spec commit) —
skill skeleton, failing tests, implementation, README/skills.sh.json registration.
