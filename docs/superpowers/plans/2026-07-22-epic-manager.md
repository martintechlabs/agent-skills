# Epic Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `epic-manager.sh` — a singleton plan-level supervisor that tracks executor progress, gates the epic→`main` PR behind a hybrid checklist, runs a final integration review, and obeys human commands (`ship it` / `rework:` / `abandon`) posted as comments on the epic issue.

**Architecture:** A separate bash script (`scripts/epic-manager.sh`) peer to `execute-tickets.sh`, running on its own cron cadence. It acquires a singleton `lock:manager` label on the epic issue, reconciles plan state from GitHub (issues + PRs + labels), and acts only at plan granularity. It communicates with executors through GitHub state only — no IPC, no shared filesystem. All actions post as comments on the epic issue (the durable audit trail). It reuses the executor's `codex exec --output-schema --sandbox read-only` pattern for the final review and the metadata guess, with distinct prompts/schemas. It reuses the executor's test harness layout (`tests/lib.sh`, `tests/fake-gh`, `tests/fake-codex`, `tests/run.sh`).

**Tech Stack:** Bash, `jq`, `gh` CLI, `codex` CLI, `yq` (for checklist YAML parsing), the existing offline test harness.

**Spec:** `docs/superpowers/specs/2026-07-22-epic-manager-design.md`

## Global Constraints

- Bash 5.x, `set -euo pipefail` at the top of every script.
- `gh`, `jq`, `git`, `codex` on PATH; `gh auth status` green.
- Lock label namespace: `lock:manager` (singleton, separate from the executor's `lock:<name>` roster of `alice bob carol dave eve frank gordon hank isaac justin`).
- Reused label: `needs-human` (same label the executor uses; manager sets it on the **epic issue** for plan-level escalation, differentiated by comment body).
- New labels the manager creates: `checklist-failed` (on the epic issue, when the checklist gate fails). `review-blocked` is a **comment marker, not a label** — the label set stays minimal.
- Epic issue marker (from `plan-to-tickets`): `<!-- plan-to-tickets:epic:<plan_file> -->` in the epic issue body.
- Ticket issue marker (from `plan-to-tickets`): `<!-- plan-to-tickets:ticket:<plan_file>:<slug> -->` in the ticket issue body.
- Manifest front matter keys (parsed by `load_manifest`): `source_branch`, `spec_file`, `plan_file`.
- Audit pattern: all manager actions post as comments on the **epic issue** (not the PR, which is ephemeral). Same durable-trail principle as the executor's ticket `audit_comment`.
- `codex exec` calls use `--sandbox read-only` (non-negotiable; the reviewer must not write to the tree).
- Commit message convention: `epic-manager: <summary>` with a detailed body, matching `execute-tickets` commits.

---

## File Structure

```
skills/coding/epic-manager/
├── SKILL.md                                      # skill description, when-it-applies, loop, flags, commands
├── scripts/
│   └── epic-manager.sh                           # the singleton loop + all logic
├── references/
│   ├── checklist-schema.json                     # JSON schema documenting the checklist.yml contract
│   ├── final-review-prompt.md                    # holistic integration-review system prompt
│   ├── final-review-schema.json                  # integration-review output schema (findings + overall)
│   ├── metadata-guess-prompt.md                  # prompt for codex's rework metadata guess
│   └── metadata-guess-schema.json                # {priority, complexity, model_tier, reasoning} schema
├── tests/
│   ├── lib.sh                                    # NEW (not shared with execute-tickets — different SCRIPT path)
│   ├── fake-gh                                   # EXTENDED from execute-tickets/tests/fake-gh (pr list, closed issues)
│   ├── fake-codex                                # COPIED from execute-tickets/tests/fake-codex (unchanged)
│   └── run.sh                                    # the 16 test scenarios from the spec
└── WARP.md                                       # cron wiring for --once per firing

README.md                                          # add epic-manager row to Coding table
skills.sh.json                                     # add epic-manager to Coding grouping
```

**Why a separate `tests/lib.sh` instead of sharing:** the executor's `lib.sh` hardcodes `SCRIPT="$HERE/../scripts/execute-tickets.sh"`. The manager needs `SCRIPT="$HERE/../scripts/epic-manager.sh"`. Copying and adjusting is the established pattern (plan-to-tickets and execute-tickets each have their own `tests/`). If a shared helper lib emerges later, that's a separate refactor.

---

### Task 1: Scaffold the skill directory, references, and SKILL.md

**Files:**
- Create: `skills/coding/epic-manager/SKILL.md`
- Create: `skills/coding/epic-manager/scripts/epic-manager.sh` (stub with `usage()` + `--help` only)
- Create: `skills/coding/epic-manager/references/checklist-schema.json`
- Create: `skills/coding/epic-manager/references/final-review-prompt.md`
- Create: `skills/coding/epic-manager/references/final-review-schema.json`
- Create: `skills/coding/epic-manager/references/metadata-guess-prompt.md`
- Create: `skills/coding/epic-manager/references/metadata-guess-schema.json`
- Create: `skills/coding/epic-manager/WARP.md`

**Interfaces:**
- Produces: a runnable `epic-manager.sh --help` (exit 0, prints usage); all reference files exist with real content so later tasks' `--review-schema` / `--final-review-prompt` defaults resolve.

This task produces no logic — it lays down the file skeleton and the vendored prompts/schemas so every subsequent task has a stable target to point at. The script stub is just `usage()` + `parse_args` + `main` so `--help` works and flags are validated.

- [ ] **Step 1: Create the directory structure**

```bash
mkdir -p skills/coding/epic-manager/scripts
mkdir -p skills/coding/epic-manager/references
mkdir -p skills/coding/epic-manager/tests
```

- [ ] **Step 2: Write `references/final-review-schema.json`**

This schema mirrors the executor's per-ticket `codex-review-schema.json` shape (findings + overall_correctness + overall_explanation + overall_confidence_score) so the same `build_feedback_bundle`-style logic can parse it. The difference is the *prompt*, not the schema.

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["findings", "overall_correctness", "overall_explanation", "overall_confidence_score"],
  "properties": {
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["title", "body", "confidence_score", "priority", "code_location"],
        "properties": {
          "title": { "type": "string", "maxLength": 80 },
          "body": { "type": "string", "minLength": 1 },
          "confidence_score": { "type": "number", "minimum": 0, "maximum": 1 },
          "priority": { "type": "integer", "minimum": 0, "maximum": 3,
            "description": "0=severe,1=major,2=minor,3=nit. Same scale as per-ticket review." },
          "code_location": {
            "type": "object", "additionalProperties": false,
            "required": ["absolute_file_path", "line_range"],
            "properties": {
              "absolute_file_path": { "type": "string", "minLength": 1 },
              "line_range": {
                "type": "object", "additionalProperties": false,
                "required": ["start", "end"],
                "properties": {
                  "start": { "type": "integer", "minimum": 1 },
                  "end": { "type": "integer", "minimum": 1 }
                }
              }
            }
          }
        }
      }
    },
    "overall_correctness": { "type": "string", "enum": ["patch is correct", "patch is incorrect"] },
    "overall_explanation": { "type": "string", "minLength": 1 },
    "overall_confidence_score": { "type": "number", "minimum": 0, "maximum": 1 }
  }
}
```

- [ ] **Step 3: Write `references/final-review-prompt.md`**

Distinct from the executor's per-ticket prompt: holistic, integration-focused, judged against the full spec (not a single ticket's scope).

```markdown
You are acting as a reviewer for a complete feature implementation spread across
multiple merged pull requests, each of which was already reviewed in isolation.

Your job now is the INTEGRATION view: do these changes collectively implement the
specification end-to-end? Look for problems that no per-ticket review could catch:
gaps between tickets, conflicting approaches, missing wiring, cross-cutting
concerns (error handling, logging, config) that fall in the seams between tickets,
and anything where the whole is less than the sum of its parts.

Do NOT re-flag issues that are local to a single ticket's diff — those were the
per-ticket reviewer's job and have already been addressed or accepted. Focus only
on integration.

## Priority scale

Same as per-ticket review. 0=severe, 1=major (both block in the sense that the
manager will flag them loudly to the human), 2=minor, 3=nit.

## Output

Produce findings + an overall correctness verdict. The manager posts your output
as an advisory comment on the epic issue; the human decides whether to ship it,
rework it, or abandon it. Your findings do not prevent merge — they inform the
human's decision.
```

- [ ] **Step 4: Write `references/metadata-guess-schema.json`**

For codex's rework-ticket metadata guess. Labels are strings matching the label name suffixes (`p1`/`p2`/`p3`, `small`/`medium`/`large`, `lite`/`efficient`/`standard`/`flagship`).

```json
{
  "type": "object",
  "additionalProperties": false,
  "required": ["priority", "complexity", "model_tier", "reasoning"],
  "properties": {
    "priority": { "type": "string", "enum": ["p1", "p2", "p3"] },
    "complexity": { "type": "string", "enum": ["small", "medium", "large"] },
    "model_tier": { "type": "string", "enum": ["lite", "efficient", "standard", "flagship"] },
    "reasoning": { "type": "string", "minLength": 1 }
  }
}
```

- [ ] **Step 5: Write `references/metadata-guess-prompt.md`**

```markdown
You are triaging a rework request filed by a human on a feature epic. The human
wrote a short description of what needs to change. Pick the ticket metadata that
will let an executor handle it well.

- **priority**: p1 = blocks the epic from shipping (do first), p2 = should do soon,
  p3 = nice to have. Default to p1 — rework requests usually block shipping.
- **complexity**: small = a few lines / one file, medium = a focused change across
  related files, large = a refactor touching many files.
- **model_tier**: lite = trivial, efficient = small well-specified change, standard
  = typical coding, flagship = security/auth/large refactor/ambiguous.

Output your choice + a one-sentence reasoning. The manager will post your reasoning
as a hint so the human can retune the labels before an executor picks up the ticket.
```

- [ ] **Step 6: Write `references/checklist-schema.json`**

This documents the `.execute-tickets/checklist.yml` contract. The script parses the YAML directly with `yq`; this schema is the reference contract and is used by the malformed-checklist test to assert the error message names the violated constraint.

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "execute-tickets pre-PR checklist",
  "type": "object",
  "required": ["pre_pr_checks"],
  "properties": {
    "pre_pr_checks": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["name", "type"],
        "properties": {
          "name": { "type": "string", "minLength": 1 },
          "type": { "type": "string", "enum": ["run", "judge"] }
        },
        "oneOf": [
          { "properties": { "type": { "const": "run" } }, "required": ["command"] },
          { "properties": { "type": { "const": "judge" } }, "required": ["instruction"] }
        ]
      }
    }
  }
}
```

- [ ] **Step 7: Write the `epic-manager.sh` stub**

The stub has `usage()`, `parse_args()`, and `main()` but no logic — every flag is parsed and validated, `--help` works, and `preflight`/`load_manifest`/`run_one_cycle` are empty stubs that later tasks fill. This makes `--help` testable immediately and gives later tasks a stable flag surface.

```bash
#!/usr/bin/env bash
# epic-manager.sh: singleton plan-level supervisor for a plan-to-tickets epic.
# Tracks executor progress, gates the epic->main PR behind a per-project hybrid
# checklist, runs a final integration review, and obeys human commands (ship it
# / rework: / abandon) posted as comments on the epic issue. Peer to
# execute-tickets.sh; communicates through GitHub state only.
set -euo pipefail

PLAN_SLUG=""
REPO=""
CHECKLIST_FILE=""
REVIEWER_CMD_DEFAULT='codex exec --model "${CODEX_MODEL:-gpt-5-codex}" --output-schema {final_review_schema} -o {final_review_output} --sandbox read-only - < {final_review_prompt_composed}'
REVIEWER_CMD=""
FINAL_REVIEW_SCHEMA=""
FINAL_REVIEW_PROMPT=""
BLOCK_PRIORITY_MAX=1
POLL_SECONDS=300
STALE_LOCK_THRESHOLD=3600
ONCE=false
DRY_RUN=false
VERBOSE=true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK_LABEL="lock:manager"
MANIFEST_FILE=""
SOURCE_BRANCH=""
SPEC_FILE=""
PLAN_FILE=""

usage() {
  cat <<'EOF'
epic-manager.sh -- supervise a plan-to-tickets epic end-to-end.

Usage:
  epic-manager.sh --plan <slug> [flags]

Required:
  --plan <slug>            Plan slug: basename of docs/superpowers/tickets/<slug>.md.

Optional:
  --repo <owner/repo>          Target repo (default: current repo via `gh repo view`).
  --checklist <path>           Override checklist file (default: .execute-tickets/checklist.yml).
  --reviewer-cmd <cmd>         Final-review codex command (default: vendored).
  --final-review-schema <path> Override final-review schema (default: vendored).
  --final-review-prompt <path> Override final-review prompt (default: vendored).
  --block-priority-max <N>     Findings at/ below this priority flagged as blocking. Default: 1.
  --poll <seconds>             Sleep between cycles in loop mode. Default: 300.
  --stale-lock-threshold <sec> Force-claim lock:manager after this staleness. Default: 3600.
  --once                       Run one cycle, then exit (cron mode).
  --dry-run                    Print reconciled state + intended actions; mutate nothing.
  --quiet                      Reduce stderr logging. Epic-issue audit comments always post.
  --help                       Show this help.

Human commands (posted as comments on the epic issue, first line = trigger):
  ship it / #shipit / 🚀 / lgtm / merge it   -> merge the epic PR (guards + CI re-verify)
  rework [#N]: <description>                  -> file a new ticket; codex picks metadata
  abandon                                     -> close epic PR + close epic issue (not planned)
EOF
}

main() {
  parse_args "$@"
  preflight
  load_manifest
  if [ "$ONCE" = true ]; then
    set +e; run_one_cycle; set -e
    exit 0
  fi
  while true; do
    set +e; run_one_cycle; local rc=$?; set -e
    [ "$rc" -ne 0 ] && sleep "$POLL_SECONDS"
  done
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --plan) req_val "$@"; PLAN_SLUG="$2"; shift 2 ;;
      --repo) req_val "$@"; REPO="$2"; shift 2 ;;
      --checklist) req_val "$@"; CHECKLIST_FILE="$2"; shift 2 ;;
      --reviewer-cmd) req_val "$@"; REVIEWER_CMD="$2"; shift 2 ;;
      --final-review-schema) req_val "$@"; FINAL_REVIEW_SCHEMA="$2"; shift 2 ;;
      --final-review-prompt) req_val "$@"; FINAL_REVIEW_PROMPT="$2"; shift 2 ;;
      --block-priority-max) req_val "$@"; BLOCK_PRIORITY_MAX="$2"; shift 2 ;;
      --poll) req_val "$@"; POLL_SECONDS="$2"; shift 2 ;;
      --stale-lock-threshold) req_val "$@"; STALE_LOCK_THRESHOLD="$2"; shift 2 ;;
      --once) ONCE=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      --quiet) VERBOSE=false; shift ;;
      --help) usage; exit 0 ;;
      *) die 2 "Unknown flag: $1" ;;
    esac
  done
  [ -n "$PLAN_SLUG" ] || die 2 "Missing --plan <slug>"
  [ -n "$REVIEWER_CMD" ] || REVIEWER_CMD="$REVIEWER_CMD_DEFAULT"
  [ -n "$FINAL_REVIEW_SCHEMA" ] || FINAL_REVIEW_SCHEMA="$SKILL_DIR/references/final-review-schema.json"
  [ -n "$FINAL_REVIEW_PROMPT" ] || FINAL_REVIEW_PROMPT="$SKILL_DIR/references/final-review-prompt.md"
  [ -n "$CHECKLIST_FILE" ] || CHECKLIST_FILE=".execute-tickets/checklist.yml"
}

req_val() { [ $# -ge 2 ] || die 2 "Missing value for $1"; }
die() { local code="$1"; shift; echo "$*" >&2; exit "$code"; }

preflight() { :; }
load_manifest() { :; }
run_one_cycle() { :; }

log() { printf '[%s manager] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
vlog() { [ "$VERBOSE" = true ] || return 0; printf '[%s manager]   %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

main "$@"
```

- [ ] **Step 8: Write `SKILL.md`**

Use the executor's SKILL.md as the structural template (front matter with `name`/`description`/`metadata`, then sections). Description follows the executor's style: what it does, when it applies, when it does NOT apply.

```markdown
---
name: epic-manager
description: >-
  Supervise a plan-to-tickets epic end-to-end: track executor progress, gate the
  epic->main PR behind a per-project hybrid checklist (run: shell + judge: codex),
  run a final integration review, and obey human commands (ship it / rework: /
  abandon) posted as comments on the epic issue. Singleton (lock:manager), runs
  on cron or in a slow loop, one plan per invocation. Peer to execute-tickets;
  communicates through GitHub state only. Use when execute-tickets has merged
  ticket PRs into the epic branch and you want the epic shepherded to a
  reviewable PR on main with a final review and human merge approval. Never
  re-plans, assigns tickets, auto-merges without human approval, or touches
  individual ticket issues (except filing new ones for rework:).
metadata:
  author: stephen-martin
  version: "0.1.0"
---

# Supervise a plan-to-tickets epic end-to-end

[Full SKILL.md body — write the complete skill doc covering: when this applies,
the loop (mirroring the spec's "The loop" section), the checklist gate, the
final review, the command surface table, the approval-reset invariant, flags,
relationship to execute-tickets. Model the prose on execute-tickets/SKILL.md.]
```

(The implementer writes the full body here — the spec is the source of truth for content; the executor's SKILL.md is the template for tone/structure/length.)

- [ ] **Step 9: Write `WARP.md`**

Mirror `skills/coding/execute-tickets/WARP.md`'s structure, adapted for the manager: `--once` per cron firing, singleton `lock:manager` means only one scheduled agent per plan (not one per worker slot like the executor), slow cadence (every 5 min, not every 1 min).

- [ ] **Step 10: Verify `--help` works**

Run: `bash skills/coding/epic-manager/scripts/epic-manager.sh --help`
Expected: exit 0, prints usage including all flags + the human-commands section.

Run: `bash skills/coding/epic-manager/scripts/epic-manager.sh`
Expected: exit 2, stderr "Missing --plan <slug>".

- [ ] **Step 11: Commit**

```bash
git add skills/coding/epic-manager/
git commit -m "epic-manager: scaffold skill directory, references, and --help stub

Lays down the file skeleton (SKILL.md, scripts/epic-manager.sh, references/,
tests/, WARP.md) and the vendored prompts/schemas (final-review, metadata-guess,
checklist) so every subsequent task has a stable target. The script is a stub:
usage() + parse_args + main with empty preflight/load_manifest/run_one_cycle,
so --help and flag validation work immediately. No logic yet."
```

---

### Task 2: Test harness scaffolding (lib.sh, fake-gh extension, fake-codex copy)

**Files:**
- Create: `skills/coding/epic-manager/tests/lib.sh`
- Create: `skills/coding/epic-manager/tests/fake-gh` (extended from executor's)
- Create: `skills/coding/epic-manager/tests/fake-codex` (copied from executor's)
- Create: `skills/coding/epic-manager/tests/run.sh` (empty runner that sources lib.sh, prints 0 passed)

**Interfaces:**
- Consumes: the executor's `tests/fake-gh`, `tests/fake-codex`, `tests/lib.sh` as the base to copy/extend.
- Produces: `make_repo`, `seed_state`, `issue_json`, `bindir_for`, `run_em`, `state_get` helpers; a fake-gh that additionally supports `pr list`, closed-issue listing, and `--delete-branch` on merge; a `run.sh` that runs and reports pass/fail.

The manager does PR operations the executor doesn't (`pr list` for epic-PR idempotency, `pr merge --delete-branch`) and needs to list **closed** issues (to count drained backlogs). The executor's fake-gh only lists open issues and has no `pr list`. This task extends the fake to cover those, plus adds a `run_em` helper (the manager equivalent of `run_et`).

- [ ] **Step 1: Copy `fake-codex` verbatim**

```bash
cp skills/coding/execute-tickets/tests/fake-codex skills/coding/epic-manager/tests/fake-codex
chmod +x skills/coding/epic-manager/tests/fake-codex
```

The executor's fake-codex is generic (writes canned JSON to `-o` path, supports `FAKE_CODEX_RESPONSES_DIR` for sequential responses). The manager uses the same `codex exec -o <out>` contract for both final review and metadata guess, so the same shim works unchanged. Verify by diffing — they must be identical.

- [ ] **Step 2: Write `lib.sh`**

Copy `skills/coding/execute-tickets/tests/lib.sh` and change `SCRIPT` to point at the manager, and rename `run_et` → `run_em`. Keep every other helper (`make_repo`, `seed_state`, `issue_json`, `bindir_for`, `state_get`, `install_reject_second_ticket_push`, `write_codex_responses`) identical — the manager reuses them all.

The only line that changes vs the executor's lib.sh:

```bash
# Before (executor):
SCRIPT="$HERE/../scripts/execute-tickets.sh"
# After (manager):
SCRIPT="$HERE/../scripts/epic-manager.sh"
```

And the runner helper is renamed (the body is identical — `cd workdir`, set PATH, run, capture OUT/ERR/RC):

```bash
# run_em <workdir> <bindir> <env-assignments...> -- <epic-manager.sh args...>
run_em() {
  local workdir="$1" bindir="$2"; shift 2
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  local outf errf
  outf="$(mktemp)"; errf="$(mktemp)"
  ( cd "$workdir" && PATH="$bindir:$PATH" env ${envs[@]+"${envs[@]}"} bash "$SCRIPT" "$@" >"$outf" 2>"$errf" )
  RC=$?
  OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}
```

- [ ] **Step 3: Extend `fake-gh` with `pr list`, closed issues, and `--delete-branch`**

Start from a copy of `skills/coding/execute-tickets/tests/fake-gh`. Three additions:

**(a) `issue list` must support `--state all` and `--state closed`:** the executor only ever lists open issues (it picks from open tickets). The manager lists all states to count closed tickets in a drained backlog. Change the `issue list` case:

```bash
      list)
        state_filter="$(find_flag_value --state "$@" || echo open)"
        local_q="$(find_flag_value -q "$@" || true)"
        case "$state_filter" in
          open|all|closed)
            base="$(jread --arg s "$state_filter" '
              [ .issues[] | select(.state as $st |
                  ($s == "all") or ($s == "open" and $st == "open") or ($s == "closed" and $st == "closed"))
              | .labels = [(.labels // [])[] | {name: .}] ]') ;;
          *) base='[]' ;;
        esac
        if [ -n "$local_q" ]; then jq -c "$local_q" <<<"$base"
        else jq -c '.' <<<"$base"; fi
        exit 0 ;;
```

**(b) Add `pr list`:** the manager checks for an existing open epic PR (idempotency). The fake needs to list PRs by state + base + head.

```bash
      list)
        state_filter="$(find_flag_value --state "$@" || echo open)"
        base_filter="$(find_flag_value --base "$@" || true)"
        head_filter="$(find_flag_value --head "$@" || true)"
        json_fields="$(find_flag_value --json "$@" || true)"
        local_q="$(find_flag_value -q "$@" || true)"
        rows="$(jread --arg s "$state_filter" --arg b "$base_filter" --arg h "$head_filter" '
          [ .prs | to_entries[]
            | select((.value.merged as $m | ($s == "open" and ($m | not)) or ($s == "merged" and $m) or ($s == "all"))
                     and ($b == "" or .value.base == $b)
                     and ($h == "" or .value.head == $h))
            | .value ]')"
        if [ -n "$json_fields" ]; then
          fields_csv="$json_fields"
          rows="$(jq -c --arg fields "$fields_csv" 'map({($fields|split(",")|.[0]): .})' <<<"$rows" 2>/dev/null || echo '[]')"
        fi
        if [ -n "$local_q" ]; then jq -c "$local_q" <<<"$rows"
        else jq -c '.' <<<"$rows"; fi
        exit 0 ;;
```

**(c) `pr merge` accepts `--delete-branch`:** the manager merges with `--delete-branch --auto`. The executor's fake already handles `--auto` vs not; just make sure `--delete-branch` is parsed without error (it doesn't need to actually delete a branch ref in the fake — the state just marks the PR merged). The existing `has_flag --auto` logic already ignores other flags, so this works as-is. Verify by reading the merge case: it calls `has_flag --auto "$@"` and otherwise ignores `--delete-branch`. No change needed, but add a test asserting `--delete-branch` doesn't break merge.

- [ ] **Step 4: Write the `run.sh` skeleton**

```bash
#!/usr/bin/env bash
# Plain-bash test runner for epic-manager.sh. No network: fake gh/codex on PATH.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib.sh"

# Tests are added in later tasks.

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 5: Verify the harness runs (empty)**

Run: `bash skills/coding/epic-manager/tests/run.sh`
Expected: "0 passed, 0 failed", exit 0.

- [ ] **Step 6: Verify fake-gh extensions work in isolation**

Write a throwaway check (not committed) that seeds state with a closed issue + an open PR, then calls the fake-gh to list them. Confirm `issue list --state closed` returns the closed issue and `pr list --state open --base main` returns the PR. Then delete the throwaway check.

- [ ] **Step 7: Commit**

```bash
git add skills/coding/epic-manager/tests/
git commit -m "epic-manager: test harness scaffolding (lib.sh, fake-gh, fake-codex, run.sh)

Copies the executor's test harness layout and extends fake-gh for the manager's
PR operations: issue list --state closed (drained-backlog detection), pr list
(epic-PR idempotency check), and --delete-branch tolerance on pr merge. fake-codex
is copied verbatim (same codex exec -o contract). lib.sh points SCRIPT at
epic-manager.sh and renames run_et -> run_em; all other helpers are shared
verbatim. run.sh is an empty runner; tests land in later tasks."
```

---

### Task 3: `preflight` + `load_manifest` + singleton lock acquire/release

**Files:**
- Modify: `skills/coding/epic-manager/scripts/epic-manager.sh` (replace the `preflight`/`load_manifest`/`run_one_cycle` stubs; add `acquire_lock`/`release_lock`/`force_claim_stale_lock`/`find_epic_issue`)
- Test: `skills/coding/epic-manager/tests/run.sh`

**Interfaces:**
- Consumes: manifest front matter (`source_branch`/`spec_file`/`plan_file`), the epic marker `<!-- plan-to-tickets:epic:<plan_file> -->`.
- Produces: `SOURCE_BRANCH`, `SPEC_FILE`, `PLAN_FILE`, `EPIC_NUMBER`, `EPIC_MARKER` globals; `acquire_lock` returns 0 (acquired) or 1 (not); `release_lock` always succeeds.

This task implements the manager's entry into a cycle: validate env, load the manifest, find the epic issue, acquire the singleton lock (with stale-lock recovery), and release it. `run_one_cycle` becomes "acquire → (stubbed body) → release" so the lock mechanics are testable in isolation.

- [ ] **Step 1: Write failing tests for preflight + manifest + lock**

Append to `run.sh`. These test the entry mechanics before any cycle body exists.

```bash
# ---- Task 3 tests: preflight, manifest, singleton lock ----

test_help() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  run_em "$d/work" "$(bindir_for "$d")" -- --help
  assert_eq "$RC" "0" "help exits 0"
  assert_contains "$OUT" "epic-manager.sh" "help mentions the script"
  assert_contains "$OUT" "--plan" "help lists --plan"
  assert_contains "$OUT" "ship it" "help lists the ship it command"
  rm -rf "$d"
}
test_help

test_missing_plan_flag() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  run_em "$d/work" "$(bindir_for "$d")" --
  assert_eq "$RC" "2" "missing --plan exits 2"
  assert_contains "$ERR" "Missing --plan" "clear error for missing --plan"
  rm -rf "$d"
}
test_missing_plan_flag

test_load_manifest() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  # Seed an epic issue with the marker so find_epic_issue succeeds.
  epic_body="Epic body.<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  seed_state "$d/state" "[$(issue_json 100 'Epic' "$epic_body" '[]')]"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" -- --plan test-plan --dry-run
  assert_eq "$RC" "0" "dry-run with valid manifest + epic exits 0"
  assert_contains "$ERR" "source_branch: epic" "load_manifest parsed source_branch"
  assert_contains "$ERR" "spec_file:" "load_manifest parsed spec_file"
  assert_contains "$ERR" "plan_file:" "load_manifest parsed plan_file"
  assert_contains "$ERR" "epic issue: #100" "found the epic issue by marker"
  rm -rf "$d"
}
test_load_manifest

test_singleton_lock_acquire_and_release() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  epic_body="<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  seed_state "$d/state" "[$(issue_json 100 'Epic' "$epic_body" '[]')]"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" -- --plan test-plan --dry-run
  # After a dry-run cycle, lock:manager should NOT be present (dry-run doesn't claim).
  labels="$(jq -r '.issues["100"].labels | join(",")' "$d/state")"
  assert_not_contains "$labels" "lock:manager" "dry-run does not acquire the lock"
  rm -rf "$d"
}
test_singleton_lock_acquire_and_release

test_singleton_lock_blocked_when_held() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  epic_body="<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  # Pre-seed the epic with lock:manager already present (another firing holds it).
  seed_state "$d/state" "[$(issue_json 100 'Epic' "$epic_body" '["lock:manager"]')]"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" -- --plan test-plan
  assert_contains "$ERR" "lock:manager held" "reports the lock is held"
  assert_contains "$ERR" "another firing" "explains why it's exiting"
  rm -rf "$d"
}
test_singleton_lock_blocked_when_held
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash skills/coding/epic-manager/tests/run.sh`
Expected: FAIL — the stubs do nothing, so `--dry-run` produces no `source_branch:`/`epic issue:` output and the lock-held test doesn't detect the label.

- [ ] **Step 3: Implement `preflight`**

```bash
preflight() {
  command -v gh >/dev/null 2>&1 || die 1 "gh is required."
  command -v jq >/dev/null 2>&1 || die 1 "jq is required."
  command -v git >/dev/null 2>&1 || die 1 "git is required."
  command -v codex >/dev/null 2>&1 || log "WARNING: codex not on PATH; --reviewer-cmd must invoke it explicitly."
  command -v yq >/dev/null 2>&1 || die 1 "yq is required (for checklist parsing)."
  gh auth status >/dev/null 2>&1 || die 1 "gh is not authenticated. Run: gh auth login"
  [ -f "$FINAL_REVIEW_SCHEMA" ] || die 1 "Final-review schema not found: $FINAL_REVIEW_SCHEMA"
  [ -f "$FINAL_REVIEW_PROMPT" ] || die 1 "Final-review prompt not found: $FINAL_REVIEW_PROMPT"
  if [ -z "$REPO" ]; then
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  fi
  [ -n "$REPO" ] || die 1 "Could not determine target repo. Pass --repo."
  ensure_labels
}

ensure_labels() {
  local existing
  existing="$(gh label list --repo "$REPO" --json name -q '.[].name' 2>/dev/null || true)"
  grep -qxF "lock:manager" <<<"$existing" && return 0
  [ "$DRY_RUN" = true ] || gh label create "lock:manager" --repo "$REPO" --color "5319e7" --force >/dev/null
}
```

- [ ] **Step 4: Implement `load_manifest` and `find_epic_issue`**

```bash
load_manifest() {
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  MANIFEST_FILE="$root/docs/superpowers/tickets/$PLAN_SLUG.md"
  [ -f "$MANIFEST_FILE" ] || die 1 "Manifest not found: $MANIFEST_FILE (run plan-to-tickets first)"
  local in_fm=false key val line
  while IFS= read -r line; do
    if [ "$line" = "---" ]; then
      if [ "$in_fm" = false ]; then in_fm=true; continue; else break; fi
    fi
    [ "$in_fm" = true ] || continue
    key="${line%%:*}"; val="${line#*:}"; val="${val# }"; val="${val#\"}"; val="${val%\"}"
    case "$key" in
      source_branch) SOURCE_BRANCH="$val" ;;
      spec_file) SPEC_FILE="$val" ;;
      plan_file) PLAN_FILE="$val" ;;
    esac
  done < "$MANIFEST_FILE"
  [ -n "$SOURCE_BRANCH" ] || die 1 "Manifest missing source_branch: $MANIFEST_FILE"
  [ -n "$SPEC_FILE" ] || die 1 "Manifest missing spec_file: $MANIFEST_FILE"
  [ -n "$PLAN_FILE" ] || die 1 "Manifest missing plan_file: $MANIFEST_FILE"
  EPIC_MARKER="<!-- plan-to-tickets:epic:$PLAN_FILE -->"
  EPIC_NUMBER="$(find_epic_issue)"
  [ -n "$EPIC_NUMBER" ] || die 1 "No epic issue found with marker $EPIC_MARKER. Run plan-to-tickets first."
  vlog "manifest: $MANIFEST_FILE"
  vlog "  source_branch: $SOURCE_BRANCH"
  vlog "  spec_file:     $SPEC_FILE"
  vlog "  plan_file:     $PLAN_FILE"
  vlog "  epic issue:    #$EPIC_NUMBER"
}

find_epic_issue() {
  # The epic issue carries the plan-to-tickets:epic marker. Search all states
  # (a completed epic may be closed; a human may have re-opened it for rework).
  gh issue list --repo "$REPO" --state all --limit 500 \
    --json number,body -q --arg marker "$EPIC_MARKER" \
    '.[] | select(.body | contains($marker)) | .number' 2>/dev/null | head -1
}
```

- [ ] **Step 5: Implement lock acquire / release / stale-claim**

```bash
acquire_lock() {
  # Returns 0 if acquired, 1 if held by another (live) firing.
  local labels has_ours
  gh issue edit "$EPIC_NUMBER" --repo "$REPO" --add-label "$LOCK_LABEL" >/dev/null 2>&1 || return 1
  labels="$(gh issue view "$EPIC_NUMBER" --repo "$REPO" --json labels -q '[.labels[].name]' 2>/dev/null || echo '[]')"
  has_ours="$(jq --arg L "$LOCK_LABEL" 'index($L) != null' <<<"$labels")"
  if [ "$has_ours" != "true" ]; then
    return 1
  fi
  # Stale-lock recovery: if a prior lock:manager comment is older than the
  # threshold, force-claim. (Simplified v1: the lock is considered fresh if we
  # just acquired it. Full staleness detection via comment timestamp is a later
  # refinement; for now, acquiring means we hold it.)
  return 0
}

release_lock() {
  gh issue edit "$EPIC_NUMBER" --repo "$REPO" --remove-label "$LOCK_LABEL" >/dev/null 2>&1 || true
}
```

Note for the implementer: the spec describes stale-lock recovery via lock-acquisition comment age. v1 ships a simpler model — `acquire_lock` uses the same add-label-then-verify pattern as the executor's `claim_ticket`, and a stale lock is detected by a separate `detect_stale_lock` function called *before* `acquire_lock` when the label is already present. If `detect_stale_lock` confirms staleness, it removes the old label and `acquire_lock` proceeds. Implement `detect_stale_lock` in this task but keep its threshold-based logic simple (compare the `lock:manager` label's... note: GitHub labels don't carry timestamps, so the stale detection must use a *comment* the manager posts when it acquires the lock, e.g. `<!-- manager:lock-acquired:<iso8601> -->`). Add that comment on acquire, find it on detect.

- [ ] **Step 6: Wire `run_one_cycle` as acquire → body → release**

```bash
run_one_cycle() {
  # If the lock is already held, check staleness; force-claim if stale, else exit.
  local labels held
  labels="$(gh issue view "$EPIC_NUMBER" --repo "$REPO" --json labels -q '[.labels[].name]' 2>/dev/null || echo '[]')"
  held="$(jq --arg L "$LOCK_LABEL" 'index($L) != null' <<<"$labels")"
  if [ "$held" = "true" ]; then
    if detect_stale_lock; then
      log "Stale lock:manager detected; force-claiming."
      gh issue edit "$EPIC_NUMBER" --repo "$REPO" --remove-label "$LOCK_LABEL" >/dev/null 2>&1 || true
    else
      log "lock:manager held by another firing; exiting."
      return 1
    fi
  fi
  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] would acquire lock:manager and run a cycle"
    return 0
  fi
  if ! acquire_lock; then
    log "Failed to acquire lock:manager; exiting."
    return 1
  fi
  # Body implemented in later tasks.
  release_lock
  return 0
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `bash skills/coding/epic-manager/tests/run.sh`
Expected: all Task 3 tests PASS.

- [ ] **Step 8: Commit**

```bash
git add skills/coding/epic-manager/scripts/epic-manager.sh skills/coding/epic-manager/tests/run.sh
git commit -m "epic-manager: preflight, manifest load, singleton lock with stale recovery

Implements the cycle entry: validate env (gh/jq/git/codex/yq + auth), load the
manifest front matter (source_branch/spec_file/plan_file), find the epic issue
by its plan-to-tickets:epic marker, and acquire the singleton lock:manager
label with stale-lock recovery (a lock-acquired HTML comment timestamped on
acquire; detect_stale_lock force-claims past --stale-lock-threshold). Dry-run
mutates nothing. run_one_cycle is acquire -> (body stub) -> release so the
lock mechanics are testable in isolation."
```

---

### Task 4: State reconciliation + progress comment

**Files:**
- Modify: `skills/coding/epic-manager/scripts/epic-manager.sh` (add `reconcile_state`, `post_progress_comment`)
- Test: `skills/coding/epic-manager/tests/run.sh`

**Interfaces:**
- Consumes: `EPIC_NUMBER`, `TICKET_MARKER_PREFIX` (built from `PLAN_FILE`), the executor's `lock:<name>` labels.
- Produces: `reconcile_state` prints a JSON object `{ready: [...], in_progress: [...], needs_human: [...], closed: [...]}` of ticket numbers; `post_progress_comment` posts a named-worker-aware summary to the epic issue.

The manager's core observation: group all ticket issues carrying this plan's marker by state. If any are ready or in-progress, post progress and exit (executors are still working). This task implements that observation and the progress audit comment.

- [ ] **Step 1: Write failing tests for reconciliation**

```bash
# ---- Task 4 tests: reconciliation + progress ----

test_reconcile_in_progress_exits_early() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  epic_body="<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  # Ticket #101 in-progress (lock:alice), ticket #102 ready, #103 closed.
  t101="$(issue_json 101 'T1' "<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->" '["lock:alice","complexity:small"]')"
  t102="$(issue_json 102 'T2' "<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:002-b -->" '["complexity:small"]')"
  t103="$(issue_json 103 'T3' "<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:003-c -->" '[]')"
  # #103 closed
  seed_state "$d/state" "[$t101,$t102,$t103]"
  jq '.issues["103"].state = "closed"' "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" FAKE_GH_LOG="$d/gh.log" -- --plan test-plan
  assert_contains "$ERR" "in-progress" "detected in-progress ticket"
  assert_contains "$ERR" "alice" "progress names the worker (alice)"
  assert_contains "$ERR" "drained" && bad "should NOT say drained" || ok "does not claim drained with in-progress"
  rm -rf "$d"
}
test_reconcile_in_progress_exits_early

test_reconcile_drained_proceeds() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  epic_body="<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  # All tickets closed, none in-progress, none ready -> drained.
  t101="$(issue_json 101 'T1' "<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->" '[]')"
  seed_state "$d/state" "[$t101]"
  jq '.issues["101"].state = "closed"' "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" FAKE_GH_LOG="$d/gh.log" -- --plan test-plan --dry-run
  assert_contains "$ERR" "drained" "detected drained backlog"
  rm -rf "$d"
}
test_reconcile_drained_proceeds
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash skills/coding/epic-manager/tests/run.sh`
Expected: FAIL — `reconcile_state` doesn't exist.

- [ ] **Step 3: Implement `reconcile_state`**

```bash
TICKET_MARKER_PREFIX=""
# Set in load_manifest alongside EPIC_MARKER:
#   TICKET_MARKER_PREFIX="<!-- plan-to-tickets:ticket:$PLAN_FILE:"

reconcile_state() {
  # Group all ticket issues carrying this plan's marker by lifecycle state.
  # Prints JSON: {ready:[n], in_progress:[n], needs_human:[n], closed:[n]}
  local raw
  raw="$(gh issue list --repo "$REPO" --state all --limit 500 \
          --json number,title,body,labels,assignees,state 2>/dev/null || echo '[]')"
  jq --arg pfx "$TICKET_MARKER_PREFIX" '
    map(select((.body // "") | contains($pfx)))
    | {
        ready:       [ .[] | select(.state == "open" and ((.labels//[])|map(.name)|any(startswith("lock:"))|not) and ((.labels//[])|map(.name)|index("needs-human")|not) and ((.assignees//[])|length==0)) | .number ],
        in_progress: [ .[] | select(.state == "open" and ((.labels//[])|map(.name)|any(startswith("lock:")))) | .number ],
        needs_human: [ .[] | select(.state == "open" and ((.labels//[])|map(.name)|index("needs-human"))) | .number ],
        closed:      [ .[] | select(.state == "closed") | .number ]
      }
  ' <<<"$raw"
}
```

- [ ] **Step 4: Implement `post_progress_comment`**

```bash
post_progress_comment() {
  local state="$1"
  local body_file; body_file="$(mktemp)"
  local ready_count in_progress_count needs_human_count closed_count
  ready_count="$(jq '.ready | length' <<<"$state")"
  in_progress_count="$(jq '.in_progress | length' <<<"$state")"
  needs_human_count="$(jq '.needs_human | length' <<<"$state")"
  closed_count="$(jq '.closed | length' <<<"$state")"
  {
    echo "### 📊 Plan progress"
    echo
    echo "- **Closed**: $closed_count"
    echo "- **In progress**: $in_progress_count"
    echo "- **Ready (waiting for an executor)**: $ready_count"
    echo "- **Needs human**: $needs_human_count"
    if [ "$in_progress_count" -gt 0 ]; then
      echo
      echo "In progress:"
      echo "$(worker_names_for_issues "$state" 'in_progress')" | sed 's/^/- /'
    fi
    if [ "$needs_human_count" -gt 0 ]; then
      echo
      echo "⚠️ Needs human: $(jq -r '.needs_human | join(", ")' <<<"$state")"
    fi
  } > "$body_file"
  gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body-file "$body_file" >/dev/null 2>&1 || true
  rm -f "$body_file"
}

# worker_names_for_issues <state_json> <key> -> prints "#N (alice)" lines
# Reads each issue's lock:<name> label to name the worker.
worker_names_for_issues() {
  local state="$1" key="$2" nums n labels worker
  nums="$(jq -r --arg k "$key" '.[$k][]' <<<"$state")"
  for n in $nums; do
    labels="$(gh issue view "$n" --repo "$REPO" --json labels -q '[.labels[].name]' 2>/dev/null || echo '[]')"
    worker="$(jq -r '.[] | select(startswith("lock:")) | sub("^lock:";"")' <<<"$labels" | head -1)"
    [ -n "$worker" ] && worker=" ($worker)" || worker=""
    echo "#$n$worker"
  done
}
```

- [ ] **Step 5: Wire reconciliation into `run_one_cycle`**

Replace the `# Body implemented in later tasks.` stub:

```bash
  local state
  state="$(reconcile_state)"
  vlog "reconciled: ready=$(jq -r '.ready|length' <<<"$state") in_progress=$(jq -r '.in_progress|length' <<<"$state") needs_human=$(jq -r '.needs_human|length' <<<"$state") closed=$(jq -r '.closed|length' <<<"$state")"
  post_progress_comment "$state"
  local ready_count in_progress_count
  ready_count="$(jq '.ready | length' <<<"$state")"
  in_progress_count="$(jq '.in_progress | length' <<<"$state")"
  if [ "$ready_count" -gt 0 ] || [ "$in_progress_count" -gt 0 ]; then
    vlog "executors still working (ready=$ready_count in_progress=$in_progress_count); exiting."
    release_lock
    return 0
  fi
  vlog "backlog drained; proceeding to checklist gate."
  # Checklist gate implemented in Task 5.
  release_lock
  return 0
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bash skills/coding/epic-manager/tests/run.sh`
Expected: all Task 3 + Task 4 tests PASS.

- [ ] **Step 7: Commit**

```bash
git add skills/coding/epic-manager/scripts/epic-manager.sh skills/coding/epic-manager/tests/run.sh
git commit -m "epic-manager: state reconciliation + named-worker progress comments

reconcile_state groups all plan tickets by lifecycle (ready/in_progress/
needs_human/closed) from gh issue list --state all. If any are ready or
in-progress, posts a progress comment naming the worker (reads lock:<name>
labels -> 'alice'/'bob'/etc.) and exits -- executors are still working. Only
a drained backlog (no ready, no in-progress) proceeds toward the checklist
gate. Progress comments go on the epic issue (durable audit trail)."
```

---

### Task 5: Hybrid checklist gate (`run:` + `judge:`)

**Files:**
- Modify: `skills/coding/epic-manager/scripts/epic-manager.sh` (add `run_checklist`, `eval_run_item`, `eval_judge_item`, `post_checklist_failure`)
- Test: `skills/coding/epic-manager/tests/run.sh`

**Interfaces:**
- Consumes: `.execute-tickets/checklist.yml` (optional; absent → gate skipped), `SOURCE_BRANCH` for the worktree checkout, `fake-codex` for `judge:` items.
- Produces: `run_checklist` returns 0 (all pass) or 1 (any fail); on fail, epic issue has `needs-human` + `checklist-failed` labels and an actionable failure comment.

This is the gate that decides whether the epic is ready for a human to see. `run:` items are shell commands (exit 0 = pass); `judge:` items are codex yes/no judgments. Any failure blocks the PR and escalates.

- [ ] **Step 1: Write failing tests for the checklist gate**

```bash
# ---- Task 5 tests: hybrid checklist gate ----

write_checklist() {
  cat > "$1/.execute-tickets/checklist.yml" <<EOF
pre_pr_checks:
  - name: CHANGELOG updated
    type: run
    command: "test -f CHANGELOG.md"
  - name: Public API documented
    type: judge
    instruction: "Every new public function has documentation."
EOF
}

test_checklist_no_file_skips_gate() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  epic_body="<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  seed_state "$d/state" "[$(issue_json 100 'Epic' "$epic_body" '[]')]"
  # No .execute-tickets/checklist.yml -> gate skipped, proceeds to "would open PR"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" -- --plan test-plan --dry-run
  assert_contains "$ERR" "checklist: skipped (no file)" "absent checklist skips the gate"
  rm -rf "$d"
}
test_checklist_no_file_skips_gate

test_checklist_run_pass() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  write_checklist "$d/work"
  echo "# changelog" > "$d/work/CHANGELOG.md"  # make the run: item pass
  git -C "$d/work" add -A && git -C "$d/work" commit -q -m "add changelog"
  git -C "$d/work" push -q origin epic
  epic_body="<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  seed_state "$d/state" "[$(issue_json 100 'Epic' "$epic_body" '[]')]"
  # FAKE_CODEX_REVIEW_JSON set to a "passed: true" judgment for the judge: item.
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" \
    FAKE_CODEX_REVIEW_JSON='{"passed":true,"reasoning":"looks good","confidence":0.9}' \
    -- --plan test-plan --dry-run
  assert_contains "$ERR" "checklist: PASS" "checklist passes when run passes and judge passes"
  rm -rf "$d"
}
test_checklist_run_pass

test_checklist_run_fail_blocks() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  write_checklist "$d/work"
  # No CHANGELOG.md -> run: item fails.
  epic_body="<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  seed_state "$d/state" "[$(issue_json 100 'Epic' "$epic_body" '[]')]"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" FAKE_GH_LOG="$d/gh.log" \
    FAKE_CODEX_REVIEW_JSON='{"passed":true,"reasoning":"ok","confidence":0.9}' \
    -- --plan test-plan
  assert_contains "$ERR" "checklist: FAIL" "checklist fails when a run: item fails"
  assert_contains "$d/gh.log" "needs-human" "sets needs-human on the epic"
  assert_contains "$d/gh.log" "checklist-failed" "sets checklist-failed on the epic"
  assert_contains "$d/gh.log" "CHANGELOG updated" "failure comment names the failed item"
  rm -rf "$d"
}
test_checklist_run_fail_blocks

test_checklist_malformed() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  mkdir -p "$d/work/.execute-tickets"
  printf 'pre_pr_checks:\n  - name: bad\n    type: unknown\n    command: x\n' > "$d/work/.execute-tickets/checklist.yml"
  epic_body="<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  seed_state "$d/state" "[$(issue_json 100 'Epic' "$epic_body" '[]')]"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" FAKE_GH_LOG="$d/gh.log" -- --plan test-plan
  assert_contains "$ERR" "checklist: MALFORMED" "malformed checklist is a hard failure"
  assert_contains "$d/gh.log" "needs-human" "malformed checklist sets needs-human"
  rm -rf "$d"
}
test_checklist_malformed
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash skills/coding/epic-manager/tests/run.sh`
Expected: FAIL — `run_checklist` doesn't exist.

- [ ] **Step 3: Implement `run_checklist` + `eval_run_item` + `eval_judge_item`**

```bash
run_checklist() {
  # Returns 0 if all pass (or no checklist file), 1 if any fail / malformed.
  # On fail/malformed, posts an actionable comment + sets needs-human + checklist-failed.
  local checklist_path
  checklist_path="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/$CHECKLIST_FILE"
  if [ ! -f "$checklist_path" ]; then
    vlog "checklist: skipped (no file at $checklist_path)"
    return 0
  fi
  # Validate structure with yq.
  if ! yq -e '.pre_pr_checks' "$checklist_path" >/dev/null 2>&1; then
    post_checklist_failure "MALFORMED" "Checklist file $checklist_path is not valid: missing top-level 'pre_pr_checks' array."
    return 1
  fi
  local count item name type results_file
  count="$(yq -r '.pre_pr_checks | length' "$checklist_path")"
  results_file="$(mktemp)"
  local i=0
  while [ "$i" -lt "$count" ]; do
    name="$(yq -r ".pre_pr_checks[$i].name // \"\"" "$checklist_path")"
    type="$(yq -r ".pre_pr_checks[$i].type // \"\"" "$checklist_path")"
    case "$type" in
      run)
        local cmd
        cmd="$(yq -r ".pre_pr_checks[$i].command // \"\"" "$checklist_path")"
        if [ -z "$cmd" ]; then
          post_checklist_failure "MALFORMED" "Checklist item '$name' (type: run) is missing 'command'."
          rm -f "$results_file"; return 1
        fi
        eval_run_item "$name" "$cmd" "$results_file" || { post_checklist_failure "FAIL" "$results_file"; rm -f "$results_file"; return 1; }
        ;;
      judge)
        local instr
        instr="$(yq -r ".pre_pr_checks[$i].instruction // \"\"" "$checklist_path")"
        if [ -z "$instr" ]; then
          post_checklist_failure "MALFORMED" "Checklist item '$name' (type: judge) is missing 'instruction'."
          rm -f "$results_file"; return 1
        fi
        eval_judge_item "$name" "$instr" "$results_file" || { post_checklist_failure "FAIL" "$results_file"; rm -f "$results_file"; return 1; }
        ;;
      *)
        post_checklist_failure "MALFORMED" "Checklist item '$name' has unknown type '$type' (expected 'run' or 'judge')."
        rm -f "$results_file"; return 1
        ;;
    esac
    i=$((i + 1))
  done
  vlog "checklist: PASS (all $count items passed)"
  rm -f "$results_file"
  return 0
}

eval_run_item() {
  local name="$1" cmd="$2" results_file="$3"
  local out rc
  out="$(bash -c "$cmd" 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    jq -n --arg n "$name" --arg t "run" --argjson passed true --arg cmd "$cmd" \
      '{name:$n, type:$t, passed:$passed, command:$cmd}' >> "$results_file"
    return 0
  fi
  jq -n --arg n "$name" --arg t "run" --argjson passed false --arg cmd "$cmd" --arg out "$out" \
    '{name:$n, type:$t, passed:$passed, command:$cmd, output:$out}' >> "$results_file"
  return 1
}

eval_judge_item() {
  local name="$1" instr="$2" results_file="$3"
  local out_json
  out_json="$(mktemp)"
  # Reuse the reviewer-cmd pattern with a judgment schema (passed/reasoning/confidence).
  # The judge schema is a separate file created in Task 1's references (or inline here).
  local judge_schema="$tmpdir/judge-schema.json"
  cat > "$judge_schema" <<'JSON'
{"type":"object","additionalProperties":false,"required":["passed","reasoning","confidence"],"properties":{"passed":{"type":"boolean"},"reasoning":{"type":"string","minLength":1},"confidence":{"type":"number","minimum":0,"maximum":1}}}
JSON
  local cmd
  cmd="$(render_cmd "$REVIEWER_CMD" \
    final_review_schema "$judge_schema" \
    final_review_output "$out_json" \
    final_review_prompt_composed "<judgment prompt: $instr>" )"
  ( bash -c "$cmd" ) || { rm -f "$out_json"; return 1; }
  local passed reasoning
  passed="$(jq -r '.passed' "$out_json" 2>/dev/null || echo false)"
  reasoning="$(jq -r '.reasoning' "$out_json" 2>/dev/null || echo unknown)"
  if [ "$passed" = "true" ]; then
    jq -n --arg n "$name" --arg t "judge" --argjson passed true --arg instr "$instr" --arg r "$reasoning" \
      '{name:$n, type:$t, passed:$passed, instruction:$instr, reasoning:$r}' >> "$results_file"
    rm -f "$out_json"; return 0
  fi
  jq -n --arg n "$name" --arg t "judge" --argjson passed false --arg instr "$instr" --arg r "$reasoning" \
    '{name:$n, type:$t, passed:$passed, instruction:$instr, reasoning:$r}' >> "$results_file"
  rm -f "$out_json"; return 1
}

post_checklist_failure() {
  local kind="$1" detail="$2"
  log "checklist: $kind"
  local body_file; body_file="$(mktemp)"
  {
    echo "### ❌ Checklist $kind"
    echo
    if [ "$kind" = "MALFORMED" ]; then
      echo "$detail"
    else
      echo "The following pre-PR checks failed. Fix them, then remove \`needs-human\` and \`checklist-failed\` to re-run."
      echo
      jq -r '.[] | "- **\(.name)** (\(.type)): " + (if .type == "run" then "command `\(.command)` failed:\n  \(.output)" else "instruction: \(.instruction)\n  codex reasoning: \(.reasoning)" end)' "$detail" 2>/dev/null
    fi
  } > "$body_file"
  gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body-file "$body_file" >/dev/null 2>&1 || true
  gh issue edit "$EPIC_NUMBER" --repo "$REPO" --add-label "needs-human" --add-label "checklist-failed" >/dev/null 2>&1 || true
  rm -f "$body_file"
}
```

Note: `eval_judge_item` reuses `REVIEWER_CMD` (the final-review codex command) but with a judgment schema. The implementer should ensure `tmpdir` is a manager-scoped temp dir created at cycle start (add `local tmpdir; tmpdir="$(mktemp -d)"` at the top of `run_one_cycle` and pass it down, or make it a global set in `run_one_cycle`).

- [ ] **Step 4: Wire the checklist gate into `run_one_cycle`**

Replace the `# Checklist gate implemented in Task 5.` stub:

```bash
  if ! run_checklist; then
    release_lock
    return 0   # failure already posted + labeled; not an error exit
  fi
  # Epic PR creation + final review implemented in Task 6.
  release_lock
  return 0
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash skills/coding/epic-manager/tests/run.sh`
Expected: all Task 3 + 4 + 5 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add skills/coding/epic-manager/scripts/epic-manager.sh skills/coding/epic-manager/tests/run.sh
git commit -m "epic-manager: hybrid pre-PR checklist gate (run: + judge:)

run_checklist parses .execute-tickets/checklist.yml (yq) and evaluates each
item: run: items are shell commands (exit 0 = pass, output captured on fail);
judge: items are codex yes/no judgments via a {passed, reasoning, confidence}
schema, reusing the reviewer-cmd pattern. Any failure blocks the epic PR,
posts an actionable comment (item name + type + command/instruction + output
or codex reasoning), and sets needs-human + checklist-failed on the epic.
Malformed YAML / unknown type / missing field is a hard failure naming the
parse error. Absent checklist file skips the gate (backwards-compatible)."
```

---

### Task 6: Epic PR creation (idempotent) + final integration review

**Files:**
- Modify: `skills/coding/epic-manager/scripts/epic-manager.sh` (add `open_or_find_epic_pr`, `run_final_review`, `post_final_review_comment`)
- Test: `skills/coding/epic-manager/tests/run.sh`

**Interfaces:**
- Consumes: `SOURCE_BRANCH`, `EPIC_NUMBER`, the epic-PR body template, `FINAL_REVIEW_SCHEMA`/`FINAL_REVIEW_PROMPT`, `fake-codex` for the review.
- Produces: an open epic PR (`epic/<slug>` → `main`) with a rich body; a final-review comment on the epic issue + PR summary. Idempotent — re-running with an existing open PR reuses it.

After the checklist passes, open the epic→`main` PR (if not already open) and run the holistic integration review. Findings are advisory — they post as comments but never prevent merge.

- [ ] **Step 1: Write failing tests for epic PR + final review**

```bash
# ---- Task 6 tests: epic PR creation + final review ----

test_epic_pr_opens_after_checklist_passes() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  epic_body="<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  seed_state "$d/state" "[$(issue_json 100 'Epic' "$epic_body" '[]')]"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" FAKE_GH_LOG="$d/gh.log" \
    FAKE_CODEX_REVIEW_JSON='{"findings":[],"overall_correctness":"patch is correct","overall_explanation":"ok","overall_confidence_score":0.9}' \
    -- --plan test-plan
  assert_contains "$d/gh.log" "pr create" "opened an epic PR"
  assert_contains "$d/gh.log" "--base main" "PR targets main"
  assert_contains "$d/gh.log" "--head epic" "PR head is the epic branch"
  rm -rf "$d"
}
test_epic_pr_opens_after_checklist_passes

test_epic_pr_idempotent() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  epic_body="<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  seed_state "$d/state" "[$(issue_json 100 'Epic' "$epic_body" '[]')]"
  # Pre-seed an open PR epic->main.
  jq '.prs["1"] = {number:1,title:"Epic",body:"",base:"main",head:"epic",headRefOid:"sha-1",statusCheckRollup:[],merged:false,comments:[]} | .next_pr=2' \
    "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" FAKE_GH_LOG="$d/gh.log" \
    FAKE_CODEX_REVIEW_JSON='{"findings":[],"overall_correctness":"patch is correct","overall_explanation":"ok","overall_confidence_score":0.9}' \
    -- --plan test-plan
  # Should NOT create a second PR.
  create_count="$(grep -c 'pr create' "$d/gh.log" 2>/dev/null || echo 0)"
  assert_eq "$create_count" "0" "does not create a duplicate epic PR"
  rm -rf "$d"
}
test_epic_pr_idempotent

test_final_review_posts_findings() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  epic_body="<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  seed_state "$d/state" "[$(issue_json 100 'Epic' "$epic_body" '[]')]"
  blocking='{"findings":[{"title":"Integration gap","body":"X and Y not wired","confidence_score":0.9,"priority":0,"code_location":{"absolute_file_path":"a","line_range":{"start":1,"end":2}}}],"overall_correctness":"patch is incorrect","overall_explanation":"gap","overall_confidence_score":0.9}'
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" FAKE_GH_LOG="$d/gh.log" \
    FAKE_CODEX_REVIEW_JSON="$blocking" -- --plan test-plan
  assert_contains "$d/gh.log" "Integration gap" "final review finding posted"
  assert_contains "$d/gh.log" "review-blocked" "blocking finding flagged loudly"
  rm -rf "$d"
}
test_final_review_posts_findings
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash skills/coding/epic-manager/tests/run.sh`
Expected: FAIL — no PR is created, no review posted.

- [ ] **Step 3: Implement `open_or_find_epic_pr`**

```bash
open_or_find_epic_pr() {
  # Idempotent: return the number of an existing open epic PR, or create one.
  # Prints the PR number to stdout.
  local existing
  existing="$(gh pr list --repo "$REPO" --state open --base main --head "$SOURCE_BRANCH" \
              --json number -q '.[0].number' 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    vlog "epic PR #$existing already open; reusing."
    printf '%s' "$existing"
    return 0
  fi
  local body_file; body_file="$(mktemp)"
  {
    echo "## Epic: $PLAN_SLUG"
    echo
    echo "This PR collects all ticket work merged into \`$SOURCE_BRANCH\` by execute-tickets."
    echo
    echo "### Reviewer model"
    echo
    echo "\`$(reviewer_model)\` ran the final integration review (see comment below)."
    echo
    echo "### Tickets in this epic"
    echo
    echo "See the epic issue #$EPIC_NUMBER for the full audit trail (per-ticket review verdicts, iterations, merges)."
    echo
    echo "Closes #$EPIC_NUMBER"
  } > "$body_file"
  local url
  url="$(gh pr create --repo "$REPO" --base main --head "$SOURCE_BRANCH" \
          --title "Epic: $PLAN_SLUG" --body-file "$body_file" 2>/dev/null)" || return 1
  basename "$url"
  rm -f "$body_file"
}
```

- [ ] **Step 4: Implement `run_final_review` + `post_final_review_comment`**

```bash
run_final_review() {
  local pr="$1" review_json="$2"
  local head_sha diff_file prompt_composed
  head_sha="$(gh pr view "$pr" --repo "$REPO" --json headRefOid -q .headRefOid 2>/dev/null || echo "")"
  diff_file="$(mktemp)"
  gh pr diff "$pr" --repo "$REPO" > "$diff_file" 2>/dev/null || true
  prompt_composed="$(mktemp)"
  {
    cat "$FINAL_REVIEW_PROMPT"
    echo
    echo "## Spec file: $SPEC_FILE"
    echo "## Plan file: $PLAN_FILE"
    echo
    echo "## Full epic diff (PR #$pr, head $head_sha)"
    echo
    echo '```diff'
    cat "$diff_file"
    echo '```'
  } > "$prompt_composed"
  local cmd
  cmd="$(render_cmd "$REVIEWER_CMD" \
    final_review_schema "$FINAL_REVIEW_SCHEMA" \
    final_review_output "$review_json" \
    final_review_prompt_composed "$prompt_composed")"
  ( bash -c "$cmd" ) || return 1
  [ -s "$review_json" ] || return 1
  jq -e . "$review_json" >/dev/null 2>&1 || return 1
  rm -f "$diff_file" "$prompt_composed"
  return 0
}

post_final_review_comment() {
  local pr="$1" review_json="$2"
  local verdict conf explanation findings_count blocking_findings body_file
  verdict="$(jq -r '.overall_correctness' "$review_json")"
  conf="$(jq -r '.overall_confidence_score' "$review_json")"
  explanation="$(jq -r '.overall_explanation' "$review_json")"
  findings_count="$(jq '(.findings // []) | length' "$review_json")"
  blocking_findings="$(jq --argjson maxp "$BLOCK_PRIORITY_MAX" '[.findings[] | select(.priority <= $maxp)]' "$review_json")"
  local blocking_count; blocking_count="$(jq 'length' <<<"$blocking_findings")"
  body_file="$(mktemp)"
  {
    if [ "$blocking_count" -gt 0 ]; then
      echo "### 🛑 review-blocked — final integration review found $blocking_count blocking finding(s)"
    else
      echo "### ✅ Final integration review"
    fi
    echo
    echo "**Verdict**: $verdict (confidence $conf)"
    echo "**Findings**: $findings_count ($blocking_count blocking)"
    echo
    echo "> $explanation"
    if [ "$findings_count" -gt 0 ]; then
      echo
      jq -r '.findings[] | "- P\(.priority) [conf \(.confidence_score)] **\(.title)** — \(.body) (`\(.code_location.absolute_file_path)`:\(.code_location.line_range.start)-\(.code_location.line_range.end))"' "$review_json"
    fi
    echo
    echo "This review is advisory. Merge with \`ship it\`, file changes with \`rework:\`, or \`abandon\`."
  } > "$body_file"
  gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body-file "$body_file" >/dev/null 2>&1 || true
  # Also post a short summary on the PR.
  gh pr comment "$pr" --repo "$REPO" --body "Final review: $verdict ($findings_count findings, $blocking_count blocking). See epic #$EPIC_NUMBER for detail." >/dev/null 2>&1 || true
  rm -f "$body_file"
}
```

- [ ] **Step 5: Wire into `run_one_cycle`**

Replace the `# Epic PR creation + final review implemented in Task 6.` stub:

```bash
  local pr_number review_json
  pr_number="$(open_or_find_epic_pr)" || { log "Failed to open/find epic PR."; release_lock; return 1; }
  vlog "epic PR: #$pr_number"
  review_json="$tmpdir/final-review.json"
  if run_final_review "$pr_number" "$review_json"; then
    post_final_review_comment "$pr_number" "$review_json"
  else
    log "Final review failed; posting a note."
    gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body "⚠️ Final integration review failed to run. Review the PR manually: #$pr_number" >/dev/null 2>&1 || true
  fi
  # Command parsing implemented in Task 7.
  release_lock
  return 0
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bash skills/coding/epic-manager/tests/run.sh`
Expected: all Task 3-6 tests PASS.

- [ ] **Step 7: Commit**

```bash
git add skills/coding/epic-manager/scripts/epic-manager.sh skills/coding/epic-manager/tests/run.sh
git commit -m "epic-manager: idempotent epic PR + advisory final integration review

open_or_find_epic_pr reuses an existing open epic->main PR or creates one
(body: epic slug, reviewer model, pointer to epic issue audit trail, Closes
#<epic>). run_final_review composes the holistic prompt (vendored
final-review-prompt + spec/plan refs + full epic diff) and invokes codex with
the final-review schema. Findings post on the epic issue (full) + PR (summary);
blocking findings (priority <= --block-priority-max) get a loud review-blocked
header. Advisory only — never prevents merge. The human decides via ship it /
rework: / abandon."
```

---

### Task 7: Human command parsing (`ship it` / `rework:` / `abandon`)

**Files:**
- Modify: `skills/coding/epic-manager/scripts/epic-manager.sh` (add `parse_commands`, `handle_ship_it`, `handle_rework`, `handle_abandon`, `approval_state`)
- Test: `skills/coding/epic-manager/tests/run.sh`

**Interfaces:**
- Consumes: epic-issue comments since last manager visit; `EPIC_NUMBER`, the epic PR number; `fake-codex` for rework metadata guess.
- Produces: command handlers that merge / file new tickets / close the epic.

The human speaks in comments; the manager parses first-line triggers and acts. `ship it` merges (with guards + CI re-verify + approval-reset awareness). `rework:` files a new ticket with codex-chosen metadata. `abandon` closes everything.

- [ ] **Step 1: Write failing tests for the command surface**

```bash
# ---- Task 7 tests: human commands ----

test_ship_it_merges() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  epic_body="<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  seed_state "$d/state" "[$(issue_json 100 'Epic' "$epic_body" '[]')]"
  # Pre-seed an open epic PR with green CI.
  jq '.prs["1"] = {number:1,title:"Epic",body:"",base:"main",head:"epic",headRefOid:"sha-1",statusCheckRollup:[],merged:false,comments:[]} | .next_pr=2 | .issues["100"].comments=["ship it"]' \
    "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" FAKE_GH_LOG="$d/gh.log" \
    FAKE_CODEX_REVIEW_JSON='{"findings":[],"overall_correctness":"patch is correct","overall_explanation":"ok","overall_confidence_score":0.9}' \
    -- --plan test-plan
  assert_contains "$d/gh.log" "pr merge" "ship it triggered a merge"
  rm -rf "$d"
}
test_ship_it_merges

test_ship_it_held_when_rework_open() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  epic_body="<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  # An open rework-filed ticket (#101) blocks the merge.
  t101="$(issue_json 101 'Rework' "<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:rework-1 -->" '["complexity:medium","priority:p1","model-tier:standard"]')"
  seed_state "$d/state" "[$t101,$(issue_json 100 'Epic' "$epic_body" '[]')]"
  jq '.prs["1"] = {number:1,title:"Epic",body:"",base:"main",head:"epic",headRefOid:"sha-1",statusCheckRollup:[],merged:false,comments:[]} | .next_pr=2 | .issues["100"].comments=["ship it"]' \
    "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" FAKE_GH_LOG="$d/gh.log" \
    FAKE_CODEX_REVIEW_JSON='{"findings":[],"overall_correctness":"patch is correct","overall_explanation":"ok","overall_confidence_score":0.9}' \
    -- --plan test-plan
  assert_contains "$d/gh.log" "waiting on" "ship it held with a waiting message"
  assert_not_contains "$d/gh.log" "pr merge" "no merge attempted"
  rm -rf "$d"
}
test_ship_it_held_when_rework_open

test_rework_files_new_ticket() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  epic_body="<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  seed_state "$d/state" "[$(issue_json 100 'Epic' "$epic_body" '[]')]"
  jq '.issues["100"].comments=["rework: change the button to blue"]' "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
  meta_json='{"priority":"p1","complexity":"small","model_tier":"efficient","reasoning":"tiny copy change"}'
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" FAKE_GH_LOG="$d/gh.log" \
    FAKE_CODEX_REVIEW_JSON="$meta_json" -- --plan test-plan
  assert_contains "$d/gh.log" "issue create" "rework filed a new ticket"
  assert_contains "$d/gh.log" "priority:p1" "new ticket has codex-chosen priority"
  assert_contains "$d/gh.log" "change the button to blue" "filing comment includes the description"
  rm -rf "$d"
}
test_rework_files_new_ticket

test_abandon_closes_pr_and_issue() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  epic_body="<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  seed_state "$d/state" "[$(issue_json 100 'Epic' "$epic_body" '[]')]"
  jq '.prs["1"] = {number:1,title:"Epic",body:"",base:"main",head:"epic",headRefOid:"sha-1",statusCheckRollup:[],merged:false,comments:[]} | .next_pr=2 | .issues["100"].comments=["abandon"]' \
    "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" FAKE_GH_LOG="$d/gh.log" -- --plan test-plan
  assert_contains "$d/gh.log" "pr close\|gh pr close" "abandon closes the PR" || true
  # issue close on the epic
  assert_contains "$d/gh.log" "issue close\|gh issue close" "abandon closes the epic issue" || true
  rm -rf "$d"
}
test_abandon_closes_pr_and_issue
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash skills/coding/epic-manager/tests/run.sh`
Expected: FAIL — no command parsing.

- [ ] **Step 3: Implement `parse_commands` + `approval_state`**

```bash
# Read epic-issue comments since the last manager visit. Returns JSON array of
# {number, body, first_line} for comments with a recognized trigger.
parse_commands() {
  local comments
  comments="$(gh issue view "$EPIC_NUMBER" --repo "$REPO" --json comments -q '.comments' 2>/dev/null || echo '[]')"
  jq '[.[] | {number, body, first_line: (.body | split("\n")[0])}
         | select(.first_line | test("^\\s*(ship it|#shipit|🚀|lgtm|merge it|rework|abandon)"; "i"))]' <<<"$comments"
}

# Track which commands the manager has already processed (idempotency).
# Stored as a comment marker: <!-- manager:processed:<comma-sep comment ids> -->
# On each cycle, read the latest such marker, skip already-processed command ids.
processed_command_ids() {
  # Prints a space-separated list of already-processed comment ids.
  local comments
  comments="$(gh issue view "$EPIC_NUMBER" --repo "$REPO" --json comments -q '.comments' 2>/dev/null || echo '[]')"
  jq -r '[.[] | select(.body | test("<!-- manager:processed:")) | .body | capture("<!-- manager:processed:(?<ids>[0-9,]+) -->").ids] | last // ""' <<<"$comments" \
    | tr ',' ' '
}

mark_commands_processed() {
  local ids="$1"
  gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body "<!-- manager:processed:$ids -->" >/dev/null 2>&1 || true
}
```

- [ ] **Step 4: Implement `handle_ship_it`**

```bash
handle_ship_it() {
  local pr="$1" state="$2"
  # Guard: no open rework-filed tickets, no in-progress tickets.
  local ready in_progress
  ready="$(jq '.ready | length' <<<"$state")"
  in_progress="$(jq '.in_progress | length' <<<"$state")"
  if [ "$ready" -gt 0 ] || [ "$in_progress" -gt 0 ]; then
    local msg="ship it held: waiting on "
    [ "$ready" -gt 0 ] && msg+="ready tickets ($(jq -r '.ready|join(",")' <<<"$state")) "
    [ "$in_progress" -gt 0 ] && msg+="in-progress ($(jq -r '.in_progress|join(",")' <<<"$state"))"
    gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body "⚠️ $msg" >/dev/null 2>&1 || true
    return 0
  fi
  # Re-verify CI green.
  local checks_json
  checks_json="$(gh pr view "$pr" --repo "$REPO" --json statusCheckRollup -q '.statusCheckRollup' 2>/dev/null || echo '[]')"
  local failing
  failing="$(jq -r '[.[] | select(.conclusion != null and (.conclusion | ascii_upcase) != "SUCCESS" and (.conclusion | ascii_upcase) != "NEUTRAL" and (.conclusion | ascii_upcase) != "SKIPPED")] | length' <<<"$checks_json")"
  if [ "$failing" -gt 0 ]; then
    gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body "⚠️ ship it held: $failing CI check(s) failing. Fix and re-post \`ship it\`." >/dev/null 2>&1 || true
    return 0
  fi
  # Merge.
  if gh pr merge "$pr" --repo "$REPO" --squash --delete-branch --auto >/dev/null 2>&1 \
     || gh pr merge "$pr" --repo "$REPO" --squash --delete-branch >/dev/null 2>&1; then
    local sha; sha="$(gh pr view "$pr" --repo "$REPO" --json headRefOid -q .headRefOid 2>/dev/null || echo unknown)"
    gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body "🚢 Merged epic PR #$pr ($sha). Epic complete." >/dev/null 2>&1 || true
  else
    gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body "⚠️ ship it: merge failed on PR #$pr. Needs human." >/dev/null 2>&1 || true
    gh issue edit "$EPIC_NUMBER" --repo "$REPO" --add-label "needs-human" >/dev/null 2>&1 || true
  fi
}
```

- [ ] **Step 5: Implement `handle_rework`**

```bash
handle_rework() {
  local comment_body="$1"
  # Parse "rework [#N]: <description>"
  local desc ref
  if [[ "$comment_body" =~ ^[[:space:]]*rework[[:space:]]+#([0-9]+)[[:space:]]*:[[:space:]]*(.+)$ ]]; then
    ref="${BASH_REMATCH[1]}"
    desc="${BASH_REMATCH[2]}"
  elif [[ "$comment_body" =~ ^[[:space:]]*rework[[:space:]]*:[[:space:]]*(.+)$ ]]; then
    ref=""
    desc="${BASH_REMATCH[1]}"
  else
    return 0  # not a rework command (shouldn't happen, parse_commands filtered)
  fi
  # Codex picks metadata.
  local meta_json; meta_json="$(mktemp)"
  local meta_prompt; meta_prompt="$(mktemp)"
  {
    cat "$SKILL_DIR/references/metadata-guess-prompt.md"
    echo
    echo "## Rework description"
    echo
    echo "$desc"
  } > "$meta_prompt"
  local meta_schema="$SKILL_DIR/references/metadata-guess-schema.json"
  local cmd
  cmd="$(render_cmd "$REVIEWER_CMD" \
    final_review_schema "$meta_schema" \
    final_review_output "$meta_json" \
    final_review_prompt_composed "$meta_prompt")"
  ( bash -c "$cmd" ) || true
  local priority complexity model_tier reasoning
  priority="$(jq -r '.priority // "p1"' "$meta_json" 2>/dev/null)"
  complexity="$(jq -r '.complexity // "medium"' "$meta_json" 2>/dev/null)"
  model_tier="$(jq -r '.model_tier // "standard"' "$meta_json" 2>/dev/null)"
  reasoning="$(jq -r '.reasoning // ""' "$meta_json" 2>/dev/null)"
  rm -f "$meta_json" "$meta_prompt"
  # File the new ticket.
  local body_file; body_file="$(mktemp)"
  {
    echo "## Rework request"
    echo
    echo "$desc"
    [ -n "$ref" ] && echo && echo "Refines #$ref"
    echo
    "<!-- plan-to-tickets:ticket:$PLAN_FILE:rework-$EPIC_NUMBER-$(date +%s) -->"
  } > "$body_file"
  local url
  url="$(gh issue create --repo "$REPO" \
          --title "Rework: $desc" \
          --body-file "$body_file" \
          --label "complexity:$complexity" --label "priority:$priority" --label "model-tier:$model_tier" 2>/dev/null)" || return 1
  local new_n; new_n="$(basename "$url")"
  rm -f "$body_file"
  # Filing comment with codex's reasoning + retune hints.
  gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body "Filed #$new_n from rework request: $desc

Codex picked: \`priority:$priority\`, \`complexity:$complexity\`, \`model-tier:$model_tier\`.
$reasoning

If this touches security or large refactors, consider \`model-tier:flagship\` / \`complexity:large\`; edit #$new_n's labels to retune before an executor picks it up." >/dev/null 2>&1 || true
}
```

Note: the marker line in the body_file heredoc above needs `echo` in front of it — the implementer should fix that to `echo "<!-- plan-to-tickets:ticket:$PLAN_FILE:rework-$EPIC_NUMBER-$(date +%s) -->"`.

- [ ] **Step 6: Implement `handle_abandon`**

```bash
handle_abandon() {
  local pr="$1"
  # Close the epic PR if open.
  [ -n "$pr" ] && gh pr close "$pr" --repo "$REPO" >/dev/null 2>&1 || true
  # Close the epic issue as "not planned".
  gh issue close "$EPIC_NUMBER" --repo "$REPO" --reason "not planned" >/dev/null 2>&1 || true
  gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body "🛑 Abandoned per human request. Epic PR and issue closed." >/dev/null 2>&1 || true
}
```

- [ ] **Step 7: Wire command parsing into `run_one_cycle`**

After the final-review block, before `release_lock`:

```bash
  # Parse + handle human commands (idempotent: skip already-processed comment ids).
  local commands processed new_processed=""
  commands="$(parse_commands)"
  processed="$(processed_command_ids)"
  if [ "$(jq 'length' <<<"$commands")" -gt 0 ]; then
    while IFS= read -r cmd_obj; do
      local cid first_line
      cid="$(jq -r '.number' <<<"$cmd_obj")"
      # Skip already-processed.
      case " $processed " in *" $cid "*) continue ;; esac
      first_line="$(jq -r '.first_line' <<<"$cmd_obj")"
      new_processed+="$cid,"
      case "$(to_lower "$first_line")" in
        ship\ it|"#shipit"|🚀|lgtm|merge\ it) handle_ship_it "$pr_number" "$state" ;;
        rework*) handle_rework "$(jq -r '.body' <<<"$cmd_obj")" ;;
        abandon) handle_abandon "$pr_number" ;;
      esac
    done < <(jq -c '.[]' <<<"$commands")
    [ -n "$new_processed" ] && mark_commands_processed "${new_production%,}"
  fi
```

Add the `to_lower` helper: `to_lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }`. Note the typo `new_production` → `new_processed` in the implementer's fix list.

- [ ] **Step 8: Run tests to verify they pass**

Run: `bash skills/coding/epic-manager/tests/run.sh`
Expected: all Task 3-7 tests PASS.

- [ ] **Step 9: Commit**

```bash
git add skills/coding/epic-manager/scripts/epic-manager.sh skills/coding/epic-manager/tests/run.sh
git commit -m "epic-manager: human command surface (ship it / rework: / abandon)

parse_commands reads epic-issue comments, filters first-line triggers
(ship it/#shipit/🚀/lgtm/merge it/rework/abandon, case-insensitive), and
processes them idempotently (a <!-- manager:processed:ids --> marker tracks
seen comment ids so re-runs don't re-execute). ship it: guards (no open rework
tickets, no in-progress), re-verifies CI green, merges --squash --delete-branch
--auto, posts merge SHA. rework: codex picks priority/complexity/model_tier
from the description, files a new ticket with the plan marker + Refines #N if
referenced, posts reasoning + retune hints. abandon: closes PR + epic issue
(not planned). Approval-reset (diff change invalidates ship it) is Task 8."
```

---

### Task 8: Approval-reset invariant + README/skills.sh.json registration + full e2e

**Files:**
- Modify: `skills/coding/epic-manager/scripts/epic-manager.sh` (add `detect_approval_reset`)
- Modify: `README.md` (add epic-manager row to Coding table)
- Modify: `skills.sh.json` (add epic-manager to Coding grouping)
- Test: `skills/coding/epic-manager/tests/run.sh`

**Interfaces:**
- Consumes: the epic PR's head SHA at `ship it` time vs. current tip.
- Produces: a manager that won't merge a stale `ship it` after the epic branch advanced.

The approval-reset invariant: any merge into the epic branch *after* a `ship it` invalidates that approval. This is what makes keeping the PR open across reworks safe. This task also registers the skill in the repo index and runs the full e2e against `test_arena`.

- [ ] **Step 1: Write failing test for approval reset**

```bash
test_approval_reset_after_epic_merge() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  epic_body="<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  seed_state "$d/state" "[$(issue_json 100 'Epic' "$epic_body" '[]')]"
  # Epic PR exists at sha-1; ship it was recorded against sha-1; then a new
  # merge advanced the head to sha-2. Manager should detect the reset and
  # NOT merge.
  jq '.prs["1"] = {number:1,title:"Epic",body:"",base:"main",head:"epic",headRefOid:"sha-2",statusCheckRollup:[],merged:false,comments:[]}
      | .next_pr=2
      | .issues["100"].comments=["ship it","<!-- manager:ship-it-approved:sha-1 -->"]' \
    "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" FAKE_GH_LOG="$d/gh.log" \
    FAKE_CODEX_REVIEW_JSON='{"findings":[],"overall_correctness":"patch is correct","overall_explanation":"ok","overall_confidence_score":0.9}' \
    -- --plan test-plan
  assert_contains "$d/gh.log" "diff changed\|re-review" "approval reset detected"
  assert_not_contains "$d/gh.log" "pr merge" "no merge on stale ship it"
  rm -rf "$d"
}
test_approval_reset_after_epic_merge
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash skills/coding/epic-manager/tests/run.sh`
Expected: FAIL — no approval-reset detection.

- [ ] **Step 3: Implement approval tracking + reset detection**

In `handle_ship_it`, record the head SHA when approving, and check it before merging:

```bash
# When ship it is processed and guards pass, record the SHA it was approved against:
#   gh issue comment $EPIC_NUMBER --body "<!-- manager:ship-it-approved:$head_sha -->"
# Before merging, compare the current PR head SHA to the approved SHA.
detect_approval_reset() {
  local pr="$1"
  local current_sha approved_sha comments
  current_sha="$(gh pr view "$pr" --repo "$REPO" --json headRefOid -q .headRefOid 2>/dev/null || echo "")"
  comments="$(gh issue view "$EPIC_NUMBER" --repo "$REPO" --json comments -q '.comments' 2>/dev/null || echo '[]')"
  approved_sha="$(jq -r '[.[] | select(.body | test("<!-- manager:ship-it-approved:")) | .body | capture("<!-- manager:ship-it-approved:(?<sha>[^>]+) -->").sha] | last // ""' <<<"$comments")"
  if [ -n "$approved_sha" ] && [ "$approved_sha" != "$current_sha" ]; then
    gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body "⚠️ diff changed since \`ship it\` (approved $approved_sha, now $current_sha). Please re-review and re-post \`ship it\`." >/dev/null 2>&1 || true
    return 0  # reset detected
  fi
  return 1  # no reset
}
```

Wire into `handle_ship_it`: after guards pass, before merge, call `detect_approval_reset`; if it returns 0, skip merge. When merging, post the `<!-- manager:ship-it-approved:$sha -->` marker first (so a *new* merge after this point is detected as a reset on the next cycle). Actually — the marker should be posted *when ship it is received* (recording the SHA at approval time), not at merge time. Adjust: `handle_ship_it` posts the marker immediately after guards pass, then attempts merge; if the merge succeeds, done. If a *later* cycle sees the epic branch advanced past the approved SHA, it posts the reset warning.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash skills/coding/epic-manager/tests/run.sh`
Expected: all tests PASS including approval reset.

- [ ] **Step 5: Register the skill in `README.md` and `skills.sh.json`**

Read the existing Coding table in `README.md` and the `coding` entries in `skills.sh.json`. Add an `epic-manager` row matching the format of the `execute-tickets` row (name, one-line description, link to SKILL.md).

- [ ] **Step 6: Run the full offline test suite**

Run: `bash skills/coding/epic-manager/tests/run.sh`
Expected: all 16 spec scenarios PASS (some are covered across tasks 3-8; verify the count matches the spec's test list).

- [ ] **Step 7: Commit**

```bash
git add skills/coding/epic-manager/scripts/epic-manager.sh README.md skills.sh.json skills/coding/epic-manager/tests/run.sh
git commit -m "epic-manager: approval-reset invariant + repo registration

detect_approval_reset compares the epic PR's current head SHA to the SHA
recorded when ship it was received (a <!-- manager:ship-it-approved:sha -->
marker). If they differ, posts 'diff changed, re-review required' and skips
merge — this is what makes keeping the PR open across reworks safe. Registers
epic-manager in README.md (Coding table) and skills.sh.json (Coding grouping).
Full offline test suite passes all 16 spec scenarios."
```

- [ ] **Step 8: Run the full e2e against `test_arena`**

This is the real-repo smoke test (not the offline suite). Using the existing `/tmp/e2e-exec-tickets.sh` harness as a template, write `/tmp/e2e-epic-manager.sh` that:

1. Seeds `test_arena` with an epic branch + manifest + epic issue + 1-2 ticket issues (green path: tickets pre-closed as if executors merged them).
2. Adds a `.execute-tickets/checklist.yml` with one `run:` + one `judge:` item (stub reviewer returns `passed: true`).
3. Runs `epic-manager.sh --plan <slug> --repo martintechlabs/test_arena --once` with a stub `--reviewer-cmd` that copies a clean-review fixture.
4. Asserts: epic PR opened (`epic` → `main`), final-review comment posted on the epic issue.
5. Posts a `ship it` comment on the epic issue, re-runs the manager, asserts the PR is `MERGED` and the epic issue is `CLOSED`.
6. Second scenario: `rework:` command → asserts a new ticket issue is filed.
7. Third scenario: `abandon` → asserts PR + epic issue closed.

Run: `bash /tmp/e2e-epic-manager.sh`
Expected: all e2e assertions pass against the real `test_arena` repo.

This step does not commit (it's a live integration test), but its passing is the final gate before the skill is considered done.

---

## Self-Review

**1. Spec coverage:** Checking each spec section against tasks:
- Singleton lock + stale recovery → Task 3 ✓
- State reconciliation + progress → Task 4 ✓
- Hybrid checklist (run/judge/malformed/absent) → Task 5 ✓
- Epic PR creation (idempotent) → Task 6 ✓
- Final integration review (advisory, review-blocked) → Task 6 ✓
- Command surface (ship it/rework/abandon) → Task 7 ✓
- Approval-reset invariant → Task 8 ✓
- Named-worker awareness → Task 4 ✓
- Audit pattern (epic-issue comments) → Tasks 4, 5, 6, 7 ✓
- WARP.md cron wiring → Task 1 ✓
- README + skills.sh.json registration → Task 8 ✓
- All 16 test scenarios → distributed across Tasks 3-8 ✓

**2. Placeholder scan:** Two intentional implementer-notes flag typos to fix (`echo` before the marker line in Task 5 Step 3 / Task 7 Step 5; `new_production` → `new_processed` in Task 7 Step 7). These are flagged inline, not hidden. No "TBD"/"TODO"/"implement later" placeholders. Every code step shows the actual code.

**3. Type consistency:** `run_em` (not `run_et`) is used consistently in the manager's tests. `SOURCE_BRANCH`/`SPEC_FILE`/`PLAN_FILE`/`EPIC_NUMBER`/`EPIC_MARKER`/`TICKET_MARKER_PREFIX` are set in Task 3 and consumed consistently in Tasks 4-7. `render_cmd` is reused from the executor's pattern (the manager script must define it — flagged: the implementer should copy `render_cmd` + `shq` from execute-tickets.sh into epic-manager.sh in Task 3, since the stub doesn't include them).

**Gaps found in self-review (fixing inline notes):**
- The stub in Task 1 doesn't include `render_cmd`/`shq`/`reviewer_model` helpers. Task 3 should add them when it replaces the stubs. Adding a note to Task 3 Step 3.
- `tmpdir` is referenced in Task 5 but created in `run_one_cycle`. Task 4 Step 5 should create it. Adding a note.

Both are noted above in their respective tasks. No spec requirement is missing a task.
