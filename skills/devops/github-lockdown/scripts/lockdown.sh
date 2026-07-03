#!/usr/bin/env bash
# github-lockdown: protect a repo's default branch behind a required PR via a
# GitHub repository ruleset, and auto-delete merged branches. Idempotent.
set -euo pipefail

# ---- defaults (secure) ----
REPO=""; BRANCH=""; APPROVALS=0; ADMIN_BYPASS=false
THREAD_RES=false; LINEAR=false; SIGNED=false; CODE_OWNER=false; DISMISS_STALE=false
STATUS_CHECKS=""; AUTO_DELETE=true; NAME="github-lockdown"; DRY_RUN=false

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
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --help) usage; exit 0 ;;
      *) shift ;;   # extended in later tasks
    esac
  done
}

main "$@"
