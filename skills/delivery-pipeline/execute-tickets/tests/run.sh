#!/usr/bin/env bash
# Plain-bash test runner for execute-tickets.sh. No network: fake `gh`/`codex`
# on PATH, and a real local git repo + bare remote so worktree/push/fetch
# behavior is exercised for real (see fake-gh, fake-codex, lib.sh).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

DEFAULT_AGENT_CMD='echo "iter {iteration}" >> note-{issue_number}.txt && git add -A && git commit -q -m "ticket {issue_number} iter {iteration}"'

test_help() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  run_et "$d/work" "$bin" -- --help
  assert_eq "$RC" "0" "help exits 0"
  assert_contains "$OUT" "execute-tickets.sh" "help mentions the script"
  assert_contains "$OUT" "--agent-cmd" "help lists the --agent-cmd flag"
  rm -rf "$d"
}

test_missing_worker_flag() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  run_et "$d/work" "$bin" -- --plan plan1 --agent-cmd echo
  assert_eq "$RC" "2" "missing --worker exits 2"
  assert_contains "$ERR" "Missing --worker" "clear error for missing --worker"
  rm -rf "$d"
}

test_manifest_not_found() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$d/state.json" \
    -- --worker alice --plan does-not-exist --agent-cmd echo --once
  assert_eq "$RC" "1" "missing manifest exits 1"
  assert_contains "$ERR" "Manifest not found" "clear error for missing manifest"
  rm -rf "$d"
}

test_help
test_missing_worker_flag
test_manifest_not_found

test_dry_run_reports_selected_ticket() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" \
    -- --worker alice --plan plan1 --agent-cmd "$DEFAULT_AGENT_CMD" --dry-run --once
  assert_eq "$RC" "0" "dry-run exits 0"
  assert_contains "$ERR" "ticket:            #101" "dry-run reports the selected ticket"
  assert_contains "$ERR" "source_branch:     epic" "dry-run reports the epic branch"
  rm -rf "$d"
}

test_dry_run_reports_selected_ticket

# --- Green path: clean review + green CI -> merge, and the ticket issue must be
# explicitly closed. "Closes #n" in the PR body does NOT auto-close anything
# here because the PR targets the epic branch, not the repo's default branch
# (GitHub only honors closing keywords against the default branch) -- so the
# executor must close the issue itself.
test_green_path_merges_and_closes_issue() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json" log="$d/gh.log"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" FAKE_GH_LOG="$log" \
    -- --worker alice --plan plan1 --agent-cmd "$DEFAULT_AGENT_CMD" --once
  assert_eq "$RC" "0" "green path exits 0"
  assert_contains "$(cat "$log")" "label create lock:justin" "ensure_lock_labels creates all 10 named lock labels, not just 4"
  jqok "$(cat "$state")" '.issues["101"].state == "closed"' "ticket issue is explicitly closed on merge"
  jqok "$(cat "$state")" '(.issues["101"].labels | index("lock:alice")) == null' "lock label released on merge"
  jqok "$(cat "$state")" '.prs["1"].merged == true' "PR is merged"
  assert_contains "$(cat "$log")" "issue close 101" "executor explicitly closes the ticket issue (Closes # keyword is a no-op against a non-default base branch)"
  rm -rf "$d"
}

test_green_path_merges_and_closes_issue

# --- Dependency gating: a ticket with an open "Depends on: #N" is not ready
# until #N is actually closed (which, per the fix above, only happens via the
# executor's explicit `gh issue close`, not the PR's body text).
seed_two_tickets_with_dependency() {
  local state="$1" ticket_101_state="$2"
  seed_state "$state" "$(jq -n --arg s101 "$ticket_101_state" '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:$s101},
    {number:102, title:"Ticket B", body:"Body B\n\nDepends on: #101\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:002-b -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
}

test_dependency_gating_blocks_when_open() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json"
  seed_two_tickets_with_dependency "$state" "open"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" \
    -- --worker alice --plan plan1 --agent-cmd "$DEFAULT_AGENT_CMD" --dry-run --once
  assert_contains "$ERR" "ticket:            #101" "picks the dependency-free ticket first"
  assert_not_contains "$ERR" "ticket:            #102" "does not pick a ticket whose dependency is still open"
  rm -rf "$d"
}

test_dependency_gating_unblocks_when_closed() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json"
  seed_two_tickets_with_dependency "$state" "closed"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" \
    -- --worker alice --plan plan1 --agent-cmd "$DEFAULT_AGENT_CMD" --dry-run --once
  assert_contains "$ERR" "ticket:            #102" "picks the dependent ticket once its dependency issue is closed"
  rm -rf "$d"
}

test_dependency_gating_blocks_when_open
test_dependency_gating_unblocks_when_closed

# --- A blocking iteration-1 review sends the ticket back to the agent; if the
# iteration-2 push then genuinely fails (rejected by the remote), the executor
# must flag needs-human instead of silently proceeding to re-review/merge a
# branch that never actually received the fix.
BLOCKING_REVIEW='{"findings":[{"title":"Null deref","body":"Will crash","confidence_score":0.95,"priority":0,"code_location":{"absolute_file_path":"x.txt","line_range":{"start":1,"end":1}}}],"overall_correctness":"patch is incorrect","overall_explanation":"crashes","overall_confidence_score":0.9}'
CLEAN_REVIEW='{"findings":[],"overall_correctness":"patch is correct","overall_explanation":"fixed","overall_confidence_score":0.9}'

test_swallowed_push_failure_on_retry_is_flagged_needs_human() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  install_reject_second_ticket_push "$d"
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json" log="$d/gh.log"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  local responses; responses="$(write_codex_responses "$d/codex-responses" "$BLOCKING_REVIEW" "$CLEAN_REVIEW")"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" FAKE_GH_LOG="$log" FAKE_CODEX_RESPONSES_DIR="$responses" \
    -- --worker alice --plan plan1 --agent-cmd "$DEFAULT_AGENT_CMD" --once
  jqok "$(cat "$state")" '(.issues["101"].labels | index("needs-human")) != null' "ticket is flagged needs-human when the retry push is silently rejected"
  jqok "$(cat "$state")" '.prs["1"].merged != true' "PR is not merged when the fix never actually reached origin"
  assert_contains "$(cat "$log")" "BODY_CONTENT(#101): Executor (worker alice) gave up: no new commits pushed on iteration 2" "needs-human reason names the real push failure, not a stale merge"
  rm -rf "$d"
}

test_swallowed_push_failure_on_retry_is_flagged_needs_human

AGENT_CMD_LOGGING='set -- {iteration} {review_feedback}; printf "iter=%s feedback_nonempty=%s\n" "$1" "$([ -s "$2" ] && echo yes || echo no)" >> "$RESULTS_DIR/agent-calls.log"; if [ -s "$2" ]; then cat "$2" >> "$RESULTS_DIR/feedback-content.log"; fi; echo iter-{iteration} >> note-{issue_number}.txt; git add -A; git commit -q -m ticket-{issue_number}-iter-{iteration}'

# --- Red path: a blocking iteration-1 review must (a) write an actionable
# feedback bundle containing the blocking finding and (b) re-invoke the agent
# with {iteration}=2 and {review_feedback} pointing at that bundle. A clean
# iteration-2 review then merges normally.
test_red_path_feeds_blocking_findings_back_to_agent() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json" results="$d/results"
  mkdir -p "$results"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  local responses; responses="$(write_codex_responses "$d/codex-responses" "$BLOCKING_REVIEW" "$CLEAN_REVIEW")"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" FAKE_CODEX_RESPONSES_DIR="$responses" RESULTS_DIR="$results" \
    -- --worker alice --plan plan1 --agent-cmd "$AGENT_CMD_LOGGING" --once
  assert_file_contains "$results/agent-calls.log" "iter=1 feedback_nonempty=no" "iteration 1 gets no feedback bundle"
  assert_file_contains "$results/agent-calls.log" "iter=2 feedback_nonempty=yes" "agent is re-invoked with iteration=2 once a blocking finding comes back"
  assert_file_contains "$results/feedback-content.log" "Null deref" "the feedback bundle passed to the agent names the blocking finding"
  assert_file_contains "$results/feedback-content.log" "Blocking findings" "the feedback bundle is the actionable-findings section, not just the raw review JSON"
  jqok "$(cat "$state")" '.prs["1"].merged == true' "clean iteration-2 review merges normally"
  rm -rf "$d"
}

test_red_path_feeds_blocking_findings_back_to_agent

# --- Iteration cap: a review that never clears within --max-iterations gives
# up and flags needs-human rather than looping forever.
test_max_iterations_gives_up_and_flags_needs_human() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json" log="$d/gh.log"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" FAKE_GH_LOG="$log" FAKE_CODEX_REVIEW_JSON="$BLOCKING_REVIEW" \
    -- --worker alice --plan plan1 --agent-cmd "$DEFAULT_AGENT_CMD" --max-iterations 2 --once
  jqok "$(cat "$state")" '(.issues["101"].labels | index("needs-human")) != null' "ticket is flagged needs-human once max-iterations is hit"
  jqok "$(cat "$state")" '.prs["1"].merged != true' "PR is never merged when the review stays blocking"
  assert_contains "$(cat "$log")" "gave up: review loop exhausted after 2 iterations" "needs-human comment names the iteration cap as the reason"
  rm -rf "$d"
}

test_max_iterations_gives_up_and_flags_needs_human

# --- Merge failure: even a clean review must flag needs-human (not silently
# succeed) if gh pr merge itself fails on both the --auto and synchronous
# attempts (e.g. branch protection blocking the executor's account).
test_merge_failure_flags_needs_human() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json" log="$d/gh.log"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" FAKE_GH_LOG="$log" \
    FAKE_GH_MERGE_AUTO_FAIL=true FAKE_GH_MERGE_SYNC_FAIL=true \
    -- --worker alice --plan plan1 --agent-cmd "$DEFAULT_AGENT_CMD" --once
  jqok "$(cat "$state")" '(.issues["101"].labels | index("needs-human")) != null' "ticket is flagged needs-human when both merge attempts fail"
  assert_contains "$(cat "$log")" "gave up: merge failed after clean review" "needs-human comment names the merge failure as the reason"
  assert_not_contains "$(cat "$log")" "issue close 101" "the ticket issue is not closed when the merge never actually happened"
  rm -rf "$d"
}

test_merge_failure_flags_needs_human

# --- Lock-label race: if a rival worker's lock label shows up alongside ours
# right after claiming (i.e. it lands between our add-label and our follow-up
# read -- pick_candidate itself would already exclude a ticket that visibly
# carries a lock:* label before either worker moves), claim_ticket must detect
# it and release its own lock rather than proceeding as if it owned the
# ticket outright. FAKE_GH_INJECT_RIVAL_LOCK simulates that mid-air write.
test_claim_ticket_releases_lock_on_rival_lock_race() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" FAKE_GH_INJECT_RIVAL_LOCK="lock:bob" \
    -- --worker alice --plan plan1 --agent-cmd "$DEFAULT_AGENT_CMD" --once
  assert_eq "$RC" "0" "cycle exits 0 even when the claim race is lost"
  assert_contains "$ERR" "Lost claim race on #101" "reports the lost race instead of silently proceeding"
  jqok "$(cat "$state")" '(.issues["101"].labels | index("lock:alice")) == null' "releases its own lock label after detecting a rival lock"
  jqok "$(cat "$state")" '(.issues["101"].labels | index("lock:bob")) != null' "does not touch the rival lock label"
  jqok "$(cat "$state")" '(.issues["101"].assignees | length) == 0' "never assigns itself to a ticket it lost the race on"
  rm -rf "$d"
}

test_claim_ticket_releases_lock_on_rival_lock_race

# --- The ERR trap in run_ticket exists to catch genuinely unexpected failures
# (not the explicit `||`-guarded ones) and clean up: release/flag the ticket
# and remove the worktree instead of leaving it running past a corrupted step.
# A misconfigured --block-priority-max (non-numeric) breaks the *unguarded*
# `jq --argjson maxp ...` call inside build_feedback_bundle -- a real
# misconfiguration an operator could actually make, not a synthetic hook.
test_unexpected_error_is_caught_immediately_not_ground_through_all_iterations() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json" log="$d/gh.log"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" FAKE_GH_LOG="$log" FAKE_CODEX_REVIEW_JSON="$BLOCKING_REVIEW" \
    -- --worker alice --plan plan1 --agent-cmd "$DEFAULT_AGENT_CMD" --block-priority-max abc --once
  local agent_calls; agent_calls="$(grep -c "Agent (iter" <<<"$ERR" || true)"
  assert_eq "$agent_calls" "1" "the unexpected error aborts on the first iteration instead of grinding through all 5"
  assert_contains "$(cat "$log")" "gave up: unexpected error in run_ticket" "needs-human reason names the real cause (an unguarded internal failure), not a fabricated iteration-exhaustion"
  assert_not_contains "$ERR" "review loop exhausted" "does not misreport an internal crash as a normal review-loop exhaustion"
  local leaked; leaked="$(find "$d" -maxdepth 1 -name 'wt-*' | wc -l | tr -d ' ')"
  assert_eq "$leaked" "0" "the ticket worktree is cleaned up, not leaked, after the unexpected error"
  jqok "$(cat "$state")" '(.issues["101"].labels | index("needs-human")) != null' "ticket is flagged needs-human"
  rm -rf "$d"
}

test_unexpected_error_is_caught_immediately_not_ground_through_all_iterations

# --- Stale epic-branch fetch: in persistent loop mode (no --once), a worker
# must re-fetch origin/<source_branch> before branching each new ticket's
# worktree, so later tickets build on sibling tickets already merged into the
# epic branch during this same process's lifetime -- not on the snapshot from
# when the process started. Ticket 101's agent_cmd simulates "meanwhile this
# got merged into epic on GitHub" via an INDEPENDENT clone that pushes to the
# bare remote directly -- deliberately NOT a push from within the shared
# work-repo's own worktree, whose local origin/epic tracking ref would
# otherwise get opportunistically updated by git's own push machinery and
# mask the very staleness this test exists to catch. This happens
# synchronously as part of ticket 101's own processing, so there is no timing
# race with ticket 102's cycle starting; only the *fetch* is in question.
AGENT_CMD_STALE_FETCH_CHECK='if [ {issue_number} = 101 ]; then T=$(mktemp -d); git clone -q "$REMOTE_URL" "$T"; git -C "$T" checkout -q epic; echo external-merge >> "$T/external-merge-101.txt"; git -C "$T" add -A; git -C "$T" commit -q -m external-merge-101; git -C "$T" push -q origin epic; rm -rf "$T"; fi; if [ -f external-merge-101.txt ]; then echo FOUND >$RESULTS_DIR/saw101-from-{issue_number}; else echo MISSING >$RESULTS_DIR/saw101-from-{issue_number}; fi; echo marker >>note-{issue_number}.txt; git add -A; git commit -q -m ticket-{issue_number} --allow-empty'

test_worker_refetches_epic_branch_between_tickets_in_loop_mode() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json" results="$d/results"
  mkdir -p "$results"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"},
    {number:102, title:"Ticket B", body:"Body B\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:002-b -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  ( cd "$d/work" && PATH="$bin:$PATH" FAKE_GH_STATE="$state" RESULTS_DIR="$results" REMOTE_URL="$d/remote.git" \
      bash "$SCRIPT" --worker alice --plan plan1 --agent-cmd "$AGENT_CMD_STALE_FETCH_CHECK" --poll 1 \
      >"$d/loop-stdout.log" 2>"$d/loop-stderr.log" & echo $! > "$d/pid" )
  local waited=0 found=""
  while [ "$waited" -lt 20 ]; do
    [ -f "$results/saw101-from-102" ] && { found="yes"; break; }
    sleep 0.2
    waited=$((waited + 1))
  done
  kill "$(cat "$d/pid")" 2>/dev/null || true
  wait "$(cat "$d/pid")" 2>/dev/null || true
  assert_eq "$found" "yes" "worker processes ticket 102 within the timeout"
  assert_file_contains "$results/saw101-from-102" "FOUND" "ticket 102's worktree sees ticket 101's epic-branch update from earlier in this same worker run"
  rm -rf "$d"
}

test_worker_refetches_epic_branch_between_tickets_in_loop_mode

# --- An unrecognized --worker value is a hard error at argument-parsing
# time, before any GitHub mutation, listing the valid names -- not a silent
# fallback and not a generic "invalid argument" message.
test_invalid_worker_name_is_rejected() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json" log="$d/gh.log"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" FAKE_GH_LOG="$log" \
    -- --worker zack --plan plan1 --agent-cmd "$DEFAULT_AGENT_CMD" --once
  assert_eq "$RC" "2" "an unrecognized worker name exits 2"
  assert_contains "$ERR" "alice" "error lists a valid worker name"
  assert_contains "$ERR" "justin" "error lists the full set of valid worker names"
  assert_eq "$(cat "$log" 2>/dev/null)" "" "no gh calls happen before worker-name validation"
  rm -rf "$d"
}

test_invalid_worker_name_is_rejected

# --- --worker is case-insensitive: the name is normalized to lowercase
# wherever it's used (lock label, worktree path, log prefix), so "Carol" and
# "carol" produce the same lock label.
test_worker_name_is_case_insensitive() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" \
    -- --worker Carol --plan plan1 --agent-cmd "$DEFAULT_AGENT_CMD" --dry-run --once
  assert_eq "$RC" "0" "a mixed-case worker name is accepted"
  assert_contains "$ERR" "DRY RUN (worker carol):" "the worker name is normalized to lowercase everywhere it's used"
  rm -rf "$d"
}

test_worker_name_is_case_insensitive

# --- init-agents.sh scaffolds .execute-tickets/agents.yml from the vendored
# Claude template, refuses overwrite without --force, and never touches checklist.yml.
INIT_SCRIPT="$HERE/../scripts/init-agents.sh"

test_init_agents_writes_file() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  bash "$INIT_SCRIPT" --repo-root "$d/work"
  assert_eq "$?" "0" "init-agents exits 0"
  [ -f "$d/work/.execute-tickets/agents.yml" ] && ok "agents.yml created" || bad "agents.yml created" "missing file"
  assert_file_contains "$d/work/.execute-tickets/agents.yml" "lite:" "template has lite key"
  assert_file_contains "$d/work/.execute-tickets/agents.yml" "efficient:" "template has efficient key"
  assert_file_contains "$d/work/.execute-tickets/agents.yml" "standard:" "template has standard key"
  assert_file_contains "$d/work/.execute-tickets/agents.yml" "flagship:" "template has flagship key"
  assert_file_contains "$d/work/.execute-tickets/agents.yml" "claude" "Claude defaults mention claude CLI"
  [ ! -f "$d/work/.execute-tickets/checklist.yml" ] && ok "does not create checklist.yml" || bad "does not create checklist.yml" "checklist was created"
  rm -rf "$d"
}

test_init_agents_writes_file

test_init_agents_refuses_overwrite_without_force() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  mkdir -p "$d/work/.execute-tickets"
  echo "lite: keep-me" > "$d/work/.execute-tickets/agents.yml"
  bash "$INIT_SCRIPT" --repo-root "$d/work" >"$d/out" 2>"$d/err"
  assert_eq "$?" "1" "second init without --force exits 1"
  assert_file_contains "$d/err" "--force" "error mentions --force"
  assert_file_contains "$d/work/.execute-tickets/agents.yml" "keep-me" "existing file left intact"
  rm -rf "$d"
}

test_init_agents_refuses_overwrite_without_force

test_init_agents_force_overwrites() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  mkdir -p "$d/work/.execute-tickets"
  echo "lite: old" > "$d/work/.execute-tickets/agents.yml"
  bash "$INIT_SCRIPT" --repo-root "$d/work" --force >"$d/out" 2>"$d/err"
  assert_eq "$?" "0" "--force init exits 0"
  assert_file_contains "$d/work/.execute-tickets/agents.yml" "flagship:" "overwritten with full template"
  assert_not_contains "$(cat "$d/work/.execute-tickets/agents.yml")" "lite: old" "old content replaced"
  rm -rf "$d"
}

test_init_agents_force_overwrites

test_init_agents_dry_run_writes_nothing() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  bash "$INIT_SCRIPT" --repo-root "$d/work" --dry-run >"$d/out" 2>"$d/err"
  assert_eq "$?" "0" "dry-run exits 0"
  [ ! -f "$d/work/.execute-tickets/agents.yml" ] && ok "dry-run does not write agents.yml" || bad "dry-run does not write agents.yml" "file was written"
  assert_file_contains "$d/out" "lite:" "dry-run prints template to stdout"
  rm -rf "$d"
}

test_init_agents_dry_run_writes_nothing

test_init_agents_preserves_existing_checklist() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  mkdir -p "$d/work/.execute-tickets"
  echo "checklist: true" > "$d/work/.execute-tickets/checklist.yml"
  bash "$INIT_SCRIPT" --repo-root "$d/work"
  assert_eq "$?" "0" "init exits 0 beside checklist"
  assert_file_contains "$d/work/.execute-tickets/checklist.yml" "checklist: true" "checklist.yml untouched"
  rm -rf "$d"
}

test_init_agents_preserves_existing_checklist

# --- agents.yml routing: --agent-cmd optional; all four tiers required at load;
# per-ticket model-tier selects the command; flag override wins.

test_missing_agent_cmd_and_agents_yml_fails_preflight() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" \
    -- --worker alice --plan plan1 --once
  assert_eq "$RC" "1" "missing agents.yml without --agent-cmd exits 1"
  assert_contains "$ERR" "agents.yml" "error names agents.yml"
  rm -rf "$d"
}

test_missing_agent_cmd_and_agents_yml_fails_preflight

test_agents_yml_missing_tier_fails_preflight() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  mkdir -p "$d/work/.execute-tickets"
  # only three keys
  cat > "$d/work/.execute-tickets/agents.yml" <<'YML'
lite: "echo lite"
efficient: "echo efficient"
standard: "echo standard"
YML
  local state="$d/state.json"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" \
    -- --worker alice --plan plan1 --once
  assert_eq "$RC" "1" "partial agents.yml exits 1"
  assert_contains "$ERR" "flagship" "error names the missing tier"
  rm -rf "$d"
}

test_agents_yml_missing_tier_fails_preflight

test_agents_yml_routes_by_model_tier() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  write_agents_yml "$d/work" \
    'echo lite > agent-tier.txt && git add -A && git commit -q -m lite' \
    'echo efficient > agent-tier.txt && git add -A && git commit -q -m efficient' \
    'echo standard > agent-tier.txt && git add -A && git commit -q -m standard' \
    'echo flagship > agent-tier.txt && git add -A && git commit -q -m flagship'
  local state="$d/state.json" log="$d/gh.log"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" FAKE_GH_LOG="$log" \
    -- --worker alice --plan plan1 --once
  assert_eq "$RC" "0" "YAML-routed green path exits 0"
  jqok "$(cat "$state")" '.issues["101"].state == "closed"' "ticket closed after YAML-routed run"
  assert_contains "$(cat "$log")" "agents.yml#efficient" "audit trail records agents.yml#efficient source"
  rm -rf "$d"
}

test_agents_yml_routes_by_model_tier

test_agent_cmd_override_wins_over_agents_yml() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  write_agents_yml "$d/work" \
    'echo yml-lite > agent-tier.txt && git add -A && git commit -q -m y' \
    'echo yml-efficient > agent-tier.txt && git add -A && git commit -q -m y' \
    'echo yml-standard > agent-tier.txt && git add -A && git commit -q -m y' \
    'echo yml-flagship > agent-tier.txt && git add -A && git commit -q -m y'
  local state="$d/state.json" log="$d/gh.log"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" FAKE_GH_LOG="$log" \
    -- --worker alice --plan plan1 --agent-cmd "$DEFAULT_AGENT_CMD" --once
  assert_eq "$RC" "0" "override path exits 0"
  assert_contains "$(cat "$log")" "--agent-cmd" "audit trail records --agent-cmd source"
  assert_not_contains "$(cat "$log")" "agents.yml#efficient" "YAML tier not used when flag set"
  rm -rf "$d"
}

test_agent_cmd_override_wins_over_agents_yml

test_invalid_model_tier_needs_human() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  write_agents_yml "$d/work"
  local state="$d/state.json" log="$d/gh.log"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:turbo"], assignees:[], state:"open"}
  ]')"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" FAKE_GH_LOG="$log" \
    -- --worker alice --plan plan1 --once
  assert_eq "$RC" "0" "worker exits 0 after needs-human (once mode still exits 0)"
  jqok "$(cat "$state")" '(.issues["101"].labels | index("needs-human")) != null' "invalid tier gets needs-human"
  assert_contains "$(cat "$log")" "model-tier" "needs-human reason mentions model-tier"
  rm -rf "$d"
}

test_invalid_model_tier_needs_human

test_dry_run_reports_agent_source_from_yml() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  write_agents_yml "$d/work" \
    'echo lite' 'echo efficient-cmd' 'echo standard' 'echo flagship'
  local state="$d/state.json"
  seed_state "$state" "$(jq -n '[
    {number:101, title:"Ticket A", body:"Body A\n\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/test-plan.md:001-a -->",
     labels:["priority:p1","complexity:small","model-tier:efficient"], assignees:[], state:"open"}
  ]')"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" \
    -- --worker alice --plan plan1 --dry-run --once
  assert_eq "$RC" "0" "dry-run with agents.yml exits 0"
  assert_contains "$ERR" "agent source:      agents.yml#efficient" "dry-run shows YAML source"
  assert_contains "$ERR" "efficient-cmd" "dry-run shows resolved efficient command"
  rm -rf "$d"
}

test_dry_run_reports_agent_source_from_yml

# ---- Repo-wide discovery: Task 1 — --plan optional, load_manifest() parameterized ----

test_plan_flag_now_optional() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json"
  seed_state "$state" "[]"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" \
    -- --worker alice --agent-cmd echo --once
  assert_not_contains "$ERR" "Missing --plan" "--plan is no longer required"
  rm -rf "$d"
}
test_plan_flag_now_optional

test_repo_wide_no_manifest_loaded_at_startup() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  local state="$d/state.json"
  seed_state "$state" "[]"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$state" \
    -- --worker alice --agent-cmd echo --once
  assert_eq "$RC" "0" "repo-wide with no tickets exits 0 (once mode always exits 0)"
  assert_not_contains "$ERR" "Manifest not found" "no manifest load is attempted at startup without --plan"
  assert_contains "$ERR" "No ready tickets" "empty repo-wide backlog behaves like today's empty-backlog case, not an error"
  rm -rf "$d"
}
test_repo_wide_no_manifest_loaded_at_startup

test_plan_given_manifest_missing_still_fatal() {
  local d; d="$(mktemp -d)"
  make_repo "$d" plan1
  local bin; bin="$(bindir_for "$d")"
  run_et "$d/work" "$bin" FAKE_GH_STATE="$d/state.json" \
    -- --worker alice --plan does-not-exist --agent-cmd echo --once
  assert_eq "$RC" "1" "missing manifest with --plan given still exits 1"
  assert_contains "$ERR" "Manifest not found" "still reports the specific reason"
  rm -rf "$d"
}
test_plan_given_manifest_missing_still_fatal
