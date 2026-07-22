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
  if [ "$ONCE" = true ]; then
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

preflight() { :; }
load_manifest() { :; }
run_one_cycle() { :; }

log() { printf '[%s manager] %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
vlog() { [ "$VERBOSE" = true ] || return 0; printf '[%s manager]   %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }

main "$@"
