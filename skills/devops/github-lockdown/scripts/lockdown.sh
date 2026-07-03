#!/usr/bin/env bash
# github-lockdown: protect a repo's default branch behind a required PR via a
# GitHub repository ruleset, and auto-delete merged branches. Idempotent.
set -euo pipefail

# ---- defaults (secure) ----
REPO=""; BRANCH=""; APPROVALS=0; ADMIN_BYPASS=false
THREAD_RES=false; LINEAR=false; SIGNED=false; CODE_OWNER=false; DISMISS_STALE=false
STATUS_CHECKS=""; AUTO_DELETE=true; NAME="github-lockdown"; DRY_RUN=false
PRINT_CONFIG=false

usage() {
  cat <<'EOF'
lockdown.sh — lock down a GitHub repo's default branch (repository rulesets).

Usage: lockdown.sh [flags]

Flags:
  --repo <owner/repo>            Target repo (default: current repo)
  --branch <name>                Branch to protect (default: repo default branch)
  --approvals N                  Required approving reviews (default: 0)
  --admin-bypass                 Let repo admins bypass the ruleset (default: off)
  --require-conversation-resolution
  --linear-history
  --signed-commits
  --require-code-owner-review
  --dismiss-stale-approvals
  --status-checks "ci,build"     Comma-separated required status check contexts
  --no-auto-delete               Do not enable delete-branch-on-merge
  --ruleset-name <name>          Ruleset name (default: github-lockdown)
  --dry-run                      Print planned changes; apply nothing
  --help                         Show this help
EOF
}

main() {
  parse_args "$@"
  if [ "$PRINT_CONFIG" = true ]; then print_config; exit 0; fi
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) REPO="$2"; shift 2 ;;
      --branch) BRANCH="$2"; shift 2 ;;
      --approvals) APPROVALS="$2"; shift 2 ;;
      --admin-bypass) ADMIN_BYPASS=true; shift ;;
      --require-conversation-resolution) THREAD_RES=true; shift ;;
      --linear-history) LINEAR=true; shift ;;
      --signed-commits) SIGNED=true; shift ;;
      --require-code-owner-review) CODE_OWNER=true; shift ;;
      --dismiss-stale-approvals) DISMISS_STALE=true; shift ;;
      --status-checks) STATUS_CHECKS="$2"; shift 2 ;;
      --no-auto-delete) AUTO_DELETE=false; shift ;;
      --ruleset-name) NAME="$2"; shift 2 ;;
      --dry-run) DRY_RUN=true; shift ;;
      --print-config) PRINT_CONFIG=true; shift ;;
      --help) usage; exit 0 ;;
      *) echo "Unknown flag: $1" >&2; usage >&2; exit 2 ;;
    esac
  done
}

print_config() {
  cat <<EOF
REPO=$REPO
BRANCH=$BRANCH
APPROVALS=$APPROVALS
ADMIN_BYPASS=$ADMIN_BYPASS
THREAD_RES=$THREAD_RES
LINEAR=$LINEAR
SIGNED=$SIGNED
CODE_OWNER=$CODE_OWNER
DISMISS_STALE=$DISMISS_STALE
STATUS_CHECKS=$STATUS_CHECKS
AUTO_DELETE=$AUTO_DELETE
NAME=$NAME
DRY_RUN=$DRY_RUN
EOF
}

main "$@"
