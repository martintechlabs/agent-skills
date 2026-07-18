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
  local outf errf
  outf="$(mktemp)"; errf="$(mktemp)"
  PATH="$(setup_path "$bindir")" env ${envs[@]+"${envs[@]}"} bash "$SCRIPT" "$@" >"$outf" 2>"$errf"
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

test_parse_args() {
  local d; d="$(mktemp -d)"
  run_ct "$d/bin" -- --print-config --input plan.json --repo acme/widgets --dry-run
  assert_contains "$OUT" "INPUT=plan.json"     "parses --input"
  assert_contains "$OUT" "REPO=acme/widgets"   "parses --repo"
  assert_contains "$OUT" "DRY_RUN=true"        "parses --dry-run"
  rm -rf "$d"
}

test_parse_args

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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
