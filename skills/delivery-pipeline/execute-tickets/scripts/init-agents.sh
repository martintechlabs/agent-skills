#!/usr/bin/env bash
# init-agents.sh — scaffold .execute-tickets/agents.yml from the skill's Claude defaults.
# Independent of execute-tickets.sh; never called by the executor.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$SKILL_DIR/references/agents.example.yml"
REPO_ROOT=""
FORCE=false
DRY_RUN=false

usage() {
  cat <<'EOF'
init-agents.sh — write .execute-tickets/agents.yml with Claude-default agent commands.

Usage:
  init-agents.sh [--repo-root <path>] [--force] [--dry-run]

Flags:
  --repo-root <path>  Target repo root (default: git rev-parse --show-toplevel, else cwd)
  --force             Overwrite an existing agents.yml
  --dry-run           Print the template to stdout; write nothing
  --help              Show this help

Does not create, read, or modify .execute-tickets/checklist.yml.
EOF
}

die() { local code="$1"; shift; echo "$*" >&2; exit "$code"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root) [ $# -ge 2 ] || die 2 "Missing value for $1"; REPO_ROOT="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help) usage; exit 0 ;;
    *) die 2 "Unknown flag: $1" ;;
  esac
done

[ -f "$TEMPLATE" ] || die 1 "Template not found: $TEMPLATE"

if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
OUT_DIR="$REPO_ROOT/.execute-tickets"
OUT_FILE="$OUT_DIR/agents.yml"

if [ "$DRY_RUN" = true ]; then
  cat "$TEMPLATE"
  exit 0
fi

if [ -f "$OUT_FILE" ] && [ "$FORCE" != true ]; then
  die 1 "Refusing to overwrite existing $OUT_FILE (pass --force, or --dry-run to preview)"
fi

mkdir -p "$OUT_DIR"
cp "$TEMPLATE" "$OUT_FILE"
echo "Wrote $OUT_FILE"
echo "Edit model flags for your org, then run execute-tickets workers without --agent-cmd."
