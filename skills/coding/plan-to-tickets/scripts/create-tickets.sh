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
  preflight
  if [ "$PREFLIGHT_ONLY" = true ]; then exit 0; fi
  load_plan
  ensure_labels
  file_epic
  file_tickets
  if [ "$DRY_RUN" != true ]; then write_manifest; fi
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --input) [ $# -ge 2 ] || { echo "Missing value for --input" >&2; exit 2; }; INPUT="$2"; shift 2 ;;
      --repo) [ $# -ge 2 ] || { echo "Missing value for --repo" >&2; exit 2; }; REPO="$2"; shift 2 ;;
      --dry-run) DRY_RUN=true; shift ;;
      --print-config) PRINT_CONFIG=true; shift ;;
      --preflight-only) PREFLIGHT_ONLY=true; shift ;;
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

preflight() {
  command -v jq >/dev/null 2>&1 || { echo "jq is required. Install jq and retry." >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "Not authenticated. Run: gh auth login" >&2; exit 1; }
  if [ "$PREFLIGHT_ONLY" = true ]; then return 0; fi
  [ -n "$INPUT" ] || { echo "Missing --input <ticket-plan.json>." >&2; exit 2; }
  [ -f "$INPUT" ] || { echo "No such file: $INPUT" >&2; exit 1; }
  jq -e . "$INPUT" >/dev/null 2>&1 || { echo "$INPUT is not valid JSON." >&2; exit 1; }
}

load_plan() {
  PLAN_JSON="$(cat "$INPUT")"
  validate_metadata
  if [ -z "$REPO" ]; then
    REPO="$(jq -r '.repo // empty' <<<"$PLAN_JSON")"
  fi
  if [ -z "$REPO" ]; then
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  fi
  [ -n "$REPO" ] || { echo "Could not determine target repo. Pass --repo or set .repo in the ticket-plan JSON." >&2; exit 1; }
  validate_dependency_order
}

validate_metadata() {
  local field
  for field in source_branch spec_file plan_file; do
    if ! jq -e --arg field "$field" \
      '.[$field] | if type == "string" then length > 0 else false end' \
      <<<"$PLAN_JSON" >/dev/null; then
      echo "Invalid ticket-plan JSON: .$field must be a non-empty string." >&2
      exit 1
    fi
  done
}

validate_dependency_order() {
  local bad
  bad="$(jq -r '
    [.tickets[].slug] as $slugs
    | [ range(0; (.tickets | length)) as $i
        | (.tickets[$i].depends_on_slugs // [])[] as $dep
        | select( ($slugs[0:$i] | index($dep)) == null )
        | "\(.tickets[$i].slug) depends on unknown/forward slug \($dep)"
      ]
    | .[]
  ' <<<"$PLAN_JSON")"
  if [ -n "$bad" ]; then
    echo "Invalid ticket-plan JSON: every depends_on_slugs entry must name an earlier ticket's slug." >&2
    printf '%s\n' "$bad" >&2
    exit 1
  fi
}

label_color() {
  case "$1" in
    epic) echo "5319e7" ;;
    complexity:small) echo "0e8a16" ;;
    complexity:medium) echo "fbca04" ;;
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

required_labels() {
  jq -r '["epic"] + [.tickets[].labels[]] | unique | .[]' <<<"$PLAN_JSON"
}

existing_labels() {
  gh label list --repo "$REPO" --json name -q '.[].name' 2>/dev/null || true
}

ensure_labels() {
  local existing name color
  existing="$(existing_labels)"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if grep -qxF "$name" <<<"$existing"; then continue; fi
    color="$(label_color "$name")"
    if [ "$DRY_RUN" = true ]; then
      echo "PLAN CREATE LABEL $name (color #$color)" >&2
      continue
    fi
    gh label create "$name" --repo "$REPO" --color "$color" --force >/dev/null
  done < <(required_labels)
}

find_issue_by_marker() {
  local marker="$1"
  gh issue list --repo "$REPO" --state all --json number,id,body --limit 200 2>/dev/null \
    | jq -r --arg m "$marker" '
        map(select(.body // "" | contains($m))) as $found
        | if ($found | length) == 0 then empty else "\($found[0].number)\t\($found[0].id)" end
      '
}

record_slug() {
  local slug="$1" num="$2" id="$3"
  SLUG_NUMBERS="$(jq --arg s "$slug" --arg n "$num" '. + {($s): $n}' <<<"$SLUG_NUMBERS")"
  SLUG_IDS="$(jq --arg s "$slug" --arg i "$id" '. + {($s): $i}' <<<"$SLUG_IDS")"
}

slug_number() { jq -r --arg s "$1" '.[$s] // empty' <<<"$SLUG_NUMBERS"; }

file_epic() {
  local plan_file title body marker found num id
  plan_file="$(jq -r '.plan_file' <<<"$PLAN_JSON")"
  marker="<!-- plan-to-tickets:epic:$plan_file -->"
  title="$(jq -r '.epic.title' <<<"$PLAN_JSON")"
  body="$(jq -r '.epic.body' <<<"$PLAN_JSON")"$'\n\n'"$marker"

  found="$(find_issue_by_marker "$marker")"
  if [ -n "$found" ]; then
    num="$(cut -f1 <<<"$found")"; id="$(cut -f2 <<<"$found")"
    if [ "$DRY_RUN" = true ]; then
      echo "PLAN UPDATE epic issue #$num" >&2
    else
      gh issue edit "$num" --repo "$REPO" --title "$title" --body "$body" >/dev/null
    fi
  else
    if [ "$DRY_RUN" = true ]; then
      echo "PLAN CREATE epic issue \"$title\"" >&2
      num=""; id=""
    else
      local url
      url="$(gh issue create --repo "$REPO" --title "$title" --body "$body" --label epic)"
      num="$(basename "$url")"
      id="$(gh issue view "$num" --repo "$REPO" --json id -q .id)"
    fi
  fi
  EPIC_NUMBER="$num"; EPIC_ID="$id"
  record_slug "epic" "$EPIC_NUMBER" "$EPIC_ID"
}

# resolved_deps <ticket-index>: "#101, #102" (resolved issue numbers) or "" if none.
resolved_deps() {
  local i="$1" dep deps out first n
  deps="$(jq -r ".tickets[$i].depends_on_slugs[]?" <<<"$PLAN_JSON")"
  [ -n "$deps" ] || { printf ''; return 0; }
  out=""
  first=true
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    n="#$(slug_number "$dep")"
    if [ "$first" = true ]; then out="$n"; first=false; else out="$out, $n"; fi
  done <<<"$deps"
  printf '%s' "$out"
}

dependency_line() {
  local i="$1" deps
  deps="$(resolved_deps "$i")"
  [ -n "$deps" ] || { printf ''; return 0; }
  printf 'Depends on: %s' "$deps"
}

file_tickets() {
  local count i slug title body marker found num id deps_line
  count="$(jq '.tickets | length' <<<"$PLAN_JSON")"
  i=0
  while [ "$i" -lt "$count" ]; do
    slug="$(jq -r ".tickets[$i].slug" <<<"$PLAN_JSON")"
    title="$(jq -r ".tickets[$i].title" <<<"$PLAN_JSON")"
    body="$(jq -r ".tickets[$i].body" <<<"$PLAN_JSON")"
    marker="<!-- plan-to-tickets:ticket:$(jq -r '.plan_file' <<<"$PLAN_JSON"):$slug -->"

    deps_line="$(dependency_line "$i")"
    [ -n "$deps_line" ] && body="$body"$'\n\n'"$deps_line"
    body="$body"$'\n\n'"Part of #$EPIC_NUMBER"$'\n'"$marker"

    found="$(find_issue_by_marker "$marker")"
    if [ -n "$found" ]; then
      num="$(cut -f1 <<<"$found")"; id="$(cut -f2 <<<"$found")"
      if [ "$DRY_RUN" = true ]; then
        echo "PLAN UPDATE ticket issue #$num ($slug)" >&2
      else
        gh issue edit "$num" --repo "$REPO" --title "$title" --body "$body" >/dev/null
      fi
    else
      if [ "$DRY_RUN" = true ]; then
        echo "PLAN CREATE ticket \"$title\" ($slug)" >&2
        num=""; id=""
      else
        local args=(--repo "$REPO" --title "$title" --body "$body")
        local label
        while IFS= read -r label; do
          [ -n "$label" ] || continue
          args+=(--label "$label")
        done < <(jq -r ".tickets[$i].labels[]" <<<"$PLAN_JSON")
        local url
        url="$(gh issue create "${args[@]}")"
        num="$(basename "$url")"
        id="$(gh issue view "$num" --repo "$REPO" --json id -q .id)"
      fi
    fi

    record_slug "$slug" "$num" "$id"
    link_sub_issue "$id" "$num" "$slug"
    i=$((i + 1))
  done
}

link_sub_issue() {
  local ticket_id="$1" ticket_num="$2" slug="$3"
  if [ "$DRY_RUN" = true ]; then
    echo "PLAN LINK sub-issue ($slug) under epic \"$(jq -r '.epic.title' <<<"$PLAN_JSON")\"" >&2
    return 0
  fi
  if ! gh api "repos/$REPO/issues/$EPIC_NUMBER/sub_issues" -f "sub_issue_id=$ticket_id" >/dev/null 2>&1; then
    echo "Sub-issues API unavailable; falling back to checkbox list in epic body for ticket #$ticket_num." >&2
    append_checkbox_fallback "$ticket_num"
  fi
}

append_checkbox_fallback() {
  local ticket_num="$1" title body
  title="$(gh issue view "$ticket_num" --repo "$REPO" --json title -q .title)"
  body="$(gh issue view "$EPIC_NUMBER" --repo "$REPO" --json body -q .body)"
  if ! grep -q '^### Tickets' <<<"$body"; then
    body="$body"$'\n\n### Tickets'
  fi
  body="$body"$'\n- [ ] #'"$ticket_num $title"
  gh issue edit "$EPIC_NUMBER" --repo "$REPO" --body "$body" >/dev/null
}

write_manifest() {
  local plan_file source_branch spec_file slug outfile root count i num complexity tier priority deps
  plan_file="$(jq -c '.plan_file' <<<"$PLAN_JSON")"
  source_branch="$(jq -c '.source_branch' <<<"$PLAN_JSON")"
  spec_file="$(jq -c '.spec_file' <<<"$PLAN_JSON")"
  slug="$(basename "$(jq -r '.plan_file' <<<"$PLAN_JSON")" .md)"
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  outfile="$root/docs/superpowers/tickets/$slug.md"
  mkdir -p "$(dirname "$outfile")"
  {
    echo "---"
    echo "source_branch: $source_branch"
    echo "spec_file: $spec_file"
    echo "plan_file: $plan_file"
    echo "---"
    echo "# Tickets filed for $(jq -r '.plan_file' <<<"$PLAN_JSON")"
    echo
    echo "Epic: #$EPIC_NUMBER"
    echo
    echo "| Ticket | Complexity | Model tier | Priority | Depends on |"
    echo "|---|---|---|---|---|"
    count="$(jq '.tickets | length' <<<"$PLAN_JSON")"
    i=0
    while [ "$i" -lt "$count" ]; do
      slug="$(jq -r ".tickets[$i].slug" <<<"$PLAN_JSON")"
      num="$(slug_number "$slug")"
      complexity="$(jq -r ".tickets[$i].labels[] | select(startswith(\"complexity:\"))" <<<"$PLAN_JSON")"
      tier="$(jq -r ".tickets[$i].labels[] | select(startswith(\"model-tier:\"))" <<<"$PLAN_JSON")"
      priority="$(jq -r ".tickets[$i].labels[] | select(startswith(\"priority:\"))" <<<"$PLAN_JSON")"
      deps="$(resolved_deps "$i")"
      echo "| #$num | $complexity | $tier | $priority | $deps |"
      i=$((i + 1))
    done
  } > "$outfile"
  echo "Wrote $outfile" >&2
}

main "$@"
