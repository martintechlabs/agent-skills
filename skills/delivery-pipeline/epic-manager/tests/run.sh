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

# ---- Task 4 tests: reconciliation + progress ----

test_reconcile_in_progress_exits_early() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  epic_body="<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  epic="$(issue_json 100 'Epic' "$epic_body" '[]')"
  t101="$(issue_json 101 'T1' "<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->" '["lock:alice","complexity:small"]')"
  t102="$(issue_json 102 'T2' "<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:002-b -->" '["complexity:small"]')"
  t103="$(issue_json 103 'T3' "<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:003-c -->" '[]')"
  seed_state "$d/state" "[$epic,$t101,$t102,$t103]"
  jq '.issues["103"].state = "closed"' "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" FAKE_GH_LOG="$d/gh.log" -- --plan test-plan --once
  assert_contains "$ERR" "in_progress" "detected in-progress ticket"
  # The worker name lands in the progress comment body, which fake-gh logs.
  assert_contains "$(cat "$d/gh.log")" "alice" "progress names the worker (alice)"
  rm -rf "$d"
}
test_reconcile_in_progress_exits_early

test_reconcile_drained_proceeds() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  epic_body="<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  epic="$(issue_json 100 'Epic' "$epic_body" '[]')"
  t101="$(issue_json 101 'T1' "<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->" '[]')"
  seed_state "$d/state" "[$epic,$t101]"
  jq '.issues["101"].state = "closed"' "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" -- --plan test-plan --dry-run
  assert_contains "$ERR" "drained" "detected drained backlog"
  rm -rf "$d"
}
test_reconcile_drained_proceeds

# ---- Task 5 tests: hybrid checklist gate ----

write_checklist() {
  mkdir -p "$1/.execute-tickets"
  cat > "$1/.execute-tickets/checklist.yml" <<EOF
pre_pr_checks:
  - name: CHANGELOG updated
    type: run
    command: "test -f CHANGELOG.md"
  - name: Public API documented
    type: judge
    instruction: "Every new public function has documentation."
EOF
}

test_checklist_no_file_skips_gate() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  epic_body="<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  epic="$(issue_json 100 'Epic' "$epic_body" '[]')"
  t101="$(issue_json 101 'T1' "<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->" '[]')"
  seed_state "$d/state" "[$epic,$t101]"
  jq '.issues["101"].state = "closed"' "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" -- --plan test-plan --dry-run
  assert_contains "$ERR" "checklist: skipped" "absent checklist skips the gate"
  rm -rf "$d"
}
test_checklist_no_file_skips_gate

test_checklist_run_fail_blocks() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  write_checklist "$d/work"
  git -C "$d/work" add -A && git -C "$d/work" commit -q -m "add checklist" && git -C "$d/work" push -q origin epic
  epic_body="<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  epic="$(issue_json 100 'Epic' "$epic_body" '[]')"
  t101="$(issue_json 101 'T1' "<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->" '[]')"
  seed_state "$d/state" "[$epic,$t101]"
  jq '.issues["101"].state = "closed"' "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" FAKE_GH_LOG="$d/gh.log" \
    FAKE_CODEX_REVIEW_JSON='{"passed":true,"reasoning":"ok","confidence":0.9}' \
    -- --plan test-plan --once
  assert_contains "$ERR" "checklist: FAIL" "checklist fails when a run: item fails"
  assert_contains "$(cat "$d/gh.log")" "needs-human" "sets needs-human on the epic"
  assert_contains "$(cat "$d/gh.log")" "checklist-failed" "sets checklist-failed on the epic"
  assert_contains "$(cat "$d/gh.log")" "CHANGELOG updated" "failure comment names the failed item"
  rm -rf "$d"
}
test_checklist_run_fail_blocks

test_checklist_malformed() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  mkdir -p "$d/work/.execute-tickets"
  printf 'pre_pr_checks:\n  - name: bad\n    type: unknown\n    command: x\n' > "$d/work/.execute-tickets/checklist.yml"
  git -C "$d/work" add -A && git -C "$d/work" commit -q -m "bad checklist" && git -C "$d/work" push -q origin epic
  epic_body="<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  epic="$(issue_json 100 'Epic' "$epic_body" '[]')"
  t101="$(issue_json 101 'T1' "<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->" '[]')"
  seed_state "$d/state" "[$epic,$t101]"
  jq '.issues["101"].state = "closed"' "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" FAKE_GH_LOG="$d/gh.log" -- --plan test-plan --once
  assert_contains "$ERR" "checklist: MALFORMED" "malformed checklist is a hard failure"
  assert_contains "$(cat "$d/gh.log")" "needs-human" "malformed checklist sets needs-human"
  rm -rf "$d"
}
test_checklist_malformed

# ---- Task 6 tests: epic PR creation + final review ----

setup_drained_epic() {
  local d="$1"
  make_repo "$d" test-plan
  local epic_body="<!-- plan-to-tickets:epic:docs/superpowers/plans/test-plan.md -->"
  local epic; epic="$(issue_json 100 'Epic' "$epic_body" '[]')"
  local t101; t101="$(issue_json 101 'T1' '<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->' '[]')"
  seed_state "$d/state" "[$epic,$t101]"
  jq '.issues["101"].state = "closed"' "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
}

test_epic_pr_opens() {
  local d; d="$(mktemp -d)"
  setup_drained_epic "$d"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" FAKE_GH_LOG="$d/gh.log" \
    FAKE_CODEX_REVIEW_JSON='{"findings":[],"overall_correctness":"patch is correct","overall_explanation":"ok","overall_confidence_score":0.9}' \
    -- --plan test-plan --once
  assert_file_contains "$d/gh.log" "pr create" "opened an epic PR"
  assert_file_contains "$d/gh.log" "--base main" "PR targets main"
  assert_file_contains "$d/gh.log" "--head epic" "PR head is the epic branch"
  rm -rf "$d"
}
test_epic_pr_opens

test_epic_pr_idempotent() {
  local d; d="$(mktemp -d)"
  setup_drained_epic "$d"
  # Pre-seed an open PR epic->main.
  jq '.prs["1"] = {number:1,title:"Epic",body:"",base:"main",head:"epic",headRefOid:"sha-1",statusCheckRollup:[],merged:false,state:"open",comments:[]} | .next_pr=2' \
    "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" FAKE_GH_LOG="$d/gh.log" \
    FAKE_CODEX_REVIEW_JSON='{"findings":[],"overall_correctness":"patch is correct","overall_explanation":"ok","overall_confidence_score":0.9}' \
    -- --plan test-plan --once
  local create_count; create_count="$(grep -c 'pr create' "$d/gh.log" 2>/dev/null || true)"
  assert_eq "$create_count" "0" "does not create a duplicate epic PR"
  rm -rf "$d"
}
test_epic_pr_idempotent

test_final_review_posts_findings() {
  local d; d="$(mktemp -d)"
  setup_drained_epic "$d"
  local blocking='{"findings":[{"title":"Integration gap","body":"X and Y not wired","confidence_score":0.9,"priority":0,"code_location":{"absolute_file_path":"a","line_range":{"start":1,"end":2}}}],"overall_correctness":"patch is incorrect","overall_explanation":"gap","overall_confidence_score":0.9}'
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" FAKE_GH_LOG="$d/gh.log" \
    FAKE_CODEX_REVIEW_JSON="$blocking" -- --plan test-plan --once
  assert_file_contains "$d/gh.log" "Integration gap" "final review finding posted"
  assert_file_contains "$d/gh.log" "review-blocked" "blocking finding flagged loudly"
  rm -rf "$d"
}
test_final_review_posts_findings

# ---- Task 7 tests: human commands ----

test_ship_it_merges() {
  local d; d="$(mktemp -d)"
  setup_drained_epic "$d"
  # Pre-seed an open epic PR + a ship-it comment.
  jq '.prs["1"] = {number:1,title:"Epic",body:"",base:"main",head:"epic",headRefOid:"sha-1",statusCheckRollup:[],merged:false,state:"open",comments:[]} | .next_pr=2 | .issues["100"].comments=[{databaseId:1,body:"ship it",createdAt:"2026-07-22T10:00:00Z"}]' \
    "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" FAKE_GH_LOG="$d/gh.log" \
    FAKE_CODEX_REVIEW_JSON='{"findings":[],"overall_correctness":"patch is correct","overall_explanation":"ok","overall_confidence_score":0.9}' \
    -- --plan test-plan --once
  assert_file_contains "$d/gh.log" "PR_MERGE" "ship it triggered a merge"
  rm -rf "$d"
}
test_ship_it_merges

test_ship_it_held_when_rework_open() {
  local d; d="$(mktemp -d)"
  setup_drained_epic "$d"
  # Add an open (ready) rework-filed ticket -> blocks ship it.
  local t102; t102="$(issue_json 102 'Rework' '<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:rework-1 -->' '[]')"
  jq --argjson t "$t102" '.issues["102"] = $t' "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
  jq '.prs["1"] = {number:1,title:"Epic",body:"",base:"main",head:"epic",headRefOid:"sha-1",statusCheckRollup:[],merged:false,state:"open",comments:[]} | .next_pr=2 | .issues["100"].comments=[{databaseId:1,body:"ship it",createdAt:"2026-07-22T10:00:00Z"}]' \
    "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" FAKE_GH_LOG="$d/gh.log" \
    FAKE_CODEX_REVIEW_JSON='{"findings":[],"overall_correctness":"patch is correct","overall_explanation":"ok","overall_confidence_score":0.9}' \
    -- --plan test-plan --once
  assert_file_contains "$d/gh.log" "waiting on" "ship it held with a waiting message"
  assert_not_contains "$(cat "$d/gh.log")" "PR_MERGE" "no merge attempted"
  rm -rf "$d"
}
test_ship_it_held_when_rework_open

test_rework_files_new_ticket() {
  local d; d="$(mktemp -d)"
  setup_drained_epic "$d"
  jq '.prs["1"] = {number:1,title:"Epic",body:"",base:"main",head:"epic",headRefOid:"sha-1",statusCheckRollup:[],merged:false,state:"open",comments:[]} | .next_pr=2 | .issues["100"].comments=[{databaseId:1,body:"rework: change the button to blue",createdAt:"2026-07-22T10:00:00Z"}]' \
    "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
  local meta_json='{"priority":"p1","complexity":"small","model_tier":"efficient","reasoning":"tiny copy change"}'
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" FAKE_GH_LOG="$d/gh.log" \
    FAKE_CODEX_REVIEW_JSON="$meta_json" -- --plan test-plan --once
  assert_file_contains "$d/gh.log" "issue create" "rework filed a new ticket"
  assert_file_contains "$d/gh.log" "priority:p1" "new ticket has codex-chosen priority"
  assert_file_contains "$d/gh.log" "change the button to blue" "filing comment includes the description"
  rm -rf "$d"
}
test_rework_files_new_ticket

test_abandon_closes_pr_and_issue() {
  local d; d="$(mktemp -d)"
  setup_drained_epic "$d"
  jq '.prs["1"] = {number:1,title:"Epic",body:"",base:"main",head:"epic",headRefOid:"sha-1",statusCheckRollup:[],merged:false,state:"open",comments:[]} | .next_pr=2 | .issues["100"].comments=[{databaseId:1,body:"abandon",createdAt:"2026-07-22T10:00:00Z"}]' \
    "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" FAKE_GH_LOG="$d/gh.log" -- --plan test-plan --once
  assert_file_contains "$d/gh.log" "PR_CLOSE" "abandon closes the PR"
  # Check issue closed in state
  local epic_state; epic_state="$(jq -r '.issues["100"].state' "$d/state")"
  assert_eq "$epic_state" "closed" "abandon closes the epic issue"
  rm -rf "$d"
}
test_abandon_closes_pr_and_issue

# ---- Task 8 tests: approval-reset invariant ----

test_approval_reset_after_epic_merge() {
  local d; d="$(mktemp -d)"
  setup_drained_epic "$d"
  # Epic PR at sha-1; ship it was recorded against sha-1; then head advanced to sha-2.
  jq '.prs["1"] = {number:1,title:"Epic",body:"",base:"main",head:"epic",headRefOid:"sha-2",statusCheckRollup:[],merged:false,state:"open",comments:[]} | .next_pr=2 | .issues["100"].comments=[{databaseId:1,body:"ship it",createdAt:"2026-07-22T10:00:00Z"},{databaseId:2,body:"<!-- manager:ship-it-approved:sha-1 -->",createdAt:"2026-07-22T10:01:00Z"}]' \
    "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" FAKE_GH_LOG="$d/gh.log" \
    FAKE_CODEX_REVIEW_JSON='{"findings":[],"overall_correctness":"patch is correct","overall_explanation":"ok","overall_confidence_score":0.9}' \
    -- --plan test-plan --once
  assert_file_contains "$d/gh.log" "diff changed" "approval reset detected"
  assert_not_contains "$(grep 'PR_MERGE' "$d/gh.log" 2>/dev/null || echo '')" "PR_MERGE" "no merge on stale ship it"
  rm -rf "$d"
}
test_approval_reset_after_epic_merge

# ---- Repo-wide discovery: Task 5 — --plan optional, load_manifest() parameterized ----

test_em_plan_flag_now_optional() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  seed_state "$d/state" "[]"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" -- --once
  assert_not_contains "$ERR" "Missing --plan" "--plan is no longer required"
  rm -rf "$d"
}
test_em_plan_flag_now_optional

test_em_repo_wide_no_manifest_loaded_at_startup() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  seed_state "$d/state" "[]"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" -- --once
  assert_not_contains "$ERR" "Manifest not found" "no manifest load is attempted at startup without --plan"
  rm -rf "$d"
}
test_em_repo_wide_no_manifest_loaded_at_startup

test_em_plan_given_manifest_missing_still_fatal() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" -- --plan does-not-exist --dry-run
  assert_eq "$RC" "1" "missing manifest with --plan given still exits 1"
  assert_contains "$ERR" "Manifest not found" "still reports the specific reason"
  rm -rf "$d"
}
test_em_plan_given_manifest_missing_still_fatal

test_em_plan_given_no_epic_still_fatal() {
  local d; d="$(mktemp -d)"
  make_repo "$d" test-plan
  seed_state "$d/state" "[$(issue_json 100 'Not the epic' 'no marker here' '[]')]"
  run_em "$d/work" "$(bindir_for "$d")" FAKE_GH_STATE="$d/state" -- --plan test-plan --dry-run
  assert_eq "$RC" "1" "missing epic issue with --plan given still exits 1"
  assert_contains "$ERR" "No epic issue" "still reports the specific reason (regression pin -- must match this exact wording)"
  rm -rf "$d"
}
test_em_plan_given_no_epic_still_fatal

# ---- Repo-wide discovery: Task 6 — discover_open_epics() staleness ranking ----

test_discover_older_visit_sorts_first_among_visited() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan-a docs/superpowers/plans/plan-a.md
  add_second_manifest_em "$d/work" plan-b docs/superpowers/plans/plan-b.md
  local bin; bin="$(bindir_for "$d")"
  local epic_a epic_b
  epic_a="$(issue_json 100 'Epic A' '<!-- plan-to-tickets:epic:docs/superpowers/plans/plan-a.md -->' '[]')"
  epic_b="$(issue_json 200 'Epic B' '<!-- plan-to-tickets:epic:docs/superpowers/plans/plan-b.md -->' '[]')"
  seed_state "$d/state" "[$epic_a,$epic_b]"
  jq '.issues["100"].comments = [{databaseId:1, body:"<!-- manager:lock-acquired:2026-01-05T00:00:00Z -->", createdAt:"2026-01-05T00:00:00Z"}]
      | .issues["200"].comments = [{databaseId:2, body:"<!-- manager:lock-acquired:2026-01-01T00:00:00Z -->", createdAt:"2026-01-01T00:00:00Z"}]' \
    "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
  run_em "$d/work" "$bin" FAKE_GH_STATE="$d/state" -- --dry-run --once
  assert_contains "$ERR" "epic issue:    #200" "epic B (older visit, Jan 1) sorts before epic A (newer visit, Jan 5)"
  rm -rf "$d"
}
test_discover_older_visit_sorts_first_among_visited

test_discover_ignores_non_epic_issues() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan-a docs/superpowers/plans/plan-a.md
  local bin; bin="$(bindir_for "$d")"
  local epic_a not_an_epic
  epic_a="$(issue_json 100 'Epic A' '<!-- plan-to-tickets:epic:docs/superpowers/plans/plan-a.md -->' '[]')"
  not_an_epic="$(issue_json 101 'A ticket' '<!-- plan-to-tickets:ticket:docs/superpowers/plans/plan-a.md:001-a -->' '[]')"
  seed_state "$d/state" "[$epic_a,$not_an_epic]"
  run_em "$d/work" "$bin" FAKE_GH_STATE="$d/state" -- --dry-run --once
  assert_contains "$ERR" "epic issue:    #100" "the epic-marker issue resolves correctly"
  assert_not_contains "$ERR" "Skipping discovered epic" "the ticket issue is not mistaken for an epic and doesn't trigger a skip"
  rm -rf "$d"
}
test_discover_ignores_non_epic_issues

# ---- Repo-wide discovery: Task 7 — per-cycle epic resolution ----

test_repo_wide_processes_stalest_epic() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan-a docs/superpowers/plans/plan-a.md
  add_second_manifest_em "$d/work" plan-b docs/superpowers/plans/plan-b.md
  local bin; bin="$(bindir_for "$d")"
  local epic_a epic_b
  epic_a="$(issue_json 100 'Epic A' '<!-- plan-to-tickets:epic:docs/superpowers/plans/plan-a.md -->' '[]')"
  epic_b="$(issue_json 200 'Epic B' '<!-- plan-to-tickets:epic:docs/superpowers/plans/plan-b.md -->' '[]')"
  seed_state "$d/state" "[$epic_a,$epic_b]"
  # Epic A already visited; Epic B never visited -> B is stalest, must be chosen.
  jq '.issues["100"].comments = [{databaseId:1, body:"<!-- manager:lock-acquired:2026-01-01T00:00:00Z -->", createdAt:"2026-01-01T00:00:00Z"}]' \
    "$d/state" > "$d/state.tmp" && mv "$d/state.tmp" "$d/state"
  run_em "$d/work" "$bin" FAKE_GH_STATE="$d/state" -- --dry-run --once
  assert_eq "$RC" "0" "repo-wide dry-run exits 0"
  assert_contains "$ERR" "epic issue:    #200" "resolved the stalest epic (B, #200), not epic A"
  rm -rf "$d"
}
test_repo_wide_processes_stalest_epic

test_repo_wide_skips_epic_with_missing_manifest() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan-a docs/superpowers/plans/plan-a.md
  # No manifest committed for plan-missing -- epic 200's marker references a
  # plan that was never filed with a manifest.
  local bin; bin="$(bindir_for "$d")"
  local epic_missing epic_a
  epic_missing="$(issue_json 200 'Broken epic' '<!-- plan-to-tickets:epic:docs/superpowers/plans/plan-missing.md -->' '[]')"
  epic_a="$(issue_json 100 'Epic A' '<!-- plan-to-tickets:epic:docs/superpowers/plans/plan-a.md -->' '[]')"
  seed_state "$d/state" "[$epic_missing,$epic_a]"
  # Both never-visited; #200 sorts first only by number-stability of jq's sort,
  # which is not guaranteed -- assert on behavior (skip + fallthrough), not order.
  run_em "$d/work" "$bin" FAKE_GH_STATE="$d/state" -- --dry-run --once
  assert_eq "$RC" "0" "repo-wide dry-run exits 0 despite one broken epic"
  assert_contains "$ERR" "epic issue:    #100" "fell through to the resolvable epic"
  rm -rf "$d"
}
test_repo_wide_skips_epic_with_missing_manifest

test_repo_wide_all_epics_broken() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan-a docs/superpowers/plans/plan-a.md
  local bin; bin="$(bindir_for "$d")"
  local epic_missing
  epic_missing="$(issue_json 200 'Broken epic' '<!-- plan-to-tickets:epic:docs/superpowers/plans/plan-missing.md -->' '[]')"
  seed_state "$d/state" "[$epic_missing]"
  run_em "$d/work" "$bin" FAKE_GH_STATE="$d/state" -- --once
  assert_contains "$ERR" "No discovered epics resolved to a valid manifest" "clear message when every discovered epic is broken"
  rm -rf "$d"
}
test_repo_wide_all_epics_broken

test_repo_wide_no_open_epics() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan-a docs/superpowers/plans/plan-a.md
  local bin; bin="$(bindir_for "$d")"
  seed_state "$d/state" "[]"
  run_em "$d/work" "$bin" FAKE_GH_STATE="$d/state" -- --once
  assert_contains "$ERR" "No open epics found" "clear message when nothing is discovered"
  rm -rf "$d"
}
test_repo_wide_no_open_epics
