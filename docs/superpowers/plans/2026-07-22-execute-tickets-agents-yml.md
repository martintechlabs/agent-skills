# execute-tickets agents.yml routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `execute-tickets.sh` resolve each ticket's coding agent from repo-local `.execute-tickets/agents.yml` (keyed by model tier), with optional `--agent-cmd` override, plus an independent `init-agents.sh` that scaffolds Claude defaults.

**Architecture:** Vendored `references/agents.example.yml` is the single source of truth for Claude-default command strings. `init-agents.sh` copies it into `<repo>/.execute-tickets/agents.yml`. `execute-tickets.sh` loads that file with `yq` when `--agent-cmd` is omitted, requires all four tiers at preflight, and selects by the ticket's `model-tier` label. When `--agent-cmd` is set, YAML is skipped entirely (flag wins for every ticket in the process).

**Tech Stack:** Bash, `yq` (mikefarah v4 CLI: `yq -r '.key' file`), existing offline harness (`tests/lib.sh`, `fake-gh`, `fake-codex`, new `fake-yq`), Claude Code CLI only in the example template.

**Spec:** `docs/superpowers/specs/2026-07-22-execute-tickets-agents-yml-design.md`

## Global Constraints

- Routing keys are only `lite` / `efficient` / `standard` / `flagship` (model tiers), never complexity.
- Each tier value is an opaque shell command string; same `{token}` set as today's `--agent-cmd`.
- When `--agent-cmd` is set, `agents.yml` is not required and is not loaded.
- When `--agent-cmd` is not set, all four YAML keys must be non-empty strings at preflight or the process exits before claiming.
- `init-agents.sh` must not read/write `checklist.yml`.
- Do not invent a pure-bash YAML parser; use `yq`.
- Pin `yq` invocations to mikefarah syntax: `yq -r '.lite // ""' "$file"`.

## File map

| Path | Role |
|------|------|
| `skills/coding/execute-tickets/references/agents.example.yml` | Claude-default template (init source of truth) |
| `skills/coding/execute-tickets/scripts/init-agents.sh` | Independent scaffolder |
| `skills/coding/execute-tickets/scripts/execute-tickets.sh` | Optional `--agent-cmd`; load/select/audit |
| `skills/coding/execute-tickets/tests/fake-yq` | Minimal `yq -r '.key' file` for offline tests |
| `skills/coding/execute-tickets/tests/lib.sh` | Install fake-yq; helper to write fixture agents.yml |
| `skills/coding/execute-tickets/tests/run.sh` | New tests for init + routing |
| `skills/coding/execute-tickets/SKILL.md` | Document config, init, override |
| `skills/coding/execute-tickets/references/warp-setup.md` | Point at agents.yml / init |

---

### Task 1: Example template + `init-agents.sh` (TDD)

**Files:**
- Create: `skills/coding/execute-tickets/references/agents.example.yml`
- Create: `skills/coding/execute-tickets/scripts/init-agents.sh`
- Modify: `skills/coding/execute-tickets/tests/lib.sh`
- Modify: `skills/coding/execute-tickets/tests/run.sh`

**Interfaces:**
- Consumes: nothing from later tasks
- Produces: `init-agents.sh` CLI flags `--repo-root`, `--force`, `--dry-run`, `--help`; exit 0 on success; exit non-zero on refuse-overwrite / missing template; writes exactly the bytes of `agents.example.yml`

- [ ] **Step 1: Add `write_agents_yml` helper and init test stubs that fail**

Append to `skills/coding/execute-tickets/tests/lib.sh`:

```bash
# write_agents_yml <repo_work_dir> [lite_cmd] [efficient_cmd] [standard_cmd] [flagship_cmd]
# Writes <repo_work_dir>/.execute-tickets/agents.yml with four non-empty tier commands.
# Defaults are echo-based commands that leave a marker file per tier for assertions.
write_agents_yml() {
  local root="$1"
  local lite="${2:-echo lite > agent-tier.txt}"
  local efficient="${3:-echo efficient > agent-tier.txt}"
  local standard="${4:-echo standard > agent-tier.txt}"
  local flagship="${5:-echo flagship > agent-tier.txt}"
  mkdir -p "$root/.execute-tickets"
  # YAML double-quoted strings; escape backslash and double-quote in commands.
  yaml_dq() { printf '"' ; printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' ; printf '"' ; }
  {
    printf 'lite: %s\n' "$(yaml_dq "$lite")"
    printf 'efficient: %s\n' "$(yaml_dq "$efficient")"
    printf 'standard: %s\n' "$(yaml_dq "$standard")"
    printf 'flagship: %s\n' "$(yaml_dq "$flagship")"
  } > "$root/.execute-tickets/agents.yml"
}
```

Append these tests to the end of `skills/coding/execute-tickets/tests/run.sh`:

```bash
# --- init-agents.sh scaffolds .execute-tickets/agents.yml from the vendored
# Claude template, refuses overwrite without --force, and never touches checklist.yml.
INIT_SCRIPT="$HERE/../scripts/init-agents.sh"

test_init_agents_writes_file() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  bash "$INIT_SCRIPT" --repo-root "$d/work"
  assert_eq "$?" "0" "init-agents exits 0"
  [ -f "$d/work/.execute-tickets/agents.yml" ] && ok "agents.yml created" || bad "agents.yml created" "missing file"
  assert_file_contains "$d/work/.execute-tickets/agents.yml" "lite:" "template has lite key"
  assert_file_contains "$d/work/.execute-tickets/agents.yml" "efficient:" "template has efficient key"
  assert_file_contains "$d/work/.execute-tickets/agents.yml" "standard:" "template has standard key"
  assert_file_contains "$d/work/.execute-tickets/agents.yml" "flagship:" "template has flagship key"
  assert_file_contains "$d/work/.execute-tickets/agents.yml" "claude" "Claude defaults mention claude CLI"
  [ ! -f "$d/work/.execute-tickets/checklist.yml" ] && ok "does not create checklist.yml" || bad "does not create checklist.yml" "checklist was created"
  rm -rf "$d"
}

test_init_agents_writes_file

test_init_agents_refuses_overwrite_without_force() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  mkdir -p "$d/work/.execute-tickets"
  echo "lite: keep-me" > "$d/work/.execute-tickets/agents.yml"
  bash "$INIT_SCRIPT" --repo-root "$d/work" >"$d/out" 2>"$d/err"
  assert_eq "$?" "1" "second init without --force exits 1"
  assert_file_contains "$d/err" "--force" "error mentions --force"
  assert_file_contains "$d/work/.execute-tickets/agents.yml" "keep-me" "existing file left intact"
  rm -rf "$d"
}

test_init_agents_refuses_overwrite_without_force

test_init_agents_force_overwrites() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  mkdir -p "$d/work/.execute-tickets"
  echo "lite: old" > "$d/work/.execute-tickets/agents.yml"
  bash "$INIT_SCRIPT" --repo-root "$d/work" --force >"$d/out" 2>"$d/err"
  assert_eq "$?" "0" "--force init exits 0"
  assert_file_contains "$d/work/.execute-tickets/agents.yml" "flagship:" "overwritten with full template"
  assert_not_contains "$(cat "$d/work/.execute-tickets/agents.yml")" "lite: old" "old content replaced"
  rm -rf "$d"
}

test_init_agents_force_overwrites

test_init_agents_dry_run_writes_nothing() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  bash "$INIT_SCRIPT" --repo-root "$d/work" --dry-run >"$d/out" 2>"$d/err"
  assert_eq "$?" "0" "dry-run exits 0"
  [ ! -f "$d/work/.execute-tickets/agents.yml" ] && ok "dry-run does not write agents.yml" || bad "dry-run does not write agents.yml" "file was written"
  assert_file_contains "$d/out" "lite:" "dry-run prints template to stdout"
  rm -rf "$d"
}

test_init_agents_dry_run_writes_nothing

test_init_agents_preserves_existing_checklist() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  mkdir -p "$d/work/.execute-tickets"
  echo "checklist: true" > "$d/work/.execute-tickets/checklist.yml"
  bash "$INIT_SCRIPT" --repo-root "$d/work"
  assert_eq "$?" "0" "init exits 0 beside checklist"
  assert_file_contains "$d/work/.execute-tickets/checklist.yml" "checklist: true" "checklist.yml untouched"
  rm -rf "$d"
}

test_init_agents_preserves_existing_checklist
```

- [ ] **Step 2: Run init tests — expect FAIL (script/template missing)**

```bash
bash skills/coding/execute-tickets/tests/run.sh 2>&1 | tail -40
```

Expected: FAIL on `test_init_agents_writes_file` (script not found / agents.yml not created).

- [ ] **Step 3: Create `references/agents.example.yml`**

Create `skills/coding/execute-tickets/references/agents.example.yml` with this exact content (Claude Code CLI flags from `claude --help`: `-p/--print`, `--model`, `--permission-mode`). Tokens use `{name}` only — never `#{issue_number}` (render_cmd shell-quotes values, so `#` + quoted number would start a shell comment).

```yaml
# .execute-tickets/agents.yml — per model-tier coding agent commands for execute-tickets.
# Each value is a shell command run from the ticket worktree.
# Tokens (shell-quoted by the executor): {issue_number} {issue_title} {issue_body}
#   {spec_file} {plan_file} {model_tier} {complexity} {priority}
#   {worktree} {branch} {review_feedback} {iteration}
# Agent must commit on {branch} and must NOT open a PR.
# Edit model aliases for your org. Scaffold with: scripts/init-agents.sh

lite: >
  claude -p "Implement execute-tickets work for issue {issue_number} ({issue_title}).
  Read the full ticket body from file path {issue_body}. Spec: {spec_file}. Plan: {plan_file}.
  Tier={model_tier} complexity={complexity} priority={priority}. Iteration={iteration}.
  If {review_feedback} is a non-empty path, read it and fix ONLY those blocking findings.
  Commit all changes on branch {branch}. Do not open a pull request."
  --model haiku --permission-mode acceptEdits

efficient: >
  claude -p "Implement execute-tickets work for issue {issue_number} ({issue_title}).
  Read the full ticket body from file path {issue_body}. Spec: {spec_file}. Plan: {plan_file}.
  Tier={model_tier} complexity={complexity} priority={priority}. Iteration={iteration}.
  If {review_feedback} is a non-empty path, read it and fix ONLY those blocking findings.
  Commit all changes on branch {branch}. Do not open a pull request."
  --model sonnet --permission-mode acceptEdits

standard: >
  claude -p "Implement execute-tickets work for issue {issue_number} ({issue_title}).
  Read the full ticket body from file path {issue_body}. Spec: {spec_file}. Plan: {plan_file}.
  Tier={model_tier} complexity={complexity} priority={priority}. Iteration={iteration}.
  If {review_feedback} is a non-empty path, read it and fix ONLY those blocking findings.
  Commit all changes on branch {branch}. Do not open a pull request."
  --model sonnet --permission-mode acceptEdits

flagship: >
  claude -p "Implement execute-tickets work for issue {issue_number} ({issue_title}).
  Read the full ticket body from file path {issue_body}. Spec: {spec_file}. Plan: {plan_file}.
  Tier={model_tier} complexity={complexity} priority={priority}. Iteration={iteration}.
  If {review_feedback} is a non-empty path, read it and fix ONLY those blocking findings.
  Commit all changes on branch {branch}. Do not open a pull request."
  --model opus --permission-mode acceptEdits
```

- [ ] **Step 4: Create `scripts/init-agents.sh`**

Create `skills/coding/execute-tickets/scripts/init-agents.sh` (executable):

```bash
#!/usr/bin/env bash
# init-agents.sh — scaffold .execute-tickets/agents.yml from the skill's Claude defaults.
# Independent of execute-tickets.sh; never called by the executor.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$SKILL_DIR/references/agents.example.yml"
REPO_ROOT=""
FORCE=false
DRY_RUN=false

usage() {
  cat <<'EOF'
init-agents.sh — write .execute-tickets/agents.yml with Claude-default agent commands.

Usage:
  init-agents.sh [--repo-root <path>] [--force] [--dry-run]

Flags:
  --repo-root <path>  Target repo root (default: git rev-parse --show-toplevel, else cwd)
  --force             Overwrite an existing agents.yml
  --dry-run           Print the template to stdout; write nothing
  --help              Show this help

Does not create, read, or modify .execute-tickets/checklist.yml.
EOF
}

die() { local code="$1"; shift; echo "$*" >&2; exit "$code"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) [ $# -ge 2 ] || die 2 "Missing value for $1"; REPO_ROOT="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help) usage; exit 0 ;;
    *) die 2 "Unknown flag: $1" ;;
  esac
done

[ -f "$TEMPLATE" ] || die 1 "Template not found: $TEMPLATE"

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
OUT_DIR="$REPO_ROOT/.execute-tickets"
OUT_FILE="$OUT_DIR/agents.yml"

if [ "$DRY_RUN" = true ]; then
  cat "$TEMPLATE"
  exit 0
fi

if [ -f "$OUT_FILE" ] && [ "$FORCE" != true ]; then
  die 1 "Refusing to overwrite existing $OUT_FILE (pass --force, or --dry-run to preview)"
fi

mkdir -p "$OUT_DIR"
cp "$TEMPLATE" "$OUT_FILE"
echo "Wrote $OUT_FILE"
echo "Edit model flags for your org, then run execute-tickets workers without --agent-cmd."
```

```bash
chmod +x skills/coding/execute-tickets/scripts/init-agents.sh
```

- [ ] **Step 5: Re-run tests — init cases PASS**

```bash
bash skills/coding/execute-tickets/tests/run.sh 2>&1 | tail -50
```

Expected: all previous tests still pass; all five new init tests pass.

- [ ] **Step 6: Commit**

```bash
git add skills/coding/execute-tickets/references/agents.example.yml \
  skills/coding/execute-tickets/scripts/init-agents.sh \
  skills/coding/execute-tickets/tests/lib.sh \
  skills/coding/execute-tickets/tests/run.sh
git commit -m "$(cat <<'EOF'
execute-tickets: add init-agents.sh and Claude agents.example.yml

Scaffold .execute-tickets/agents.yml from a vendored four-tier template;
refuse overwrite without --force; leave checklist.yml alone.
EOF
)"
```

---

### Task 2: Load `agents.yml` + optional `--agent-cmd` in the executor (TDD)

**Files:**
- Create: `skills/coding/execute-tickets/tests/fake-yq`
- Modify: `skills/coding/execute-tickets/tests/lib.sh` (`bindir_for` installs fake-yq)
- Modify: `skills/coding/execute-tickets/tests/run.sh`
- Modify: `skills/coding/execute-tickets/scripts/execute-tickets.sh`

**Interfaces:**
- Consumes: `write_agents_yml` from Task 1
- Produces: globals `AGENT_CMD_LITE|EFFICIENT|STANDARD|FLAGSHIP`, `AGENTS_YML_PATH`, `resolve_agent_cmd <tier> -> prints cmd`; `agent_source_label <tier> -> --agent-cmd|agents.yml#<tier>`; `--agent-cmd` optional

- [ ] **Step 1: Add `fake-yq` and install it in `bindir_for`**

Create `skills/coding/execute-tickets/tests/fake-yq` (executable):

```bash
#!/usr/bin/env bash
# Minimal mikefarah-compatible yq for tests: yq -r '.key // ""' file
set -euo pipefail
if [ "${1:-}" = "-r" ] && [ $# -eq 3 ]; then
  expr="$2"
  file="$3"
  # Support '.lite // ""' and '.lite'
  key="$(printf '%s' "$expr" | sed -E 's/^\.([a-zA-Z0-9_]+).*/\1/')"
  [ -f "$file" ] || exit 1
  # Prefer python3 for YAML (available on macOS CI runners); fallback: grep for simple keys.
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" "$key" <<'PY'
import sys
path, key = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
# Very small YAML subset: top-level key: value or key: > folded blocks
import re
# Strip comments
lines = text.splitlines()
i = 0
n = len(lines)
while i < n:
    line = lines[i]
    if re.match(rf'^{re.escape(key)}:\s*$', line) or re.match(rf'^{re.escape(key)}:\s*>\s*$', line) or re.match(rf'^{re.escape(key)}:\s*\|\s*$', line):
        # folded/literal block
        i += 1
        parts = []
        while i < n and (lines[i].startswith("  ") or lines[i].startswith("\t") or lines[i].strip() == ""):
            parts.append(lines[i].strip())
            i += 1
        print(" ".join(p for p in parts if p))
        sys.exit(0)
    m = re.match(rf'^{re.escape(key)}:\s*(.*)$', line)
    if m:
        val = m.group(1).strip()
        if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
            val = val[1:-1]
        print(val)
        sys.exit(0)
    i += 1
print("")
PY
    exit 0
  fi
  # Fallback: single-line key: value only
  val="$(grep -E "^${key}:" "$file" | head -1 | sed -E "s/^${key}:[[:space:]]*//" | sed -E 's/^["'\'']//; s/["'\'']$//')"
  printf '%s\n' "$val"
  exit 0
fi
echo "fake-yq: unsupported invocation: $*" >&2
exit 2
```

In `bindir_for` in `lib.sh`, after copying fake-codex:

```bash
  cp "$HERE/fake-yq" "$dir/bin/yq"; chmod +x "$dir/bin/yq"
```

Also `chmod +x skills/coding/execute-tickets/tests/fake-yq`.

- [ ] **Step 2: Add failing executor tests for YAML routing**

Append to `run.sh`:

```bash
# --- agents.yml routing: --agent-cmd optional; all four tiers required at load;
# per-ticket model-tier selects the command; flag override wins.

test_missing_agent_cmd_and_agents_yml_fails_preflight() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" \
    -- --worker alice --plan plan1 --once
  assert_eq "$RC" "1" "missing agents.yml without --agent-cmd exits 1"
  assert_contains "$ERR" "agents.yml" "error names agents.yml"
  rm -rf "$d"
}

test_missing_agent_cmd_and_agents_yml_fails_preflight

test_agents_yml_missing_tier_fails_preflight() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  mkdir -p "$d/work/.execute-tickets"
  # only three keys
  cat > "$d/work/.execute-tickets/agents.yml" <<'EOF'
lite: "echo lite"
efficient: "echo efficient"
standard: "echo standard"
EOF
  local state="$d/state.json"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" \
    -- --worker alice --plan plan1 --once
  assert_eq "$RC" "1" "partial agents.yml exits 1"
  assert_contains "$ERR" "flagship" "error names the missing tier"
  rm -rf "$d"
}

test_agents_yml_missing_tier_fails_preflight

test_agents_yml_routes_by_model_tier() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  # efficient tier command commits and tags which command ran
  write_agents_yml "$d/work" \
    'echo lite > agent-tier.txt && git add -A && git commit -q -m lite' \
    'echo efficient > agent-tier.txt && git add -A && git commit -q -m efficient' \
    'echo standard > agent-tier.txt && git add -A && git commit -q -m standard' \
    'echo flagship > agent-tier.txt && git add -A && git commit -q -m flagship'
  local state="$d/state.json" log="$d/gh.log"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" FAKE_GH_LOG="$log" \
    -- --worker alice --plan plan1 --once
  assert_eq "$RC" "0" "YAML-routed green path exits 0"
  jqok "$(cat "$state")" '.issues["101"].state == "closed"' "ticket closed after YAML-routed run"
  # The agent ran in a worktree; after merge the epic may hold the commit.
  # Assert via audit comment that source was agents.yml#efficient.
  assert_contains "$(cat "$log")" "agents.yml#efficient" "audit trail records agents.yml#efficient source"
  rm -rf "$d"
}

test_agents_yml_routes_by_model_tier

test_agent_cmd_override_wins_over_agents_yml() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  write_agents_yml "$d/work" \
    'echo yml-lite > agent-tier.txt && git add -A && git commit -q -m y' \
    'echo yml-efficient > agent-tier.txt && git add -A && git commit -q -m y' \
    'echo yml-standard > agent-tier.txt && git add -A && git commit -q -m y' \
    'echo yml-flagship > agent-tier.txt && git add -A && git commit -q -m y'
  local state="$d/state.json" log="$d/gh.log"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" FAKE_GH_LOG="$log" \
    -- --worker alice --plan plan1 --agent-cmd "$DEFAULT_AGENT_CMD" --once
  assert_eq "$RC" "0" "override path exits 0"
  assert_contains "$(cat "$log")" "--agent-cmd" "audit trail records --agent-cmd source"
  assert_not_contains "$(cat "$log")" "agents.yml#efficient" "YAML tier not used when flag set"
  rm -rf "$d"
}

test_agent_cmd_override_wins_over_agents_yml

test_invalid_model_tier_needs_human() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  write_agents_yml "$d/work"
  local state="$d/state.json" log="$d/gh.log"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:turbo"], assignees:[], state:"open"}
  ]')"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" FAKE_GH_LOG="$log" \
    -- --worker alice --plan plan1 --once
  assert_eq "$RC" "0" "worker exits 0 after needs-human (once mode still exits 0)"
  jqok "$(cat "$state")" '(.issues["101"].labels | index("needs-human")) != null' "invalid tier gets needs-human"
  assert_contains "$(cat "$log")" "model-tier" "needs-human reason mentions model-tier"
  rm -rf "$d"
}

test_invalid_model_tier_needs_human

test_dry_run_reports_agent_source_from_yml() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  write_agents_yml "$d/work" \
    'echo lite' 'echo efficient-cmd' 'echo standard' 'echo flagship'
  local state="$d/state.json"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" \
    -- --worker alice --plan plan1 --dry-run --once
  assert_eq "$RC" "0" "dry-run with agents.yml exits 0"
  assert_contains "$ERR" "agent source:      agents.yml#efficient" "dry-run shows YAML source"
  assert_contains "$ERR" "efficient-cmd" "dry-run shows resolved efficient command"
  rm -rf "$d"
}

test_dry_run_reports_agent_source_from_yml
```

- [ ] **Step 3: Run new tests — expect FAIL**

```bash
bash skills/coding/execute-tickets/tests/run.sh 2>&1 | rg -n "FAIL|missing agents|optional|agents.yml" | head -40
```

Expected: FAIL on missing `--agent-cmd` still required, and/or agents.yml ignored.

- [ ] **Step 4: Implement load/select in `execute-tickets.sh`**

**4a. Globals** (near `AGENT_CMD=""`):

```bash
AGENT_CMD=""   # optional global override
AGENT_CMD_LITE=""
AGENT_CMD_EFFICIENT=""
AGENT_CMD_STANDARD=""
AGENT_CMD_FLAGSHIP=""
AGENTS_YML_PATH=""
```

**4b. `usage()`** — change Required flags so `--agent-cmd` is optional; document:

```
  --agent-cmd <cmd>     Optional. If set, used for every ticket (overrides agents.yml).
                        If omitted, load .execute-tickets/agents.yml (all four tiers required).
```

**4c. `parse_args`** — remove the hard die for missing `AGENT_CMD`:

```bash
  # AGENT_CMD optional: validated in preflight against agents.yml when empty
```

**4d. Add helpers** (before `preflight` or near `render_cmd`):

```bash
is_valid_model_tier() {
  case "$1" in lite|efficient|standard|flagship) return 0 ;; *) return 1 ;; esac
}

load_agents_yml() {
  local root file
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  file="$root/.execute-tickets/agents.yml"
  AGENTS_YML_PATH="$file"
  [ -f "$file" ] || die 1 "Missing $file (run scripts/init-agents.sh or pass --agent-cmd)"
  command -v yq >/dev/null 2>&1 || die 1 "yq is required to load agents.yml (mikefarah yq v4). Or pass --agent-cmd."
  AGENT_CMD_LITE="$(yq -r '.lite // ""' "$file")"
  AGENT_CMD_EFFICIENT="$(yq -r '.efficient // ""' "$file")"
  AGENT_CMD_STANDARD="$(yq -r '.standard // ""' "$file")"
  AGENT_CMD_FLAGSHIP="$(yq -r '.flagship // ""' "$file")"
  local missing=()
  [ -n "$AGENT_CMD_LITE" ] || missing+=(lite)
  [ -n "$AGENT_CMD_EFFICIENT" ] || missing+=(efficient)
  [ -n "$AGENT_CMD_STANDARD" ] || missing+=(standard)
  [ -n "$AGENT_CMD_FLAGSHIP" ] || missing+=(flagship)
  if [ "${#missing[@]}" -gt 0 ]; then
    die 1 "agents.yml missing or empty keys: ${missing[*]} (file: $file)"
  fi
}

# resolve_agent_cmd <tier> -> command string on stdout
resolve_agent_cmd() {
  local tier="$1"
  if [ -n "$AGENT_CMD" ]; then
    printf '%s' "$AGENT_CMD"
    return 0
  fi
  case "$tier" in
    lite) printf '%s' "$AGENT_CMD_LITE" ;;
    efficient) printf '%s' "$AGENT_CMD_EFFICIENT" ;;
    standard) printf '%s' "$AGENT_CMD_STANDARD" ;;
    flagship) printf '%s' "$AGENT_CMD_FLAGSHIP" ;;
    *) return 1 ;;
  esac
}

agent_source_label() {
  local tier="$1"
  if [ -n "$AGENT_CMD" ]; then
    printf '%s' "--agent-cmd"
  else
    printf 'agents.yml#%s' "$tier"
  fi
}
```

**4e. End of `preflight`**, after repo is known, before or after `ensure_lock_labels`:

```bash
  if [ -z "$AGENT_CMD" ]; then
    load_agents_yml
  fi
```

**4f. `invoke_agent`** — resolve template instead of always `$AGENT_CMD`:

```bash
invoke_agent() {
  local n="$1" title="$2" body_file="$3" tier="$4" complexity="$5" priority="$6"
  local worktree="$7" branch="$8" review_feedback="$9" iteration="${10}"
  local tmpl cmd
  tmpl="$(resolve_agent_cmd "$tier")" || return 1
  cmd="$(render_cmd "$tmpl" \
    issue_number "$n" \
    issue_title "$title" \
    issue_body "$body_file" \
    spec_file "$SPEC_FILE" \
    plan_file "$PLAN_FILE" \
    model_tier "$tier" \
    complexity "$complexity" \
    priority "$priority" \
    worktree "$worktree" \
    branch "$branch" \
    review_feedback "$review_feedback" \
    iteration "$iteration")"
  log "Agent (iter $iteration) for #$n via $(agent_source_label "$tier"): cd $worktree"
  vlog "agent cmd: $cmd"
  ( cd "$worktree" && bash -c "$cmd" )
}
```

**4g. Early in `run_ticket`**, after reading `tier` / before worktree create (or immediately after claim setup), validate tier:

```bash
  if ! is_valid_model_tier "$tier"; then
    flag_needs_human "$n" "missing or invalid model-tier label (got: ${tier:-empty}); expected lite|efficient|standard|flagship" ""
    cleanup_ticket_state ... # only if worktree already created; if before worktree, just release lock
    return 1
  fi
```

Place this **before** worktree creation so cleanup is only: release lock + needs-human. Pattern:

```bash
  tier="$(label_value "$candidate" model-tier)"
  complexity="$(label_value "$candidate" complexity)"
  priority="$(label_value "$candidate" priority)"

  if ! is_valid_model_tier "$tier"; then
    flag_needs_human "$n" "missing or invalid model-tier label (got: ${tier:-empty}); expected lite|efficient|standard|flagship" ""
    release_ticket "$n" 2>/dev/null || true
    return 1
  fi
```

Check whether `flag_needs_human` already removes the lock; if it does, do not double-release. Read existing `flag_needs_human` and match its contract (today it removes lock and adds needs-human).

**4h. `audit_comment`** — change Agent line to include source. Add optional 9th arg `agent_source` or compute inside from global + tier:

```bash
    printf '**Agent**: %s · model_tier=%s · PR #%s\n' "$(agent_source_label "$tier")" "$tier" "$pr"
```

Fake-gh logs body content when commenting — the test asserts `agents.yml#efficient` / `--agent-cmd` appears in the log. Ensure `fake-gh` logs issue comment bodies (existing tests already use `BODY_CONTENT(#101):` patterns). If comments are only logged as `issue comment`, extend audit to put source in a form that lands in the log the same way other body assertions work — follow the existing `assert_contains "$(cat "$log")" "BODY_CONTENT..."` pattern used in push-failure tests. If needed, assert on stderr `vlog`/`log` lines instead: prefer durable issue comments as the spec requires.

If `fake-gh` stores comment bodies, assert:

```bash
assert_contains "$(cat "$log")" "agents.yml#efficient"
```

**4i. `dry_run_report`** — resolve cmd via `resolve_agent_cmd` and print source:

```bash
  local agent_tmpl agent_cmd reviewer_cmd src
  if ! is_valid_model_tier "$tier"; then
    agent_tmpl="<invalid model-tier: ${tier:-empty}>"
    src="invalid-tier"
  else
    agent_tmpl="$(resolve_agent_cmd "$tier")"
    src="$(agent_source_label "$tier")"
  fi
  agent_cmd="$(render_cmd "$agent_tmpl" ...)"
  ...
  agent source:      $src
  agent cmd:         $agent_cmd
```

- [ ] **Step 5: Re-run full suite**

```bash
bash skills/coding/execute-tickets/tests/run.sh
```

Expected: all tests PASS (including existing green path with `--agent-cmd`).

- [ ] **Step 6: Commit**

```bash
git add skills/coding/execute-tickets/scripts/execute-tickets.sh \
  skills/coding/execute-tickets/tests/fake-yq \
  skills/coding/execute-tickets/tests/lib.sh \
  skills/coding/execute-tickets/tests/run.sh
git commit -m "$(cat <<'EOF'
execute-tickets: route agent commands from agents.yml by model tier

Make --agent-cmd optional; load and validate four tiers via yq; override
flag wins; invalid model-tier labels get needs-human.
EOF
)"
```

---

### Task 3: Document config, init, and override in SKILL.md + Warp setup

**Files:**
- Modify: `skills/coding/execute-tickets/SKILL.md`
- Modify: `skills/coding/execute-tickets/references/warp-setup.md`

**Interfaces:**
- Consumes: behavior from Tasks 1–2
- Produces: operator docs only

- [ ] **Step 1: Update SKILL.md**

Apply these content changes (edit in place; keep named-worker docs intact):

1. **description frontmatter** — mention `.execute-tickets/agents.yml` routing and optional `--agent-cmd`.

2. **When this applies** — add `yq` when not using `--agent-cmd`; first-time setup: run `scripts/init-agents.sh`.

3. Replace the paragraph that says the skill never ships an agent with:

```markdown
- Prefer repo-local `.execute-tickets/agents.yml` (scaffold with
  `scripts/init-agents.sh`) mapping each model tier to a shell command.
  Pass `--agent-cmd` only to override that file for the whole worker process.
```

4. **Agent command section** — retitle to "Agent commands" and document:
   - Config path and four keys
   - Selection table (flag vs YAML)
   - `init-agents.sh` flags
   - Token table unchanged
   - Note that tier→concrete model mapping is now primarily `agents.yml`, with `--agent-cmd` as override

5. **Procedure step 2** — "Choose the agent invocation" becomes: run `init-agents.sh` if no config; edit models; or compose `--agent-cmd` for one-off.

6. **Launch examples** — show workers without `--agent-cmd` once YAML exists:

```bash
for W in alice bob carol dave; do
  skills/coding/execute-tickets/scripts/execute-tickets.sh \
    --worker "$W" --plan <plan-slug> \
    > "logs/executor-${W}.log" 2>&1 &
done
```

7. **Flags table** — `--agent-cmd` row: optional; required only if no valid `agents.yml`.

8. **What this skill deliberately does not do** — remove or rewrite "**Map model tiers to concrete models.** That's `--agent-cmd`'s job." to:

```markdown
- **Invent model IDs for you over time.** `init-agents.sh` ships a Claude snapshot;
  projects own edits to `agents.yml`.
```

- [ ] **Step 2: Update `references/warp-setup.md`**

- Environment: install `yq` (mikefarah) in addition to `git`/`gh`/`jq`/agent CLIs.
- Prefer committing `.execute-tickets/agents.yml` (from `init-agents.sh`) so scheduled agents need no `--agent-cmd`.
- Example prompt command drops `--agent-cmd` when config is present; keep override note.

- [ ] **Step 3: Run full test suite once more (docs-only; no logic change)**

```bash
bash skills/coding/execute-tickets/tests/run.sh
```

Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add skills/coding/execute-tickets/SKILL.md \
  skills/coding/execute-tickets/references/warp-setup.md
git commit -m "$(cat <<'EOF'
execute-tickets: document agents.yml routing and init-agents.sh

First-time setup via init-agents; workers can omit --agent-cmd when
repo config is present; Warp env needs yq.
EOF
)"
```

---

## Spec coverage checklist (self-review)

| Spec requirement | Task |
|------------------|------|
| `.execute-tickets/agents.yml` path | 1, 2 |
| Keys lite/efficient/standard/flagship | 1, 2 |
| Opaque command strings + tokens | 1, 2 |
| Config primary; `--agent-cmd` wins | 2 |
| All four keys required at load | 2 |
| Missing/invalid tier → needs-human | 2 |
| `init-agents.sh` independent | 1 |
| `--force` / `--dry-run` / no checklist touch | 1 |
| Claude defaults template | 1 |
| `yq` dependency | 2 |
| Audit source label | 2 |
| Dry-run shows source | 2 |
| SKILL.md / Warp docs | 3 |
| Reviewer config unchanged | (no task — non-goal) |

## Placeholder / consistency scan

- No TBD steps; concrete file paths and code blocks throughout.
- Function names consistent: `load_agents_yml`, `resolve_agent_cmd`, `agent_source_label`, `is_valid_model_tier`, `write_agents_yml`.
- `fake-yq` supports both single-line and `>` folded blocks so `agents.example.yml` and test fixtures both parse.
