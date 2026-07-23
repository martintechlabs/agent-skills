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
