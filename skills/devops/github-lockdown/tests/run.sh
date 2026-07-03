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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
