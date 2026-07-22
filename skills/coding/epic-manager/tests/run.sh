#!/usr/bin/env bash
# Plain-bash test runner for epic-manager.sh. No network: fake gh/codex on PATH.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/lib.sh"

# Tests are added in later tasks.

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]

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
  epic_body="Epic body.<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  seed_state "$d/state" "[$(issue_json 100 'Epic' "$epic_body" '[]')]"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" -- --plan test-plan --dry-run
  assert_eq "$RC" "0" "dry-run with valid manifest + epic exits 0"
  assert_contains "$ERR" "source_branch: epic" "load_manifest parsed source_branch"
  assert_contains "$ERR" "spec_file:" "load_manifest parsed spec_file"
  assert_contains "$ERR" "plan_file:" "load_manifest parsed plan_file"
  assert_contains "$ERR" "#100" "found the epic issue by marker"
  rm -rf "$d"
}
test_load_manifest

test_dry_run_does_not_acquire_lock() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  epic_body="<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  seed_state "$d/state" "[$(issue_json 100 'Epic' "$epic_body" '[]')]"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" -- --plan test-plan --dry-run
  labels="$(jq -r '.issues["100"].labels | join(",")' "$d/state")"
  assert_not_contains "$labels" "lock:manager" "dry-run does not acquire the lock"
  rm -rf "$d"
}
test_dry_run_does_not_acquire_lock

test_lock_held_exits_clean() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  epic_body="<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  seed_state "$d/state" "[$(issue_json 100 'Epic' "$epic_body" '["lock:manager"]')]"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" -- --plan test-plan --once
  assert_contains "$ERR" "lock:manager held" "reports the lock is held"
  rm -rf "$d"
}
test_lock_held_exits_clean

test_no_epic_issue_errors() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  # No epic issue with the marker -> should error clearly.
  seed_state "$d/state" "[$(issue_json 100 'Not the epic' 'no marker here' '[]')]"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" -- --plan test-plan --dry-run
  assert_eq "$RC" "1" "missing epic issue exits 1"
  assert_contains "$ERR" "No epic issue" "clear error when epic issue not found"
  rm -rf "$d"
}
test_no_epic_issue_errors
