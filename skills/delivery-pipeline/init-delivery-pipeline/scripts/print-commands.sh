#!/usr/bin/env bash
# print-commands.sh — render the ready-to-paste execute-tickets worker loop and the
# epic-manager singleton command for a given plan/repo/worker-count. Pure templating:
# no gh/codex calls, no file writes, no network.
set -euo pipefail

WORKER_NAMES=(alice bob carol dave eve frank gordon hank isaac justin)
PLAN=""
REPO=""
WORKERS=10

usage() {
  cat <<'EOF'
print-commands.sh — print the execute-tickets worker loop and the epic-manager
singleton command, ready to paste into cron or Warp.

Usage:
  print-commands.sh --plan <slug> --repo <owner/repo> [--workers <N>]

Flags:
  --plan <slug>        Plan slug (required).
  --repo <owner/repo>  Target repo (required).
  --workers <N>        Number of execute-tickets workers, 1-10 (default: 10).
  --help                Show this help.
EOF
}

die() { local code="$1"; shift; echo "$*" >&2; exit "$code"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --plan) [ $# -ge 2 ] || die 2 "Missing value for --plan"; PLAN="$2"; shift 2 ;;
    --repo) [ $# -ge 2 ] || die 2 "Missing value for --repo"; REPO="$2"; shift 2 ;;
    --workers) [ $# -ge 2 ] || die 2 "Missing value for --workers"; WORKERS="$2"; shift 2 ;;
    --help) usage; exit 0 ;;
    *) die 2 "Unknown flag: $1" ;;
  esac
done

[ -n "$PLAN" ] || die 2 "Missing --plan <slug>"
[ -n "$REPO" ] || die 2 "Missing --repo <owner/repo>"

case "$WORKERS" in
  ''|*[!0-9]*) die 2 "--workers must be a number between 1 and 10 (got: $WORKERS)" ;;
esac
[ "$WORKERS" -ge 1 ] && [ "$WORKERS" -le 10 ] || die 2 "--workers must be between 1 and 10 (got: $WORKERS)"

SELECTED=("${WORKER_NAMES[@]:0:$WORKERS}")

echo "# execute-tickets: launch $WORKERS worker(s)"
echo "for W in ${SELECTED[*]}; do"
echo "  skills/delivery-pipeline/execute-tickets/scripts/execute-tickets.sh \\"
echo "    --worker \"\$W\" --plan $PLAN --repo $REPO \\"
echo "    > \"logs/executor-\${W}.log\" 2>&1 &"
echo "done"
echo "wait"
echo
echo "# epic-manager: singleton, run --once per cron firing"
echo "skills/delivery-pipeline/epic-manager/scripts/epic-manager.sh \\"
echo "  --plan $PLAN --repo $REPO --once"
echo
echo "# Wiring either into Warp specifically, see:"
echo "#   execute-tickets/references/warp-setup.md"
echo "#   epic-manager/references/warp-setup.md"
