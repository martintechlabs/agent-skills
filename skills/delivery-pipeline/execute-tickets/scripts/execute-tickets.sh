#!/usr/bin/env bash
# execute-tickets.sh: pick ready plan-to-tickets issues, drive each through an
# agent -> codex review -> CI verification loop, then merge the PR back to the
# plan's epic branch. Designed to run as up to 10 parallel worker processes per
# repo; per-worker label locks (`lock:alice`..`lock:justin`) make ticket claim atomic.
#
# Each ticket branch is sub-branched from the manifest's source_branch (the
# epic branch). Only priority 0/1 codex findings block merge; priority 2/3
# findings are posted as informational PR comments before merge.
set -euo pipefail

WORKER=""
PLAN_SLUG=""
REPO_WIDE=false   # true when --plan was omitted: discover across every open plan
REPO=""
AGENT_CMD=""   # optional global override; when empty, load agents.yml
AGENT_CMD_LITE=""
AGENT_CMD_EFFICIENT=""
AGENT_CMD_STANDARD=""
AGENT_CMD_FLAGSHIP=""
AGENTS_YML_PATH=""
REVIEWER_CMD_DEFAULT='codex exec --model "${CODEX_MODEL:-gpt-5-codex}" --output-schema {review_schema} -o {review_output} --sandbox read-only - < {review_prompt_composed}'
REVIEWER_CMD=""
REVIEW_SCHEMA=""
REVIEW_PROMPT=""
POLL_SECONDS=30
ONCE=false
DRY_RUN=false
VERBOSE=true
# Worker identity: a fixed, ordered list of names (not numbers) so lock
# labels read as text in a GitHub issue's label list instead of an
# easily-misread single digit next to priority:p3/complexity:small/etc.
# Order only matters for readability -- nothing depends on the list being
# sorted. Extend by editing this array; nothing else needs to change.
WORKER_NAMES=(alice bob carol dave eve frank gordon hank isaac justin)
MAX_ITERATIONS=5
BLOCK_PRIORITY_MAX=1     # findings with priority <= this block merge (0=severe, 1=major)
MIN_CONFIDENCE="0.5"     # findings below this confidence never block
MERGE_METHOD="--squash"
CI_WATCH_TIMEOUT=1800    # seconds; per iteration wait for PR checks to settle

# Runtime state
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST_FILE=""
SOURCE_BRANCH=""
SPEC_FILE=""
PLAN_FILE=""
TICKET_MARKER_PREFIX=""
TICKET_MARKER_GENERIC_PREFIX="<!-- plan-to-tickets:ticket:"
LOCK_LABEL=""

usage() {
  cat <<'EOF'
execute-tickets.sh -- dispatch plan-to-tickets issues through agent + codex review + merge.

Usage:
  execute-tickets.sh --worker <name> --plan <plan-slug> [--agent-cmd <cmd>] [flags]

Required flags:
  --worker <name>       Worker identity (case-insensitive), one of:
                          alice bob carol dave eve frank gordon hank isaac justin
                        Distinct per concurrent process.
  --plan <slug>         Plan slug: basename of docs/superpowers/tickets/<slug>.md.
  --agent-cmd <cmd>     Optional. If set, used for every ticket (overrides agents.yml).
                        If omitted, load <repo>/.execute-tickets/agents.yml (all four
                        model-tier keys required: lite efficient standard flagship).
                        Scaffold with scripts/init-agents.sh. Runs from the ticket
                        worktree. Token substitutions (each shell-quoted):
                          {issue_number} {issue_title} {issue_body}
                          {spec_file} {plan_file}
                          {model_tier} {complexity} {priority}
                          {worktree} {branch}
                          {review_feedback}   -- path to feedback bundle on retries;
                                                 empty string on the first pass.
                          {iteration}         -- 1 on first pass, 2+ on review retries.
                        Agent MUST commit its changes on {branch}. Pushing optional
                        (executor pushes if missing). Agent MUST NOT open a PR.

Optional flags:
  --repo <owner/repo>       Target repo (default: current repo via `gh repo view`).
  --reviewer-cmd <cmd>      Codex review command. Tokens: {review_schema}
                            {review_prompt_composed} {review_output} {pr_number}
                            {branch} {worktree} {head_sha}. Default:
                            'codex exec --model $CODEX_MODEL --output-schema {review_schema}
                             -o {review_output} --sandbox read-only - < {review_prompt_composed}'
  --review-schema <path>    Override review output schema (default: vendored
                            references/codex-review-schema.json).
  --review-prompt <path>    Override reviewer system prompt (default: vendored
                            references/codex-review-prompt.md).
  --block-priority-max <N>  Findings with priority <= N block merge. Default: 1
                            (0 severe + 1 major block; 2 minor + 3 nit inform only).
  --min-confidence <F>      Findings below this confidence are never blocking.
                            Default: 0.5.
  --max-iterations <N>      Max agent+review cycles before needs-human. Default: 5.
  --merge-method <flag>     One of --squash, --rebase, --merge. Default: --squash.
  --ci-timeout <seconds>    Per-iteration wait for PR checks to settle. Default: 1800.
  --poll <seconds>          Sleep between empty polls in loop mode. Default: 30.
  --once                    Pick+run at most one ticket, then exit.
  --dry-run                 Print the selected ticket + composed commands; do not
                            claim/worktree/agent/review/merge.
  --quiet                   Reduce stderr progress logging. Ticket audit comments
                            (model, verdicts, findings, feedback bundles) always post
                            so a human can trace what happened from the issue alone.
  --help                    Show this help.
EOF
}

main() {
  parse_args "$@"
  preflight
  if [ "$REPO_WIDE" != true ]; then
    load_manifest "$PLAN_SLUG" || die 1 "Manifest not found or malformed for plan '$PLAN_SLUG' (run plan-to-tickets first)"
  fi
  # run_one_cycle is called as a bare statement, never as the tested command
  # of an if/&&/||/! -- bash suppresses errexit (and ERR traps) for a
  # command's *entire* call tree in that position, which would silently
  # disable run_ticket's unexpected-error cleanup several frames down. Instead
  # its ordinary (non-error) nonzero returns -- "no ready ticket", "lost the
  # claim race" -- are absorbed with a `set +e`/`set -e` toggle around the
  # call, which does not carry that suppression into the callee.
  if [ "$ONCE" = true ]; then
    set +e
    run_one_cycle
    set -e
    exit 0
  fi
  while true; do
    set +e
    run_one_cycle
    local cycle_rc=$?
    set -e
    if [ "$cycle_rc" -ne 0 ]; then
      sleep "$POLL_SECONDS"
    fi
  done
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --worker) req_val "$@"; WORKER="$2"; shift 2 ;;
      --plan) req_val "$@"; PLAN_SLUG="$2"; shift 2 ;;
      --agent-cmd) req_val "$@"; AGENT_CMD="$2"; shift 2 ;;
      --repo) req_val "$@"; REPO="$2"; shift 2 ;;
      --reviewer-cmd) req_val "$@"; REVIEWER_CMD="$2"; shift 2 ;;
      --review-schema) req_val "$@"; REVIEW_SCHEMA="$2"; shift 2 ;;
      --review-prompt) req_val "$@"; REVIEW_PROMPT="$2"; shift 2 ;;
      --block-priority-max) req_val "$@"; BLOCK_PRIORITY_MAX="$2"; shift 2 ;;
      --min-confidence) req_val "$@"; MIN_CONFIDENCE="$2"; shift 2 ;;
      --max-iterations) req_val "$@"; MAX_ITERATIONS="$2"; shift 2 ;;
      --merge-method) req_val "$@"; MERGE_METHOD="$2"; shift 2 ;;
      --ci-timeout) req_val "$@"; CI_WATCH_TIMEOUT="$2"; shift 2 ;;
      --poll) req_val "$@"; POLL_SECONDS="$2"; shift 2 ;;
      --once) ONCE=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      --quiet) VERBOSE=false; shift ;;
      --help) usage; exit 0 ;;
      *) die 2 "Unknown flag: $1" ;;
    esac
  done
  [ -n "$WORKER" ] || die 2 "Missing --worker <name>. Valid names: ${WORKER_NAMES[*]}"
  WORKER="${WORKER,,}"
  is_valid_worker_name "$WORKER" || die 2 "--worker must be one of: ${WORKER_NAMES[*]} (got: $WORKER)"
  if [ -z "$PLAN_SLUG" ]; then
    REPO_WIDE=true
  fi
  # AGENT_CMD optional: validated in preflight against agents.yml when empty
  case "$MERGE_METHOD" in --squash|--rebase|--merge) ;; *) die 2 "--merge-method must be --squash|--rebase|--merge" ;; esac
  LOCK_LABEL="lock:$WORKER"
  [ -n "$REVIEWER_CMD" ] || REVIEWER_CMD="$REVIEWER_CMD_DEFAULT"
  [ -n "$REVIEW_SCHEMA" ] || REVIEW_SCHEMA="$SKILL_DIR/references/codex-review-schema.json"
  [ -n "$REVIEW_PROMPT" ] || REVIEW_PROMPT="$SKILL_DIR/references/codex-review-prompt.md"
}

req_val() { [ $# -ge 2 ] || die 2 "Missing value for $1"; }
die() { local code="$1"; shift; echo "$*" >&2; exit "$code"; }

is_valid_worker_name() {
  local w="$1" name
  for name in "${WORKER_NAMES[@]}"; do
    [ "$name" = "$w" ] && return 0
  done
  return 1
}

is_valid_model_tier() {
  case "$1" in lite|efficient|standard|flagship) return 0 ;; *) return 1 ;; esac
}

load_agents_yml() {
  local root file
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  file="$root/.execute-tickets/agents.yml"
  AGENTS_YML_PATH="$file"
  [ -f "$file" ] || die 1 "Missing $file (run scripts/init-agents.sh or pass --agent-cmd)"
  command -v yq >/dev/null 2>&1 || die 1 "yq is required to load agents.yml (mikefarah yq v4). Or pass --agent-cmd."
  AGENT_CMD_LITE="$(yq -r '.lite // ""' "$file")"
  AGENT_CMD_EFFICIENT="$(yq -r '.efficient // ""' "$file")"
  AGENT_CMD_STANDARD="$(yq -r '.standard // ""' "$file")"
  AGENT_CMD_FLAGSHIP="$(yq -r '.flagship // ""' "$file")"
  local missing=()
  [ -n "$AGENT_CMD_LITE" ] || missing+=(lite)
  [ -n "$AGENT_CMD_EFFICIENT" ] || missing+=(efficient)
  [ -n "$AGENT_CMD_STANDARD" ] || missing+=(standard)
  [ -n "$AGENT_CMD_FLAGSHIP" ] || missing+=(flagship)
  if [ "${#missing[@]}" -gt 0 ]; then
    die 1 "agents.yml missing or empty keys: ${missing[*]} (file: $file)"
  fi
}

# resolve_agent_cmd <tier> -> command string on stdout
resolve_agent_cmd() {
  local tier="$1"
  if [ -n "$AGENT_CMD" ]; then
    printf '%s' "$AGENT_CMD"
    return 0
  fi
  case "$tier" in
    lite) printf '%s' "$AGENT_CMD_LITE" ;;
    efficient) printf '%s' "$AGENT_CMD_EFFICIENT" ;;
    standard) printf '%s' "$AGENT_CMD_STANDARD" ;;
    flagship) printf '%s' "$AGENT_CMD_FLAGSHIP" ;;
    *) return 1 ;;
  esac
}

agent_source_label() {
  local tier="$1"
  if [ -n "$AGENT_CMD" ]; then
    printf '%s' "--agent-cmd"
  else
    printf 'agents.yml#%s' "$tier"
  fi
}

preflight() {
  command -v gh >/dev/null 2>&1 || die 1 "gh is required."
  command -v jq >/dev/null 2>&1 || die 1 "jq is required."
  command -v git >/dev/null 2>&1 || die 1 "git is required."
  command -v codex >/dev/null 2>&1 || log "WARNING: codex not on PATH; --reviewer-cmd must invoke it explicitly."
  gh auth status >/dev/null 2>&1 || die 1 "gh is not authenticated. Run: gh auth login"
  [ -f "$REVIEW_SCHEMA" ] || die 1 "Review schema not found: $REVIEW_SCHEMA"
  [ -f "$REVIEW_PROMPT" ] || die 1 "Review prompt not found: $REVIEW_PROMPT"
  if [ -z "$REPO" ]; then
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  fi
  [ -n "$REPO" ] || die 1 "Could not determine target repo. Pass --repo."
  if [ -z "$AGENT_CMD" ]; then
    load_agents_yml
  fi
  ensure_lock_labels
}

ensure_lock_labels() {
  local existing name
  existing="$(gh label list --repo "$REPO" --json name -q '.[].name' 2>/dev/null || true)"
  local w
  for w in "${WORKER_NAMES[@]}"; do
    name="lock:$w"
    grep -qxF "$name" <<<"$existing" && continue
    [ "$DRY_RUN" = true ] && continue
    gh label create "$name" --repo "$REPO" --color "cccccc" --force >/dev/null
  done
  if ! grep -qxF "needs-human" <<<"$existing"; then
    [ "$DRY_RUN" = true ] || gh label create "needs-human" --repo "$REPO" \
      --color "d93f0b" --description "Executor gave up; requires human triage" --force >/dev/null
  fi
}

# load_manifest <slug> -- populates MANIFEST_FILE/SOURCE_BRANCH/SPEC_FILE/PLAN_FILE/
# TICKET_MARKER_PREFIX/PLAN_SLUG for <slug>. Returns 1 (never dies) on a missing or
# malformed manifest -- the caller decides whether that's fatal (--plan given) or a
# skip-this-candidate signal (repo-wide mode). Globals are only assigned on full
# success, so a failed call never leaves partial state behind.
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
    key="${line%%:*}"; val="${line#*:}"; val="${val# }"
    val="${val#\"}"; val="${val%\"}"
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
  PLAN_SLUG="$slug"
  MANIFEST_FILE="$manifest_file"
  SOURCE_BRANCH="$source_branch"
  SPEC_FILE="$spec_file"
  PLAN_FILE="$plan_file"
  TICKET_MARKER_PREFIX="<!-- plan-to-tickets:ticket:$PLAN_FILE:"
  vlog "manifest: $MANIFEST_FILE"
  vlog "  source_branch: $SOURCE_BRANCH"
  vlog "  spec_file:     $SPEC_FILE"
  vlog "  plan_file:     $PLAN_FILE"
  vlog "  reviewer model: $(reviewer_model)"
  return 0
}

run_one_cycle() {
  # pick_candidate() now returns a JSON array (Task 3 adds the full
  # skip-and-retry iteration over it for repo-wide mode) -- for now, just take
  # the top-ranked candidate, same as the old single-object contract did.
  local candidates candidate
  candidates="$(pick_candidate)"
  if [ "$(jq 'length' <<<"$candidates")" -eq 0 ]; then
    log "No ready tickets."
    return 1
  fi
  candidate="$(jq -c '.[0]' <<<"$candidates")"
  local n
  n="$(jq -r '.number' <<<"$candidate")"
  log "Candidate: #$n ($(jq -r '.title' <<<"$candidate"))"
  if [ "$DRY_RUN" = true ]; then
    dry_run_report "$candidate"
    return 0
  fi
  if ! claim_ticket "$n"; then
    log "Lost claim race on #$n; will retry."
    return 1
  fi
  # Bare statement + explicit rc capture, not `if run_ticket ...; then` --
  # run_ticket is a subshell with its own ERR trap for unexpected failures,
  # and calling it as an if/&&/||/! test would suppress that trap for its
  # entire execution (see main()'s comment for the underlying bash behavior).
  set +e
  run_ticket "$candidate"
  local ticket_rc=$?
  set -e
  if [ "$ticket_rc" -eq 0 ]; then
    log "Completed #$n."
  else
    log "Failed #$n; marked needs-human."
  fi
  return 0
}

pick_candidate() {
  local pfx
  if [ "$REPO_WIDE" = true ]; then
    pfx="$TICKET_MARKER_GENERIC_PREFIX"
  else
    pfx="$TICKET_MARKER_PREFIX"
  fi
  local raw ready dep_numbers closed_map
  raw="$(gh issue list --repo "$REPO" --state open --limit 200 \
          --json number,title,body,labels,assignees 2>/dev/null || echo '[]')"
  ready="$(jq --arg pfx "$pfx" '
    map(select(
      (.body // "" | contains($pfx))
      and ((.labels // []) | map(.name) | any(startswith("lock:")) | not)
      and ((.labels // []) | map(.name) | index("needs-human") | not)
      and ((.assignees // []) | length == 0)
    ))
  ' <<<"$raw")"
  [ "$(jq 'length' <<<"$ready")" -gt 0 ] || { echo '[]'; return 0; }

  dep_numbers="$(jq -r '
    .[] | (.body // "")
    | capture("Depends on: (?<line>[^\\n]+)"; "g").line // empty
  ' <<<"$ready" | tr ',' '\n' | grep -oE '#[0-9]+' | tr -d '#' | sort -u)"

  closed_map="{}"
  if [ -n "$dep_numbers" ]; then
    local all_open n state
    all_open="$(gh issue list --repo "$REPO" --state open --limit 500 \
                  --json number -q '[.[].number]' 2>/dev/null || echo '[]')"
    for n in $dep_numbers; do
      if jq -e --argjson n "$n" 'index($n)' <<<"$all_open" >/dev/null; then
        state="open"
      else
        state="closed"
      fi
      closed_map="$(jq --argjson n "$n" --arg s "$state" '. + {($n|tostring): $s}' <<<"$closed_map")"
    done
  fi

  jq --argjson deps "$closed_map" '
    map(
      . as $t
      | (($t.body // "")
          | [scan("Depends on: ([^\n]+)")]
          | (if length == 0 then [] else .[0][0] | split(",") | map(gsub("[^0-9]"; "")) | map(select(length>0)) end)
        ) as $deplist
      | . + {
          ready: ($deplist | all(. as $n | ($deps[$n] // "closed") == "closed")),
          _priority: (
            (.labels // []) | map(.name)
            | (if index("priority:p1") then 1
              elif index("priority:p2") then 2
              elif index("priority:p3") then 3
              else 4 end)
          ),
          _complexity: (
            (.labels // []) | map(.name)
            | (if index("complexity:small") then 1
              elif index("complexity:medium") then 2
              else 3 end)
          )
        }
    )
    | map(select(.ready))
    | sort_by(._priority, ._complexity, .number)
  ' <<<"$ready"
}

claim_ticket() {
  local n="$1" labels ours others
  gh issue edit "$n" --repo "$REPO" --add-label "$LOCK_LABEL" >/dev/null 2>&1 \
    || { log "gh edit failed on #$n"; return 1; }
  labels="$(gh issue view "$n" --repo "$REPO" --json labels -q '[.labels[].name]' 2>/dev/null || echo '[]')"
  ours="$(jq --arg L "$LOCK_LABEL" 'index($L) != null' <<<"$labels")"
  others="$(jq --arg L "$LOCK_LABEL" 'map(select(startswith("lock:") and . != $L)) | length' <<<"$labels")"
  if [ "$ours" != "true" ] || [ "$others" != "0" ]; then
    gh issue edit "$n" --repo "$REPO" --remove-label "$LOCK_LABEL" >/dev/null 2>&1 || true
    return 1
  fi
  gh issue edit "$n" --repo "$REPO" --add-assignee "@me" >/dev/null 2>&1 || true
  return 0
}

release_ticket() {
  gh issue edit "$1" --repo "$REPO" --remove-label "$LOCK_LABEL" >/dev/null 2>&1 || true
}

close_ticket_issue() {
  gh issue close "$1" --repo "$REPO" >/dev/null 2>&1 || true
}

flag_needs_human() {
  local n="$1" reason="$2" attach="${3:-}"
  gh issue edit "$n" --repo "$REPO" --add-label "needs-human" \
    --remove-label "$LOCK_LABEL" >/dev/null 2>&1 || true
  if [ -n "$attach" ] && [ -f "$attach" ]; then
    gh issue comment "$n" --repo "$REPO" --body-file "$attach" >/dev/null 2>&1 || true
    gh issue comment "$n" --repo "$REPO" \
      --body "Executor (worker $WORKER) gave up: $reason" >/dev/null 2>&1 || true
  else
    gh issue comment "$n" --repo "$REPO" \
      --body "Executor (worker $WORKER) gave up: $reason" >/dev/null 2>&1 || true
  fi
}

# Full per-ticket loop: worktree -> agent -> PR -> (CI + codex) -> [re-agent] -> merge.
# A subshell (parens, not braces): its ERR trap below only needs to guarantee
# THIS ticket's cleanup runs and THIS ticket ends in needs-human -- it must
# not be able to kill the whole worker process out from under the other
# tickets it still has to process. Requires the call site to invoke this as a
# bare statement (see run_one_cycle) -- calling it as an if/&&/||/! test
# would suppress -e/the trap for its entire execution regardless of this
# subshell.
run_ticket() (
  # -E (errtrace): without it, the ERR trap below only fires for commands
  # written directly in this function's own body, not for failures inside the
  # helpers it calls (build_feedback_bundle, run_reviewer, etc.) -- which is
  # most of what actually runs here.
  set -Ee
  local candidate="$1"
  local n title body_file slug branch worktree root tier complexity priority
  n="$(jq -r '.number' <<<"$candidate")"
  title="$(jq -r '.title' <<<"$candidate")"
  slug="$(slug_from_title "$title")"
  branch="ticket/${n}-${slug}"
  root="$(git rev-parse --show-toplevel)"
  worktree="$(dirname "$root")/wt-$(basename "$root")-w${WORKER}-i${n}"

  tier="$(label_value "$candidate" model-tier)"
  complexity="$(label_value "$candidate" complexity)"
  priority="$(label_value "$candidate" priority)"

  vlog "ticket #$n: $title"
  vlog "  agent model_tier=$tier  complexity=$complexity  priority=$priority"
  vlog "  agent source: $(agent_source_label "$tier" 2>/dev/null || echo invalid-tier)"
  vlog "  reviewer model: $(reviewer_model)"
  vlog "  worktree: $worktree"
  vlog "  branch:   $branch"

  if ! is_valid_model_tier "$tier"; then
    flag_needs_human "$n" "missing or invalid model-tier label (got: ${tier:-empty}); expected lite|efficient|standard|flagship" ""
    return 1
  fi

  body_file="$(mktemp)"
  jq -r '.body' <<<"$candidate" > "$body_file"

  # Cleanup on any unexpected exit inside this ticket.
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'flag_needs_human "'"$n"'" "unexpected error in run_ticket" ""; \
        git worktree remove --force "'"$worktree"'" 2>/dev/null || true; \
        rm -rf "'"$tmpdir"'" "'"$body_file"'"' ERR

  # Fetch fresh per ticket, not once per process: sibling tickets merge into
  # source_branch as this worker (and others) complete them, so a fetch done
  # only at process startup would go stale after the very first ticket and
  # every later worktree would branch from a snapshot that predates its
  # siblings' merged work.
  git fetch origin "$SOURCE_BRANCH" >/dev/null 2>&1 || log "Warning: could not fetch origin/$SOURCE_BRANCH"

  # Sub-branch from source_branch (freshly fetched above). Force to origin
  # state so workers pick up sibling tickets already merged into the epic branch.
  git worktree add --detach "$worktree" "origin/$SOURCE_BRANCH" >/dev/null 2>&1 \
    || { flag_needs_human "$n" "worktree add failed" ""; cleanup_ticket_state "$worktree" "$body_file" "$tmpdir"; return 1; }
  git -C "$worktree" switch -c "$branch" >/dev/null 2>&1 \
    || { flag_needs_human "$n" "branch create failed" ""; cleanup_ticket_state "$worktree" "$body_file" "$tmpdir"; return 1; }

  # First agent pass: no review feedback yet.
  local review_feedback=""
  local iteration=1
  if ! invoke_agent "$n" "$title" "$body_file" "$tier" "$complexity" "$priority" \
                    "$worktree" "$branch" "$review_feedback" "$iteration"; then
    flag_needs_human "$n" "agent failed on iteration $iteration" ""
    cleanup_ticket_state "$worktree" "$body_file" "$tmpdir"
    return 1
  fi

  if ! ensure_branch_pushed "$worktree" "$branch"; then
    flag_needs_human "$n" "no commits pushed to origin/$branch" ""
    cleanup_ticket_state "$worktree" "$body_file" "$tmpdir"
    return 1
  fi

  # Open PR targeting the epic (source_branch). Closes the issue on merge.
  local pr_number
  if ! pr_number="$(open_pr "$n" "$title" "$branch")"; then
    flag_needs_human "$n" "gh pr create failed" ""
    cleanup_ticket_state "$worktree" "$body_file" "$tmpdir"
    return 1
  fi
  log "PR #$pr_number opened for ticket #$n"

  # Review + fix loop.
  local feedback_file="$tmpdir/feedback.md"
  local review_json="$tmpdir/review.json"
  local ci_json="$tmpdir/ci.json"

  while :; do
    log "Iteration $iteration: waiting for CI on PR #$pr_number..."
    wait_for_ci "$pr_number" "$ci_json" "$CI_WATCH_TIMEOUT" || true

    log "Iteration $iteration: running codex review on PR #$pr_number..."
    if ! run_reviewer "$pr_number" "$branch" "$worktree" "$review_json" "$body_file" "$tmpdir"; then
      flag_needs_human "$n" "reviewer command failed" ""
      cleanup_ticket_state "$worktree" "$body_file" "$tmpdir"
      return 1
    fi

    # Build the feedback bundle. Empty = green light.
    build_feedback_bundle "$review_json" "$ci_json" "$feedback_file"

    if [ ! -s "$feedback_file" ]; then
      # Post informational (P2/P3) findings as PR comments before merging, if any.
      post_informational_findings "$pr_number" "$review_json"
      audit_comment "$n" "$iteration" "$pr_number" green "$review_json" "$ci_json" "" "$tier"
      log "Iteration $iteration: green. Merging PR #$pr_number ($MERGE_METHOD)."
      if ! merge_pr "$pr_number"; then
        flag_needs_human "$n" "merge failed after clean review" ""
        cleanup_ticket_state "$worktree" "$body_file" "$tmpdir"
        return 1
      fi
      # The PR targets the epic branch, not the repo's default branch, so
      # GitHub ignores "Closes #n" entirely (closing keywords only take effect
      # against the default branch) -- close the ticket issue explicitly so
      # dependents relying on "Depends on: #n" -> closed can unblock.
      close_ticket_issue "$n"
      release_ticket "$n"
      cleanup_ticket_state "$worktree" "$body_file" "$tmpdir"
      return 0
    fi

    if [ "$iteration" -ge "$MAX_ITERATIONS" ]; then
      audit_comment "$n" "$iteration" "$pr_number" exhausted "$review_json" "$ci_json" "$feedback_file" "$tier"
      log "Iteration $iteration: max iterations reached; needs-human."
      flag_needs_human "$n" "review loop exhausted after $iteration iterations" ""
      cleanup_ticket_state "$worktree" "$body_file" "$tmpdir"
      return 1
    fi

    audit_comment "$n" "$iteration" "$pr_number" blocking "$review_json" "$ci_json" "$feedback_file" "$tier"
    iteration=$((iteration + 1))
    log "Iteration $iteration: feeding blocking findings back to agent."
    if ! invoke_agent "$n" "$title" "$body_file" "$tier" "$complexity" "$priority" \
                      "$worktree" "$branch" "$feedback_file" "$iteration"; then
      flag_needs_human "$n" "agent failed on iteration $iteration" ""
      cleanup_ticket_state "$worktree" "$body_file" "$tmpdir"
      return 1
    fi
    if ! ensure_branch_pushed "$worktree" "$branch"; then
      flag_needs_human "$n" "no new commits pushed on iteration $iteration" ""
      cleanup_ticket_state "$worktree" "$body_file" "$tmpdir"
      return 1
    fi
    # Loop back: re-wait CI, re-review, re-decide.
  done
)

cleanup_ticket_state() {
  local worktree="$1" body_file="$2" tmpdir="$3"
  git worktree remove --force "$worktree" 2>/dev/null || true
  rm -f "$body_file"
  rm -rf "$tmpdir"
  trap - ERR
}

invoke_agent() {
  local n="$1" title="$2" body_file="$3" tier="$4" complexity="$5" priority="$6"
  local worktree="$7" branch="$8" review_feedback="$9" iteration="${10}"
  local tmpl cmd
  tmpl="$(resolve_agent_cmd "$tier")" || return 1
  cmd="$(render_cmd "$tmpl" \
    issue_number "$n" \
    issue_title "$title" \
    issue_body "$body_file" \
    spec_file "$SPEC_FILE" \
    plan_file "$PLAN_FILE" \
    model_tier "$tier" \
    complexity "$complexity" \
    priority "$priority" \
    worktree "$worktree" \
    branch "$branch" \
    review_feedback "$review_feedback" \
    iteration "$iteration")"
  log "Agent (iter $iteration) for #$n via $(agent_source_label "$tier"): cd $worktree"
  vlog "agent cmd: $cmd"
  ( cd "$worktree" && bash -c "$cmd" )
}

open_pr() {
  local n="$1" title="$2" branch="$3"
  local pr_body
  # NOT "Closes #n": this PR targets the epic branch, not the repo's default
  # branch, so GitHub ignores closing keywords here. The executor closes the
  # ticket issue explicitly on merge (see close_ticket_issue).
  pr_body=$'Ticket: #'"$n"$'\n\nOpened by execute-tickets.sh (worker '"$WORKER"$').'
  local url
  url="$(gh pr create --repo "$REPO" --base "$SOURCE_BRANCH" --head "$branch" \
          --title "$title" --body "$pr_body" 2>/dev/null)" || return 1
  basename "$url"
}

ensure_branch_pushed() {
  local worktree="$1" branch="$2"
  # Prefer whatever the agent already pushed; otherwise push on its behalf.
  # Propagate the real push exit status either way -- swallowing a failed
  # push here would let the caller believe new commits reached origin when
  # they didn't, silently re-reviewing/merging a stale PR head.
  if git -C "$worktree" rev-parse --verify --quiet "origin/$branch" >/dev/null 2>&1; then
    # Also push any newer local commits (agent may have committed after last push).
    git -C "$worktree" push origin "$branch" >/dev/null 2>&1
    return $?
  fi
  git -C "$worktree" push -u origin "$branch" >/dev/null 2>&1
}

wait_for_ci() {
  local pr="$1" out="$2" timeout="$3"
  # gh pr checks --watch blocks until checks settle; timeout it and then re-read state.
  timeout "$timeout" gh pr checks "$pr" --repo "$REPO" --watch >/dev/null 2>&1 || true
  gh pr view "$pr" --repo "$REPO" --json statusCheckRollup > "$out" 2>/dev/null || echo '{}' > "$out"
  vlog_ci "$out"
}

# Run the reviewer. Composes prompt = vendored prompt + PR context, then invokes
# --reviewer-cmd with tokens. Writes JSON to $review_json.
run_reviewer() {
  local pr="$1" branch="$2" worktree="$3" review_json="$4" body_file="$5" tmpdir="$6"
  local head_sha diff_file prompt_composed pr_body ticket_body
  head_sha="$(gh pr view "$pr" --repo "$REPO" --json headRefOid -q .headRefOid 2>/dev/null || echo "")"
  diff_file="$tmpdir/pr.diff"
  gh pr diff "$pr" --repo "$REPO" > "$diff_file" 2>/dev/null || true

  prompt_composed="$tmpdir/review-prompt.md"
  {
    cat "$REVIEW_PROMPT"
    echo
    echo "## Ticket"
    echo
    cat "$body_file"
    echo
    echo "## Plan file: $PLAN_FILE"
    echo "## Spec file: $SPEC_FILE"
    echo
    echo "## Diff to review (PR #$pr, head $head_sha)"
    echo
    echo '```diff'
    cat "$diff_file"
    echo '```'
  } > "$prompt_composed"

  local cmd
  cmd="$(render_cmd "$REVIEWER_CMD" \
    review_schema "$REVIEW_SCHEMA" \
    review_prompt_composed "$prompt_composed" \
    review_output "$review_json" \
    pr_number "$pr" \
    branch "$branch" \
    worktree "$worktree" \
    head_sha "$head_sha")"
  vlog "reviewer cmd: $cmd"
  ( cd "$worktree" && bash -c "$cmd" ) || return 1
  [ -s "$review_json" ] || { log "Reviewer produced no output at $review_json"; return 1; }
  jq -e . "$review_json" >/dev/null 2>&1 || { log "Reviewer output is not valid JSON"; return 1; }
  vlog_review_summary "$review_json"
  return 0
}

# Populate $out with the actionable feedback bundle. Empty file = merge is clean.
build_feedback_bundle() {
  local review_json="$1" ci_json="$2" out="$3"
  : > "$out"

  # 1) Blocking codex findings (priority <= BLOCK_PRIORITY_MAX AND confidence >= MIN_CONFIDENCE).
  local blocking overall_bad
  blocking="$(jq --argjson maxp "$BLOCK_PRIORITY_MAX" --argjson minc "$MIN_CONFIDENCE" '
    [(.findings // [])[]
     | select(.priority <= $maxp and .confidence_score >= $minc)]
  ' "$review_json")"
  overall_bad="$(jq -r '.overall_correctness // "" | . == "patch is incorrect"' "$review_json")"

  # 2) Failing CI checks (anything not SUCCESS/NEUTRAL/SKIPPED/PENDING).
  local failing_checks
  failing_checks="$(jq -r '
    (.statusCheckRollup // [])
    | map(select((.conclusion // .status // "") as $s
                 | ($s | ascii_upcase) as $S
                 | ($S != "SUCCESS" and $S != "NEUTRAL" and $S != "SKIPPED" and $S != "PENDING" and $S != "IN_PROGRESS" and $S != "QUEUED" and $S != "")))
    | map("- " + (.name // .context // "check") + " -> " + ((.conclusion // .status // "unknown") | ascii_downcase)
          + (if .detailsUrl then " (" + .detailsUrl + ")" else "" end))
    | .[]
  ' "$ci_json")"

  local num_blocking
  num_blocking="$(jq 'length' <<<"$blocking")"

  if [ "$num_blocking" = "0" ] && [ -z "$failing_checks" ] && [ "$overall_bad" != "true" ]; then
    vlog "decision: GREEN — merging (no blocking findings, no failing CI, overall correct)"
    return 0  # empty file -> clean
  fi
  vlog "decision: BLOCKING — blocking_findings=$num_blocking, failing_ci=$([ -n "$failing_checks" ] && echo yes || echo no), overall_incorrect=$overall_bad"

  {
    echo "# Review feedback"
    echo
    if [ "$overall_bad" = "true" ]; then
      echo "## Overall verdict: patch is incorrect"
      echo
      jq -r '.overall_explanation // ""' "$review_json"
      echo
    fi
    if [ "$num_blocking" -gt 0 ]; then
      echo "## Blocking findings (priority <= $BLOCK_PRIORITY_MAX, confidence >= $MIN_CONFIDENCE)"
      echo
      jq -r '.[] | "### P\(.priority) [\(.confidence_score)] \(.title)\n\n\(.body)\n\nLocation: `\(.code_location.absolute_file_path)`:\(.code_location.line_range.start)-\(.code_location.line_range.end)\n"' <<<"$blocking"
    fi
    if [ -n "$failing_checks" ]; then
      echo "## Failing CI checks"
      echo
      printf '%s\n' "$failing_checks"
      echo
      echo "Fix these so the PR checks turn green."
    fi
  } > "$out"
  vlog "feedback bundle (fed to agent on next iteration):"
  while IFS= read -r line; do vlog "  $line"; done < "$out"
}

# Post informational (P2/P3, or low-confidence) findings as PR comments before merge.
post_informational_findings() {
  local pr="$1" review_json="$2"
  local informational
  informational="$(jq --argjson maxp "$BLOCK_PRIORITY_MAX" --argjson minc "$MIN_CONFIDENCE" '
    [(.findings // [])[]
     | select(.priority > $maxp or .confidence_score < $minc)]
  ' "$review_json")"
  local count
  count="$(jq 'length' <<<"$informational")"
  [ "$count" -gt 0 ] || return 0
  local body
  body="$(jq -r '
    "Codex review — informational findings (non-blocking):\n\n" +
    (map("- P\(.priority) [\(.confidence_score)] **\(.title)** — \(.body) (`\(.code_location.absolute_file_path)`:\(.code_location.line_range.start)-\(.code_location.line_range.end))") | join("\n"))
  ' <<<"$informational")"
  gh pr comment "$pr" --repo "$REPO" --body "$body" >/dev/null 2>&1 || true
}

# Post an audit comment to the TICKET ISSUE (not the PR) so a human can trace
# what happened from the issue thread alone -- without worker logs, which are
# ephemeral, and without the PR, which is merged + deleted. One comment per
# iteration carries the reviewer model, the verdict, every finding, the CI
# state, the GREEN/BLOCKING/EXHAUSTED decision, and -- on blocking iterations
# -- the full feedback bundle that was fed to the agent, collapsed so the
# thread stays scannable. Always fires, regardless of --quiet: the audit trail
# on the ticket is the durable record this executor exists to produce.
audit_comment() {
  local n="$1" iteration="$2" pr="$3" decision="$4"
  local review_json="$5" ci_json="$6" feedback_file="${7:-}" tier="${8:-}"

  local verdict conf explanation findings_count findings_list
  verdict="$(jq -r '.overall_correctness // "unknown"' "$review_json" 2>/dev/null || echo unknown)"
  conf="$(jq -r '.overall_confidence_score // "unknown"' "$review_json" 2>/dev/null || echo unknown)"
  explanation="$(jq -r '.overall_explanation // ""' "$review_json" 2>/dev/null || true)"
  findings_count="$(jq '(.findings // []) | length' "$review_json" 2>/dev/null || echo 0)"
  case "$findings_count" in ''|*[!0-9]*) findings_count=0 ;; esac
  findings_list="$(jq -r '(.findings // [])[] | "- P\(.priority) [conf \(.confidence_score)] \(.title) — \(.code_location.absolute_file_path):\(.code_location.line_range.start)-\(.code_location.line_range.end)"' "$review_json" 2>/dev/null || true)"

  local ci_count ci_summary
  ci_count="$(jq '(.statusCheckRollup // []) | length' "$ci_json" 2>/dev/null || echo 0)"
  case "$ci_count" in ''|*[!0-9]*) ci_count=0 ;; esac
  if [ "$ci_count" -eq 0 ]; then
    ci_summary="no checks configured"
  else
    ci_summary="$(jq -r '(.statusCheckRollup // []) | map(.name + " -> " + ((.conclusion // .status // "unknown") | ascii_downcase)) | join(", ")' "$ci_json" 2>/dev/null || echo unknown)"
  fi

  local emoji
  case "$decision" in
    green)     emoji="✅" ;;
    blocking)  emoji="🔴" ;;
    exhausted) emoji="🛑" ;;
    *)         emoji="ℹ️" ;;
  esac

  local body_file
  body_file="$(mktemp)"
  {
    printf '### %s Iteration %s\n\n' "$emoji" "$iteration"
    printf '**Agent**: %s · model_tier=%s · PR #%s\n' "$(agent_source_label "$tier")" "$tier" "$pr"
    printf '**Reviewer**: %s\n' "$(reviewer_model)"
    printf '**Verdict**: %s (confidence %s)\n' "$verdict" "$conf"
    printf '**Findings**: %s\n' "$findings_count"
    [ -n "$findings_list" ] && printf '%s\n' "$findings_list"
    printf '**CI**: %s\n' "$ci_summary"
    printf '**Decision**: %s %s\n' "$emoji" "$decision"
    [ -n "$explanation" ] && printf '\n> %s\n' "$explanation"
    if [ -n "$feedback_file" ] && [ -s "$feedback_file" ]; then
      printf '\n<details><summary>Feedback bundle (fed to agent on next iteration)</summary>\n\n'
      cat "$feedback_file"
      printf '\n</details>\n'
    fi
  } > "$body_file"
  gh issue comment "$n" --repo "$REPO" --body-file "$body_file" >/dev/null 2>&1 || true
  rm -f "$body_file"
}

merge_pr() {
  local pr="$1"
  vlog "merging PR #$pr ($MERGE_METHOD)"
  # First attempt: auto-merge with the configured strategy, delete the ticket branch.
  if gh pr merge "$pr" --repo "$REPO" "$MERGE_METHOD" --delete-branch --auto >/dev/null 2>&1; then
    return 0
  fi
  # Second attempt: try synchronous merge (no --auto) in case auto-merge isn't enabled.
  if gh pr merge "$pr" --repo "$REPO" "$MERGE_METHOD" --delete-branch >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# render_cmd <template> <key1> <val1> <key2> <val2> ...
# Replaces every {key} in the template with the shell-quoted value.
render_cmd() {
  local tmpl="$1"; shift
  local out="$tmpl" k v
  while [ $# -ge 2 ]; do
    k="$1"; v="$2"; shift 2
    out="${out//\{$k\}/$(shq "$v")}"
  done
  printf '%s' "$out"
}

shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

label_value() {
  local candidate="$1" prefix="$2"
  jq -r --arg p "$prefix:" '.labels[].name | select(startswith($p)) | sub("^" + $p; "")' \
    <<<"$candidate" | head -n1
}

slug_from_title() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-40
}

dry_run_report() {
  local candidate="$1" n title tier complexity priority worktree branch root
  n="$(jq -r '.number' <<<"$candidate")"
  title="$(jq -r '.title' <<<"$candidate")"
  tier="$(label_value "$candidate" model-tier)"
  complexity="$(label_value "$candidate" complexity)"
  priority="$(label_value "$candidate" priority)"
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  worktree="$(dirname "$root")/wt-$(basename "$root")-w${WORKER}-i${n}"
  branch="ticket/${n}-$(slug_from_title "$title")"

  local agent_tmpl agent_cmd reviewer_cmd src
  if ! is_valid_model_tier "$tier"; then
    agent_tmpl="<invalid model-tier: ${tier:-empty}>"
    src="invalid-tier"
  else
    agent_tmpl="$(resolve_agent_cmd "$tier")"
    src="$(agent_source_label "$tier")"
  fi
  agent_cmd="$(render_cmd "$agent_tmpl" \
    issue_number "$n" issue_title "$title" issue_body "<tmpfile>" \
    spec_file "$SPEC_FILE" plan_file "$PLAN_FILE" \
    model_tier "$tier" complexity "$complexity" priority "$priority" \
    worktree "$worktree" branch "$branch" \
    review_feedback "" iteration "1")"
  reviewer_cmd="$(render_cmd "$REVIEWER_CMD" \
    review_schema "$REVIEW_SCHEMA" \
    review_prompt_composed "<tmpfile>" \
    review_output "<tmpfile>" \
    pr_number "<pr>" branch "$branch" worktree "$worktree" head_sha "<sha>")"

  cat <<EOF >&2
DRY RUN (worker $WORKER):
  repo:              $REPO
  plan:              $PLAN_SLUG
  source_branch:     $SOURCE_BRANCH (epic; ticket branch will sub-branch from origin/$SOURCE_BRANCH)
  ticket:            #$n  $title
  labels:            complexity=$complexity priority=$priority tier=$tier
  worktree:          $worktree
  branch:            $branch
  merge method:      $MERGE_METHOD
  block priority <=: $BLOCK_PRIORITY_MAX  (min confidence: $MIN_CONFIDENCE)
  max iterations:    $MAX_ITERATIONS
  review schema:     $REVIEW_SCHEMA
  review prompt:     $REVIEW_PROMPT
  agent source:      $src
  agent cmd:         $agent_cmd
  reviewer cmd:      $reviewer_cmd
  reviewer model:    $(reviewer_model)
EOF
}

log() {
  printf '[%s worker=%s] %s\n' "$(date -u +%FT%TZ)" "$WORKER" "$*" >&2
}

# vlog: verbose line (suppressed by --quiet). Carries the back-and-forth a user needs
# to follow what the executor is actually doing: model in use, rendered agent/reviewer
# commands, review verdicts + findings, feedback bundles, CI states, merge attempts.
vlog() {
  [ "$VERBOSE" = true ] || return 0
  printf '[%s worker=%s]   %s\n' "$(date -u +%FT%TZ)" "$WORKER" "$*" >&2
}

# Reviewer model is only knowable when using the default reviewer cmd (which embeds
# ${CODEX_MODEL:-gpt-5-codex}). A custom --reviewer-cmd owns its own model choice.
reviewer_model() {
  if [ "$REVIEWER_CMD" = "$REVIEWER_CMD_DEFAULT" ]; then
    echo "${CODEX_MODEL:-gpt-5-codex}"
  else
    echo "(set by --reviewer-cmd)"
  fi
}

vlog_review_summary() {
  local r="$1" n
  vlog "review verdict: $(jq -r '.overall_correctness' "$r") (confidence $(jq -r '.overall_confidence_score' "$r"))"
  vlog "  explanation: $(jq -r '.overall_explanation' "$r")"
  n="$(jq '(.findings // []) | length' "$r" 2>/dev/null || echo 0)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  vlog "  findings ($n):"
  if [ "$n" -gt 0 ]; then
    jq -r '.findings[] | "    P\(.priority) [conf \(.confidence_score)] \(.title) — \(.code_location.absolute_file_path):\(.code_location.line_range.start)-\(.code_location.line_range.end)"' "$r" \
      | while IFS= read -r line; do vlog "$line"; done
  fi
}

vlog_ci() {
  local c="$1" n
  n="$(jq '(.statusCheckRollup // []) | length' "$c" 2>/dev/null || echo 0)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" -eq 0 ]; then
    vlog "ci: no checks configured on repo"
    return
  fi
  vlog "ci checks ($n):"
  jq -r '(.statusCheckRollup // [])[] | "    \(.name // .context // "check") -> \((.conclusion // .status // "unknown") | ascii_downcase)"' "$c" 2>/dev/null \
    | while IFS= read -r line; do vlog "$line"; done
}

main "$@"
