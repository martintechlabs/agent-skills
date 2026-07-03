# github-lockdown Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a manual-only `github-lockdown` skill that locks down a GitHub repo — protects the default branch behind a required PR (0 approvers by default), blocks force-pushes and branch deletion, and auto-deletes merged branches — via a tested `gh`+`jq` bash script.

**Architecture:** A bundled `scripts/lockdown.sh` does all GitHub work through the `gh` CLI: preflight (auth/jq/admin), resolve repo + branch, build the ruleset JSON with `jq`, idempotently upsert a ruleset named `github-lockdown` (POST to create / PUT to update by id), then PATCH the repo's `delete_branch_on_merge`. A `--dry-run` mode prints the JSON body to **stdout** and a human plan to **stderr** without mutating anything — this is the seam the tests assert against. `tests/run.sh` is a plain-bash runner that PATH-shims a fake `gh` returning canned JSON, so nothing hits the network. `SKILL.md` runs a short interview (with a one-line "just use the defaults" path) and invokes the script.

**Tech Stack:** Bash, GitHub CLI (`gh`), `jq`, GitHub Repository Rulesets REST API (`/repos/{owner}/{repo}/rulesets`).

---

## File Structure

```
skills/devops/github-lockdown/
├── SKILL.md                 # frontmatter (disable-model-invocation: true) + interview/procedure
├── scripts/lockdown.sh      # bash + gh + jq; secure defaults, knobs as flags, --dry-run seam
├── tests/run.sh             # plain-bash runner; PATH-shims a fake gh; jq assertions on the payload
└── references/rulesets.md   # ruleset model, required permissions, troubleshooting, how to undo
```

Repo-level changes: add a row to the **DevOps** table in `README.md`, and add `github-lockdown` to the `devops` grouping in `skills.sh.json`.

### Script internal contract (referenced by every task)

`lockdown.sh` is organized into shell functions so tests and later tasks can target them:

- `usage()` — prints help.
- `parse_args()` — sets globals from flags (see flag list below).
- `preflight()` — `gh auth status`, `jq` present, `viewerPermission == ADMIN`; else exit 1 with remediation.
- `resolve_repo()` — sets `REPO` (`--repo` or `gh repo view --json nameWithOwner`).
- `ref_includes()` — echoes JSON array: `["~DEFAULT_BRANCH"]` by default, `["refs/heads/<branch>"]` if `--branch`.
- `build_ruleset_json()` — echoes the full ruleset request body (built with `jq`).
- `find_ruleset_id()` — echoes the id of an existing ruleset named `$NAME`, or empty.
- `apply_ruleset()` — dry-run: body→stdout, plan→stderr; real: `gh api` POST/PUT.
- `apply_auto_delete()` — dry-run: plan→stderr; real: `gh api -X PATCH`.
- `verify()` — real runs only: re-GET and print a summary.
- `main()` — orchestrates the above.

**Flags:** `--repo <owner/repo>`, `--branch <name>`, `--approvals N` (default 0), `--admin-bypass`, `--require-conversation-resolution`, `--linear-history`, `--signed-commits`, `--require-code-owner-review`, `--dismiss-stale-approvals`, `--status-checks "ci,build"`, `--no-auto-delete`, `--ruleset-name <name>` (default `github-lockdown`), `--dry-run`, `--help`.

**Dry-run output contract (the test seam):**
- **stdout** = the ruleset JSON request body, and nothing else (jq-parseable).
- **stderr** = human plan lines, one per action, each starting with `PLAN `:
  - `PLAN CREATE ruleset name=<name> via POST repos/<repo>/rulesets`
  - `PLAN UPDATE ruleset id=<id> via PUT repos/<repo>/rulesets/<id>`
  - `PLAN SET repos/<repo> delete_branch_on_merge=true`

---

## Task 1: Skill scaffold, test harness, and `--help`

**Files:**
- Create: `skills/devops/github-lockdown/scripts/lockdown.sh`
- Create: `skills/devops/github-lockdown/tests/run.sh`
- Create: `skills/devops/github-lockdown/tests/fake-gh` (fake `gh` shim used by all tests)

- [ ] **Step 1: Write the failing test harness + first test**

Create `skills/devops/github-lockdown/tests/run.sh`:

```bash
#!/usr/bin/env bash
# Plain-bash test runner for lockdown.sh. No network: a fake `gh` is put on PATH.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/lockdown.sh"
PASS=0
FAIL=0

# Build a temp dir holding the fake gh, prepend to PATH.
setup_path() {
  local bindir="$1"
  mkdir -p "$bindir"
  cp "$HERE/fake-gh" "$bindir/gh"
  chmod +x "$bindir/gh"
  echo "$bindir:$PATH"
}

# run_lockdown <bindir> <env-assignments...> -- <lockdown args...>
# Captures stdout->$OUT, stderr->$ERR, exit->$RC
run_lockdown() {
  local bindir="$1"; shift
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift  # drop --
  local outf errf
  outf="$(mktemp)"; errf="$(mktemp)"
  PATH="$(setup_path "$bindir")" env "${envs[@]}" bash "$SCRIPT" "$@" >"$outf" 2>"$errf"
  RC=$?
  OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

assert_eq()       { [ "$1" = "$2" ] && ok "$3" || bad "$3" "expected [$2] got [$1]"; }
assert_contains() { case "$1" in *"$2"*) ok "$3";; *) bad "$3" "[$1] did not contain [$2]";; esac; }

# ---- Task 1 test ----
test_help() {
  local d; d="$(mktemp -d)"
  run_lockdown "$d/bin" -- --help
  assert_eq "$RC" "0" "help exits 0"
  assert_contains "$OUT" "lockdown.sh" "help mentions the script"
  assert_contains "$OUT" "--approvals" "help lists the --approvals flag"
  rm -rf "$d"
}

test_help

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
```

Create `skills/devops/github-lockdown/tests/fake-gh` (extended in later tasks; Task 1 only needs it to exist and be executable — `--help` never calls `gh`):

```bash
#!/usr/bin/env bash
# Fake `gh` for tests. Records calls to $FAKE_GH_LOG and emits canned JSON.
# Behavior is tuned per-test via env vars:
#   FAKE_GH_VIEWER_PERMISSION  (default ADMIN)
#   FAKE_GH_NAME_WITH_OWNER    (default octo/repo)
#   FAKE_GH_RULESETS_JSON      (default [])   -> response for GET .../rulesets
set -uo pipefail
[ -n "${FAKE_GH_LOG:-}" ] && printf '%s\n' "$*" >>"$FAKE_GH_LOG"

case "$1" in
  auth)
    # `gh auth status`
    exit 0 ;;
  repo)
    # `gh repo view --json <field> -q <expr>`
    shift 2  # drop: repo view
    case "$*" in
      *viewerPermission*) printf '%s\n' "${FAKE_GH_VIEWER_PERMISSION:-ADMIN}" ;;
      *nameWithOwner*)    printf '%s\n' "${FAKE_GH_NAME_WITH_OWNER:-octo/repo}" ;;
      *)                  printf '\n' ;;
    esac ;;
  api)
    # `gh api <path> [ -X METHOD ] [ --input FILE | -f k=v ]`
    case "$*" in
      *rulesets*) printf '%s\n' "${FAKE_GH_RULESETS_JSON:-[]}" ;;
      *)          printf '{}\n' ;;
    esac ;;
  *)
    exit 0 ;;
esac
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash skills/devops/github-lockdown/tests/run.sh`
Expected: FAIL — `lockdown.sh` does not exist yet, so the run errors and assertions fail (non-zero exit).

- [ ] **Step 3: Create the minimal script skeleton**

Create `skills/devops/github-lockdown/scripts/lockdown.sh`:

```bash
#!/usr/bin/env bash
# github-lockdown: protect a repo's default branch behind a required PR via a
# GitHub repository ruleset, and auto-delete merged branches. Idempotent.
set -euo pipefail

# ---- defaults (secure) ----
REPO=""; BRANCH=""; APPROVALS=0; ADMIN_BYPASS=false
THREAD_RES=false; LINEAR=false; SIGNED=false; CODE_OWNER=false; DISMISS_STALE=false
STATUS_CHECKS=""; AUTO_DELETE=true; NAME="github-lockdown"; DRY_RUN=false

usage() {
  cat <<'EOF'
lockdown.sh — lock down a GitHub repo's default branch (repository rulesets).

Usage: lockdown.sh [flags]

Flags:
  --repo <owner/repo>            Target repo (default: current repo)
  --branch <name>                Branch to protect (default: repo default branch)
  --approvals N                  Required approving reviews (default: 0)
  --admin-bypass                 Let repo admins bypass the ruleset (default: off)
  --require-conversation-resolution
  --linear-history
  --signed-commits
  --require-code-owner-review
  --dismiss-stale-approvals
  --status-checks "ci,build"     Comma-separated required status check contexts
  --no-auto-delete               Do not enable delete-branch-on-merge
  --ruleset-name <name>          Ruleset name (default: github-lockdown)
  --dry-run                      Print planned changes; apply nothing
  --help                         Show this help
EOF
}

main() {
  parse_args "$@"
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --help) usage; exit 0 ;;
      *) shift ;;   # extended in later tasks
    esac
  done
}

main "$@"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash skills/devops/github-lockdown/tests/run.sh`
Expected: PASS — `3 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
chmod +x skills/devops/github-lockdown/scripts/lockdown.sh skills/devops/github-lockdown/tests/run.sh skills/devops/github-lockdown/tests/fake-gh
git add skills/devops/github-lockdown/
git commit -m "github-lockdown: scaffold script, test harness, and --help"
```

---

## Task 2: Flag parsing

**Files:**
- Modify: `skills/devops/github-lockdown/scripts/lockdown.sh` (`parse_args`)
- Test: `skills/devops/github-lockdown/tests/run.sh`

- [ ] **Step 1: Write the failing test**

Add to `tests/run.sh` before the summary block. This test uses a hidden `--print-config` debug flag that dumps parsed globals as `KEY=VALUE` lines so parsing can be asserted directly:

```bash
test_parse_args() {
  local d; d="$(mktemp -d)"
  run_lockdown "$d/bin" -- --print-config \
    --repo acme/widgets --branch develop --approvals 2 --admin-bypass \
    --linear-history --signed-commits --require-code-owner-review \
    --dismiss-stale-approvals --require-conversation-resolution \
    --status-checks "ci,build" --no-auto-delete --ruleset-name custom --dry-run
  assert_contains "$OUT" "REPO=acme/widgets"      "parses --repo"
  assert_contains "$OUT" "BRANCH=develop"         "parses --branch"
  assert_contains "$OUT" "APPROVALS=2"            "parses --approvals"
  assert_contains "$OUT" "ADMIN_BYPASS=true"      "parses --admin-bypass"
  assert_contains "$OUT" "LINEAR=true"            "parses --linear-history"
  assert_contains "$OUT" "SIGNED=true"            "parses --signed-commits"
  assert_contains "$OUT" "CODE_OWNER=true"        "parses --require-code-owner-review"
  assert_contains "$OUT" "DISMISS_STALE=true"     "parses --dismiss-stale-approvals"
  assert_contains "$OUT" "THREAD_RES=true"        "parses --require-conversation-resolution"
  assert_contains "$OUT" "STATUS_CHECKS=ci,build" "parses --status-checks"
  assert_contains "$OUT" "AUTO_DELETE=false"      "parses --no-auto-delete"
  assert_contains "$OUT" "NAME=custom"            "parses --ruleset-name"
  assert_contains "$OUT" "DRY_RUN=true"           "parses --dry-run"
  rm -rf "$d"
}

test_parse_args
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash skills/devops/github-lockdown/tests/run.sh`
Expected: FAIL — flags are ignored and `--print-config` is unknown; no `REPO=acme/widgets` in output.

- [ ] **Step 3: Implement full `parse_args` (and a `--print-config` debug dump)**

Replace `parse_args` in `lockdown.sh`:

```bash
PRINT_CONFIG=false

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) REPO="$2"; shift 2 ;;
      --branch) BRANCH="$2"; shift 2 ;;
      --approvals) APPROVALS="$2"; shift 2 ;;
      --admin-bypass) ADMIN_BYPASS=true; shift ;;
      --require-conversation-resolution) THREAD_RES=true; shift ;;
      --linear-history) LINEAR=true; shift ;;
      --signed-commits) SIGNED=true; shift ;;
      --require-code-owner-review) CODE_OWNER=true; shift ;;
      --dismiss-stale-approvals) DISMISS_STALE=true; shift ;;
      --status-checks) STATUS_CHECKS="$2"; shift 2 ;;
      --no-auto-delete) AUTO_DELETE=false; shift ;;
      --ruleset-name) NAME="$2"; shift 2 ;;
      --dry-run) DRY_RUN=true; shift ;;
      --print-config) PRINT_CONFIG=true; shift ;;
      --help) usage; exit 0 ;;
      *) echo "Unknown flag: $1" >&2; usage >&2; exit 2 ;;
    esac
  done
}

print_config() {
  cat <<EOF
REPO=$REPO
BRANCH=$BRANCH
APPROVALS=$APPROVALS
ADMIN_BYPASS=$ADMIN_BYPASS
THREAD_RES=$THREAD_RES
LINEAR=$LINEAR
SIGNED=$SIGNED
CODE_OWNER=$CODE_OWNER
DISMISS_STALE=$DISMISS_STALE
STATUS_CHECKS=$STATUS_CHECKS
AUTO_DELETE=$AUTO_DELETE
NAME=$NAME
DRY_RUN=$DRY_RUN
EOF
}
```

Update `main` to honor the debug flag:

```bash
main() {
  parse_args "$@"
  if [ "$PRINT_CONFIG" = true ]; then print_config; exit 0; fi
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash skills/devops/github-lockdown/tests/run.sh`
Expected: PASS — all Task 1 + Task 2 assertions pass.

- [ ] **Step 5: Commit**

```bash
git add skills/devops/github-lockdown/
git commit -m "github-lockdown: full flag parsing"
```

---

## Task 3: Preflight (auth, jq, admin permission)

**Files:**
- Modify: `skills/devops/github-lockdown/scripts/lockdown.sh` (`preflight`, `main`)
- Test: `skills/devops/github-lockdown/tests/run.sh`

- [ ] **Step 1: Write the failing tests**

Add to `tests/run.sh`. Preflight runs before any mutation, so we drive it with `--dry-run` and a hidden `--preflight-only` flag that runs preflight then exits 0:

```bash
test_preflight_admin_ok() {
  local d; d="$(mktemp -d)"
  run_lockdown "$d/bin" FAKE_GH_VIEWER_PERMISSION=ADMIN -- --preflight-only --repo octo/repo
  assert_eq "$RC" "0" "preflight passes for ADMIN"
  rm -rf "$d"
}

test_preflight_non_admin_fails() {
  local d; d="$(mktemp -d)"
  run_lockdown "$d/bin" FAKE_GH_VIEWER_PERMISSION=WRITE -- --preflight-only --repo octo/repo
  assert_eq "$RC" "1" "preflight fails for non-admin"
  assert_contains "$ERR" "admin" "non-admin error mentions admin"
  rm -rf "$d"
}

test_preflight_admin_ok
test_preflight_non_admin_fails
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash skills/devops/github-lockdown/tests/run.sh`
Expected: FAIL — `--preflight-only` is unknown (exit 2) and there is no `preflight` function.

- [ ] **Step 3: Implement `preflight` and wire it up**

Add the `--preflight-only` flag to `parse_args` (add a global `PREFLIGHT_ONLY=false` near the other defaults, and a case):

```bash
      --preflight-only) PREFLIGHT_ONLY=true; shift ;;
```

Add the function:

```bash
preflight() {
  command -v jq >/dev/null 2>&1 || { echo "jq is required. Install jq and retry." >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "Not authenticated. Run: gh auth login" >&2; exit 1; }
  resolve_repo
  local perm
  perm="$(gh repo view "$REPO" --json viewerPermission -q .viewerPermission 2>/dev/null || true)"
  if [ "$perm" != "ADMIN" ]; then
    echo "You need admin permission on $REPO to change rulesets (have: ${perm:-unknown})." >&2
    echo "Ask an org/repo admin to run this, or grant yourself the admin role." >&2
    exit 1
  fi
}

resolve_repo() {
  if [ -z "$REPO" ]; then
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  fi
  [ -n "$REPO" ] || { echo "Could not determine repo. Pass --repo <owner/repo>." >&2; exit 1; }
}
```

Update `main`:

```bash
main() {
  parse_args "$@"
  if [ "$PRINT_CONFIG" = true ]; then print_config; exit 0; fi
  preflight
  if [ "$PREFLIGHT_ONLY" = true ]; then exit 0; fi
}
```

Note: the fake `gh` returns `ADMIN`/`WRITE` for `viewerPermission` per `FAKE_GH_VIEWER_PERMISSION`, and exits 0 for `auth status`, so both tests exercise the real code path.

- [ ] **Step 4: Run to verify it passes**

Run: `bash skills/devops/github-lockdown/tests/run.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/devops/github-lockdown/
git commit -m "github-lockdown: preflight (auth, jq, admin permission)"
```

---

## Task 4: Build the default ruleset JSON (dry-run stdout)

**Files:**
- Modify: `skills/devops/github-lockdown/scripts/lockdown.sh` (`ref_includes`, `build_ruleset_json`, `main`)
- Test: `skills/devops/github-lockdown/tests/run.sh`

- [ ] **Step 1: Write the failing test**

Add to `tests/run.sh`. A default dry-run prints the JSON body to stdout; assert its shape with `jq`:

```bash
# jqok <json> <jq-filter-returning-true> <label>
jqok() {
  local got; got="$(printf '%s' "$1" | jq -r "$2" 2>/dev/null)"
  assert_eq "$got" "true" "$3"
}

test_default_ruleset_body() {
  local d; d="$(mktemp -d)"
  run_lockdown "$d/bin" FAKE_GH_VIEWER_PERMISSION=ADMIN FAKE_GH_RULESETS_JSON='[]' \
    -- --dry-run --repo octo/repo
  assert_eq "$RC" "0" "default dry-run exits 0"
  jqok "$OUT" '.name == "github-lockdown"'                                   "name is github-lockdown"
  jqok "$OUT" '.enforcement == "active"'                                     "enforcement active"
  jqok "$OUT" '.target == "branch"'                                          "target branch"
  jqok "$OUT" '(.bypass_actors | length) == 0'                              "no bypass actors"
  jqok "$OUT" '.conditions.ref_name.include == ["~DEFAULT_BRANCH"]'          "targets default branch"
  jqok "$OUT" 'any(.rules[]; .type == "non_fast_forward")'                   "blocks force-push"
  jqok "$OUT" 'any(.rules[]; .type == "deletion")'                          "blocks deletion"
  jqok "$OUT" '(.rules[] | select(.type=="pull_request") | .parameters.required_approving_review_count) == 0' "0 approvers"
  rm -rf "$d"
}

test_default_ruleset_body
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash skills/devops/github-lockdown/tests/run.sh`
Expected: FAIL — no JSON is printed yet (main exits after preflight).

- [ ] **Step 3: Implement `ref_includes` and `build_ruleset_json`; print body in dry-run**

Add functions:

```bash
ref_includes() {
  if [ -n "$BRANCH" ]; then
    jq -n --arg b "refs/heads/$BRANCH" '[$b]'
  else
    jq -n '["~DEFAULT_BRANCH"]'
  fi
}

build_ruleset_json() {
  local rules
  rules="$(jq -n \
    --argjson approvals "$APPROVALS" \
    --argjson dismiss "$DISMISS_STALE" \
    --argjson codeowner "$CODE_OWNER" \
    --argjson threadres "$THREAD_RES" \
    '[
      {type:"pull_request", parameters:{
        required_approving_review_count:$approvals,
        dismiss_stale_reviews_on_push:$dismiss,
        require_code_owner_review:$codeowner,
        require_last_push_approval:false,
        required_review_thread_resolution:$threadres
      }},
      {type:"non_fast_forward"},
      {type:"deletion"}
    ]')"

  [ "$LINEAR" = true ] && rules="$(jq '. + [{type:"required_linear_history"}]' <<<"$rules")"
  [ "$SIGNED" = true ] && rules="$(jq '. + [{type:"required_signatures"}]' <<<"$rules")"

  if [ -n "$STATUS_CHECKS" ]; then
    local checks
    checks="$(printf '%s' "$STATUS_CHECKS" | jq -R 'split(",") | map({context: (. | gsub("^\\s+|\\s+$";""))})')"
    rules="$(jq --argjson c "$checks" \
      '. + [{type:"required_status_checks", parameters:{
          required_status_checks:$c,
          strict_required_status_checks_policy:false,
          do_not_enforce_on_create:false }}]' <<<"$rules")"
  fi

  local bypass="[]"
  # RepositoryRole id 5 == the built-in "admin" repo role.
  [ "$ADMIN_BYPASS" = true ] && bypass='[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]'

  jq -n \
    --arg name "$NAME" \
    --argjson refs "$(ref_includes)" \
    --argjson rules "$rules" \
    --argjson bypass "$bypass" \
    '{
      name: $name,
      target: "branch",
      enforcement: "active",
      bypass_actors: $bypass,
      conditions: { ref_name: { include: $refs, exclude: [] } },
      rules: $rules
    }'
}
```

Extend `main` to build and (for now) print the body:

```bash
main() {
  parse_args "$@"
  if [ "$PRINT_CONFIG" = true ]; then print_config; exit 0; fi
  preflight
  if [ "$PREFLIGHT_ONLY" = true ]; then exit 0; fi
  local body; body="$(build_ruleset_json)"
  if [ "$DRY_RUN" = true ]; then printf '%s\n' "$body"; fi
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash skills/devops/github-lockdown/tests/run.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/devops/github-lockdown/
git commit -m "github-lockdown: build default ruleset JSON body"
```

---

## Task 5: Optional-rule flags flip the right fields

**Files:**
- Modify: none (behavior already implemented in Task 4) — this task adds regression tests.
- Test: `skills/devops/github-lockdown/tests/run.sh`

- [ ] **Step 1: Write the failing tests**

Add to `tests/run.sh`:

```bash
test_flags_flip_fields() {
  local d; d="$(mktemp -d)"
  run_lockdown "$d/bin" FAKE_GH_VIEWER_PERMISSION=ADMIN -- --dry-run --repo octo/repo \
    --approvals 2 --admin-bypass --linear-history --signed-commits \
    --require-code-owner-review --dismiss-stale-approvals \
    --require-conversation-resolution --status-checks "ci, build" --branch release
  jqok "$OUT" '(.rules[] | select(.type=="pull_request") | .parameters.required_approving_review_count) == 2' "approvals=2"
  jqok "$OUT" '(.rules[] | select(.type=="pull_request") | .parameters.require_code_owner_review) == true'     "code owner review on"
  jqok "$OUT" '(.rules[] | select(.type=="pull_request") | .parameters.dismiss_stale_reviews_on_push) == true' "dismiss stale on"
  jqok "$OUT" '(.rules[] | select(.type=="pull_request") | .parameters.required_review_thread_resolution) == true' "conversation resolution on"
  jqok "$OUT" 'any(.rules[]; .type=="required_linear_history")'   "linear history rule present"
  jqok "$OUT" 'any(.rules[]; .type=="required_signatures")'       "signatures rule present"
  jqok "$OUT" '(.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks) == [{context:"ci"},{context:"build"}]' "status checks trimmed + parsed"
  jqok "$OUT" '.bypass_actors == [{actor_id:5, actor_type:"RepositoryRole", bypass_mode:"always"}]' "admin bypass actor"
  jqok "$OUT" '.conditions.ref_name.include == ["refs/heads/release"]' "explicit branch target"
  rm -rf "$d"
}

test_flags_flip_fields
```

- [ ] **Step 2: Run to verify it fails or passes**

Run: `bash skills/devops/github-lockdown/tests/run.sh`
Expected: PASS if Task 4 is correct. If `--status-checks "ci, build"` fails the trim assertion, fix the `gsub` in `build_ruleset_json` so surrounding whitespace is stripped, then re-run until PASS.

- [ ] **Step 3: (only if a test failed) fix `build_ruleset_json`**

If the status-check trim assertion failed, ensure the `map` uses `gsub("^\\s+|\\s+$";"")` on each split element (as written in Task 4). Re-run.

- [ ] **Step 4: Confirm all pass**

Run: `bash skills/devops/github-lockdown/tests/run.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/devops/github-lockdown/
git commit -m "github-lockdown: lock in optional-rule flag behavior with tests"
```

---

## Task 6: Idempotent upsert (create vs update-by-id) + auto-delete plan

**Files:**
- Modify: `skills/devops/github-lockdown/scripts/lockdown.sh` (`find_ruleset_id`, `apply_ruleset`, `apply_auto_delete`, `main`)
- Test: `skills/devops/github-lockdown/tests/run.sh`

- [ ] **Step 1: Write the failing tests**

Add to `tests/run.sh`. Dry-run emits `PLAN ` lines on stderr:

```bash
test_plan_create() {
  local d; d="$(mktemp -d)"
  run_lockdown "$d/bin" FAKE_GH_VIEWER_PERMISSION=ADMIN FAKE_GH_RULESETS_JSON='[]' \
    -- --dry-run --repo octo/repo
  assert_contains "$ERR" "PLAN CREATE ruleset name=github-lockdown via POST repos/octo/repo/rulesets" "plans a CREATE when none exists"
  assert_contains "$ERR" "PLAN SET repos/octo/repo delete_branch_on_merge=true" "plans auto-delete"
  rm -rf "$d"
}

test_plan_update() {
  local d; d="$(mktemp -d)"
  run_lockdown "$d/bin" FAKE_GH_VIEWER_PERMISSION=ADMIN \
    FAKE_GH_RULESETS_JSON='[{"id":42,"name":"github-lockdown"},{"id":7,"name":"other"}]' \
    -- --dry-run --repo octo/repo
  assert_contains "$ERR" "PLAN UPDATE ruleset id=42 via PUT repos/octo/repo/rulesets/42" "plans an UPDATE by id when it exists"
  rm -rf "$d"
}

test_plan_no_auto_delete() {
  local d; d="$(mktemp -d)"
  run_lockdown "$d/bin" FAKE_GH_VIEWER_PERMISSION=ADMIN FAKE_GH_RULESETS_JSON='[]' \
    -- --dry-run --repo octo/repo --no-auto-delete
  case "$ERR" in *"delete_branch_on_merge"*) bad "no-auto-delete suppresses the plan" "found delete_branch_on_merge line";; *) ok "no-auto-delete suppresses the plan";; esac
  rm -rf "$d"
}

test_plan_create
test_plan_update
test_plan_no_auto_delete
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash skills/devops/github-lockdown/tests/run.sh`
Expected: FAIL — no `PLAN` lines are emitted yet.

- [ ] **Step 3: Implement upsert + auto-delete (dry-run branch first)**

Add functions:

```bash
find_ruleset_id() {
  gh api "repos/$REPO/rulesets" --paginate 2>/dev/null \
    | jq -r --arg n "$NAME" 'if type=="array" then . else [.] end | map(select(.name==$n)) | (.[0].id // empty)'
}

apply_ruleset() {
  local body="$1" id="$2"
  if [ "$DRY_RUN" = true ]; then
    if [ -n "$id" ]; then
      echo "PLAN UPDATE ruleset id=$id via PUT repos/$REPO/rulesets/$id" >&2
    else
      echo "PLAN CREATE ruleset name=$NAME via POST repos/$REPO/rulesets" >&2
    fi
    return 0
  fi
  if [ -n "$id" ]; then
    printf '%s' "$body" | gh api -X PUT "repos/$REPO/rulesets/$id" --input - >/dev/null
  else
    printf '%s' "$body" | gh api -X POST "repos/$REPO/rulesets" --input - >/dev/null
  fi
}

apply_auto_delete() {
  [ "$AUTO_DELETE" = true ] || return 0
  if [ "$DRY_RUN" = true ]; then
    echo "PLAN SET repos/$REPO delete_branch_on_merge=true" >&2
    return 0
  fi
  gh api -X PATCH "repos/$REPO" -F delete_branch_on_merge=true >/dev/null
}
```

Update `main`:

```bash
main() {
  parse_args "$@"
  if [ "$PRINT_CONFIG" = true ]; then print_config; exit 0; fi
  preflight
  if [ "$PREFLIGHT_ONLY" = true ]; then exit 0; fi
  local body id
  body="$(build_ruleset_json)"
  id="$(find_ruleset_id)"
  if [ "$DRY_RUN" = true ]; then printf '%s\n' "$body"; fi
  apply_ruleset "$body" "$id"
  apply_auto_delete
}
```

Note: the fake `gh` returns `FAKE_GH_RULESETS_JSON` for any `api` call whose args contain `rulesets`, which covers `find_ruleset_id`'s GET.

- [ ] **Step 4: Run to verify it passes**

Run: `bash skills/devops/github-lockdown/tests/run.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/devops/github-lockdown/
git commit -m "github-lockdown: idempotent upsert + auto-delete planning"
```

---

## Task 7: Real apply path + verify summary

**Files:**
- Modify: `skills/devops/github-lockdown/scripts/lockdown.sh` (`verify`, `main`)
- Modify: `skills/devops/github-lockdown/tests/fake-gh` (record `-X` method + path)
- Test: `skills/devops/github-lockdown/tests/run.sh`

- [ ] **Step 1: Write the failing test**

Add to `tests/run.sh`. A non-dry-run run must issue the real `gh api` mutation and print a verification summary. We record calls via `FAKE_GH_LOG`:

```bash
test_real_apply_records_calls() {
  local d; d="$(mktemp -d)"; local log="$d/gh.log"
  run_lockdown "$d/bin" FAKE_GH_VIEWER_PERMISSION=ADMIN FAKE_GH_RULESETS_JSON='[]' FAKE_GH_LOG="$log" \
    -- --repo octo/repo
  assert_eq "$RC" "0" "real apply exits 0"
  local logtext; logtext="$(cat "$log")"
  assert_contains "$logtext" "api -X POST repos/octo/repo/rulesets" "issues POST to create ruleset"
  assert_contains "$logtext" "api -X PATCH repos/octo/repo" "issues PATCH for auto-delete"
  assert_contains "$OUT" "Locked down" "prints a verification summary"
  rm -rf "$d"
}

test_real_apply_records_calls
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash skills/devops/github-lockdown/tests/run.sh`
Expected: FAIL — no `Locked down` summary is printed; the log-order assertion may also fail depending on arg formatting.

- [ ] **Step 3: Add `verify` and print a summary; ensure the fake gh logs enough**

The fake `gh` already logs `"$*"`. Confirm `tests/fake-gh` records the full argv (it does via `printf '%s\n' "$*"`). No change needed unless the log line differs; if the assertion substring doesn't match, adjust the fake to log `"$*"` verbatim (it already does).

Add `verify` to `lockdown.sh` and call it on the real path:

```bash
verify() {
  local approvals="$APPROVALS" target="default branch"
  [ -n "$BRANCH" ] && target="$BRANCH"
  echo "Locked down $REPO ($target): required PR, $approvals approver(s), force-push + deletion blocked."
  [ "$AUTO_DELETE" = true ] && echo "  Auto-delete merged branches: on."
  [ "$ADMIN_BYPASS" = true ] && echo "  Admin bypass: enabled."
}
```

Update the tail of `main`:

```bash
  apply_ruleset "$body" "$id"
  apply_auto_delete
  if [ "$DRY_RUN" != true ]; then verify; fi
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash skills/devops/github-lockdown/tests/run.sh`
Expected: PASS — all tests green.

- [ ] **Step 5: Commit**

```bash
git add skills/devops/github-lockdown/
git commit -m "github-lockdown: real apply path + verification summary"
```

---

## Task 8: `references/rulesets.md`

**Files:**
- Create: `skills/devops/github-lockdown/references/rulesets.md`

- [ ] **Step 1: Write the reference doc**

Create `skills/devops/github-lockdown/references/rulesets.md`:

```markdown
# GitHub rulesets: how this skill applies the lockdown

This skill enforces branch protection through **repository rulesets** (not classic
branch protection), plus the repo-level `delete_branch_on_merge` setting.

## What gets created

A ruleset named `github-lockdown` on the repo, `enforcement: active`, targeting the
default branch via the `~DEFAULT_BRANCH` ref selector (or `refs/heads/<branch>` when
`--branch` is passed). Default rules: `pull_request` with
`required_approving_review_count: 0`, `non_fast_forward` (block force-push), and
`deletion` (block branch deletion). By default **no bypass actors** — the rules apply
to everyone, including admins. `--admin-bypass` adds the built-in admin repo role
(RepositoryRole id 5) as an `always` bypass actor.

## Required permissions

You must have the **admin** role on the repo (the script checks `viewerPermission`).
`gh` must be authenticated (`gh auth login`) with a token that can manage rulesets.
`jq` must be installed.

## Idempotency

The script looks up an existing ruleset **by name** (`github-lockdown`). If found it
`PUT`s an update to that id; otherwise it `POST`s a new one. Re-running never creates
duplicates, and it never touches rulesets it did not create.

## Inspecting and undoing

- List rulesets: `gh api repos/<owner>/<repo>/rulesets`
- View one: `gh api repos/<owner>/<repo>/rulesets/<id>`
- Remove the lockdown: `gh api -X DELETE repos/<owner>/<repo>/rulesets/<id>`
- Turn off auto-delete: `gh api -X PATCH repos/<owner>/<repo> -F delete_branch_on_merge=false`

## Notes

- Rulesets are available on **public and private** repos, including free plans — this is
  why the skill uses them instead of classic branch protection.
- `--dry-run` prints the exact JSON body (stdout) and the planned actions (stderr) without
  changing anything.
- Status checks are matched by their **context** string (the check name that appears on the
  commit status); pass them comma-separated via `--status-checks`.
```

- [ ] **Step 2: Verify it renders and links are self-consistent**

Run: `grep -n "github-lockdown" skills/devops/github-lockdown/references/rulesets.md`
Expected: matches present; skim for accuracy against `scripts/lockdown.sh`.

- [ ] **Step 3: Commit**

```bash
git add skills/devops/github-lockdown/references/rulesets.md
git commit -m "github-lockdown: add rulesets reference doc"
```

---

## Task 9: `SKILL.md` (frontmatter + interview + procedure)

**Files:**
- Create: `skills/devops/github-lockdown/SKILL.md`

- [ ] **Step 1: Write SKILL.md**

Create `skills/devops/github-lockdown/SKILL.md`:

```markdown
---
name: github-lockdown
description: >-
  Lock down a GitHub repository: protect the default branch behind a required pull
  request (0 approvers by default), block force-pushes and branch deletion, and enable
  auto-delete of merged branches. Uses GitHub repository rulesets via the gh CLI, enforced
  for everyone including admins by default. Manual-only — invoke by name when you want to
  secure a repo ("lock down this repo", "protect main", "require PRs").
disable-model-invocation: true
metadata:
  author: martintechlabs
  version: "0.1.0"
---

# Lock down a GitHub repository

Protect a repo's default branch with a GitHub **repository ruleset** and turn on
auto-delete of merged branches. The bundled `scripts/lockdown.sh` does the work through
the `gh` CLI; it is **idempotent** (upserts one ruleset named `github-lockdown`) and only
ever *adds* protection — it never deletes branches, history, or rulesets it did not create.

## When this applies

- The target is a **GitHub** repo and you have (or can get) the **admin** role on it.
- `gh` is installed and authenticated (`gh auth login`) and `jq` is installed.

If the user is not an admin, stop and tell them an admin must run this — do not invent a
workaround.

## Defaults (the fast path)

The standard lockdown, applied with no flags:

- Protect the **default branch** (correct whether it's `main` or `master`).
- **Require a pull request**, with **0 required approvers**.
- **Block force-pushes** and **block branch deletion**.
- **Auto-delete** branches on merge.
- **No bypass** — enforced for everyone, including admins.

## Procedure

1. **Ask: defaults or customize?** Say exactly what the defaults are (above) and ask:
   *"Apply the standard lockdown, or customize it?"*
   - If they accept the defaults, go straight to step 3 with no other questions.

2. **If customizing, run this short interview** (offer the default in brackets; skip any
   the user doesn't care about):
   - Required approvers? [0]
   - Require status checks to pass? If so, which check names (comma-separated)? [none]
   - Any extras? (any of: require conversation resolution · require linear history ·
     require signed commits · require code-owner review · dismiss stale approvals on push)
     [none]
   - Should repo admins be allowed to bypass? [no]

3. **Resolve the target repo.** Default to the current repo. If ambiguous, ask for
   `owner/repo`.

4. **Dry-run and confirm.** Run the script with `--dry-run` and the chosen flags, show the
   user the planned changes, and get explicit confirmation before applying:

   ```bash
   skills/devops/github-lockdown/scripts/lockdown.sh --dry-run --repo <owner/repo> [flags]
   ```

5. **Apply.** Re-run without `--dry-run`. Report the verification summary the script prints.

## Flags

| Flag | Effect |
|------|--------|
| `--repo <owner/repo>` | Target repo (default: current repo) |
| `--branch <name>` | Protect a specific branch (default: the default branch) |
| `--approvals N` | Required approving reviews (default: 0) |
| `--admin-bypass` | Let repo admins bypass (default: off) |
| `--require-conversation-resolution` | Require review threads resolved before merge |
| `--linear-history` | Require linear history |
| `--signed-commits` | Require signed commits |
| `--require-code-owner-review` | Require a CODEOWNERS review |
| `--dismiss-stale-approvals` | Dismiss stale approvals on push |
| `--status-checks "ci,build"` | Require these status check contexts to pass |
| `--no-auto-delete` | Leave `delete_branch_on_merge` unchanged |
| `--dry-run` | Print planned changes; apply nothing |

See `references/rulesets.md` for the ruleset model, required permissions, and how to undo
the lockdown.
```

- [ ] **Step 2: Verify the frontmatter parses and matches the script's flags**

Run:
```bash
head -n 12 skills/devops/github-lockdown/SKILL.md
diff <(grep -oE '\-\-[a-z-]+' skills/devops/github-lockdown/SKILL.md | sort -u) \
     <(grep -oE '\-\-[a-z-]+' skills/devops/github-lockdown/scripts/lockdown.sh | sort -u) || true
```
Expected: frontmatter has `name: github-lockdown` and `disable-model-invocation: true`; the flag diff shows no user-facing flag documented in SKILL.md that the script does not implement (internal debug flags like `--print-config`/`--preflight-only` may appear only in the script — that's fine).

- [ ] **Step 3: Commit**

```bash
git add skills/devops/github-lockdown/SKILL.md
git commit -m "github-lockdown: add SKILL.md with interview + procedure"
```

---

## Task 10: Repo integration (README + skills.sh.json) and final verification

**Files:**
- Modify: `README.md` (DevOps table)
- Modify: `skills.sh.json` (devops grouping)

- [ ] **Step 1: Inspect the current grouping format**

Run: `cat skills.sh.json`
Expected: see the existing `devops` grouping that lists `conductor-neon-db`. Note the exact JSON shape so the edit matches.

- [ ] **Step 2: Add the skill to `skills.sh.json`**

Add `"github-lockdown"` to the same `devops` grouping array that contains `conductor-neon-db`, matching the existing formatting (order: keep alphabetical or append — follow whatever the file already does).

- [ ] **Step 3: Add the README row**

In `README.md`, under the **DevOps** table (the one containing `conductor-neon-db`), add a row:

```markdown
| [`github-lockdown`](skills/devops/github-lockdown/SKILL.md) | Locks down a GitHub repo — protects the default branch behind a required PR (0 approvers by default), blocks force-pushes and branch deletion, and auto-deletes merged branches — via GitHub repository rulesets and the `gh` CLI. Manual-only, idempotent, with a short interview and a `--dry-run` preview. |
```

- [ ] **Step 4: Validate JSON and run the full test suite**

Run:
```bash
jq . skills.sh.json >/dev/null && echo "skills.sh.json OK"
bash skills/devops/github-lockdown/tests/run.sh
```
Expected: `skills.sh.json OK`, then `... passed, 0 failed` (non-zero failures fail the task).

- [ ] **Step 5: Shellcheck (if available) and commit**

Run (best-effort lint):
```bash
command -v shellcheck >/dev/null && shellcheck skills/devops/github-lockdown/scripts/lockdown.sh skills/devops/github-lockdown/tests/run.sh skills/devops/github-lockdown/tests/fake-gh || echo "shellcheck not installed; skipping"
```
Fix any errors it reports (warnings are optional). Then:

```bash
git add README.md skills.sh.json
git commit -m "github-lockdown: list skill in README and skills.sh.json"
```

---

## Task 11: Live smoke test against a throwaway repo (manual, optional but recommended)

**Files:** none (runtime verification only)

This exercises the real `gh` path end-to-end. Skip only if no GitHub account is available; if skipped, say so explicitly rather than claiming it passed.

- [ ] **Step 1: Create a throwaway repo**

Run: `gh repo create gh-lockdown-smoke-$$ --private --clone && cd gh-lockdown-smoke-$$`
(Or use any repo you own and have admin on.)

- [ ] **Step 2: Dry-run**

Run: `/path/to/skills/devops/github-lockdown/scripts/lockdown.sh --dry-run`
Expected: prints a JSON ruleset body (stdout) and `PLAN CREATE ... / PLAN SET ... delete_branch_on_merge=true` (stderr). Nothing changes on GitHub.

- [ ] **Step 3: Apply, then verify idempotency**

Run:
```bash
/path/to/skills/devops/github-lockdown/scripts/lockdown.sh
/path/to/skills/devops/github-lockdown/scripts/lockdown.sh   # second run must UPDATE, not duplicate
gh api "repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)/rulesets"
```
Expected: first run prints "Locked down ..."; second run also succeeds; the rulesets list contains exactly **one** ruleset named `github-lockdown`.

- [ ] **Step 4: Confirm enforcement, then clean up**

Confirm in the GitHub UI (Settings → Rules) that the default branch requires a PR and blocks deletion/force-push, and that Settings → General → "Automatically delete head branches" is on. Then delete the throwaway repo:

Run: `gh repo delete gh-lockdown-smoke-$$ --yes`

---

## Self-Review

**Spec coverage:**
- Manual-only, rulesets mechanism, default lockdown (protect default branch, required PR, 0 approvers, block force-push/deletion, auto-delete) → Tasks 3–7, 9. ✓
- No-bypass-by-default, `--admin-bypass` escape hatch → Task 4/5. ✓
- Short interview + "just defaults" path → Task 9 (SKILL.md). ✓
- Idempotent upsert by name, `--dry-run`, verify, admin preflight, flag surface → Tasks 3, 4, 6, 7. ✓
- Plain-bash tests with fake-gh shim covering payload, upsert, flags, auto-delete, non-admin failure → Tasks 1–7. ✓
- `references/rulesets.md`, README row, `skills.sh.json` grouping → Tasks 8, 10. ✓

**Type/name consistency:** Globals (`REPO`, `APPROVALS`, `NAME`, `AUTO_DELETE`, `DRY_RUN`, …) and functions (`preflight`, `resolve_repo`, `ref_includes`, `build_ruleset_json`, `find_ruleset_id`, `apply_ruleset`, `apply_auto_delete`, `verify`, `main`) are used consistently across tasks. The ruleset name default `github-lockdown` is identical in the script, tests, SKILL.md, and reference doc. The dry-run `PLAN ` line strings in Task 6's implementation match Task 6's test assertions verbatim.

**Placeholder scan:** No TBD/TODO; every code step contains complete, runnable content.
```
