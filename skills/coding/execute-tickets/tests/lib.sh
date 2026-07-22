#!/usr/bin/env bash
# Shared helpers for execute-tickets.sh tests. Sourced by run.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/execute-tickets.sh"
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
# "epic" checked out (the SKILL.md-documented precondition: the operator has the
# epic branch checked out locally when running the executor).
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
    '{number:$n, title:$title, body:$body, labels:$labels, assignees:[], state:"open"}'
}

# seed_state <state_file> <issue_json_array>
seed_state() {
  local state="$1" issues="$2"
  jq -n --argjson issues "$issues" \
    '{issues: (reduce $issues[] as $i ({}; . + {($i.number|tostring): $i})), prs: {}, next_pr: 1}' \
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

# run_et <workdir> <bindir> <env-assignments...> -- <execute-tickets.sh args...>
# Captures stdout->$OUT, stderr->$ERR, exit->$RC. Runs from <workdir> so the
# script's `git rev-parse --show-toplevel` resolves inside the test repo.
run_et() {
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

# install_reject_second_ticket_push <dir>
# Installs a pre-receive hook on <dir>/remote.git that allows the first push to
# any refs/heads/ticket/* ref but rejects the second and later push to that
# same ref -- deterministically simulates a real push failure on a review-loop
# retry, with no timing dependency.
install_reject_second_ticket_push() {
  local dir="$1"
  cat > "$dir/remote.git/hooks/pre-receive" <<'EOF'
#!/usr/bin/env bash
while read -r oldrev newrev refname; do
  case "$refname" in
    refs/heads/ticket/*)
      counterfile="$GIT_DIR/ticket-push-count-$(basename "$refname")"
      count=0
      [ -f "$counterfile" ] && count="$(cat "$counterfile")"
      count=$((count + 1))
      echo "$count" > "$counterfile"
      if [ "$count" -ge 2 ]; then
        echo "REJECTED: simulated push failure (attempt $count) for $refname" >&2
        exit 1
      fi
      ;;
  esac
done
exit 0
EOF
  chmod +x "$dir/remote.git/hooks/pre-receive"
}

# write_codex_responses <dir> <json1> <json2> [...] -> prints the responses dir
write_codex_responses() {
  local dir="$1"; shift
  mkdir -p "$dir"
  local i=1
  for json in "$@"; do
    printf '%s' "$json" > "$dir/$i.json"
    i=$((i + 1))
  done
  printf '%s' "$dir"
}
