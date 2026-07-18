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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
