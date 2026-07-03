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
  PATH="$(setup_path "$bindir")" env ${envs[@]+"${envs[@]}"} bash "$SCRIPT" "$@" >"$outf" 2>"$errf"
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
