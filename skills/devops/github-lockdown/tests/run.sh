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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
