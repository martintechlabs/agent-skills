#!/usr/bin/env bash
# epic-manager.sh: singleton plan-level supervisor for a plan-to-tickets epic.
# Tracks executor progress, gates the epic->main PR behind a per-project hybrid
# checklist, runs a final integration review, and obeys human commands (ship it
# / rework: / abandon) posted as comments on the epic issue. Peer to
# execute-tickets.sh; communicates through GitHub state only.
set -euo pipefail

PLAN_SLUG=""
REPO=""
CHECKLIST_FILE=""
REVIEWER_CMD_DEFAULT='codex exec --model "${CODEX_MODEL:-gpt-5-codex}" --output-schema {final_review_schema} -o {final_review_output} --sandbox read-only - < {final_review_prompt_composed}'
REVIEWER_CMD=""
FINAL_REVIEW_SCHEMA=""
FINAL_REVIEW_PROMPT=""
BLOCK_PRIORITY_MAX=1
POLL_SECONDS=300
STALE_LOCK_THRESHOLD=3600
ONCE=false
DRY_RUN=false
VERBOSE=true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK_LABEL="lock:manager"
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
  --block-priority-max <N>     Findings at/ below this priority flagged as blocking. Default: 1.
  --poll <seconds>             Sleep between cycles in loop mode. Default: 300.
  --stale-lock-threshold <sec> Force-claim lock:manager after this staleness. Default: 3600.
  --once                       Run one cycle, then exit (cron mode).
  --dry-run                    Print reconciled state + intended actions; mutate nothing.
  --quiet                      Reduce stderr logging. Epic-issue audit comments always post.
  --help                       Show this help.

Human commands (posted as comments on the epic issue, first line = trigger):
  ship it / #shipit / 🚀 / lgtm / merge it   -> merge the epic PR (guards + CI re-verify)
  rework [#N]: <description>                  -> file a new ticket; codex picks metadata
  abandon                                     -> close epic PR + close epic issue (not planned)
EOF
}

main() {
  parse_args "$@"
  preflight
  load_manifest
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
      --poll) req_val "$@"; POLL_SECONDS="$2"; shift 2 ;;
      --stale-lock-threshold) req_val "$@"; STALE_LOCK_THRESHOLD="$2"; shift 2 ;;
      --once) ONCE=true; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      --quiet) VERBOSE=false; shift ;;
      --help) usage; exit 0 ;;
      *) die 2 "Unknown flag: $1" ;;
    esac
  done
  [ -n "$PLAN_SLUG" ] || die 2 "Missing --plan <slug>"
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
  grep -qxF "lock:manager" <<<"$existing" && return 0
  grep -qxF "needs-human" <<<"$existing" && return 0
  [ "$DRY_RUN" = true ] && return 0
  grep -qxF "lock:manager" <<<"$existing" || \
    gh label create "lock:manager" --repo "$REPO" --color "5319e7" --force >/dev/null 2>&1 || true
  grep -qxF "needs-human" <<<"$existing" || \
    gh label create "needs-human" --repo "$REPO" --color "d93f0b" --force >/dev/null 2>&1 || true
}

load_manifest() {
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  MANIFEST_FILE="$root/docs/superpowers/tickets/$PLAN_SLUG.md"
  [ -f "$MANIFEST_FILE" ] || die 1 "Manifest not found: $MANIFEST_FILE (run plan-to-tickets first)"
  local in_fm=false key val line
  while IFS= read -r line; do
    if [ "$line" = "---" ]; then
      if [ "$in_fm" = false ]; then in_fm=true; continue; else break; fi
    fi
    [ "$in_fm" = true ] || continue
    key="${line%%:*}"; val="${line#*:}"; val="${val# }"; val="${val#\"}"; val="${val%\"}"
    case "$key" in
      source_branch) SOURCE_BRANCH="$val" ;;
      spec_file) SPEC_FILE="$val" ;;
      plan_file) PLAN_FILE="$val" ;;
    esac
  done < "$MANIFEST_FILE"
  [ -n "$SOURCE_BRANCH" ] || die 1 "Manifest missing source_branch: $MANIFEST_FILE"
  [ -n "$SPEC_FILE" ] || die 1 "Manifest missing spec_file: $MANIFEST_FILE"
  [ -n "$PLAN_FILE" ] || die 1 "Manifest missing plan_file: $MANIFEST_FILE"
  EPIC_MARKER="<!-- plan-to-tickets:epic:$PLAN_FILE -->"
  TICKET_MARKER_PREFIX="<!-- plan-to-tickets:ticket:$PLAN_FILE:"
  EPIC_NUMBER="$(find_epic_issue)"
  [ -n "$EPIC_NUMBER" ] || die 1 "No epic issue found with marker $EPIC_MARKER. Run plan-to-tickets first."
  vlog "manifest: $MANIFEST_FILE"
  vlog "  source_branch: $SOURCE_BRANCH"
  vlog "  spec_file:     $SPEC_FILE"
  vlog "  plan_file:     $PLAN_FILE"
  vlog "  epic issue:    #$EPIC_NUMBER"
}

find_epic_issue() {
  # The epic issue carries the plan-to-tickets:epic marker. Search all states
  # (a completed epic may be closed; a human may have re-opened it for rework).
  gh issue list --repo "$REPO" --state all --limit 500 \
    --json number,body 2>/dev/null \
    | jq -r --arg marker "$EPIC_MARKER" '.[] | select(.body // "" | contains($marker)) | .number' \
    | head -1
}

# Singleton lock:manager. Acquired at cycle start, released at end. A firing
# that can't acquire it exits cleanly. Stale locks (process killed) are
# force-claimed past --stale-lock-threshold via the timestamp on the
# lock-acquired comment marker.
acquire_lock() {
  # Returns 0 if acquired, 1 otherwise.
  gh issue edit "$EPIC_NUMBER" --repo "$REPO" --add-label "$LOCK_LABEL" >/dev/null 2>&1 || return 1
  local labels has_ours
  labels="$(gh issue view "$EPIC_NUMBER" --repo "$REPO" --json labels -q '[.labels[].name]' 2>/dev/null || echo '[]')"
  has_ours="$(jq --arg L "$LOCK_LABEL" 'index($L) != null' <<<"$labels")"
  [ "$has_ours" = "true" ] || return 1
  # Record when we acquired, for stale detection by a later firing.
  gh issue comment "$EPIC_NUMBER" --repo "$REPO" \
    --body "<!-- manager:lock-acquired:$(date -u +%FT%TZ) -->" >/dev/null 2>&1 || true
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
    return 0
  fi
  if ! acquire_lock; then
    log "Failed to acquire lock:manager; exiting."
    return 1
  fi
  # Body implemented in later tasks (reconcile, checklist, epic PR, commands).
  release_lock
  return 0
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

log() { printf '[%s manager] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
vlog() { [ "$VERBOSE" = true ] || return 0; printf '[%s manager]   %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

main "$@"
