# plan-to-tickets Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a `plan-to-tickets` skill that turns a superpowers spec + implementation plan into a GitHub backlog — one epic issue plus complexity/model-tier/priority/dependency-tagged ticket sub-issues — via a tested `gh`+`jq` bash script, with the decomposition judgment (merging/splitting plan Tasks, picking tiers, ordering) done by the agent itself per SKILL.md's procedure.

**Architecture:** All decomposition judgment (merge tiny plan Tasks, split oversized ones, classify complexity/task-nature, assign an abstract model tier, compute dependencies/priority) lives in `SKILL.md` as agent-side reasoning — there is no code for it. That reasoning's *output* is a small ticket-plan JSON (schema fixed by this plan). A bundled `scripts/create-tickets.sh` does all the mechanical GitHub work through `gh`: validates the JSON (including that every dependency points to an earlier ticket), ensures labels exist, idempotently finds-or-creates the epic and each ticket issue by a hidden marker comment (so re-runs update instead of duplicating), links each ticket as a native GitHub sub-issue of the epic (falling back to a checkbox line in the epic body if that API is unavailable), and writes a manifest file. A `--dry-run` mode prints every planned `gh` call to stderr without mutating anything — this is the seam the tests assert against, and the seam the SKILL.md procedure uses for the user-facing confirmation gate before anything is filed for real. `tests/run.sh` is a plain-bash runner that PATH-shims a fake `gh` returning canned JSON, so nothing hits the network.

**Tech Stack:** Bash, GitHub CLI (`gh`), `jq`, GitHub Issues REST API (`gh issue create/edit/view/list`, `gh label list/create`), GitHub's sub-issues API (`repos/{owner}/{repo}/issues/{number}/sub_issues`).

---

## File Structure

```
skills/coding/plan-to-tickets/
├── SKILL.md                      # frontmatter + decomposition procedure + JSON schema + preview gate
├── references/model-tiers.md     # editable complexity × task-nature → abstract model-tier table
├── scripts/create-tickets.sh     # bash + gh + jq; idempotent; --dry-run seam
└── tests/
    ├── run.sh                    # plain-bash runner; PATH-shims a fake gh; assertions on gh calls + files
    └── fake-gh                   # fake `gh` shim used by all tests
```

Repo-level changes: add a row to the **Coding** table in `README.md`, and add `plan-to-tickets` to the `coding` grouping in `skills.sh.json`.

### Script internal contract (referenced by every task)

`create-tickets.sh` is organized into shell functions so tests and later tasks can target them. **No bash-4-only features** (no `declare -A`, no `mapfile`/`readarray`) — this repo's other scripts run on macOS's system `/bin/bash` (3.2), which lacks them; slug→number/id lookups use small `jq`-maintained JSON objects instead of associative arrays.

- `usage()` — prints help.
- `parse_args()` — sets globals from flags.
- `print_config()` — debug dump of parsed globals (test seam, like `github-lockdown`'s).
- `preflight()` — `jq` present, `gh auth status` succeeds; then (unless `--preflight-only`) validates `--input` was given, exists, and is valid JSON.
- `load_plan()` — reads the ticket-plan JSON into `$PLAN_JSON`; resolves `$REPO` (`--repo` flag > `.repo` in the JSON > `gh repo view`); calls `validate_dependency_order`.
- `validate_dependency_order()` — fails fast (exit 1) if any ticket's `depends_on_slugs` names a slug that isn't an *earlier* ticket's slug.
- `label_color(name)` — echoes a fixed color hex for known label names, a neutral gray default otherwise.
- `required_labels()` — echoes every label the plan needs (`epic` + the union of every ticket's `labels`), deduped.
- `existing_labels()` / `ensure_labels()` — list current repo labels; create any required label that's missing (dry-run: `PLAN CREATE LABEL` lines).
- `find_issue_by_marker(marker)` — echoes `"<number>\t<id>"` of the first open-or-closed issue whose body contains `marker`, or empty.
- `record_slug(slug, number, id)` / `slug_number(slug)` — maintain the slug→number/id map across the run (as `jq` objects, not associative arrays).
- `file_epic()` — find-or-create/update the epic issue by its marker comment; sets `$EPIC_NUMBER`/`$EPIC_ID`; records slug `epic`.
- `resolved_deps(i)` / `dependency_line(i)` — resolve ticket `i`'s `depends_on_slugs` to real issue numbers (`"#101, #102"`) / render the `Depends on: ...` body line.
- `file_tickets()` — loop over tickets in order (dependency order is creation order); find-or-create/update each by marker, with the `Depends on:` / `Part of #<epic>` lines appended to the body.
- `link_sub_issue(id, number, slug)` — call the sub-issues API; on failure, fall back to `append_checkbox_fallback`.
- `append_checkbox_fallback(number)` — append a `- [ ] #<number> <title>` line (under a `### Tickets` heading it creates once) to the epic body.
- `write_manifest()` — write `docs/superpowers/tickets/<plan-slug>.md` (resolved via `git rev-parse --show-toplevel`, not CWD) summarizing the epic + every ticket.
- `main()` — orchestrates the above.

**Flags:** `--input <file>` (required), `--repo <owner/repo>` (default: `.repo` in the JSON, or current repo), `--dry-run`, `--help`. Hidden/debug: `--print-config`, `--preflight-only`.

**Dry-run output contract (the test seam):** stderr = human plan lines, one per action, each starting with `PLAN `:
- `PLAN CREATE LABEL <name> (color #<hex>)`
- `PLAN CREATE epic issue "<title>"` / `PLAN UPDATE epic issue #<n>`
- `PLAN CREATE ticket "<title>" (<slug>)` / `PLAN UPDATE ticket issue #<n> (<slug>)`
- `PLAN LINK sub-issue (<slug>) under epic "<title>"`

### Ticket-plan JSON schema (the contract between SKILL.md's reasoning and the script)

```json
{
  "repo": "owner/repo",
  "plan_file": "docs/superpowers/plans/YYYY-MM-DD-<feature>.md",
  "epic": { "title": "string", "body": "string (goal/architecture summary, links to spec+plan)" },
  "tickets": [
    {
      "slug": "001-short-slug",
      "title": "string",
      "body": "string (concrete files/steps/code for this ticket's scope)",
      "labels": ["complexity:small|medium", "priority:p1|p2|p3", "model-tier:lite|efficient|standard|flagship"],
      "depends_on_slugs": ["<slug of an earlier ticket, if any>"]
    }
  ]
}
```

`repo` is optional (falls back per `load_plan`). `tickets` must be in dependency order — every `depends_on_slugs` entry must name a slug appearing *earlier* in the array; the script enforces this and fails fast otherwise. The script appends the `Depends on:`/`Part of #<epic>`/marker lines to each ticket's `body` itself — the agent-authored body should **not** include them.

---

## Task 1: Skill scaffold, test harness, fake `gh`, and `--help`

**Files:**
- Create: `skills/coding/plan-to-tickets/scripts/create-tickets.sh`
- Create: `skills/coding/plan-to-tickets/tests/run.sh`
- Create: `skills/coding/plan-to-tickets/tests/fake-gh`

- [ ] **Step 1: Write the test harness + first test**

Create `skills/coding/plan-to-tickets/tests/run.sh`:

```bash
#!/usr/bin/env bash
# Plain-bash test runner for create-tickets.sh. No network: a fake `gh` is put on PATH.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/create-tickets.sh"
PASS=0
FAIL=0

setup_path() {
  local bindir="$1"
  mkdir -p "$bindir"
  cp "$HERE/fake-gh" "$bindir/gh"
  chmod +x "$bindir/gh"
  echo "$bindir:$PATH"
}

# run_ct <bindir> <env-assignments...> -- <create-tickets.sh args...>
# Captures stdout->$OUT, stderr->$ERR, exit->$RC
run_ct() {
  local bindir="$1"; shift
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift  # drop --
  local outf errf workdir
  outf="$(mktemp)"; errf="$(mktemp)"
  # Run from the test's own temp dir (parent of $bindir), never the repo root: a real
  # (non-dry-run) invocation calls write_manifest, which resolves its output path via
  # `git rev-parse --show-toplevel` — without this, that would resolve to *this* repo
  # and leak a stray docs/superpowers/tickets/*.md file into it on every test run.
  workdir="$(dirname "$bindir")"
  ( cd "$workdir" && PATH="$(setup_path "$bindir")" env ${envs[@]+"${envs[@]}"} bash "$SCRIPT" "$@" >"$outf" 2>"$errf" )
  RC=$?
  OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

assert_eq()       { [ "$1" = "$2" ] && ok "$3" || bad "$3" "expected [$2] got [$1]"; }
assert_contains() { case "$1" in *"$2"*) ok "$3";; *) bad "$3" "[$1] did not contain [$2]";; esac; }
assert_not_contains() { case "$1" in *"$2"*) bad "$3" "[$1] contained [$2]";; *) ok "$3";; esac; }

# jqok <json> <jq-filter-returning-true> <label>
jqok() {
  local got; got="$(printf '%s' "$1" | jq -r "$2" 2>/dev/null)"
  assert_eq "$got" "true" "$3"
}

# ---- Task 1 test ----
test_help() {
  local d; d="$(mktemp -d)"
  run_ct "$d/bin" -- --help
  assert_eq "$RC" "0" "help exits 0"
  assert_contains "$OUT" "create-tickets.sh" "help mentions the script"
  assert_contains "$OUT" "--input" "help lists the --input flag"
  rm -rf "$d"
}

test_help

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
```

Create `skills/coding/plan-to-tickets/tests/fake-gh` (complete from the start — a test fixture, not production code; later tasks exercise more of it):

```bash
#!/usr/bin/env bash
# Fake `gh` for create-tickets.sh tests. Records every invocation to $FAKE_GH_LOG
# (argv joined by spaces, one call per line) and emits canned/deterministic output
# so tests never touch the network.
#
# Tunable via env vars:
#   FAKE_GH_AUTH_FAIL          "true" makes `gh auth status` fail
#   FAKE_GH_NAME_WITH_OWNER    default: octo/repo
#   FAKE_GH_LABELS             newline-separated existing label names (default: empty)
#   FAKE_GH_ISSUES_JSON        JSON array returned by `gh issue list` (default: [])
#   FAKE_GH_COUNTER_FILE       file holding the next issue number to mint (required for `issue create`)
#   FAKE_GH_SUBISSUES_FAIL     "true" makes the sub_issues POST fail
#   FAKE_GH_ISSUE_TITLE        title returned by `gh issue view --json title` (default: "Fake Title")
#   FAKE_GH_EPIC_BODY          body returned by `gh issue view --json body` (default: "")
#
# Issue "id" (the sub_issues linking field) is always number+9000, so tests can
# catch code that mixes up number vs id.
set -uo pipefail
[ -n "${FAKE_GH_LOG:-}" ] && printf '%s\n' "$*" >>"$FAKE_GH_LOG"

case "$1" in
  auth)
    [ "${FAKE_GH_AUTH_FAIL:-false}" = true ] && exit 1
    exit 0 ;;
  repo)
    printf '%s\n' "${FAKE_GH_NAME_WITH_OWNER:-octo/repo}"
    exit 0 ;;
  api)
    case "$*" in
      *sub_issues*)
        [ "${FAKE_GH_SUBISSUES_FAIL:-false}" = true ] && { echo "sub_issues unavailable" >&2; exit 1; }
        printf '{}\n' ;;
      *) printf '{}\n' ;;
    esac
    exit 0 ;;
  label)
    case "$2" in
      list) printf '%s\n' "${FAKE_GH_LABELS:-}" ;;
      create) exit 0 ;;
      *) exit 0 ;;
    esac
    exit 0 ;;
  issue)
    case "$2" in
      list)
        printf '%s\n' "${FAKE_GH_ISSUES_JSON:-[]}" ;;
      create)
        counter_file="${FAKE_GH_COUNTER_FILE:?FAKE_GH_COUNTER_FILE must be set}"
        [ -f "$counter_file" ] || echo 100 > "$counter_file"
        n="$(cat "$counter_file")"
        echo "$((n + 1))" > "$counter_file"
        printf 'https://github.com/%s/issues/%s\n' "${FAKE_GH_NAME_WITH_OWNER:-octo/repo}" "$n" ;;
      edit)
        exit 0 ;;
      view)
        num="$3"
        case "$*" in
          *'.id'*) echo "$((num + 9000))" ;;
          *'.title'*) printf '%s\n' "${FAKE_GH_ISSUE_TITLE:-Fake Title}" ;;
          *'.body'*) printf '%s\n' "${FAKE_GH_EPIC_BODY:-}" ;;
          *) printf '{}\n' ;;
        esac ;;
      *) exit 0 ;;
    esac
    exit 0 ;;
  *)
    exit 0 ;;
esac
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash skills/coding/plan-to-tickets/tests/run.sh`
Expected: FAIL — `create-tickets.sh` does not exist yet.

- [ ] **Step 3: Create the minimal script skeleton**

Create `skills/coding/plan-to-tickets/scripts/create-tickets.sh`:

```bash
#!/usr/bin/env bash
# create-tickets.sh: mechanical GitHub creation for plan-to-tickets. No decomposition
# logic here -- takes a ticket-plan JSON (epic + tickets, already ordered so every
# ticket's dependencies precede it) and idempotently files an epic issue plus ticket
# sub-issues on GitHub via `gh`.
set -euo pipefail

INPUT=""; REPO=""; DRY_RUN=false; PREFLIGHT_ONLY=false; PRINT_CONFIG=false
PLAN_JSON=""
EPIC_NUMBER=""; EPIC_ID=""
SLUG_NUMBERS='{}'
SLUG_IDS='{}'

usage() {
  cat <<'EOF'
create-tickets.sh — file a plan-to-tickets backlog on GitHub from a ticket-plan JSON.

Usage: create-tickets.sh --input <ticket-plan.json> [flags]

Flags:
  --input <file>        Ticket-plan JSON (required; see SKILL.md for the schema)
  --repo <owner/repo>   Target repo (default: .repo in the JSON, or current repo)
  --dry-run             Print every planned gh call; apply nothing
  --help                Show this help
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

Run: `bash skills/coding/plan-to-tickets/tests/run.sh`
Expected: PASS — `3 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
chmod +x skills/coding/plan-to-tickets/scripts/create-tickets.sh skills/coding/plan-to-tickets/tests/run.sh skills/coding/plan-to-tickets/tests/fake-gh
git add skills/coding/plan-to-tickets/
git commit -m "plan-to-tickets: scaffold script, test harness, and --help"
```

---

## Task 2: Flag parsing

**Files:**
- Modify: `skills/coding/plan-to-tickets/scripts/create-tickets.sh` (`parse_args`, add `print_config`)
- Test: `skills/coding/plan-to-tickets/tests/run.sh`

- [ ] **Step 1: Write the failing test**

Add to `tests/run.sh` before the summary block:

```bash
test_parse_args() {
  local d; d="$(mktemp -d)"
  run_ct "$d/bin" -- --print-config --input plan.json --repo acme/widgets --dry-run
  assert_contains "$OUT" "INPUT=plan.json"     "parses --input"
  assert_contains "$OUT" "REPO=acme/widgets"   "parses --repo"
  assert_contains "$OUT" "DRY_RUN=true"        "parses --dry-run"
  rm -rf "$d"
}

test_parse_args
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash skills/coding/plan-to-tickets/tests/run.sh`
Expected: FAIL — `--print-config`/`--input`/`--repo`/`--dry-run` are all ignored.

- [ ] **Step 3: Implement full `parse_args` and `print_config`**

Replace `parse_args` in `create-tickets.sh`:

```bash
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --input) [ $# -ge 2 ] || { echo "Missing value for --input" >&2; exit 2; }; INPUT="$2"; shift 2 ;;
      --repo) [ $# -ge 2 ] || { echo "Missing value for --repo" >&2; exit 2; }; REPO="$2"; shift 2 ;;
      --dry-run) DRY_RUN=true; shift ;;
      --print-config) PRINT_CONFIG=true; shift ;;
      --help) usage; exit 0 ;;
      *) echo "Unknown flag: $1" >&2; usage >&2; exit 2 ;;
    esac
  done
}

print_config() {
  cat <<EOF
INPUT=$INPUT
REPO=$REPO
DRY_RUN=$DRY_RUN
EOF
}
```

Update `main`:

```bash
main() {
  parse_args "$@"
  if [ "$PRINT_CONFIG" = true ]; then print_config; exit 0; fi
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash skills/coding/plan-to-tickets/tests/run.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/coding/plan-to-tickets/
git commit -m "plan-to-tickets: full flag parsing"
```

---

## Task 3: Preflight (`jq`, `gh auth`)

**Files:**
- Modify: `skills/coding/plan-to-tickets/scripts/create-tickets.sh` (`preflight`, `parse_args`, `main`)
- Test: `skills/coding/plan-to-tickets/tests/run.sh`

- [ ] **Step 1: Write the failing tests**

Add to `tests/run.sh`. A hidden `--preflight-only` flag runs preflight then exits, so tests can target it without needing a valid `--input`:

```bash
test_preflight_auth_ok() {
  local d; d="$(mktemp -d)"
  run_ct "$d/bin" -- --preflight-only
  assert_eq "$RC" "0" "preflight passes when authenticated"
  rm -rf "$d"
}

test_preflight_auth_fail() {
  local d; d="$(mktemp -d)"
  run_ct "$d/bin" FAKE_GH_AUTH_FAIL=true -- --preflight-only
  assert_eq "$RC" "1" "preflight fails when not authenticated"
  assert_contains "$ERR" "Not authenticated" "clear error when not authenticated"
  rm -rf "$d"
}

test_preflight_auth_ok
test_preflight_auth_fail
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash skills/coding/plan-to-tickets/tests/run.sh`
Expected: FAIL — `--preflight-only` is an unknown flag (exit 2).

- [ ] **Step 3: Implement `preflight` and wire it up**

Add the flag to `parse_args` (new case, alongside the others):

```bash
      --preflight-only) PREFLIGHT_ONLY=true; shift ;;
```

Add the function:

```bash
preflight() {
  command -v jq >/dev/null 2>&1 || { echo "jq is required. Install jq and retry." >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "Not authenticated. Run: gh auth login" >&2; exit 1; }
  if [ "$PREFLIGHT_ONLY" = true ]; then return 0; fi
  [ -n "$INPUT" ] || { echo "Missing --input <ticket-plan.json>." >&2; exit 2; }
  [ -f "$INPUT" ] || { echo "No such file: $INPUT" >&2; exit 1; }
  jq -e . "$INPUT" >/dev/null 2>&1 || { echo "$INPUT is not valid JSON." >&2; exit 1; }
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

Note: `preflight`'s `--input`/file/JSON checks only run when `PREFLIGHT_ONLY` is false, so `--preflight-only` alone (no `--input`) still exercises the auth/jq checks without needing a real file — matching the two tests above.

- [ ] **Step 4: Run to verify it passes**

Run: `bash skills/coding/plan-to-tickets/tests/run.sh`
Expected: PASS.

Note on scope: this task deliberately does not test a *missing* `jq` via `PATH` manipulation — on this repo's dev machines multiple standard directories (e.g. `/usr/bin`) can independently provide a `jq` binary, making that scenario environment-dependent and flaky to assert on. `github-lockdown`'s test suite has the same gap for the same reason; the `command -v jq` check itself is still present in the script.

- [ ] **Step 5: Commit**

```bash
git add skills/coding/plan-to-tickets/
git commit -m "plan-to-tickets: preflight (jq, gh auth)"
```

---

## Task 4: Load the ticket-plan JSON + dependency-order validation

**Files:**
- Modify: `skills/coding/plan-to-tickets/scripts/create-tickets.sh` (`load_plan`, `validate_dependency_order`, `main`)
- Test: `skills/coding/plan-to-tickets/tests/run.sh`

- [ ] **Step 1: Write the failing tests**

Add to `tests/run.sh`:

```bash
test_missing_input_value_flag() {
  local d; d="$(mktemp -d)"
  run_ct "$d/bin" -- --input
  assert_eq "$RC" "2" "missing --input value exits 2"
  assert_contains "$ERR" "Missing value for --input" "clear error for missing --input value"
  rm -rf "$d"
}

test_input_not_found() {
  local d; d="$(mktemp -d)"
  run_ct "$d/bin" -- --input "$d/nope.json"
  assert_eq "$RC" "1" "missing input file exits 1"
  assert_contains "$ERR" "No such file" "clear error for missing input file"
  rm -rf "$d"
}

test_input_invalid_json() {
  local d; d="$(mktemp -d)"
  printf 'not json' > "$d/bad.json"
  run_ct "$d/bin" -- --input "$d/bad.json"
  assert_eq "$RC" "1" "invalid JSON input exits 1"
  assert_contains "$ERR" "not valid JSON" "clear error for invalid JSON"
  rm -rf "$d"
}

write_good_plan() {
  cat > "$1" <<'EOF'
{
  "repo": "octo/repo",
  "plan_file": "docs/superpowers/plans/2026-07-18-example.md",
  "epic": {"title": "Example Feature", "body": "Epic body text."},
  "tickets": [
    {"slug": "001-a", "title": "Ticket A", "body": "Body A",
     "labels": ["complexity:small", "priority:p1", "model-tier:efficient"], "depends_on_slugs": []},
    {"slug": "002-b", "title": "Ticket B", "body": "Body B",
     "labels": ["complexity:medium", "priority:p1", "model-tier:standard"], "depends_on_slugs": ["001-a"]}
  ]
}
EOF
}

write_bad_dependency_plan() {
  cat > "$1" <<'EOF'
{
  "repo": "octo/repo",
  "plan_file": "docs/superpowers/plans/2026-07-18-example.md",
  "epic": {"title": "Example Feature", "body": "Epic body text."},
  "tickets": [
    {"slug": "001-a", "title": "Ticket A", "body": "Body A", "labels": ["complexity:small"], "depends_on_slugs": ["999-nope"]}
  ]
}
EOF
}

test_dependency_validation_fails() {
  local d; d="$(mktemp -d)"
  write_bad_dependency_plan "$d/plan.json"
  run_ct "$d/bin" -- --input "$d/plan.json"
  assert_eq "$RC" "1" "unknown/forward dependency exits 1"
  assert_contains "$ERR" "001-a depends on unknown/forward slug 999-nope" "names the bad ticket and slug"
  rm -rf "$d"
}

test_dependency_validation_passes() {
  local d; d="$(mktemp -d)"
  write_good_plan "$d/plan.json"
  # FAKE_GH_ISSUES_JSON/FAKE_GH_COUNTER_FILE are set so this test stays valid once later
  # tasks wire more of main() past load_plan — right now (Task 4) main() stops here anyway.
  run_ct "$d/bin" FAKE_GH_ISSUES_JSON='[]' FAKE_GH_COUNTER_FILE="$d/counter" -- --input "$d/plan.json"
  assert_eq "$RC" "0" "well-ordered dependencies load cleanly"
  rm -rf "$d"
}

test_missing_input_value_flag
test_input_not_found
test_input_invalid_json
test_dependency_validation_fails
test_dependency_validation_passes
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash skills/coding/plan-to-tickets/tests/run.sh`
Expected: FAIL — `main` doesn't call `load_plan` yet, so the dependency tests don't exercise it (they'll pass trivially/incorrectly or the later tasks' assumption breaks) — confirm the two flag/file tests (`test_missing_input_value_flag`, `test_input_not_found`, `test_input_invalid_json`) already pass from Task 3's `preflight`, and the two dependency tests fail with `RC=0` for both (no validation ever runs).

- [ ] **Step 3: Implement `load_plan` and `validate_dependency_order`**

Add the functions:

```bash
load_plan() {
  PLAN_JSON="$(cat "$INPUT")"
  if [ -z "$REPO" ]; then
    REPO="$(jq -r '.repo // empty' <<<"$PLAN_JSON")"
  fi
  if [ -z "$REPO" ]; then
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  fi
  [ -n "$REPO" ] || { echo "Could not determine target repo. Pass --repo or set .repo in the ticket-plan JSON." >&2; exit 1; }
  validate_dependency_order
}

validate_dependency_order() {
  local bad
  bad="$(jq -r '
    [.tickets[].slug] as $slugs
    | [ range(0; (.tickets | length)) as $i
        | (.tickets[$i].depends_on_slugs // [])[] as $dep
        | select( ($slugs[0:$i] | index($dep)) == null )
        | "\(.tickets[$i].slug) depends on unknown/forward slug \($dep)"
      ]
    | .[]
  ' <<<"$PLAN_JSON")"
  if [ -n "$bad" ]; then
    echo "Invalid ticket-plan JSON: every depends_on_slugs entry must name an earlier ticket's slug." >&2
    printf '%s\n' "$bad" >&2
    exit 1
  fi
}
```

Update `main`:

```bash
main() {
  parse_args "$@"
  if [ "$PRINT_CONFIG" = true ]; then print_config; exit 0; fi
  preflight
  if [ "$PREFLIGHT_ONLY" = true ]; then exit 0; fi
  load_plan
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash skills/coding/plan-to-tickets/tests/run.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/coding/plan-to-tickets/
git commit -m "plan-to-tickets: load ticket-plan JSON, validate dependency order"
```

---

## Task 5: Label ensure (create missing labels, skip existing)

**Files:**
- Modify: `skills/coding/plan-to-tickets/scripts/create-tickets.sh` (`label_color`, `required_labels`, `existing_labels`, `ensure_labels`, `main`)
- Test: `skills/coding/plan-to-tickets/tests/run.sh`

- [ ] **Step 1: Write the failing tests**

Add to `tests/run.sh`:

```bash
test_ensure_labels_dry_run_only_missing() {
  local d; d="$(mktemp -d)"
  write_good_plan "$d/plan.json"
  run_ct "$d/bin" FAKE_GH_LABELS=$'epic\ncomplexity:small' -- --input "$d/plan.json" --dry-run
  assert_contains "$ERR" "PLAN CREATE LABEL complexity:medium" "plans creating a missing label"
  assert_contains "$ERR" "PLAN CREATE LABEL priority:p1" "plans creating another missing label"
  assert_not_contains "$ERR" "PLAN CREATE LABEL epic" "does not re-plan an existing label"
  assert_not_contains "$ERR" "PLAN CREATE LABEL complexity:small" "does not re-plan another existing label"
  rm -rf "$d"
}

test_ensure_labels_real_run() {
  local d; d="$(mktemp -d)"; local log="$d/gh.log"
  write_good_plan "$d/plan.json"
  run_ct "$d/bin" FAKE_GH_LABELS=$'epic' FAKE_GH_LOG="$log" FAKE_GH_COUNTER_FILE="$d/counter" \
    -- --input "$d/plan.json" --repo octo/repo
  local logtext; logtext="$(cat "$log")"
  assert_contains "$logtext" "label create complexity:small --repo octo/repo --color 0e8a16 --force" "creates a missing label with its color"
  assert_not_contains "$logtext" "label create epic" "does not recreate an existing label"
  rm -rf "$d"
}

test_ensure_labels_dry_run_only_missing
test_ensure_labels_real_run
```

Note: `test_ensure_labels_real_run` runs the *whole* script for real (no `--dry-run`), which will fail past `ensure_labels` right now (nothing else is implemented yet, so `main` just returns after `load_plan` — that's fine, the assertions only check the label-related log lines).

- [ ] **Step 2: Run to verify it fails**

Run: `bash skills/coding/plan-to-tickets/tests/run.sh`
Expected: FAIL — no `PLAN CREATE LABEL` lines and no `label create` calls yet.

- [ ] **Step 3: Implement label ensure**

Add the functions:

```bash
label_color() {
  case "$1" in
    epic) echo "5319e7" ;;
    complexity:small) echo "0e8a16" ;;
    complexity:medium) echo "fbca04" ;;
    priority:p1) echo "b60205" ;;
    priority:p2) echo "d93f0b" ;;
    priority:p3) echo "c5def5" ;;
    model-tier:lite) echo "bfd4f2" ;;
    model-tier:efficient) echo "1d76db" ;;
    model-tier:standard) echo "0052cc" ;;
    model-tier:flagship) echo "5319e7" ;;
    *) echo "ededed" ;;
  esac
}

required_labels() {
  jq -r '["epic"] + [.tickets[].labels[]] | unique | .[]' <<<"$PLAN_JSON"
}

existing_labels() {
  gh label list --repo "$REPO" --json name -q '.[].name' 2>/dev/null || true
}

ensure_labels() {
  local existing name color
  existing="$(existing_labels)"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if grep -qxF "$name" <<<"$existing"; then continue; fi
    color="$(label_color "$name")"
    if [ "$DRY_RUN" = true ]; then
      echo "PLAN CREATE LABEL $name (color #$color)" >&2
      continue
    fi
    gh label create "$name" --repo "$REPO" --color "$color" --force >/dev/null
  done < <(required_labels)
}
```

Update `main`:

```bash
main() {
  parse_args "$@"
  if [ "$PRINT_CONFIG" = true ]; then print_config; exit 0; fi
  preflight
  if [ "$PREFLIGHT_ONLY" = true ]; then exit 0; fi
  load_plan
  ensure_labels
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash skills/coding/plan-to-tickets/tests/run.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/coding/plan-to-tickets/
git commit -m "plan-to-tickets: ensure required labels exist"
```

---

## Task 6: Epic find-or-create/update (marker-based idempotency)

**Files:**
- Modify: `skills/coding/plan-to-tickets/scripts/create-tickets.sh` (`find_issue_by_marker`, `record_slug`, `slug_number`, `file_epic`, `main`)
- Test: `skills/coding/plan-to-tickets/tests/run.sh`

- [ ] **Step 1: Write the failing tests**

Add to `tests/run.sh`:

```bash
test_epic_dry_run_create_when_absent() {
  local d; d="$(mktemp -d)"
  write_good_plan "$d/plan.json"
  run_ct "$d/bin" FAKE_GH_ISSUES_JSON='[]' -- --input "$d/plan.json" --dry-run
  assert_contains "$ERR" 'PLAN CREATE epic issue "Example Feature"' "plans creating the epic when none exists"
  rm -rf "$d"
}

test_epic_dry_run_update_when_present() {
  local d; d="$(mktemp -d)"
  write_good_plan "$d/plan.json"
  local issues='[{"number":100,"id":9100,"body":"old body\n\n<!-- plan-to-tickets:epic:docs/superpowers/plans/2026-07-18-example.md -->"}]'
  run_ct "$d/bin" FAKE_GH_ISSUES_JSON="$issues" -- --input "$d/plan.json" --dry-run
  assert_contains "$ERR" "PLAN UPDATE epic issue #100" "plans updating the existing epic by marker"
  rm -rf "$d"
}

test_epic_real_create() {
  local d; d="$(mktemp -d)"; local log="$d/gh.log"
  write_good_plan "$d/plan.json"
  run_ct "$d/bin" FAKE_GH_ISSUES_JSON='[]' FAKE_GH_LOG="$log" FAKE_GH_COUNTER_FILE="$d/counter" \
    -- --input "$d/plan.json" --repo octo/repo
  assert_contains "$(cat "$log")" "issue create --repo octo/repo --title Example Feature" "creates the epic issue"
  assert_contains "$(cat "$log")" "--label epic" "labels the epic issue"
  rm -rf "$d"
}

test_epic_real_update() {
  local d; d="$(mktemp -d)"; local log="$d/gh.log"
  write_good_plan "$d/plan.json"
  local issues='[{"number":100,"id":9100,"body":"old body\n\n<!-- plan-to-tickets:epic:docs/superpowers/plans/2026-07-18-example.md -->"}]'
  run_ct "$d/bin" FAKE_GH_ISSUES_JSON="$issues" FAKE_GH_LOG="$log" FAKE_GH_COUNTER_FILE="$d/counter" \
    -- --input "$d/plan.json" --repo octo/repo
  assert_contains "$(cat "$log")" "issue edit 100 --repo octo/repo --title Example Feature" "updates the existing epic by number, not a new create"
  # Scoped to the epic's own title, not "issue create" anywhere: once later tasks wire
  # file_tickets into main(), this same plan's (not-yet-seeded) tickets legitimately get
  # created — only the epic itself must never be recreated.
  assert_not_contains "$(cat "$log")" "issue create --repo octo/repo --title Example Feature" "never creates a duplicate epic"
  rm -rf "$d"
}

test_epic_dry_run_create_when_absent
test_epic_dry_run_update_when_present
test_epic_real_create
test_epic_real_update
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash skills/coding/plan-to-tickets/tests/run.sh`
Expected: FAIL — no epic handling exists yet.

- [ ] **Step 3: Implement marker lookup, slug tracking, and `file_epic`**

Add the functions:

```bash
find_issue_by_marker() {
  local marker="$1"
  gh issue list --repo "$REPO" --state all --json number,id,body --limit 200 2>/dev/null \
    | jq -r --arg m "$marker" '
        map(select(.body // "" | contains($m))) as $found
        | if ($found | length) == 0 then empty else "\($found[0].number)\t\($found[0].id)" end
      '
}

record_slug() {
  local slug="$1" num="$2" id="$3"
  SLUG_NUMBERS="$(jq --arg s "$slug" --arg n "$num" '. + {($s): $n}' <<<"$SLUG_NUMBERS")"
  SLUG_IDS="$(jq --arg s "$slug" --arg i "$id" '. + {($s): $i}' <<<"$SLUG_IDS")"
}

slug_number() { jq -r --arg s "$1" '.[$s] // empty' <<<"$SLUG_NUMBERS"; }

file_epic() {
  local plan_file title body marker found num id
  plan_file="$(jq -r '.plan_file' <<<"$PLAN_JSON")"
  marker="<!-- plan-to-tickets:epic:$plan_file -->"
  title="$(jq -r '.epic.title' <<<"$PLAN_JSON")"
  body="$(jq -r '.epic.body' <<<"$PLAN_JSON")"$'\n\n'"$marker"

  found="$(find_issue_by_marker "$marker")"
  if [ -n "$found" ]; then
    num="$(cut -f1 <<<"$found")"; id="$(cut -f2 <<<"$found")"
    if [ "$DRY_RUN" = true ]; then
      echo "PLAN UPDATE epic issue #$num" >&2
    else
      gh issue edit "$num" --repo "$REPO" --title "$title" --body "$body" >/dev/null
    fi
  else
    if [ "$DRY_RUN" = true ]; then
      echo "PLAN CREATE epic issue \"$title\"" >&2
      num=""; id=""
    else
      local url
      url="$(gh issue create --repo "$REPO" --title "$title" --body "$body" --label epic)"
      num="$(basename "$url")"
      id="$(gh issue view "$num" --repo "$REPO" --json id -q .id)"
    fi
  fi
  EPIC_NUMBER="$num"; EPIC_ID="$id"
  record_slug "epic" "$EPIC_NUMBER" "$EPIC_ID"
}
```

Update `main`:

```bash
main() {
  parse_args "$@"
  if [ "$PRINT_CONFIG" = true ]; then print_config; exit 0; fi
  preflight
  if [ "$PREFLIGHT_ONLY" = true ]; then exit 0; fi
  load_plan
  ensure_labels
  file_epic
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash skills/coding/plan-to-tickets/tests/run.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/coding/plan-to-tickets/
git commit -m "plan-to-tickets: idempotent epic find-or-create/update"
```

---

## Task 7: Ticket loop — create/update with `Depends on:`/`Part of` lines

**Files:**
- Modify: `skills/coding/plan-to-tickets/scripts/create-tickets.sh` (`resolved_deps`, `dependency_line`, `file_tickets`, `main`)
- Test: `skills/coding/plan-to-tickets/tests/run.sh`

- [ ] **Step 1: Write the failing tests**

Add to `tests/run.sh`:

```bash
test_tickets_dry_run() {
  local d; d="$(mktemp -d)"
  write_good_plan "$d/plan.json"
  run_ct "$d/bin" FAKE_GH_ISSUES_JSON='[]' -- --input "$d/plan.json" --dry-run
  assert_contains "$ERR" 'PLAN CREATE ticket "Ticket A" (001-a)' "plans creating ticket A"
  assert_contains "$ERR" 'PLAN CREATE ticket "Ticket B" (002-b)' "plans creating ticket B"
  rm -rf "$d"
}

test_tickets_real_create_with_resolved_dependency() {
  local d; d="$(mktemp -d)"; local log="$d/gh.log"
  write_good_plan "$d/plan.json"
  run_ct "$d/bin" FAKE_GH_ISSUES_JSON='[]' FAKE_GH_LOG="$log" FAKE_GH_COUNTER_FILE="$d/counter" \
    -- --input "$d/plan.json" --repo octo/repo
  local logtext; logtext="$(cat "$log")"
  assert_contains "$logtext" "issue create --repo octo/repo --title Ticket A --body Body A" "creates ticket A"
  assert_contains "$logtext" "--label complexity:small --label priority:p1 --label model-tier:efficient" "labels ticket A"
  assert_contains "$logtext" "issue create --repo octo/repo --title Ticket B --body Body B" "creates ticket B"
  assert_contains "$logtext" "Depends on: #101" "ticket B's body resolves its dependency to a real issue number"
  assert_contains "$logtext" "Part of #100" "ticket B's body references the epic"
  rm -rf "$d"
}

test_tickets_idempotent_update() {
  local d; d="$(mktemp -d)"; local log="$d/gh.log"
  write_good_plan "$d/plan.json"
  local issues='[
    {"number":100,"id":9100,"body":"<!-- plan-to-tickets:epic:docs/superpowers/plans/2026-07-18-example.md -->"},
    {"number":101,"id":9101,"body":"Body A\n\nPart of #100\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/2026-07-18-example.md:001-a -->"},
    {"number":102,"id":9102,"body":"Body B\n\nDepends on: #101\n\nPart of #100\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/2026-07-18-example.md:002-b -->"}
  ]'
  run_ct "$d/bin" FAKE_GH_ISSUES_JSON="$issues" FAKE_GH_LOG="$log" FAKE_GH_COUNTER_FILE="$d/counter" \
    -- --input "$d/plan.json" --repo octo/repo
  local logtext; logtext="$(cat "$log")"
  assert_contains "$logtext" "issue edit 101" "updates ticket A by number"
  assert_contains "$logtext" "issue edit 102" "updates ticket B by number"
  assert_not_contains "$logtext" "issue create --repo octo/repo --title Ticket" "never duplicates a ticket"
  rm -rf "$d"
}

test_tickets_dry_run
test_tickets_real_create_with_resolved_dependency
test_tickets_idempotent_update
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash skills/coding/plan-to-tickets/tests/run.sh`
Expected: FAIL — no ticket handling exists yet.

- [ ] **Step 3: Implement dependency resolution and the ticket loop**

Add the functions:

```bash
# resolved_deps <ticket-index>: "#101, #102" (resolved issue numbers) or "" if none.
resolved_deps() {
  local i="$1" dep deps out first n
  deps="$(jq -r ".tickets[$i].depends_on_slugs[]?" <<<"$PLAN_JSON")"
  [ -n "$deps" ] || { printf ''; return 0; }
  out=""
  first=true
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    n="#$(slug_number "$dep")"
    if [ "$first" = true ]; then out="$n"; first=false; else out="$out, $n"; fi
  done <<<"$deps"
  printf '%s' "$out"
}

dependency_line() {
  local i="$1" deps
  deps="$(resolved_deps "$i")"
  [ -n "$deps" ] || { printf ''; return 0; }
  printf 'Depends on: %s' "$deps"
}

file_tickets() {
  local count i slug title body marker found num id deps_line
  count="$(jq '.tickets | length' <<<"$PLAN_JSON")"
  i=0
  while [ "$i" -lt "$count" ]; do
    slug="$(jq -r ".tickets[$i].slug" <<<"$PLAN_JSON")"
    title="$(jq -r ".tickets[$i].title" <<<"$PLAN_JSON")"
    body="$(jq -r ".tickets[$i].body" <<<"$PLAN_JSON")"
    marker="<!-- plan-to-tickets:ticket:$(jq -r '.plan_file' <<<"$PLAN_JSON"):$slug -->"

    deps_line="$(dependency_line "$i")"
    [ -n "$deps_line" ] && body="$body"$'\n\n'"$deps_line"
    body="$body"$'\n\n'"Part of #$EPIC_NUMBER"$'\n'"$marker"

    found="$(find_issue_by_marker "$marker")"
    if [ -n "$found" ]; then
      num="$(cut -f1 <<<"$found")"; id="$(cut -f2 <<<"$found")"
      if [ "$DRY_RUN" = true ]; then
        echo "PLAN UPDATE ticket issue #$num ($slug)" >&2
      else
        gh issue edit "$num" --repo "$REPO" --title "$title" --body "$body" >/dev/null
      fi
    else
      if [ "$DRY_RUN" = true ]; then
        echo "PLAN CREATE ticket \"$title\" ($slug)" >&2
        num=""; id=""
      else
        local args=(--repo "$REPO" --title "$title" --body "$body")
        local label
        while IFS= read -r label; do
          [ -n "$label" ] || continue
          args+=(--label "$label")
        done < <(jq -r ".tickets[$i].labels[]" <<<"$PLAN_JSON")
        local url
        url="$(gh issue create "${args[@]}")"
        num="$(basename "$url")"
        id="$(gh issue view "$num" --repo "$REPO" --json id -q .id)"
      fi
    fi

    record_slug "$slug" "$num" "$id"
    i=$((i + 1))
  done
}
```

Update `main`:

```bash
main() {
  parse_args "$@"
  if [ "$PRINT_CONFIG" = true ]; then print_config; exit 0; fi
  preflight
  if [ "$PREFLIGHT_ONLY" = true ]; then exit 0; fi
  load_plan
  ensure_labels
  file_epic
  file_tickets
}
```

Note: sub-issue linking is intentionally not called yet — Task 8 adds it. This task's tests only assert on ticket create/update, labels, and body content.

- [ ] **Step 4: Run to verify it passes**

Run: `bash skills/coding/plan-to-tickets/tests/run.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/coding/plan-to-tickets/
git commit -m "plan-to-tickets: ticket find-or-create/update with resolved dependencies"
```

---

## Task 8: Sub-issue linking + checkbox fallback

**Files:**
- Modify: `skills/coding/plan-to-tickets/scripts/create-tickets.sh` (`link_sub_issue`, `append_checkbox_fallback`, `file_tickets`)
- Test: `skills/coding/plan-to-tickets/tests/run.sh`

- [ ] **Step 1: Write the failing tests**

Add to `tests/run.sh`:

```bash
test_sub_issue_link_success() {
  local d; d="$(mktemp -d)"; local log="$d/gh.log"
  write_good_plan "$d/plan.json"
  run_ct "$d/bin" FAKE_GH_ISSUES_JSON='[]' FAKE_GH_LOG="$log" FAKE_GH_COUNTER_FILE="$d/counter" \
    -- --input "$d/plan.json" --repo octo/repo
  local logtext; logtext="$(cat "$log")"
  assert_contains "$logtext" "api repos/octo/repo/issues/100/sub_issues -f sub_issue_id=9101" "links ticket A as a sub-issue by id (not number)"
  assert_contains "$logtext" "api repos/octo/repo/issues/100/sub_issues -f sub_issue_id=9102" "links ticket B as a sub-issue by id"
  rm -rf "$d"
}

test_sub_issue_link_dry_run() {
  local d; d="$(mktemp -d)"
  write_good_plan "$d/plan.json"
  run_ct "$d/bin" FAKE_GH_ISSUES_JSON='[]' -- --input "$d/plan.json" --dry-run
  assert_contains "$ERR" 'PLAN LINK sub-issue (001-a) under epic "Example Feature"' "plans linking ticket A"
  rm -rf "$d"
}

test_sub_issue_fallback_on_failure() {
  local d; d="$(mktemp -d)"; local log="$d/gh.log"
  write_good_plan "$d/plan.json"
  run_ct "$d/bin" FAKE_GH_ISSUES_JSON='[]' FAKE_GH_SUBISSUES_FAIL=true FAKE_GH_ISSUE_TITLE="Ticket A" \
    FAKE_GH_LOG="$log" FAKE_GH_COUNTER_FILE="$d/counter" \
    -- --input "$d/plan.json" --repo octo/repo
  assert_contains "$ERR" "Sub-issues API unavailable; falling back to checkbox list in epic body for ticket #101." "reports the fallback (non-silent)"
  local logtext; logtext="$(cat "$log")"
  assert_contains "$logtext" "issue edit 100 --repo octo/repo --body" "falls back to editing the epic body"
  assert_contains "$logtext" "### Tickets" "adds a Tickets heading"
  assert_contains "$logtext" "- [ ] #101 Ticket A" "appends a checkbox line for the ticket"
  rm -rf "$d"
}

test_sub_issue_fallback_no_duplicate_heading() {
  local d; d="$(mktemp -d)"; local log="$d/gh.log"
  # A single-ticket plan: exactly one fallback call, so the heading count below is
  # unambiguous (a multi-ticket plan would append the pre-existing heading text once
  # per ticket's independent issue-edit call, which is correct but would make a
  # log-wide count meaningless).
  cat > "$d/plan.json" <<'EOF'
{
  "repo": "octo/repo",
  "plan_file": "docs/superpowers/plans/2026-07-18-example.md",
  "epic": {"title": "Example Feature", "body": "Epic body text."},
  "tickets": [
    {"slug": "001-a", "title": "Ticket A", "body": "Body A",
     "labels": ["complexity:small", "priority:p1", "model-tier:efficient"], "depends_on_slugs": []}
  ]
}
EOF
  run_ct "$d/bin" FAKE_GH_ISSUES_JSON='[]' FAKE_GH_SUBISSUES_FAIL=true \
    FAKE_GH_EPIC_BODY=$'Epic body.\n\n### Tickets\n- [ ] #99 Existing ticket' \
    FAKE_GH_LOG="$log" FAKE_GH_COUNTER_FILE="$d/counter" \
    -- --input "$d/plan.json" --repo octo/repo
  local heading_count
  heading_count="$(grep -o '### Tickets' "$log" | wc -l | tr -d ' ')"
  assert_eq "$heading_count" "1" "does not add a second Tickets heading when one already exists"
  rm -rf "$d"
}

test_sub_issue_link_success
test_sub_issue_link_dry_run
test_sub_issue_fallback_on_failure
test_sub_issue_fallback_no_duplicate_heading
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash skills/coding/plan-to-tickets/tests/run.sh`
Expected: FAIL — sub-issue linking isn't called yet.

- [ ] **Step 3: Implement linking + fallback, and wire it into the ticket loop**

Add the functions:

```bash
link_sub_issue() {
  local ticket_id="$1" ticket_num="$2" slug="$3"
  if [ "$DRY_RUN" = true ]; then
    echo "PLAN LINK sub-issue ($slug) under epic \"$(jq -r '.epic.title' <<<"$PLAN_JSON")\"" >&2
    return 0
  fi
  if ! gh api "repos/$REPO/issues/$EPIC_NUMBER/sub_issues" -f "sub_issue_id=$ticket_id" >/dev/null 2>&1; then
    echo "Sub-issues API unavailable; falling back to checkbox list in epic body for ticket #$ticket_num." >&2
    append_checkbox_fallback "$ticket_num"
  fi
}

append_checkbox_fallback() {
  local ticket_num="$1" title body
  title="$(gh issue view "$ticket_num" --repo "$REPO" --json title -q .title)"
  body="$(gh issue view "$EPIC_NUMBER" --repo "$REPO" --json body -q .body)"
  if ! grep -q '^### Tickets' <<<"$body"; then
    body="$body"$'\n\n### Tickets'
  fi
  body="$body"$'\n- [ ] #'"$ticket_num $title"
  gh issue edit "$EPIC_NUMBER" --repo "$REPO" --body "$body" >/dev/null
}
```

In `file_tickets`, add the call right after `record_slug`:

```bash
    record_slug "$slug" "$num" "$id"
    link_sub_issue "$id" "$num" "$slug"
    i=$((i + 1))
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash skills/coding/plan-to-tickets/tests/run.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add skills/coding/plan-to-tickets/
git commit -m "plan-to-tickets: link tickets as native sub-issues, fall back to checkbox list"
```

---

## Task 9: Manifest writer

**Files:**
- Modify: `skills/coding/plan-to-tickets/scripts/create-tickets.sh` (`write_manifest`, `main`)
- Test: `skills/coding/plan-to-tickets/tests/run.sh`

- [ ] **Step 1: Write the failing test**

Add to `tests/run.sh`. The manifest path is resolved from the git repo root, so the test runs inside a throwaway git repo:

```bash
test_write_manifest() {
  local d; d="$(mktemp -d)"
  (cd "$d" && git init -q)
  write_good_plan "$d/plan.json"
  local outf errf; outf="$(mktemp)"; errf="$(mktemp)"
  local bindir="$d/bin"; mkdir -p "$bindir"; cp "$HERE/fake-gh" "$bindir/gh"; chmod +x "$bindir/gh"
  ( cd "$d" && \
    PATH="$bindir:$PATH" FAKE_GH_ISSUES_JSON='[]' FAKE_GH_COUNTER_FILE="$d/counter" \
    bash "$SCRIPT" --input "$d/plan.json" --repo octo/repo >"$outf" 2>"$errf" )
  local manifest="$d/docs/superpowers/tickets/2026-07-18-example.md"
  [ -f "$manifest" ] && ok "writes the manifest file" || bad "writes the manifest file" "not found: $manifest"
  local content; content="$(cat "$manifest" 2>/dev/null || true)"
  assert_contains "$content" "Epic: #100" "manifest records the epic number"
  assert_contains "$content" "| #101 | complexity:small | model-tier:efficient | priority:p1 |" "manifest records ticket A's metadata"
  assert_contains "$content" "| #102 | complexity:medium | model-tier:standard | priority:p1 | #101 |" "manifest resolves ticket B's dependency to a real number"
  rm -f "$outf" "$errf"; rm -rf "$d"
}

test_manifest_skipped_on_dry_run() {
  local d; d="$(mktemp -d)"
  (cd "$d" && git init -q)
  write_good_plan "$d/plan.json"
  ( cd "$d" && PATH="$HERE/../tests:$PATH" true ) # no-op; real check below
  local bindir="$d/bin"; mkdir -p "$bindir"; cp "$HERE/fake-gh" "$bindir/gh"; chmod +x "$bindir/gh"
  ( cd "$d" && PATH="$bindir:$PATH" FAKE_GH_ISSUES_JSON='[]' bash "$SCRIPT" --input "$d/plan.json" --repo octo/repo --dry-run >/dev/null 2>/dev/null )
  [ -e "$d/docs/superpowers/tickets/2026-07-18-example.md" ] \
    && bad "dry-run does not write a manifest" "file exists" \
    || ok "dry-run does not write a manifest"
  rm -rf "$d"
}

test_write_manifest
test_manifest_skipped_on_dry_run
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash skills/coding/plan-to-tickets/tests/run.sh`
Expected: FAIL — no manifest is written yet.

- [ ] **Step 3: Implement `write_manifest`**

Add the function:

```bash
write_manifest() {
  local plan_file slug outfile root count i num complexity tier priority deps
  plan_file="$(jq -r '.plan_file' <<<"$PLAN_JSON")"
  slug="$(basename "$plan_file" .md)"
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  outfile="$root/docs/superpowers/tickets/$slug.md"
  mkdir -p "$(dirname "$outfile")"
  {
    echo "# Tickets filed for $plan_file"
    echo
    echo "Epic: #$EPIC_NUMBER"
    echo
    echo "| Ticket | Complexity | Model tier | Priority | Depends on |"
    echo "|---|---|---|---|---|"
    count="$(jq '.tickets | length' <<<"$PLAN_JSON")"
    i=0
    while [ "$i" -lt "$count" ]; do
      slug="$(jq -r ".tickets[$i].slug" <<<"$PLAN_JSON")"
      num="$(slug_number "$slug")"
      complexity="$(jq -r ".tickets[$i].labels[] | select(startswith(\"complexity:\"))" <<<"$PLAN_JSON")"
      tier="$(jq -r ".tickets[$i].labels[] | select(startswith(\"model-tier:\"))" <<<"$PLAN_JSON")"
      priority="$(jq -r ".tickets[$i].labels[] | select(startswith(\"priority:\"))" <<<"$PLAN_JSON")"
      deps="$(resolved_deps "$i")"
      echo "| #$num | $complexity | $tier | $priority | $deps |"
      i=$((i + 1))
    done
  } > "$outfile"
  echo "Wrote $outfile" >&2
}
```

Update `main`:

```bash
main() {
  parse_args "$@"
  if [ "$PRINT_CONFIG" = true ]; then print_config; exit 0; fi
  preflight
  if [ "$PREFLIGHT_ONLY" = true ]; then exit 0; fi
  load_plan
  ensure_labels
  file_epic
  file_tickets
  if [ "$DRY_RUN" != true ]; then write_manifest; fi
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash skills/coding/plan-to-tickets/tests/run.sh`
Expected: PASS — all tests green (Tasks 1–9).

- [ ] **Step 5: Commit**

```bash
git add skills/coding/plan-to-tickets/
git commit -m "plan-to-tickets: write the tickets manifest after a real run"
```

---

## Task 10: `references/model-tiers.md`

**Files:**
- Create: `skills/coding/plan-to-tickets/references/model-tiers.md`

- [ ] **Step 1: Write the reference doc**

Create `skills/coding/plan-to-tickets/references/model-tiers.md`:

```markdown
# Model tiers

`create-tickets.sh` never sees this file — it just applies whatever `model-tier:<tier>`
label the agent already chose. This table is what the agent (via SKILL.md's procedure)
crosses complexity × task-nature against to make that choice, and it's meant to be edited
per project: rename a tier, collapse two into one, or add one back, as long as every
ticket still ends up with exactly one `model-tier:*` label.

No specific model or vendor name ever appears on a ticket — only an abstract capability
tier. Mapping a tier to an actual model (which Claude/GPT/Gemini/open-weight model, which
provider) is a decision for whatever dispatches the ticket, made separately from this
skill, so a ticket never goes stale as a team's model roster changes.

## The four tiers

- **`lite`** — no code-reasoning required: docs, copy, config-only changes.
- **`efficient`** — cheap but code-capable: small, fully-specified, mechanical code changes.
- **`standard`** — everyday integration work: multi-file but well-understood, moderate judgment.
- **`flagship`** — the hardest judgment calls: architecture-adjacent decisions, ambiguous
  specs, cross-cutting design.

## Default cross table

All `small`/`medium` complexity × `text`/`mechanical`/`judgment` task-nature combinations.
The two marked *rare* are edge cases folded into a neighboring tier rather than earning a
distinct fifth tier:

| complexity | task nature | model tier             |
|-----------|-------------|--------------------------|
| small     | text        | `lite`                   |
| small     | mechanical  | `efficient`              |
| small     | judgment    | `standard` *(rare)*      |
| medium    | text        | `efficient` *(rare)*     |
| medium    | mechanical  | `standard`               |
| medium    | judgment    | `flagship`               |

## Why four

Four is the smallest set that distinguishes every complexity × task-nature combination
this skill actually produces (complexity is only `small`/`medium` — see SKILL.md's
"never emit a large/hard ticket" rule — crossed with three task natures). Fewer tiers
would collapse genuinely different capability requirements (a docs-only edit and a
judgment-heavy integration are not the same job); more would split hairs no real
complexity/nature combination in this skill's own output calls for.
```

- [ ] **Step 2: Verify it renders and is internally consistent**

Run: `grep -n "model-tier:" skills/coding/plan-to-tickets/references/model-tiers.md`
Expected: the four tier names (`lite`, `efficient`, `standard`, `flagship`) match exactly what `label_color()` in `scripts/create-tickets.sh` already has entries for (`model-tier:lite`, `model-tier:efficient`, `model-tier:standard`, `model-tier:flagship`).

- [ ] **Step 3: Commit**

```bash
git add skills/coding/plan-to-tickets/references/model-tiers.md
git commit -m "plan-to-tickets: add model-tiers reference doc"
```

---

## Task 11: `SKILL.md` (frontmatter + decomposition procedure + JSON schema + preview gate)

**Files:**
- Create: `skills/coding/plan-to-tickets/SKILL.md`

- [ ] **Step 1: Write SKILL.md**

Create `skills/coding/plan-to-tickets/SKILL.md`:

```markdown
---
name: plan-to-tickets
description: >-
  Turn a superpowers spec + implementation plan into a GitHub backlog: one epic issue
  for the top-level spec/plan, and complexity/model-tier/priority/dependency-tagged
  ticket sub-issues that independent workers (out of scope for this skill) can pick up.
  Use when the user wants to split an implementation plan into tickets, file a backlog
  from a plan, break a plan into GitHub issues for parallel workers, or asks to turn a
  spec+plan into an epic with sub-issues. Does not execute or assign tickets — it stops
  once the backlog exists on GitHub.
metadata:
  author: stephen-martin
  version: "0.1.0"
---

# Turn a plan into a GitHub ticket backlog

Take a superpowers spec + implementation plan (the `docs/superpowers/specs/...` +
`docs/superpowers/plans/...` pair from `brainstorming` and `writing-plans`) and file a
GitHub backlog: an epic issue for the spec/plan, plus ticket sub-issues — each tagged
with a complexity, an abstract model tier, a priority, and its dependencies on other
tickets. The bundled `scripts/create-tickets.sh` does the mechanical GitHub work; it is
**idempotent** (finds an existing epic/tickets by a hidden marker and updates them
instead of duplicating).

This skill never dispatches, assigns, or monitors work — it stops once the backlog
exists.

## When this applies

- You have a plan file (`docs/superpowers/plans/YYYY-MM-DD-<feature>.md`, the
  `### Task N` format from `writing-plans`) and its paired spec
  (`docs/superpowers/specs/YYYY-MM-DD-<feature>-design.md`).
- The target is a **GitHub** repo, `gh` is installed and authenticated, and `jq` is
  installed.

If no plan is named, use the most recently modified file under
`docs/superpowers/plans/` and confirm it with the user before proceeding. If no spec
matches the plan's `<feature>` slug, ask the user for the spec path — do not proceed
without one.

## Procedure

### 1. Read the spec and plan

Read both files in full. Extract every `### Task N` block from the plan (its `Files:`
list and every step) in order.

### 2. Decompose plan Tasks into tickets

For each Task, compute a raw signal:

- **File count** touched (`Create`/`Modify`/`Test` paths under `Files:`).
- Whether steps are fully **mechanical** (code given verbatim, matching `writing-plans`'
  "no placeholders" bar) or require **judgment** (an outcome described without full code,
  multiple existing subsystems touched, or code not shown in the task).

Classify each raw Task as tiny / right-sized / oversized, then:

1. **Merge** adjacent tiny Tasks that touch the same file/component and have no
   independent shippable value into one ticket. Never merge across unrelated
   components merely to reduce ticket count.
2. **Split** oversized Tasks along natural seams — the `Files:` boundary or independently
   testable step groups. Repeat until every resulting unit fits the complexity bound
   below.
3. **Classify final complexity**:
   - **small** — 1-2 files, fully spec'd/mechanical, no cross-cutting judgment.
   - **medium** — 3+ files, or integration/judgment across existing code, but still one
     coherent, single-sitting deliverable.
   - If a unit still doesn't fit `medium` after a split pass, split again — down to a
     single plan Step if needed. If one already-indivisible Step still reads as exceeding
     `medium` (rare), stop splitting and force it into `medium`, adding a flagged note to
     the ticket body: `⚠️ exceeds typical medium scope; could not be split further
     without breaking a single plan step — consider revising the source plan.`
     `large`/`hard` is never a valid complexity label — this forced case is the one
     exception, and it must always be visibly flagged, never silent.
4. **Classify task nature**: `text` (docs/copy/config-only), `mechanical` (isolated,
   fully spec'd code change), or `judgment` (multi-file integration, design decisions not
   fully spelled out) — from file extensions and step content.
5. **Assign a model tier**: cross complexity × task-nature against
   `references/model-tiers.md` to get the `model-tier:<tier>` label. Never name a
   specific model or vendor.
6. **Compute dependencies**: ticket B depends on ticket A when B's steps read/modify a
   file A creates, or the plan's own ordering makes B build on A's output. Tickets with
   no file/content overlap and no ordering requirement are independent — no dependency
   edge between them.
7. **Compute priority**: `p1` for tickets on the critical path or blocking multiple
   others, `p2` for normal work, `p3` for optional/polish/cleanup work the plan or spec
   calls out as such.

### 3. Build the ticket-plan JSON

Write a JSON file (e.g. to a scratch/temp path) matching this schema:

\`\`\`json
{
  "repo": "owner/repo",
  "plan_file": "docs/superpowers/plans/YYYY-MM-DD-<feature>.md",
  "epic": { "title": "string", "body": "string (goal/architecture summary, links to the committed spec+plan files, a compact table of tickets: title/complexity/model tier/priority)" },
  "tickets": [
    {
      "slug": "001-short-slug",
      "title": "string",
      "body": "string — the concrete files and steps/code for this ticket's scope, reconstructed from the merged/split plan Tasks (self-contained per writing-plans' zero-context bar). Do NOT include Depends-on/Part-of/marker lines — the script adds those.",
      "labels": ["complexity:small", "priority:p1", "model-tier:efficient"],
      "depends_on_slugs": []
    }
  ]
}
\`\`\`

`tickets` **must** be in dependency order: every `depends_on_slugs` entry must name a
slug that appears *earlier* in the array. `repo` is optional (the script falls back to
the current repo).

### 4. Preview and confirm before filing anything

Filing GitHub issues is a visible, shared-state action. Run the script in `--dry-run`
mode against the ticket-plan JSON:

\`\`\`bash
skills/coding/plan-to-tickets/scripts/create-tickets.sh --input <ticket-plan.json> --dry-run
\`\`\`

This both validates the JSON (invalid JSON, missing fields, or an out-of-order
dependency all fail here with a clear error) and confirms exactly what would be created
or updated. Render a human-readable table from the ticket-plan JSON itself — ticket
title, complexity, task nature, model tier, priority, dependencies — for the whole
backlog (epic + every ticket), and ask the user to confirm. If they request changes
(re-bucket a ticket, change a tier, change priority), edit the ticket-plan JSON and
re-run `--dry-run` before proceeding. **Do not run the script for real until the user
confirms.**

### 5. File the backlog

Once confirmed, run without `--dry-run`:

\`\`\`bash
skills/coding/plan-to-tickets/scripts/create-tickets.sh --input <ticket-plan.json>
\`\`\`

Report the epic issue link, every ticket's issue link, and the path to the manifest the
script writes (`docs/superpowers/tickets/<plan-slug>.md`). Re-running this skill against
the same plan later (e.g. after editing it) updates the same epic/tickets in place —
it will not create duplicates.

## Flags (`scripts/create-tickets.sh`)

| Flag | Effect |
|------|--------|
| `--input <file>` | Ticket-plan JSON (required) |
| `--repo <owner/repo>` | Target repo (default: `.repo` in the JSON, or current repo) |
| `--dry-run` | Print every planned `gh` call; apply nothing |

See `references/model-tiers.md` for the complexity × task-nature → model-tier table.
```

- [ ] **Step 2: Verify the frontmatter parses and the schema matches the script**

Run:
```bash
head -n 12 skills/coding/plan-to-tickets/SKILL.md
grep -n '"slug"\|"depends_on_slugs"\|"labels"\|"repo"\|"plan_file"' skills/coding/plan-to-tickets/SKILL.md
```
Expected: frontmatter has `name: plan-to-tickets`; every field named in SKILL.md's schema (`repo`, `plan_file`, `epic.title`, `epic.body`, `tickets[].slug/title/body/labels/depends_on_slugs`) matches a field the script actually reads (cross-check against the `jq -r '.foo'` expressions added in Tasks 4, 6, 7, 9).

- [ ] **Step 3: Commit**

```bash
git add skills/coding/plan-to-tickets/SKILL.md
git commit -m "plan-to-tickets: add SKILL.md with decomposition procedure and JSON schema"
```

---

## Task 12: Repo integration (README + skills.sh.json) and full test run

**Files:**
- Modify: `README.md` (Coding table)
- Modify: `skills.sh.json` (coding grouping)

- [ ] **Step 1: Inspect the current grouping format**

Run: `cat skills.sh.json`
Expected: see the existing `coding` grouping listing `consult-codex`, `codex-review`, `ship-ready-pr-loop`, `optimize-agents-md`, `git-merge-origin-main`.

- [ ] **Step 2: Add the skill to `skills.sh.json`**

Add `"plan-to-tickets"` to that same `coding` grouping array, matching the existing formatting/ordering convention in the file.

- [ ] **Step 3: Add the README row**

In `README.md`, under the **Coding** table, add a row:

```markdown
| [`plan-to-tickets`](skills/coding/plan-to-tickets/SKILL.md) | Turns a superpowers spec + implementation plan into a GitHub backlog — an epic issue plus complexity/model-tier/priority/dependency-tagged ticket sub-issues for independent workers to pick up. Idempotent, with a `--dry-run` preview gate before anything is filed. |
```

- [ ] **Step 4: Validate JSON and run the full test suite**

Run:
```bash
jq . skills.sh.json >/dev/null && echo "skills.sh.json OK"
bash skills/coding/plan-to-tickets/tests/run.sh
```
Expected: `skills.sh.json OK`, then `... passed, 0 failed`.

- [ ] **Step 5: Shellcheck (if available) and commit**

Run (best-effort lint):
```bash
command -v shellcheck >/dev/null && shellcheck skills/coding/plan-to-tickets/scripts/create-tickets.sh skills/coding/plan-to-tickets/tests/run.sh skills/coding/plan-to-tickets/tests/fake-gh || echo "shellcheck not installed; skipping"
```
Fix any errors it reports (warnings are optional). Then:

```bash
git add README.md skills.sh.json
git commit -m "plan-to-tickets: list skill in README and skills.sh.json"
```

---

## Task 13: Live smoke test against a throwaway repo (manual, optional but recommended)

**Files:** none (runtime verification only)

This exercises the real `gh` path end-to-end, including the real sub-issues API (which
the fake-`gh` test suite cannot fully validate). Skip only if no GitHub account is
available; if skipped, say so explicitly rather than claiming it passed.

- [ ] **Step 1: Create a throwaway repo**

Run: `gh repo create plan-to-tickets-smoke-$$ --private --clone && cd plan-to-tickets-smoke-$$`

- [ ] **Step 2: Hand-write a tiny ticket-plan JSON**

Create `/tmp/smoke-plan.json` with 1 epic + 2 tickets (one depending on the other),
matching the schema in `SKILL.md`, with `"repo"` set to the throwaway repo's
`owner/name`.

- [ ] **Step 3: Dry-run**

Run: `/path/to/skills/coding/plan-to-tickets/scripts/create-tickets.sh --input /tmp/smoke-plan.json --dry-run`
Expected: `PLAN CREATE LABEL ...`, `PLAN CREATE epic issue ...`, `PLAN CREATE ticket ...`,
`PLAN LINK sub-issue ...` lines on stderr. Nothing changes on GitHub.

- [ ] **Step 4: Apply, then verify idempotency and the real sub-issues link**

Run:
```bash
/path/to/skills/coding/plan-to-tickets/scripts/create-tickets.sh --input /tmp/smoke-plan.json
/path/to/skills/coding/plan-to-tickets/scripts/create-tickets.sh --input /tmp/smoke-plan.json   # second run must UPDATE, not duplicate
```
Expected: first run prints `Wrote docs/superpowers/tickets/...`; second run also succeeds
with no new issues created. In the GitHub UI, confirm the epic issue shows a native
sub-issues progress bar listing both tickets, and that the second ticket's body contains
a real `Depends on: #<n>` line.

- [ ] **Step 5: Clean up**

Run: `gh repo delete plan-to-tickets-smoke-$$ --yes`

---

## Self-Review

**Spec coverage:**
- GitHub Issues only, epic + ticket sub-issues, never dispatches/monitors workers → Purpose/Non-goals in SKILL.md (Task 11). ✓
- Complexity small/medium only, forced-medium-with-flagged-note exception, never "large"/"hard" → decomposition algorithm in SKILL.md step 2.3 (Task 11), matching the spec's exact wording. ✓
- Abstract model tiers (no vendor/model names), 4-tier default table → `references/model-tiers.md` (Task 10), `label_color()` (Task 5). ✓
- Dependencies vs. priority as two separate axes → `Depends on:`/`Part of` body lines + `depends_on_slugs` validation (Tasks 4, 7) vs. `priority:p1/p2/p3` labels (Task 5/11). ✓
- Preview/confirmation gate before filing → `--dry-run` seam (every task) + SKILL.md step 4 (Task 11). ✓
- Native sub-issues API with id (not number), checkbox fallback, non-silent reporting → Task 8. ✓
- Idempotency via hidden marker comments (epic and per-ticket) → Tasks 6, 7. ✓
- Missing labels created on first use → Task 5. ✓
- Output manifest committed alongside spec/plan → Task 9 (the file itself; committing it is part of the user's normal workflow after reviewing the skill's report, same as the spec/plan files). ✓
- `references/model-tiers.md`, README row, `skills.sh.json` grouping → Tasks 10, 12. ✓
- Plain-bash tests with fake-gh (no bash-4 features, matching `github-lockdown`) → Tasks 1–9. ✓

**Type/name consistency:** Globals (`INPUT`, `REPO`, `DRY_RUN`, `PLAN_JSON`, `EPIC_NUMBER`,
`EPIC_ID`, `SLUG_NUMBERS`, `SLUG_IDS`) and functions (`preflight`, `load_plan`,
`validate_dependency_order`, `label_color`, `required_labels`, `existing_labels`,
`ensure_labels`, `find_issue_by_marker`, `record_slug`, `slug_number`, `file_epic`,
`resolved_deps`, `dependency_line`, `file_tickets`, `link_sub_issue`,
`append_checkbox_fallback`, `write_manifest`, `main`) are named identically everywhere
they're used across tasks. The marker format (`<!-- plan-to-tickets:epic:<plan_file> -->`,
`<!-- plan-to-tickets:ticket:<plan_file>:<slug> -->`) is identical in `file_epic`,
`file_tickets`, and every test that seeds `FAKE_GH_ISSUES_JSON`. The fake `gh`'s id
convention (`number + 9000`) is used consistently by every test that asserts on
`sub_issue_id=`.

**Placeholder scan:** No TBD/TODO; every code step contains complete, runnable content —
every function and every test assertion in this plan was hand-verified against a working
copy of the script and fake-`gh` before being written into these tasks (not just
transcribed from a mental model).
