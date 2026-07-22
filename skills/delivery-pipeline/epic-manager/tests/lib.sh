#!/usr/bin/env bash
# Shared helpers for epic-manager.sh tests. Sourced by run.sh.
# Mirrors execute-tickets/tests/lib.sh with SCRIPT pointed at epic-manager.sh
# and run_et renamed to run_em. All other helpers are shared verbatim.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/epic-manager.sh"
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

assert_eq()            { [ "$1" = "$2" ] && ok "$3" || bad "$3" "expected [$2] got [$1]"; }
assert_contains()      { case "$1" in *"$2"*) ok "$3";; *) bad "$3" "[$1] did not contain [$2]";; esac; }
assert_not_contains()  { case "$1" in *"$2"*) bad "$3" "[$1] contained [$2]";; *) ok "$3";; esac; }
assert_file_contains() { assert_contains "$(cat "$1" 2>/dev/null)" "$2" "$3"; }

# jqok <json> <jq-filter-returning-true> <label>
jqok() {
  local got; got="$(printf '%s' "$1" | jq -r "$2" 2>/dev/null)"
  assert_eq "$got" "true" "$3"
}

# make_repo <dir> <plan_slug> [ticket_marker_plan_file]
# Creates a bare "origin" remote at <dir>/remote.git and a working checkout at
# <dir>/work with an "epic" branch holding a committed plan-to-tickets manifest,
# matching what plan-to-tickets' create-tickets.sh would have produced. Leaves
# "epic" checked out (the SKILL.md-documented precondition).
make_repo() {
  local dir="$1" slug="$2" plan_file="${3:-docs/superpowers/plans/test-plan.md}"
  mkdir -p "$dir"
  git init -q --bare "$dir/remote.git"
  git init -q -b main "$dir/work"
  git -C "$dir/work" config user.email "test@example.com"
  git -C "$dir/work" config user.name "Test Runner"
  echo "readme" > "$dir/work/README.md"
  git -C "$dir/work" add README.md
  git -C "$dir/work" commit -q -m "initial commit"
  git -C "$dir/work" switch -c epic -q
  mkdir -p "$dir/work/docs/superpowers/tickets"
  cat > "$dir/work/docs/superpowers/tickets/$slug.md" <<EOF
---
source_branch: "epic"
spec_file: "docs/superpowers/specs/test-spec.md"
plan_file: "$plan_file"
---

# Tickets filed for $plan_file
EOF
  git -C "$dir/work" add docs/superpowers/tickets/"$slug".md
  git -C "$dir/work" commit -q -m "file tickets for $slug"
  git -C "$dir/work" remote add origin "$dir/remote.git"
  git -C "$dir/work" push -q origin main epic
}

# issue_json <number> <title> <body> <labels_json_array> -> one issue object
issue_json() {
  local n="$1" title="$2" body="$3" labels="$4"
  jq -n --argjson n "$n" --arg title "$title" --arg body "$body" --argjson labels "$labels" \
    '{number:$n, title:$title, body:$body, labels:$labels, assignees:[], state:"open", comments:[]}'
}

# seed_state <state_file> <issue_json_array>
seed_state() {
  local state="$1" issues="$2"
  jq -n --argjson issues "$issues" \
    '{issues: (reduce $issues[] as $i ({}; . + {($i.number|tostring): $i})), prs: {}, next_pr: 1, next_issue: 200}' \
    > "$state"
}

# bindir_for <dir> -> creates <dir>/bin with fake gh/codex on it, prints the path
bindir_for() {
  local dir="$1"
  mkdir -p "$dir/bin"
  cp "$HERE/fake-gh" "$dir/bin/gh"; chmod +x "$dir/bin/gh"
  cp "$HERE/fake-codex" "$dir/bin/codex"; chmod +x "$dir/bin/codex"
  printf '%s' "$dir/bin"
}

# run_em <workdir> <bindir> <env-assignments...> -- <epic-manager.sh args...>
# Captures stdout->$OUT, stderr->$ERR, exit->$RC. Runs from <workdir> so the
# script's `git rev-parse --show-toplevel` resolves inside the test repo.
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

state_get() { jq -r "$2" "$1"; }
