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

test_plan_create() {
  local d; d="$(mktemp -d)"
  run_lockdown "$d/bin" FAKE_GH_VIEWER_PERMISSION=ADMIN FAKE_GH_RULESETS_JSON='[]' \
    -- --dry-run --repo octo/repo
  assert_contains "$ERR" "PLAN CREATE ruleset name=github-lockdown via POST repos/octo/repo/rulesets" "plans a CREATE when none exists"
  assert_contains "$ERR" "PLAN SET repos/octo/repo delete_branch_on_merge=true" "plans auto-delete"
  rm -rf "$d"
}

test_plan_update() {
  local d; d="$(mktemp -d)"
  run_lockdown "$d/bin" FAKE_GH_VIEWER_PERMISSION=ADMIN \
    FAKE_GH_RULESETS_JSON='[{"id":42,"name":"github-lockdown"},{"id":7,"name":"other"}]' \
    -- --dry-run --repo octo/repo
  assert_contains "$ERR" "PLAN UPDATE ruleset id=42 via PUT repos/octo/repo/rulesets/42" "plans an UPDATE by id when it exists"
  rm -rf "$d"
}

test_plan_no_auto_delete() {
  local d; d="$(mktemp -d)"
  run_lockdown "$d/bin" FAKE_GH_VIEWER_PERMISSION=ADMIN FAKE_GH_RULESETS_JSON='[]' \
    -- --dry-run --repo octo/repo --no-auto-delete
  case "$ERR" in *"delete_branch_on_merge"*) bad "no-auto-delete suppresses the plan" "found delete_branch_on_merge line";; *) ok "no-auto-delete suppresses the plan";; esac
  rm -rf "$d"
}

test_plan_create
test_plan_update
test_plan_no_auto_delete

test_real_apply_records_calls() {
  local d; d="$(mktemp -d)"; local log="$d/gh.log"
  run_lockdown "$d/bin" FAKE_GH_VIEWER_PERMISSION=ADMIN FAKE_GH_RULESETS_JSON='[]' FAKE_GH_LOG="$log" \
    -- --repo octo/repo
  assert_eq "$RC" "0" "real apply exits 0"
  local logtext; logtext="$(cat "$log")"
  assert_contains "$logtext" "api -X POST repos/octo/repo/rulesets" "issues POST to create ruleset"
  assert_contains "$logtext" "api -X PATCH repos/octo/repo" "issues PATCH for auto-delete"
  assert_contains "$OUT" "Locked down" "prints a verification summary"
  rm -rf "$d"
}

test_real_apply_records_calls

test_missing_flag_value() {
  local d; d="$(mktemp -d)"
  run_lockdown "$d/bin" -- --repo
  assert_eq "$RC" "2" "missing --repo value exits 2"
  assert_contains "$ERR" "Missing value for --repo" "clear error for missing --repo value"
  rm -rf "$d"
}

test_bad_approvals() {
  local d; d="$(mktemp -d)"
  run_lockdown "$d/bin" -- --approvals abc --repo octo/repo
  assert_eq "$RC" "2" "non-numeric --approvals exits 2"
  assert_contains "$ERR" "non-negative integer" "clear error for bad --approvals"
  rm -rf "$d"
}

test_rulesets_get_failure_reports() {
  local d; d="$(mktemp -d)"
  # A fake gh that fails the rulesets GET. Override PATH's gh via a wrapper dir.
  local bin="$d/bin"; mkdir -p "$bin"
  cat >"$bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1" in
  auth) exit 0 ;;
  repo) case "$*" in *viewerPermission*) echo ADMIN;; *nameWithOwner*) echo octo/repo;; esac ;;
  api) case "$*" in *rulesets*) echo "HTTP 500" >&2; exit 1;; *) echo '{}';; esac ;;
  *) exit 0 ;;
esac
GH
  chmod +x "$bin/gh"
  local outf errf; outf="$(mktemp)"; errf="$(mktemp)"
  PATH="$bin:$PATH" bash "$SCRIPT" --dry-run --repo octo/repo >"$outf" 2>"$errf"
  local rc=$?
  assert_eq "$rc" "1" "rulesets GET failure exits 1"
  assert_contains "$(cat "$errf")" "Failed to list rulesets" "reports GET failure with remediation"
  rm -f "$outf" "$errf"; rm -rf "$d"
}

test_missing_flag_value
test_bad_approvals
test_rulesets_get_failure_reports

test_real_apply_update_puts() {
  local d; d="$(mktemp -d)"; local log="$d/gh.log"
  run_lockdown "$d/bin" FAKE_GH_VIEWER_PERMISSION=ADMIN \
    FAKE_GH_RULESETS_JSON='[{"id":99,"name":"github-lockdown"}]' FAKE_GH_LOG="$log" \
    -- --repo octo/repo --no-auto-delete
  assert_eq "$RC" "0" "real update exits 0"
  assert_contains "$(cat "$log")" "api -X PUT repos/octo/repo/rulesets/99 --input -" "updates existing ruleset via PUT by id"
  rm -rf "$d"
}

test_real_apply_update_puts

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
