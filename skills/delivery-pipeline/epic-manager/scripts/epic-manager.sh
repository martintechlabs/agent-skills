#!/usr/bin/env bash
# epic-manager.sh: singleton plan-level supervisor for a plan-to-tickets epic.
# Tracks executor progress, gates the epic->main PR behind a per-project hybrid
# checklist, runs a final integration review, and obeys human commands (ship it
# / rework: / abandon) posted as comments on the epic issue. Peer to
# execute-tickets.sh; communicates through GitHub state only.
set -euo pipefail

PLAN_SLUG=""
REPO_WIDE=false   # true when --plan was omitted: discover across every open epic
REPO=""
CHECKLIST_FILE=""
REVIEWER_CMD_DEFAULT='codex exec --model "${CODEX_MODEL:-gpt-5-codex}" --output-schema {final_review_schema} -o {final_review_output} --sandbox read-only - < {final_review_prompt_composed}'
REVIEWER_CMD=""
FINAL_REVIEW_SCHEMA=""
FINAL_REVIEW_PROMPT=""
BLOCK_PRIORITY_MAX=1
AUTO_REWORK_PRIORITY_MAX=2
POLL_SECONDS=300
STALE_LOCK_THRESHOLD=3600
MAX_AUTO_REWORK_ROUNDS=5
ONCE=false
DRY_RUN=false
VERBOSE=true
HUMAN_ACTED_THIS_CYCLE=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK_LABEL="lock:manager"
LOCK_ACQUIRED_AT=""
MANIFEST_FILE=""
SOURCE_BRANCH=""
SPEC_FILE=""
PLAN_FILE=""
EPIC_NUMBER=""
EPIC_MARKER=""
TICKET_MARKER_PREFIX=""

usage() {
  cat <<'EOF'
epic-manager.sh -- supervise a plan-to-tickets epic end-to-end.

Usage:
  epic-manager.sh --plan <slug> [flags]

Required:
  --plan <slug>            Plan slug: basename of docs/superpowers/tickets/<slug>.md.

Optional:
  --repo <owner/repo>          Target repo (default: current repo via `gh repo view`).
  --checklist <path>           Override checklist file (default: .execute-tickets/checklist.yml).
  --reviewer-cmd <cmd>         Final-review codex command (default: vendored).
  --final-review-schema <path> Override final-review schema (default: vendored).
  --final-review-prompt <path> Override final-review prompt (default: vendored).
  --block-priority-max <N>     Findings at/ below this priority get the loud review-blocked
                                banner (still advisory -- never gates `ship it`). Default: 1.
  --auto-rework-priority-max <N> Findings at/below this priority trigger an auto-rework round
                                (broader than --block-priority-max by default, so minor findings
                                get fixed too, not just merge-blocking ones). Default: 2.
  --max-auto-rework-rounds <N> Auto-file a rework ticket from qualifying final-review findings,
                                up to N rounds, before escalating to needs-human. 0 disables
                                auto-rework (old advisory-only behavior). Default: 5.
  --poll <seconds>             Sleep between cycles in loop mode. Default: 300.
  --stale-lock-threshold <sec> Force-claim lock:manager after this staleness. Default: 3600.
  --once                       Run one cycle, then exit (cron mode).
  --dry-run                    Print reconciled state + intended actions; mutate nothing.
  --quiet                      Reduce stderr logging. Epic-issue audit comments always post.
  --help                       Show this help.

Human commands (posted as comments on the epic issue, first line = trigger):
  ship it / shipit / #shipit / 🚀 / lgtm / merge it -> merge the epic PR (guards + CI re-verify)
  rework [#N]: <description>                  -> file a new ticket; codex picks metadata
  abandon                                     -> close epic PR + close epic issue (not planned)
EOF
}

main() {
  parse_args "$@"
  preflight
  if [ "$REPO_WIDE" != true ]; then
    load_manifest "$PLAN_SLUG" || die 1 "Manifest not found or malformed for plan '$PLAN_SLUG', or no epic issue found for it (run plan-to-tickets first)"
  fi
  # --dry-run and --once both run a single cycle and exit. The loop mode is for
  # long-running terminals / CI; cron firings always pass --once (see WARP.md).
  if [ "$ONCE" = true ] || [ "$DRY_RUN" = true ]; then
    set +e; run_one_cycle; set -e
    exit 0
  fi
  while true; do
    set +e; run_one_cycle; local rc=$?; set -e
    [ "$rc" -ne 0 ] && sleep "$POLL_SECONDS"
  done
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --plan) req_val "$@"; PLAN_SLUG="$2"; shift 2 ;;
      --repo) req_val "$@"; REPO="$2"; shift 2 ;;
      --checklist) req_val "$@"; CHECKLIST_FILE="$2"; shift 2 ;;
      --reviewer-cmd) req_val "$@"; REVIEWER_CMD="$2"; shift 2 ;;
      --final-review-schema) req_val "$@"; FINAL_REVIEW_SCHEMA="$2"; shift 2 ;;
      --final-review-prompt) req_val "$@"; FINAL_REVIEW_PROMPT="$2"; shift 2 ;;
      --block-priority-max) req_val "$@"; BLOCK_PRIORITY_MAX="$2"; shift 2 ;;
      --auto-rework-priority-max) req_val "$@"; AUTO_REWORK_PRIORITY_MAX="$2"; shift 2 ;;
      --max-auto-rework-rounds) req_val "$@"; MAX_AUTO_REWORK_ROUNDS="$2"; shift 2 ;;
      --poll) req_val "$@"; POLL_SECONDS="$2"; shift 2 ;;
      --stale-lock-threshold) req_val "$@"; STALE_LOCK_THRESHOLD="$2"; shift 2 ;;
      --once) ONCE=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      --quiet) VERBOSE=false; shift ;;
      --help) usage; exit 0 ;;
      *) die 2 "Unknown flag: $1" ;;
    esac
  done
  if [ -z "$PLAN_SLUG" ]; then
    REPO_WIDE=true
  fi
  [ -n "$REVIEWER_CMD" ] || REVIEWER_CMD="$REVIEWER_CMD_DEFAULT"
  [ -n "$FINAL_REVIEW_SCHEMA" ] || FINAL_REVIEW_SCHEMA="$SKILL_DIR/references/final-review-schema.json"
  [ -n "$FINAL_REVIEW_PROMPT" ] || FINAL_REVIEW_PROMPT="$SKILL_DIR/references/final-review-prompt.md"
  [ -n "$CHECKLIST_FILE" ] || CHECKLIST_FILE=".execute-tickets/checklist.yml"
}

req_val() { [ $# -ge 2 ] || die 2 "Missing value for $1"; }
die() { local code="$1"; shift; echo "$*" >&2; exit "$code"; }

preflight() {
  command -v gh >/dev/null 2>&1 || die 1 "gh is required."
  command -v jq >/dev/null 2>&1 || die 1 "jq is required."
  command -v git >/dev/null 2>&1 || die 1 "git is required."
  command -v codex >/dev/null 2>&1 || log "WARNING: codex not on PATH; --reviewer-cmd must invoke it explicitly."
  command -v yq >/dev/null 2>&1 || log "WARNING: yq not on PATH; checklist gate will fail if .execute-tickets/checklist.yml exists."
  gh auth status >/dev/null 2>&1 || die 1 "gh is not authenticated. Run: gh auth login"
  [ -f "$FINAL_REVIEW_SCHEMA" ] || die 1 "Final-review schema not found: $FINAL_REVIEW_SCHEMA"
  [ -f "$FINAL_REVIEW_PROMPT" ] || die 1 "Final-review prompt not found: $FINAL_REVIEW_PROMPT"
  if [ -z "$REPO" ]; then
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  fi
  [ -n "$REPO" ] || die 1 "Could not determine target repo. Pass --repo."
  ensure_labels
}

ensure_labels() {
  local existing
  existing="$(gh label list --repo "$REPO" --json name -q '.[].name' 2>/dev/null || true)"
  [ "$DRY_RUN" = true ] && return 0
  grep -qxF "lock:manager" <<<"$existing" || \
    gh label create "lock:manager" --repo "$REPO" --color "5319e7" --force >/dev/null 2>&1 || true
  grep -qxF "needs-human" <<<"$existing" || \
    gh label create "needs-human" --repo "$REPO" --color "d93f0b" --force >/dev/null 2>&1 || true
  grep -qxF "auto-rework-exhausted" <<<"$existing" || \
    gh label create "auto-rework-exhausted" --repo "$REPO" --color "b60205" --force >/dev/null 2>&1 || true
}

# Same color scheme as plan-to-tickets/scripts/create-tickets.sh's label_color().
rework_label_color() {
  case "$1" in
    complexity:small) echo "0e8a16" ;;
    complexity:medium) echo "fbca04" ;;
    complexity:large) echo "b60205" ;;
    priority:p1) echo "b60205" ;;
    priority:p2) echo "d93f0b" ;;
    priority:p3) echo "c5def5" ;;
    model-tier:lite) echo "bfd4f2" ;;
    model-tier:efficient) echo "1d76db" ;;
    model-tier:standard) echo "0052cc" ;;
    model-tier:flagship) echo "5319e7" ;;
    *) echo "ededed" ;;
  esac
}

ensure_rework_label() {
  local name="$1" existing
  existing="$(gh label list --repo "$REPO" --json name -q '.[].name' 2>/dev/null || true)"
  grep -qxF "$name" <<<"$existing" && return 0
  gh label create "$name" --repo "$REPO" --color "$(rework_label_color "$name")" --force >/dev/null 2>&1 || true
}

# load_manifest <slug> -- populates MANIFEST_FILE/SOURCE_BRANCH/SPEC_FILE/PLAN_FILE/
# EPIC_MARKER/TICKET_MARKER_PREFIX/EPIC_NUMBER/PLAN_SLUG for <slug>. Returns 1
# (never dies) on a missing/malformed manifest or a missing epic issue -- the
# caller decides whether that's fatal (--plan given) or a skip signal (repo-wide).
load_manifest() {
  local slug="$1"
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  local manifest_file="$root/docs/superpowers/tickets/$slug.md"
  if [ ! -f "$manifest_file" ]; then
    log "Manifest not found: $manifest_file (run plan-to-tickets first)"
    return 1
  fi
  local source_branch="" spec_file="" plan_file=""
  local in_fm=false key val line
  while IFS= read -r line; do
    if [ "$line" = "---" ]; then
      if [ "$in_fm" = false ]; then in_fm=true; continue; else break; fi
    fi
    [ "$in_fm" = true ] || continue
    key="${line%%:*}"; val="${line#*:}"; val="${val# }"; val="${val#\"}"; val="${val%\"}"
    case "$key" in
      source_branch) source_branch="$val" ;;
      spec_file) spec_file="$val" ;;
      plan_file) plan_file="$val" ;;
    esac
  done < "$manifest_file"
  if [ -z "$source_branch" ] || [ -z "$spec_file" ] || [ -z "$plan_file" ]; then
    log "Manifest missing source_branch/spec_file/plan_file: $manifest_file"
    return 1
  fi
  local epic_marker="<!-- plan-to-tickets:epic:$plan_file -->"
  local epic_number
  epic_number="$(find_epic_issue_by_marker "$epic_marker")"
  if [ -z "$epic_number" ]; then
    log "No epic issue found with marker $epic_marker. Run plan-to-tickets first."
    return 1
  fi
  PLAN_SLUG="$slug"
  MANIFEST_FILE="$manifest_file"
  SOURCE_BRANCH="$source_branch"
  SPEC_FILE="$spec_file"
  PLAN_FILE="$plan_file"
  EPIC_MARKER="$epic_marker"
  TICKET_MARKER_PREFIX="<!-- plan-to-tickets:ticket:$PLAN_FILE:"
  EPIC_NUMBER="$epic_number"
  vlog "manifest: $MANIFEST_FILE"
  vlog "  source_branch: $SOURCE_BRANCH"
  vlog "  spec_file:     $SPEC_FILE"
  vlog "  plan_file:     $PLAN_FILE"
  vlog "  epic issue:    #$EPIC_NUMBER"
  return 0
}

find_epic_issue_by_marker() {
  # The epic issue carries the plan-to-tickets:epic marker. Search all states
  # (a completed epic may be closed; a human may have re-opened it for rework).
  local marker="$1"
  gh issue list --repo "$REPO" --state all --limit 500 \
    --json number,body 2>/dev/null \
    | jq -r --arg marker "$marker" '.[] | select(.body // "" | contains($marker)) | .number' \
    | head -1
}

# Singleton lock:manager. Acquired at cycle start, released at end. A firing
# that can't acquire it exits cleanly. Stale locks (process killed) are
# force-claimed past --stale-lock-threshold via the timestamp on the
# lock-acquired comment marker.
acquire_lock() {
  # Returns 0 if acquired, 1 otherwise. Does not post a comment on its own --
  # the lock-acquired marker rides along on the next post_progress_comment
  # call instead, so a human reading the thread gets one comment that both
  # confirms the lock and says what the manager is about to do, rather than a
  # bare "lock acquired" with no stated intent.
  gh issue edit "$EPIC_NUMBER" --repo "$REPO" --add-label "$LOCK_LABEL" >/dev/null 2>&1 || return 1
  local labels has_ours
  labels="$(gh issue view "$EPIC_NUMBER" --repo "$REPO" --json labels -q '[.labels[].name]' 2>/dev/null || echo '[]')"
  has_ours="$(jq --arg L "$LOCK_LABEL" 'index($L) != null' <<<"$labels")"
  [ "$has_ours" = "true" ] || return 1
  LOCK_ACQUIRED_AT="$(date -u +%FT%TZ)"
  return 0
}

release_lock() {
  gh issue edit "$EPIC_NUMBER" --repo "$REPO" --remove-label "$LOCK_LABEL" >/dev/null 2>&1 || true
}

detect_stale_lock() {
  # Returns 0 (true) if the held lock is older than STALE_LOCK_THRESHOLD.
  local comments acquired_ts
  comments="$(gh issue view "$EPIC_NUMBER" --repo "$REPO" --json comments -q '.comments' 2>/dev/null || echo '[]')"
  acquired_ts="$(jq -r '[.[] | select(.body // "" | test("<!-- manager:lock-acquired:")) | (.body | capture("<!-- manager:lock-acquired:(?<ts>[^>]+) -->").ts)] | last // ""' <<<"$comments" 2>/dev/null || echo "")"
  [ -n "$acquired_ts" ] || return 1   # no marker -> can't confirm staleness -> don't force-claim
  local now_sec then_sec
  now_sec="$(date -u +%s)"
  then_sec="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$acquired_ts" +%s 2>/dev/null || echo 0)"
  [ "$then_sec" -gt 0 ] || return 1
  [ $((now_sec - then_sec)) -ge "$STALE_LOCK_THRESHOLD" ]
}

run_one_cycle() {
  local labels held
  labels="$(gh issue view "$EPIC_NUMBER" --repo "$REPO" --json labels -q '[.labels[].name]' 2>/dev/null || echo '[]')"
  held="$(jq --arg L "$LOCK_LABEL" 'index($L) != null' <<<"$labels")"
  if [ "$held" = "true" ]; then
    if detect_stale_lock; then
      log "Stale lock:manager detected; force-claiming."
      gh issue edit "$EPIC_NUMBER" --repo "$REPO" --remove-label "$LOCK_LABEL" >/dev/null 2>&1 || true
    else
      log "lock:manager held by another firing; exiting."
      return 1
    fi
  fi
  if [ "$DRY_RUN" = true ]; then
    log "[dry-run] would acquire lock:manager and run a cycle"
    local state; state="$(reconcile_state)"
    vlog "reconciled: ready=$(jq -r '.ready|length' <<<"$state") in_progress=$(jq -r '.in_progress|length' <<<"$state") needs_human=$(jq -r '.needs_human|length' <<<"$state") closed=$(jq -r '.closed|length' <<<"$state")"
    local ready_count in_progress_count
    ready_count="$(jq '.ready | length' <<<"$state")"
    in_progress_count="$(jq '.in_progress | length' <<<"$state")"
    if [ "$ready_count" -gt 0 ] || [ "$in_progress_count" -gt 0 ]; then
      vlog "executors still working; would post progress + exit"
    else
      vlog "backlog drained; would proceed to checklist gate"
      local checklist_path
      checklist_path="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/$CHECKLIST_FILE"
      if [ ! -f "$checklist_path" ]; then
        vlog "checklist: skipped (no file at $checklist_path)"
      else
        vlog "checklist: would run items from $checklist_path"
      fi
    fi
    return 0
  fi
  if ! acquire_lock; then
    log "Failed to acquire lock:manager; exiting."
    return 1
  fi
  local state; state="$(reconcile_state)"
  vlog "reconciled: ready=$(jq -r '.ready|length' <<<"$state") in_progress=$(jq -r '.in_progress|length' <<<"$state") needs_human=$(jq -r '.needs_human|length' <<<"$state") closed=$(jq -r '.closed|length' <<<"$state")"
  local ready_count in_progress_count
  ready_count="$(jq '.ready | length' <<<"$state")"
  in_progress_count="$(jq '.in_progress | length' <<<"$state")"
  local tmpdir; tmpdir="$(mktemp -d)"
  local pr_number=""
  if [ "$ready_count" -gt 0 ] || [ "$in_progress_count" -gt 0 ]; then
    vlog "executors still working (ready=$ready_count in_progress=$in_progress_count); parsing commands + exiting."
    post_progress_comment "$state" "→ executors still working ($ready_count ready, $in_progress_count in progress) — nothing for the manager to do yet, checking back next cycle."
    # Parse commands every cycle so the human gets feedback even mid-execution.
    parse_and_handle_commands "" "$state" "$tmpdir"
    release_lock
    rm -rf "$tmpdir"
    return 0
  fi
  vlog "backlog drained; proceeding to checklist gate."
  post_progress_comment "$state" "→ backlog drained — running the pre-PR checklist, then opening/updating the epic PR and running the final integration review."
  if ! run_checklist "$tmpdir"; then
    release_lock
    rm -rf "$tmpdir"
    return 0   # failure already posted + labeled; not an error exit
  fi
  pr_number="$(open_or_find_epic_pr)" || { log "Failed to open/find epic PR."; release_lock; rm -rf "$tmpdir"; return 1; }
  vlog "epic PR: #$pr_number"
  local review_json="$tmpdir/final-review.json"
  if run_final_review "$pr_number" "$review_json" "$tmpdir"; then
    post_final_review_comment "$pr_number" "$review_json"
  else
    log "Final review failed; posting a note."
    gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body "⚠️ Final integration review failed to run. Review the PR manually: #$pr_number" >/dev/null 2>&1 || true
  fi
  # Parse + handle human commands (idempotent: skip already-processed comment ids).
  HUMAN_ACTED_THIS_CYCLE=false
  parse_and_handle_commands "$pr_number" "$state" "$tmpdir"
  # If the review found anything worth fixing (not just merge-blocking
  # severity -- see AUTO_REWORK_PRIORITY_MAX) and no human command fired this
  # cycle, try to self-heal via an automatic rework round rather than sitting
  # idle waiting for a human to notice, or worse, shipping with known findings
  # still open. Never overrides an explicit human command posted in this same
  # cycle -- that always takes precedence.
  if [ "$HUMAN_ACTED_THIS_CYCLE" != "true" ] && [ -s "$review_json" ]; then
    local auto_rework_count
    auto_rework_count="$(jq --argjson maxp "$AUTO_REWORK_PRIORITY_MAX" '[.findings[]? | select(.priority <= $maxp)] | length' "$review_json" 2>/dev/null || echo 0)"
    [ "$auto_rework_count" -gt 0 ] && maybe_auto_rework "$review_json" "$tmpdir"
  fi
  release_lock
  rm -rf "$tmpdir"
  return 0
}

reconcile_state() {
  # Group all ticket issues carrying this plan's marker by lifecycle state.
  # Prints JSON: {ready:[n], in_progress:[n], needs_human:[n], closed:[n]}
  local raw
  raw="$(gh issue list --repo "$REPO" --state all --limit 500 \
          --json number,title,body,labels,state 2>/dev/null || echo '[]')"
  # `gh issue list --json state` returns "OPEN"/"CLOSED" (uppercase) -- compare
  # case-insensitively so this doesn't silently stop matching on a gh version
  # that changes casing again.
  jq --arg pfx "$TICKET_MARKER_PREFIX" '
    map(select((.body // "") | contains($pfx)) | .state |= ascii_downcase)
    | {
        ready:       [ .[] | select(.state == "open" and ((.labels//[])|map(.name)|any(startswith("lock:"))|not) and ((.labels//[])|map(.name)|index("needs-human")|not)) | .number ],
        in_progress: [ .[] | select(.state == "open" and ((.labels//[])|map(.name)|any(startswith("lock:")))) | .number ],
        needs_human: [ .[] | select(.state == "open" and ((.labels//[])|map(.name)|index("needs-human"))) | .number ],
        closed:      [ .[] | select(.state == "closed") | .number ]
      }
  ' <<<"$raw"
}

# next_action is a plain-language statement of what this cycle is about to do
# (or just did before this posts, for the checklist/PR/review branch -- see
# call site). Combined with the lock-acquired marker so a human reading the
# thread gets one comment that both confirms the lock and says what it's for,
# instead of a bare "lock acquired" with no stated intent.
post_progress_comment() {
  local state="$1" next_action="$2"
  local body_file; body_file="$(mktemp)"
  local ready_count in_progress_count needs_human_count closed_count
  ready_count="$(jq '.ready | length' <<<"$state")"
  in_progress_count="$(jq '.in_progress | length' <<<"$state")"
  needs_human_count="$(jq '.needs_human | length' <<<"$state")"
  closed_count="$(jq '.closed | length' <<<"$state")"
  {
    echo "🔒 lock:manager acquired"
    echo
    echo "### 📊 Plan progress"
    echo
    echo "- **Closed**: $closed_count"
    echo "- **In progress**: $in_progress_count"
    echo "- **Ready (waiting for an executor)**: $ready_count"
    echo "- **Needs human**: $needs_human_count"
    if [ "$in_progress_count" -gt 0 ]; then
      echo
      echo "In progress:"
      worker_names_for_issues "$state" 'in_progress' | sed 's/^/- /'
    fi
    if [ "$needs_human_count" -gt 0 ]; then
      echo
      echo "⚠️ Needs human: $(jq -r '.needs_human | join(", ")' <<<"$state")"
    fi
    if [ -n "$next_action" ]; then
      echo
      echo "$next_action"
    fi
    echo
    echo "<!-- manager:lock-acquired:$LOCK_ACQUIRED_AT -->"
  } > "$body_file"
  gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body-file "$body_file" >/dev/null 2>&1 || true
  rm -f "$body_file"
}

# worker_names_for_issues <state_json> <key> -> prints "#N (alice)" lines
# Reads each issue's lock:<name> label to name the worker.
worker_names_for_issues() {
  local state="$1" key="$2" nums n labels worker
  nums="$(jq -r --arg k "$key" '.[$k][]' <<<"$state")"
  for n in $nums; do
    labels="$(gh issue view "$n" --repo "$REPO" --json labels -q '[.labels[].name]' 2>/dev/null || echo '[]')"
    worker="$(jq -r '.[] | select(startswith("lock:")) | sub("^lock:";"")' <<<"$labels" | head -1)"
    [ -n "$worker" ] && worker=" ($worker)" || worker=""
    echo "#$n$worker"
  done
}

# Helper: shell-quote a value for safe interpolation into a rendered command.
shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# render_cmd <template> <key1> <val1> ... -- replaces every {key} with shell-quoted val.
render_cmd() {
  local tmpl="$1"; shift
  local out="$tmpl" k v
  while [ $# -ge 2 ]; do
    k="$1"; v="$2"; shift 2
    out="${out//\{$k\}/$(shq "$v")}"
  done
  printf '%s' "$out"
}

# Reviewer model is only knowable when using the default reviewer cmd.
reviewer_model() {
  if [ "$REVIEWER_CMD" = "$REVIEWER_CMD_DEFAULT" ]; then
    echo "${CODEX_MODEL:-gpt-5-codex}"
  else
    echo "(set by --reviewer-cmd)"
  fi
}

# run_checklist <tmpdir> -> returns 0 if all pass (or no checklist file), 1 on fail/malformed.
run_checklist() {
  local tmpdir="$1"
  local root checklist_path
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  checklist_path="$root/$CHECKLIST_FILE"
  if [ ! -f "$checklist_path" ]; then
    vlog "checklist: skipped (no file at $checklist_path)"
    return 0
  fi
  if ! yq -e '.pre_pr_checks' "$checklist_path" >/dev/null 2>&1; then
    post_checklist_failure "MALFORMED" "Checklist file $checklist_path is not valid: missing top-level 'pre_pr_checks' array."
    return 1
  fi
  local count name type results_file
  count="$(yq -r '.pre_pr_checks | length' "$checklist_path")"
  results_file="$tmpdir/checklist-results.json"
  echo '[]' > "$results_file"
  local i=0
  while [ "$i" -lt "$count" ]; do
    name="$(yq -r ".pre_pr_checks[$i].name // \"\"" "$checklist_path")"
    type="$(yq -r ".pre_pr_checks[$i].type // \"\"" "$checklist_path")"
    case "$type" in
      run)
        local cmd
        cmd="$(yq -r ".pre_pr_checks[$i].command // \"\"" "$checklist_path")"
        if [ -z "$cmd" ]; then
          post_checklist_failure "MALFORMED" "Checklist item '$name' (type: run) is missing 'command'."
          return 1
        fi
        if ! eval_run_item "$name" "$cmd" "$results_file"; then
          post_checklist_failure "FAIL" "$results_file"
          return 1
        fi
        ;;
      judge)
        local instr
        instr="$(yq -r ".pre_pr_checks[$i].instruction // \"\"" "$checklist_path")"
        if [ -z "$instr" ]; then
          post_checklist_failure "MALFORMED" "Checklist item '$name' (type: judge) is missing 'instruction'."
          return 1
        fi
        if ! eval_judge_item "$name" "$instr" "$results_file" "$tmpdir"; then
          post_checklist_failure "FAIL" "$results_file"
          return 1
        fi
        ;;
      *)
        post_checklist_failure "MALFORMED" "Checklist item '$name' has unknown type '$type' (expected 'run' or 'judge')."
        return 1
        ;;
    esac
    i=$((i + 1))
  done
  vlog "checklist: PASS (all $count items passed)"
  return 0
}

eval_run_item() {
  local name="$1" cmd="$2" results_file="$3"
  local out rc
  out="$(bash -c "$cmd" 2>&1)" && rc=0 || rc=$?
  local tmp_item; tmp_item="$(mktemp)"
  if [ "$rc" -eq 0 ]; then
    jq -n -c --arg n "$name" --argjson passed true --arg cmd "$cmd" \
      '{name:$n, type:"run", passed:$passed, command:$cmd}' > "$tmp_item"
    jq -c --slurpfile item "$tmp_item" '. + $item' "$results_file" > "$results_file.tmp" && mv "$results_file.tmp" "$results_file"
    rm -f "$tmp_item"; return 0
  fi
  jq -n -c --arg n "$name" --argjson passed false --arg cmd "$cmd" --arg out "$out" \
    '{name:$n, type:"run", passed:$passed, command:$cmd, output:$out}' > "$tmp_item"
  jq -c --slurpfile item "$tmp_item" '. + $item' "$results_file" > "$results_file.tmp" && mv "$results_file.tmp" "$results_file"
  rm -f "$tmp_item"; return 1
}

eval_judge_item() {
  local name="$1" instr="$2" results_file="$3" tmpdir="$4"
  local out_json judge_schema prompt_file
  out_json="$tmpdir/judge-$name.json"
  judge_schema="$tmpdir/judge-schema.json"
  printf '%s\n' '{"type":"object","additionalProperties":false,"required":["passed","reasoning","confidence"],"properties":{"passed":{"type":"boolean"},"reasoning":{"type":"string","minLength":1},"confidence":{"type":"number","minimum":0,"maximum":1}}}' > "$judge_schema"
  prompt_file="$tmpdir/judge-prompt.md"
  {
    cat "$SKILL_DIR/references/metadata-guess-prompt.md"
    echo
    echo "## Judgment instruction"
    echo
    echo "$instr"
  } > "$prompt_file"
  local cmd
  cmd="$(render_cmd "$REVIEWER_CMD" \
    final_review_schema "$judge_schema" \
    final_review_output "$out_json" \
    final_review_prompt_composed "$prompt_file")"
  ( bash -c "$cmd" ) || { rm -f "$out_json"; return 1; }
  local passed reasoning
  passed="$(jq -r '.passed // false' "$out_json" 2>/dev/null || echo false)"
  reasoning="$(jq -r '.reasoning // "unknown"' "$out_json" 2>/dev/null || echo unknown)"
  local tmp_item; tmp_item="$(mktemp)"
  if [ "$passed" = "true" ]; then
    jq -n -c --arg n "$name" --argjson passed true --arg instr "$instr" --arg r "$reasoning" \
      '{name:$n, type:"judge", passed:$passed, instruction:$instr, reasoning:$r}' > "$tmp_item"
    jq -c --slurpfile item "$tmp_item" '. + $item' "$results_file" > "$results_file.tmp" && mv "$results_file.tmp" "$results_file"
    rm -f "$tmp_item" "$out_json"; return 0
  fi
  jq -n -c --arg n "$name" --argjson passed false --arg instr "$instr" --arg r "$reasoning" \
    '{name:$n, type:"judge", passed:$passed, instruction:$instr, reasoning:$r}' > "$tmp_item"
  jq -c --slurpfile item "$tmp_item" '. + $item' "$results_file" > "$results_file.tmp" && mv "$results_file.tmp" "$results_file"
  rm -f "$tmp_item" "$out_json"; return 1
}

post_checklist_failure() {
  local kind="$1" detail="$2"
  log "checklist: $kind"
  local body_file; body_file="$(mktemp)"
  {
    echo "### ❌ Checklist $kind"
    echo
    if [ "$kind" = "MALFORMED" ]; then
      echo "$detail"
    else
      echo "The following pre-PR checks failed. Fix them, then remove \`needs-human\` and \`checklist-failed\` to re-run."
      echo
      jq -r '.[] | "- **\(.name)** (\(.type)): " + (if .type == "run" then "command `" + .command + "` failed:\n  " + (.output // "") else "instruction: " + .instruction + "\n  codex reasoning: " + (.reasoning // "") end)' "$detail" 2>/dev/null
    fi
  } > "$body_file"
  gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body-file "$body_file" >/dev/null 2>&1 || true
  gh issue edit "$EPIC_NUMBER" --repo "$REPO" --add-label "needs-human" --add-label "checklist-failed" >/dev/null 2>&1 || true
  rm -f "$body_file"
}

open_or_find_epic_pr() {
  # Idempotent: return the number of an existing open epic PR, or create one.
  local existing
  existing="$(gh pr list --repo "$REPO" --state open --base main --head "$SOURCE_BRANCH" \
              --json number -q '.[0].number' 2>/dev/null || true)"
  # "null" or empty means no existing PR.
  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    vlog "epic PR #$existing already open; reusing."
    printf '%s' "$existing"
    return 0
  fi
  local body_file; body_file="$(mktemp)"
  {
    echo "## Epic: $PLAN_SLUG"
    echo
    echo "This PR collects all ticket work merged into \`$SOURCE_BRANCH\` by execute-tickets."
    echo
    echo "### Reviewer model"
    echo
    echo "\`$(reviewer_model)\` ran the final integration review (see comment below)."
    echo
    echo "### Tickets in this epic"
    echo
    echo "See the epic issue #$EPIC_NUMBER for the full audit trail."
    echo
    echo "Closes #$EPIC_NUMBER"
  } > "$body_file"
  local url
  url="$(gh pr create --repo "$REPO" --base main --head "$SOURCE_BRANCH" \
          --title "Epic: $PLAN_SLUG" --body-file "$body_file" 2>/dev/null)" || return 1
  basename "$url"
  rm -f "$body_file"
}

run_final_review() {
  local pr="$1" review_json="$2" tmpdir="$3"
  local head_sha diff_file prompt_composed
  head_sha="$(gh pr view "$pr" --repo "$REPO" --json headRefOid -q .headRefOid 2>/dev/null || echo "")"
  diff_file="$tmpdir/epic.diff"
  gh pr diff "$pr" --repo "$REPO" > "$diff_file" 2>/dev/null || true
  prompt_composed="$tmpdir/review-prompt.md"
  {
    cat "$FINAL_REVIEW_PROMPT"
    echo
    echo "## Spec file: $SPEC_FILE"
    echo "## Plan file: $PLAN_FILE"
    echo
    echo "## Full epic diff (PR #$pr, head $head_sha)"
    echo
    echo '```diff'
    cat "$diff_file"
    echo '```'
  } > "$prompt_composed"
  local cmd
  cmd="$(render_cmd "$REVIEWER_CMD" \
    final_review_schema "$FINAL_REVIEW_SCHEMA" \
    final_review_output "$review_json" \
    final_review_prompt_composed "$prompt_composed")"
  vlog "reviewer cmd: $cmd"
  ( bash -c "$cmd" ) || return 1
  [ -s "$review_json" ] || return 1
  jq -e . "$review_json" >/dev/null 2>&1 || return 1
  return 0
}

post_final_review_comment() {
  local pr="$1" review_json="$2"
  local verdict conf explanation findings_count blocking_findings blocking_count body_file
  verdict="$(jq -r '.overall_correctness // "unknown"' "$review_json" 2>/dev/null || echo unknown)"
  conf="$(jq -r '.overall_confidence_score // "unknown"' "$review_json" 2>/dev/null || echo unknown)"
  explanation="$(jq -r '.overall_explanation // ""' "$review_json" 2>/dev/null || true)"
  findings_count="$(jq '(.findings // []) | length' "$review_json" 2>/dev/null || echo 0)"
  blocking_findings="$(jq --argjson maxp "$BLOCK_PRIORITY_MAX" '[.findings[] | select(.priority <= $maxp)]' "$review_json" 2>/dev/null || echo '[]')"
  blocking_count="$(jq 'length' <<<"$blocking_findings" 2>/dev/null || echo 0)"
  body_file="$(mktemp)"
  {
    if [ "$blocking_count" -gt 0 ]; then
      echo "### 🛑 review-blocked — final integration review found $blocking_count blocking finding(s)"
    else
      echo "### ✅ Final integration review"
    fi
    echo
    echo "**Verdict**: $verdict (confidence $conf)"
    echo "**Findings**: $findings_count ($blocking_count blocking)"
    echo
    [ -n "$explanation" ] && echo "> $explanation"
    if [ "$findings_count" -gt 0 ]; then
      echo
      jq -r '.findings[] | "- P\(.priority) [conf \(.confidence_score)] **\(.title)** — \(.body)"' "$review_json" 2>/dev/null || true
    fi
    echo
    echo "This review is advisory. Merge with \`ship it\`, file changes with \`rework:\`, or \`abandon\`."
  } > "$body_file"
  gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body-file "$body_file" >/dev/null 2>&1 || true
  gh pr comment "$pr" --repo "$REPO" --body "Final review: $verdict ($findings_count findings, $blocking_count blocking). See epic #$EPIC_NUMBER for detail." >/dev/null 2>&1 || true
  rm -f "$body_file"
}

detect_approval_reset() {
  local pr="$1"
  local current_sha approved_sha comments
  current_sha="$(gh pr view "$pr" --repo "$REPO" --json headRefOid -q .headRefOid 2>/dev/null || echo "")"
  comments="$(gh issue view "$EPIC_NUMBER" --repo "$REPO" --json comments -q '.comments' 2>/dev/null || echo '[]')"
  approved_sha="$(jq -r '[.[] | select(.body // "" | test("<!-- manager:ship-it-approved:")) | (.body | capture("<!-- manager:ship-it-approved:(?<sha>[^>]+) -->").sha)] | last // ""' <<<"$comments" 2>/dev/null || echo "")"
  if [ -n "$approved_sha" ] && [ "$approved_sha" != "$current_sha" ]; then
    gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body "⚠️ diff changed since \`ship it\` (approved $approved_sha, now $current_sha). Please re-review and re-post \`ship it\`." >/dev/null 2>&1 || true
    # Update the marker to the current SHA so the next ship-it can merge.
    gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body "🔁 approval reset — tracking new head $current_sha
<!-- manager:ship-it-approved:$current_sha -->" >/dev/null 2>&1 || true
    return 0  # reset detected
  fi
  return 1  # no reset
}

to_lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }

parse_and_handle_commands() {
  local pr="$1" state="$2" tmpdir="$3"
  local comments
  comments="$(gh issue view "$EPIC_NUMBER" --repo "$REPO" --json comments -q '.comments' 2>/dev/null || echo '[]')"
  [ "$(jq 'length' <<<"$comments" 2>/dev/null || echo 0)" -eq 0 ] && return 0
  # Idempotency: skip comments already processed. Every manager:processed marker
  # only lists the ids that round newly saw -- union ALL such markers ever
  # posted, not just the latest one, or ids from earlier rounds silently
  # reappear as "unprocessed" and get reprocessed (rework comments included,
  # which files a duplicate ticket every cycle).
  local processed
  processed="$(jq -r '
    [.[] | select(.body | test("<!-- manager:processed:")) | (.body | capture("<!-- manager:processed:(?<ids>[0-9,]+) -->").ids)]
    | map(split(",")) | add // []
    | join(",")
  ' <<<"$comments" 2>/dev/null || echo "")"
  local new_ids=""
  while IFS= read -r cmd_obj; do
    local cid body first_line lower
    cid="$(jq -r '(.url // "") | (capture("#issuecomment-(?<n>[0-9]+)") // {n:"0"}).n' <<<"$cmd_obj")"
    # Skip already-processed (processed is comma-joined; compare as space-delimited tokens).
    case " ${processed//,/ } " in *" $cid "*) continue ;; esac
    body="$(jq -r '.body' <<<"$cmd_obj")"
    first_line="$(head -1 <<<"$body" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    lower="$(to_lower "$first_line")"
    new_ids+="$cid,"
    vlog "command from comment #$cid: $first_line"
    case "$lower" in
      ship\ it|shipit|"#shipit"|🚀|lgtm|merge\ it) HUMAN_ACTED_THIS_CYCLE=true; handle_ship_it "$pr" "$state" ;;
      rework*) HUMAN_ACTED_THIS_CYCLE=true; handle_rework "$body" "$tmpdir" ;;
      abandon) HUMAN_ACTED_THIS_CYCLE=true; handle_abandon "$pr" ;;
      *) vlog "  (not a recognized command; ignoring)" ;;
    esac
  done < <(jq -c '.[]' <<<"$comments" 2>/dev/null)
  # "above" would misleadingly imply spatial adjacency in the thread -- this
  # count includes any comment that wasn't yet covered by a prior processed
  # marker, which can include older comments posted by a step that runs after
  # this function in the same cycle (e.g. an auto-rework filing notice), not
  # just the ones immediately preceding this comment.
  [ -n "$new_ids" ] && gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body "✅ caught up on $(tr ',' ' ' <<<"${new_ids%,}" | wc -w | tr -d ' ') previously-unprocessed comment(s) (not necessarily all directly above -- some may be from earlier in the thread, posted by a step that runs after this check)
<!-- manager:processed:${new_ids%,} -->" >/dev/null 2>&1 || true
}

handle_ship_it() {
  local pr="$1" state="$2"
  # Guard 1: no ready tickets, no in-progress tickets.
  local ready_count in_progress_count
  ready_count="$(jq '.ready | length' <<<"$state" 2>/dev/null || echo 0)"
  in_progress_count="$(jq '.in_progress | length' <<<"$state" 2>/dev/null || echo 0)"
  if [ "$ready_count" -gt 0 ] || [ "$in_progress_count" -gt 0 ]; then
    local msg="ship it held: waiting on "
    [ "$ready_count" -gt 0 ] && msg+="ready tickets ($(jq -r '.ready|join(",")' <<<"$state")) "
    [ "$in_progress_count" -gt 0 ] && msg+="in-progress ($(jq -r '.in_progress|join(",")' <<<"$state"))"
    gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body "⚠️ $msg" >/dev/null 2>&1 || true
    return 0
  fi
  # Guard 2: no epic PR yet (backlog drained but PR not opened).
  if [ -z "$pr" ] || [ "$pr" = "null" ]; then
    gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body "⚠️ ship it: epic PR not yet open." >/dev/null 2>&1 || true
    return 0
  fi
  # Re-verify CI green.
  local checks_json failing
  checks_json="$(gh pr view "$pr" --repo "$REPO" --json statusCheckRollup -q '.statusCheckRollup' 2>/dev/null || echo '[]')"
  failing="$(jq '[.[] | select(.conclusion != null and (.conclusion | ascii_upcase) != "SUCCESS" and (.conclusion | ascii_upcase) != "NEUTRAL" and (.conclusion | ascii_upcase) != "SKIPPED")] | length' <<<"$checks_json" 2>/dev/null || echo 0)"
  if [ "$failing" -gt 0 ]; then
    gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body "⚠️ ship it held: $failing CI check(s) failing. Fix and re-post \`ship it\`." >/dev/null 2>&1 || true
    return 0
  fi
  # Approval-reset: if the epic diff changed since the last ship-it approval, don't merge.
  if detect_approval_reset "$pr"; then
    return 0
  fi
  # Record the approved SHA (so a later diff change is detected).
  local cur_sha; cur_sha="$(gh pr view "$pr" --repo "$REPO" --json headRefOid -q .headRefOid 2>/dev/null || echo unknown)"
  gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body "✅ ship it approved at $cur_sha
<!-- manager:ship-it-approved:$cur_sha -->" >/dev/null 2>&1 || true
  # Merge.
  if gh pr merge "$pr" --repo "$REPO" --squash --delete-branch --auto >/dev/null 2>&1 \
     || gh pr merge "$pr" --repo "$REPO" --squash --delete-branch >/dev/null 2>&1; then
    local sha; sha="$(gh pr view "$pr" --repo "$REPO" --json headRefOid -q .headRefOid 2>/dev/null || echo unknown)"
    gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body "🚢 Merged epic PR #$pr ($sha). Epic complete." >/dev/null 2>&1 || true
  else
    gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body "⚠️ ship it: merge failed on PR #$pr. Needs human." >/dev/null 2>&1 || true
    gh issue edit "$EPIC_NUMBER" --repo "$REPO" --add-label "needs-human" >/dev/null 2>&1 || true
  fi
}

# Shared by handle_rework (human-triggered) and maybe_auto_rework (findings-triggered).
# mode is "human" or "auto:<round>/<max>" -- selects title prefix + comment phrasing only.
# The most recent final-review comment on the epic issue, if any -- almost
# always what a rework request (especially a terse human one like "please fix
# those 2 issues") is actually responding to. Feeding it to codex lets the
# expanded ticket body resolve vague references instead of parroting them.
fetch_recent_review_context() {
  gh issue view "$EPIC_NUMBER" --repo "$REPO" --json comments -q '
    [.comments[] | select(.body | test("^### (🛑 review-blocked|✅ Final integration review)"))] | last // {} | .body // ""
  ' 2>/dev/null || echo ""
}

file_rework_ticket() {
  local desc="$1" ref="$2" marker_suffix="$3" tmpdir="$4" mode="$5"
  # Codex expands the request into a self-contained ticket body and picks metadata.
  local meta_json meta_prompt meta_schema cmd review_context
  meta_json="$tmpdir/metadata-$marker_suffix.json"
  meta_prompt="$tmpdir/metadata-prompt-$marker_suffix.md"
  review_context="$(fetch_recent_review_context)"
  {
    cat "$SKILL_DIR/references/metadata-guess-prompt.md"
    echo
    echo "## Rework request (raw, possibly terse/vague)"
    echo
    echo "$desc"
    if [ -n "$review_context" ]; then
      echo
      echo "## Recent context: most recent final integration review comment on the epic"
      echo
      echo "$review_context"
    fi
  } > "$meta_prompt"
  meta_schema="$SKILL_DIR/references/metadata-guess-schema.json"
  cmd="$(render_cmd "$REVIEWER_CMD" \
    final_review_schema "$meta_schema" \
    final_review_output "$meta_json" \
    final_review_prompt_composed "$meta_prompt")"
  ( bash -c "$cmd" ) || true
  local priority complexity model_tier reasoning expanded_description guessed_title
  priority="$(jq -r '.priority // "p1"' "$meta_json" 2>/dev/null || echo p1)"
  complexity="$(jq -r '.complexity // "medium"' "$meta_json" 2>/dev/null || echo medium)"
  model_tier="$(jq -r '.model_tier // "standard"' "$meta_json" 2>/dev/null || echo standard)"
  reasoning="$(jq -r '.reasoning // ""' "$meta_json" 2>/dev/null || echo "")"
  expanded_description="$(jq -r '.expanded_description // ""' "$meta_json" 2>/dev/null || echo "")"
  guessed_title="$(jq -r '.title // ""' "$meta_json" 2>/dev/null || echo "")"
  # gh issue create's --label rejects any label that doesn't already exist in
  # the repo. plan-to-tickets only pre-creates labels its own decomposition
  # actually used, so a codex-picked tier/complexity/priority absent from that
  # set (e.g. model-tier:flagship on a repo whose real tickets never needed
  # it) would otherwise fail issue creation silently. Ensure all three exist
  # first, same color scheme as plan-to-tickets/scripts/create-tickets.sh.
  ensure_rework_label "complexity:$complexity"
  ensure_rework_label "priority:$priority"
  ensure_rework_label "model-tier:$model_tier"
  # File the new ticket. The executor's only view of this ticket is its body --
  # it never sees this comment thread or the review -- so a vague raw request
  # is not enough on its own; expanded_description is what makes it actionable.
  local body_file; body_file="$(mktemp)"
  local marker="<!-- plan-to-tickets:ticket:$PLAN_FILE:$marker_suffix -->"
  local title_prefix="Rework"
  [ "$mode" = "human" ] || title_prefix="Auto-rework"
  # GitHub hard-rejects issue creation past 256 chars and titles can't contain
  # newlines. desc itself is safe for human requests (a short comment line) but
  # can be a multi-paragraph findings dump for auto-rework, so prefer codex's
  # short title and always defensively collapse+truncate whatever's used,
  # regardless of source.
  local title_body="$guessed_title"
  [ -n "$title_body" ] || title_body="$desc"
  title_body="$(tr '\n' ' ' <<<"$title_body" | cut -c1-180)"
  {
    echo "## Rework request (as posted)"
    echo
    echo "$desc"
    if [ -n "$expanded_description" ]; then
      echo
      echo "## What to do"
      echo
      echo "$expanded_description"
    fi
    [ -n "$ref" ] && echo && echo "Refines #$ref"
    [ "$mode" = "human" ] || { echo; echo "_Filed automatically by epic-manager ($mode) from final integration review findings._"; }
    echo
    echo "$marker"
  } > "$body_file"
  local url create_err
  create_err="$(mktemp)"
  url="$(gh issue create --repo "$REPO" \
          --title "$title_prefix: $title_body" \
          --body-file "$body_file" \
          --label "complexity:$complexity" --label "priority:$priority" --label "model-tier:$model_tier" 2>"$create_err")"
  if [ -z "$url" ]; then
    log "file_rework_ticket: gh issue create failed: $(cat "$create_err")"
    local retry_hint="Please retry the \`rework:\` comment."
    [ "$mode" = "human" ] || retry_hint="Will retry next cycle."
    gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body "⚠️ Failed to file a ticket from rework request \"$desc\": \`gh issue create\` errored ($(cat "$create_err" | tr '\n' ' ')). $retry_hint" >/dev/null 2>&1 || true
    rm -f "$body_file" "$create_err"
    return 1
  fi
  rm -f "$create_err"
  local new_n; new_n="$(basename "$url")"
  rm -f "$body_file"
  local filed_note="Filed #$new_n from rework request: $desc"
  [ "$mode" = "human" ] || filed_note="🔁 auto-filed #$new_n ($mode) from final integration review findings"
  gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body "$filed_note

Codex picked: \`priority:$priority\`, \`complexity:$complexity\`, \`model-tier:$model_tier\`.
$reasoning

If this touches security or large refactors, consider \`model-tier:flagship\` / \`complexity:large\`; edit #$new_n's labels to retune before an executor picks it up." >/dev/null 2>&1 || true
  return 0
}

handle_rework() {
  local comment_body="$1" tmpdir="$2"
  # Parse "rework [#N]: <description>"
  local desc ref=""
  if [[ "$comment_body" =~ ^[[:space:]]*rework[[:space:]]+#([0-9]+)[[:space:]]*:[[:space:]]*(.+)$ ]]; then
    ref="${BASH_REMATCH[1]}"
    desc="${BASH_REMATCH[2]}"
  elif [[ "$comment_body" =~ ^[[:space:]]*rework[[:space:]]*:[[:space:]]*(.+)$ ]]; then
    desc="${BASH_REMATCH[1]}"
  else
    return 0
  fi
  file_rework_ticket "$desc" "$ref" "rework-$(date +%s)" "$tmpdir" "human"
}

# Counts prior auto-filed rework tickets for this plan (any state) by marker,
# so the round cap survives across separate --once cron firings.
count_auto_rework_rounds() {
  local raw needle
  raw="$(gh issue list --repo "$REPO" --state all --limit 500 --json body 2>/dev/null || echo '[]')"
  needle="${TICKET_MARKER_PREFIX}auto-rework-"
  jq --arg needle "$needle" '[.[] | select((.body // "") | contains($needle))] | length' <<<"$raw" 2>/dev/null || echo 0
}

synthesize_rework_desc_from_review() {
  local review_json="$1"
  jq -r --argjson maxp "$AUTO_REWORK_PRIORITY_MAX" '
    (.overall_explanation // "") as $expl
    | ([.findings[]? | select(.priority <= $maxp) | "- **\(.title)**: \(.body)"] | join("\n")) as $findings
    | "Final integration review found issues worth fixing before shipping:\n\n" + $findings
      + (if ($expl | length) > 0 then "\n\nOverall assessment: " + $expl else "" end)
  ' "$review_json" 2>/dev/null
}

# Called when the final review finds anything at/below AUTO_REWORK_PRIORITY_MAX
# and no human command fired this cycle. Files an automatic rework ticket from
# the review's own findings, capped at MAX_AUTO_REWORK_ROUNDS total rounds for
# this plan before escalating to a human -- the same "don't retry forever,
# hand off after N" shape execute-tickets already uses for --max-iterations on
# a single ticket. Deliberately broader than the review-blocked/BLOCK_PRIORITY_MAX
# banner threshold: the goal is to reach `ship it` with as few open findings as
# possible, not just to clear the ones severe enough to loudly flag.
maybe_auto_rework() {
  local review_json="$1" tmpdir="$2"
  [ "$MAX_AUTO_REWORK_ROUNDS" -gt 0 ] || return 0
  local round; round="$(count_auto_rework_rounds)"
  if [ "$round" -ge "$MAX_AUTO_REWORK_ROUNDS" ]; then
    gh issue edit "$EPIC_NUMBER" --repo "$REPO" --add-label "needs-human" --add-label "auto-rework-exhausted" >/dev/null 2>&1 || true
    gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body "### 🚧 auto-rework exhausted ($round/$MAX_AUTO_REWORK_ROUNDS rounds)

The final integration review still finds blocking issues after $round automatic rework round(s). Escalating to a human -- review the findings above and either post \`rework: <description>\` yourself, or \`abandon\`." >/dev/null 2>&1 || true
    return 0
  fi
  local desc; desc="$(synthesize_rework_desc_from_review "$review_json")"
  [ -n "$desc" ] || return 0
  file_rework_ticket "$desc" "" "auto-rework-$((round+1))-$(date +%s)" "$tmpdir" "auto:$((round+1))/$MAX_AUTO_REWORK_ROUNDS"
}

handle_abandon() {
  local pr="$1"
  [ -n "$pr" ] && [ "$pr" != "null" ] && gh pr close "$pr" --repo "$REPO" >/dev/null 2>&1 || true
  gh issue close "$EPIC_NUMBER" --repo "$REPO" --reason "not planned" >/dev/null 2>&1 || true
  gh issue comment "$EPIC_NUMBER" --repo "$REPO" --body "🛑 Abandoned per human request. Epic PR and issue closed." >/dev/null 2>&1 || true
}

log() { printf '[%s manager] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
vlog() { [ "$VERBOSE" = true ] || return 0; printf '[%s manager]   %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

main "$@"
