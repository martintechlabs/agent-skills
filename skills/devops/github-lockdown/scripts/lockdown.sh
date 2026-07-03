#!/usr/bin/env bash
# github-lockdown: protect a repo's default branch behind a required PR via a
# GitHub repository ruleset, and auto-delete merged branches. Idempotent.
set -euo pipefail

# ---- defaults (secure) ----
REPO=""; BRANCH=""; APPROVALS=0; ADMIN_BYPASS=false
THREAD_RES=false; LINEAR=false; SIGNED=false; CODE_OWNER=false; DISMISS_STALE=false
STATUS_CHECKS=""; AUTO_DELETE=true; NAME="github-lockdown"; DRY_RUN=false
PRINT_CONFIG=false
PREFLIGHT_ONLY=false

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
  preflight
  if [ "$PREFLIGHT_ONLY" = true ]; then exit 0; fi

  local body id
  body="$(build_ruleset_json)"
  id="$(find_ruleset_id)"
  if [ "$DRY_RUN" = true ]; then printf '%s\n' "$body"; fi
  apply_ruleset "$body" "$id"
  apply_auto_delete
  if [ "$DRY_RUN" != true ]; then verify; fi
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) [ $# -ge 2 ] || { echo "Missing value for --repo" >&2; exit 2; }; REPO="$2"; shift 2 ;;
      --branch) [ $# -ge 2 ] || { echo "Missing value for --branch" >&2; exit 2; }; BRANCH="$2"; shift 2 ;;
      --approvals)
        [ $# -ge 2 ] || { echo "Missing value for --approvals" >&2; exit 2; }
        case "$2" in ''|*[!0-9]*) echo "--approvals must be a non-negative integer" >&2; exit 2 ;; esac
        APPROVALS="$2"; shift 2 ;;
      --admin-bypass) ADMIN_BYPASS=true; shift ;;
      --require-conversation-resolution) THREAD_RES=true; shift ;;
      --linear-history) LINEAR=true; shift ;;
      --signed-commits) SIGNED=true; shift ;;
      --require-code-owner-review) CODE_OWNER=true; shift ;;
      --dismiss-stale-approvals) DISMISS_STALE=true; shift ;;
      --status-checks) [ $# -ge 2 ] || { echo "Missing value for --status-checks" >&2; exit 2; }; STATUS_CHECKS="$2"; shift 2 ;;
      --no-auto-delete) AUTO_DELETE=false; shift ;;
      --ruleset-name) [ $# -ge 2 ] || { echo "Missing value for --ruleset-name" >&2; exit 2; }; NAME="$2"; shift 2 ;;
      --dry-run) DRY_RUN=true; shift ;;
      --print-config) PRINT_CONFIG=true; shift ;;
      --preflight-only) PREFLIGHT_ONLY=true; shift ;;
      --help) usage; exit 0 ;;
      *) echo "Unknown flag: $1" >&2; usage >&2; exit 2 ;;
    esac
  done
}

preflight() {
  command -v jq >/dev/null 2>&1 || { echo "jq is required. Install jq and retry." >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "Not authenticated. Run: gh auth login" >&2; exit 1; }
  resolve_repo
  local perm
  perm="$(gh repo view "$REPO" --json viewerPermission -q .viewerPermission 2>/dev/null || true)"
  if [ "$perm" != "ADMIN" ]; then
    echo "You need admin permission on $REPO to change rulesets (have: ${perm:-unknown})." >&2
    echo "Ask an org/repo admin to run this, or grant yourself the admin role." >&2
    exit 1
  fi
}

resolve_repo() {
  if [ -z "$REPO" ]; then
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  fi
  [ -n "$REPO" ] || { echo "Could not determine repo. Pass --repo <owner/repo>." >&2; exit 1; }
}

ref_includes() {
  if [ -n "$BRANCH" ]; then
    jq -n --arg b "refs/heads/$BRANCH" '[$b]'
  else
    jq -n '["~DEFAULT_BRANCH"]'
  fi
}

build_ruleset_json() {
  local rules
  rules="$(jq -n \
    --argjson approvals "$APPROVALS" \
    --argjson dismiss "$DISMISS_STALE" \
    --argjson codeowner "$CODE_OWNER" \
    --argjson threadres "$THREAD_RES" \
    '[
      {type:"pull_request", parameters:{
        required_approving_review_count:$approvals,
        dismiss_stale_reviews_on_push:$dismiss,
        require_code_owner_review:$codeowner,
        require_last_push_approval:false,
        required_review_thread_resolution:$threadres
      }},
      {type:"non_fast_forward"},
      {type:"deletion"}
    ]')"

  [ "$LINEAR" = true ] && rules="$(jq '. + [{type:"required_linear_history"}]' <<<"$rules")"
  [ "$SIGNED" = true ] && rules="$(jq '. + [{type:"required_signatures"}]' <<<"$rules")"

  if [ -n "$STATUS_CHECKS" ]; then
    local checks
    checks="$(printf '%s' "$STATUS_CHECKS" | jq -R 'split(",") | map({context: (. | gsub("^\\s+|\\s+$";""))})')"
    rules="$(jq --argjson c "$checks" \
      '. + [{type:"required_status_checks", parameters:{
          required_status_checks:$c,
          strict_required_status_checks_policy:false,
          do_not_enforce_on_create:false }}]' <<<"$rules")"
  fi

  local bypass="[]"
  # RepositoryRole id 5 == the built-in "admin" repo role.
  [ "$ADMIN_BYPASS" = true ] && bypass='[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]'

  jq -n \
    --arg name "$NAME" \
    --argjson refs "$(ref_includes)" \
    --argjson rules "$rules" \
    --argjson bypass "$bypass" \
    '{
      name: $name,
      target: "branch",
      enforcement: "active",
      bypass_actors: $bypass,
      conditions: { ref_name: { include: $refs, exclude: [] } },
      rules: $rules
    }'
}

find_ruleset_id() {
  local out
  if ! out="$(gh api "repos/$REPO/rulesets" --paginate 2>&1)"; then
    echo "Failed to list rulesets for $REPO." >&2
    echo "$out" >&2
    echo "Check that the repo exists and your token can manage rulesets." >&2
    exit 1
  fi
  printf '%s' "$out" | jq -r --arg n "$NAME" 'if type=="array" then . else [.] end | map(select(.name==$n)) | (.[0].id // empty)'
}

apply_ruleset() {
  local body="$1" id="$2"
  if [ "$DRY_RUN" = true ]; then
    if [ -n "$id" ]; then
      echo "PLAN UPDATE ruleset id=$id via PUT repos/$REPO/rulesets/$id" >&2
    else
      echo "PLAN CREATE ruleset name=$NAME via POST repos/$REPO/rulesets" >&2
    fi
    return 0
  fi
  if [ -n "$id" ]; then
    printf '%s' "$body" | gh api -X PUT "repos/$REPO/rulesets/$id" --input - >/dev/null
  else
    printf '%s' "$body" | gh api -X POST "repos/$REPO/rulesets" --input - >/dev/null
  fi
}

apply_auto_delete() {
  [ "$AUTO_DELETE" = true ] || return 0
  if [ "$DRY_RUN" = true ]; then
    echo "PLAN SET repos/$REPO delete_branch_on_merge=true" >&2
    return 0
  fi
  gh api -X PATCH "repos/$REPO" -F delete_branch_on_merge=true >/dev/null
}

verify() {
  local approvals="$APPROVALS" target="default branch"
  [ -n "$BRANCH" ] && target="$BRANCH"
  echo "Locked down $REPO ($target): required PR, $approvals approver(s), force-push + deletion blocked."
  [ "$AUTO_DELETE" = true ] && echo "  Auto-delete merged branches: on."
  [ "$ADMIN_BYPASS" = true ] && echo "  Admin bypass: enabled."
  return 0
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
