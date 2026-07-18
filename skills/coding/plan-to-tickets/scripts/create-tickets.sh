#!/usr/bin/env bash
# create-tickets.sh: mechanical GitHub creation for plan-to-tickets. No decomposition
# logic here -- takes a ticket-plan JSON (epic + tickets, already ordered so every
# ticket's dependencies precede it) and idempotently files an epic issue plus ticket
# sub-issues on GitHub via `gh`.
set -euo pipefail

INPUT=""; REPO=""; DRY_RUN=false; PREFLIGHT_ONLY=false; PRINT_CONFIG=false
PLAN_JSON=""
EPIC_NUMBER=""; EPIC_ID=""
SLUG_NUMBERS='{}'
SLUG_IDS='{}'

usage() {
  cat <<'EOF'
create-tickets.sh — file a plan-to-tickets backlog on GitHub from a ticket-plan JSON.

Usage: create-tickets.sh --input <ticket-plan.json> [flags]

Flags:
  --input <file>        Ticket-plan JSON (required; see SKILL.md for the schema)
  --repo <owner/repo>   Target repo (default: .repo in the JSON, or current repo)
  --dry-run             Print every planned gh call; apply nothing
  --help                Show this help
EOF
}

main() {
  parse_args "$@"
  if [ "$PRINT_CONFIG" = true ]; then print_config; exit 0; fi
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --input) [ $# -ge 2 ] || { echo "Missing value for --input" >&2; exit 2; }; INPUT="$2"; shift 2 ;;
      --repo) [ $# -ge 2 ] || { echo "Missing value for --repo" >&2; exit 2; }; REPO="$2"; shift 2 ;;
      --dry-run) DRY_RUN=true; shift ;;
      --print-config) PRINT_CONFIG=true; shift ;;
      --help) usage; exit 0 ;;
      *) echo "Unknown flag: $1" >&2; usage >&2; exit 2 ;;
    esac
  done
}

print_config() {
  cat <<EOF
INPUT=$INPUT
REPO=$REPO
DRY_RUN=$DRY_RUN
EOF
}

main "$@"
