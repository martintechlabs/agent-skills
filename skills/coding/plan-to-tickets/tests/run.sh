#!/usr/bin/env bash
# Plain-bash test runner for create-tickets.sh. No network: a fake `gh` is put on PATH.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/create-tickets.sh"
PASS=0
FAIL=0

setup_path() {
  local bindir="$1"
  mkdir -p "$bindir"
  cp "$HERE/fake-gh" "$bindir/gh"
  chmod +x "$bindir/gh"
  echo "$bindir:$PATH"
}

# run_ct <bindir> <env-assignments...> -- <create-tickets.sh args...>
# Captures stdout->$OUT, stderr->$ERR, exit->$RC
run_ct() {
  local bindir="$1"; shift
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift  # drop --
  local outf errf workdir
  outf="$(mktemp)"; errf="$(mktemp)"
  # Run from the test's own temp dir (parent of $bindir), never the repo root: a real
  # (non-dry-run) invocation calls write_manifest, which resolves its output path via
  # `git rev-parse --show-toplevel` — without this, that would resolve to *this* repo
  # and leak a stray docs/superpowers/tickets/*.md file into it on every test run.
  workdir="$(dirname "$bindir")"
  ( cd "$workdir" && PATH="$(setup_path "$bindir")" env ${envs[@]+"${envs[@]}"} bash "$SCRIPT" "$@" >"$outf" 2>"$errf" )
  RC=$?
  OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

assert_eq()       { [ "$1" = "$2" ] && ok "$3" || bad "$3" "expected [$2] got [$1]"; }
assert_contains() { case "$1" in *"$2"*) ok "$3";; *) bad "$3" "[$1] did not contain [$2]";; esac; }
assert_not_contains() { case "$1" in *"$2"*) bad "$3" "[$1] contained [$2]";; *) ok "$3";; esac; }

# jqok <json> <jq-filter-returning-true> <label>
jqok() {
  local got; got="$(printf '%s' "$1" | jq -r "$2" 2>/dev/null)"
  assert_eq "$got" "true" "$3"
}

# ---- Task 1 test ----
test_help() {
  local d; d="$(mktemp -d)"
  run_ct "$d/bin" -- --help
  assert_eq "$RC" "0" "help exits 0"
  assert_contains "$OUT" "create-tickets.sh" "help mentions the script"
  assert_contains "$OUT" "--input" "help lists the --input flag"
  rm -rf "$d"
}

test_help

test_parse_args() {
  local d; d="$(mktemp -d)"
  run_ct "$d/bin" -- --print-config --input plan.json --repo acme/widgets --dry-run
  assert_contains "$OUT" "INPUT=plan.json"     "parses --input"
  assert_contains "$OUT" "REPO=acme/widgets"   "parses --repo"
  assert_contains "$OUT" "DRY_RUN=true"        "parses --dry-run"
  rm -rf "$d"
}

test_parse_args

test_preflight_auth_ok() {
  local d; d="$(mktemp -d)"
  run_ct "$d/bin" -- --preflight-only
  assert_eq "$RC" "0" "preflight passes when authenticated"
  rm -rf "$d"
}

test_preflight_auth_fail() {
  local d; d="$(mktemp -d)"
  run_ct "$d/bin" FAKE_GH_AUTH_FAIL=true -- --preflight-only
  assert_eq "$RC" "1" "preflight fails when not authenticated"
  assert_contains "$ERR" "Not authenticated" "clear error when not authenticated"
  rm -rf "$d"
}

test_preflight_auth_ok
test_preflight_auth_fail

test_missing_input_value_flag() {
  local d; d="$(mktemp -d)"
  run_ct "$d/bin" -- --input
  assert_eq "$RC" "2" "missing --input value exits 2"
  assert_contains "$ERR" "Missing value for --input" "clear error for missing --input value"
  rm -rf "$d"
}

test_input_not_found() {
  local d; d="$(mktemp -d)"
  run_ct "$d/bin" -- --input "$d/nope.json"
  assert_eq "$RC" "1" "missing input file exits 1"
  assert_contains "$ERR" "No such file" "clear error for missing input file"
  rm -rf "$d"
}

test_input_invalid_json() {
  local d; d="$(mktemp -d)"
  printf 'not json' > "$d/bad.json"
  run_ct "$d/bin" -- --input "$d/bad.json"
  assert_eq "$RC" "1" "invalid JSON input exits 1"
  assert_contains "$ERR" "not valid JSON" "clear error for invalid JSON"
  rm -rf "$d"
}

write_good_plan() {
  cat > "$1" <<'EOF'
{
  "repo": "octo/repo",
  "source_branch": "feature/metadata:proof#1",
  "spec_file": "docs/superpowers/specs/2026-07-18-example-design.md",
  "plan_file": "docs/superpowers/plans/2026-07-18-example.md",
  "epic": {"title": "Example Feature", "body": "Epic body text."},
  "tickets": [
    {"slug": "001-a", "title": "Ticket A", "body": "Body A",
     "labels": ["complexity:small", "priority:p1", "model-tier:efficient"], "depends_on_slugs": []},
    {"slug": "002-b", "title": "Ticket B", "body": "Body B",
     "labels": ["complexity:medium", "priority:p1", "model-tier:standard"], "depends_on_slugs": ["001-a"]}
  ]
}
EOF
}

write_bad_dependency_plan() {
  cat > "$1" <<'EOF'
{
  "repo": "octo/repo",
  "source_branch": "feature/metadata:proof#1",
  "spec_file": "docs/superpowers/specs/2026-07-18-example-design.md",
  "plan_file": "docs/superpowers/plans/2026-07-18-example.md",
  "epic": {"title": "Example Feature", "body": "Epic body text."},
  "tickets": [
    {"slug": "001-a", "title": "Ticket A", "body": "Body A", "labels": ["complexity:small"], "depends_on_slugs": ["999-nope"]}
  ]
}
EOF
}

test_dependency_validation_fails() {
  local d; d="$(mktemp -d)"
  write_bad_dependency_plan "$d/plan.json"
  run_ct "$d/bin" -- --input "$d/plan.json"
  assert_eq "$RC" "1" "unknown/forward dependency exits 1"
  assert_contains "$ERR" "001-a depends on unknown/forward slug 999-nope" "names the bad ticket and slug"
  rm -rf "$d"
}

test_dependency_validation_passes() {
  local d; d="$(mktemp -d)"
  write_good_plan "$d/plan.json"
  # FAKE_GH_ISSUES_JSON/FAKE_GH_COUNTER_FILE are set so this test stays valid once later
  # tasks wire more of main() past load_plan — right now (Task 4) main() stops here anyway.
  run_ct "$d/bin" FAKE_GH_ISSUES_JSON='[]' FAKE_GH_COUNTER_FILE="$d/counter" -- --input "$d/plan.json"
  assert_eq "$RC" "0" "well-ordered dependencies load cleanly"
  rm -rf "$d"
}

test_required_metadata_validation() {
  local field variant filter d log logtext
  for field in source_branch spec_file plan_file; do
    for variant in missing null non_string empty; do
      d="$(mktemp -d)"
      log="$d/gh.log"
      write_good_plan "$d/base.json"
      case "$variant" in
        missing)    filter='del(.[$field])' ;;
        null)       filter='.[$field] = null' ;;
        non_string) filter='.[$field] = 42' ;;
        empty)      filter='.[$field] = ""' ;;
      esac
      jq --arg field "$field" "$filter" "$d/base.json" > "$d/plan.json"

      run_ct "$d/bin" FAKE_GH_LOG="$log" FAKE_GH_ISSUES_JSON='[]' \
        FAKE_GH_COUNTER_FILE="$d/counter" \
        -- --input "$d/plan.json" --repo octo/repo

      assert_eq "$RC" "1" "$field rejects $variant values"
      assert_contains "$ERR" \
        "Invalid ticket-plan JSON: .$field must be a non-empty string." \
        "$field reports a clear $variant error"
      logtext="$(cat "$log")"
      assert_not_contains "$logtext" "label create" "$field $variant failure creates no labels"
      assert_not_contains "$logtext" "issue create" "$field $variant failure creates no issues"
      assert_not_contains "$logtext" "issue edit" "$field $variant failure edits no issues"
      assert_not_contains "$logtext" "api " "$field $variant failure links no sub-issues"
      rm -rf "$d"
    done
  done
}

test_missing_input_value_flag
test_input_not_found
test_input_invalid_json
test_dependency_validation_fails
test_dependency_validation_passes
test_required_metadata_validation

test_ensure_labels_dry_run_only_missing() {
  local d; d="$(mktemp -d)"
  write_good_plan "$d/plan.json"
  run_ct "$d/bin" FAKE_GH_LABELS=$'epic\ncomplexity:small' -- --input "$d/plan.json" --dry-run
  assert_contains "$ERR" "PLAN CREATE LABEL complexity:medium" "plans creating a missing label"
  assert_contains "$ERR" "PLAN CREATE LABEL priority:p1" "plans creating another missing label"
  assert_not_contains "$ERR" "PLAN CREATE LABEL epic" "does not re-plan an existing label"
  assert_not_contains "$ERR" "PLAN CREATE LABEL complexity:small" "does not re-plan another existing label"
  rm -rf "$d"
}

test_ensure_labels_real_run() {
  local d; d="$(mktemp -d)"; local log="$d/gh.log"
  write_good_plan "$d/plan.json"
  run_ct "$d/bin" FAKE_GH_LABELS=$'epic' FAKE_GH_LOG="$log" FAKE_GH_COUNTER_FILE="$d/counter" \
    -- --input "$d/plan.json" --repo octo/repo
  local logtext; logtext="$(cat "$log")"
  assert_contains "$logtext" "label create complexity:small --repo octo/repo --color 0e8a16 --force" "creates a missing label with its color"
  assert_not_contains "$logtext" "label create epic" "does not recreate an existing label"
  rm -rf "$d"
}

test_ensure_labels_dry_run_only_missing
test_ensure_labels_real_run

test_epic_dry_run_create_when_absent() {
  local d; d="$(mktemp -d)"
  write_good_plan "$d/plan.json"
  run_ct "$d/bin" FAKE_GH_ISSUES_JSON='[]' -- --input "$d/plan.json" --dry-run
  assert_contains "$ERR" 'PLAN CREATE epic issue "Example Feature"' "plans creating the epic when none exists"
  rm -rf "$d"
}

test_epic_dry_run_update_when_present() {
  local d; d="$(mktemp -d)"
  write_good_plan "$d/plan.json"
  local issues='[{"number":100,"id":9100,"body":"old body\n\n<!-- plan-to-tickets:epic:docs/superpowers/plans/2026-07-18-example.md -->"}]'
  run_ct "$d/bin" FAKE_GH_ISSUES_JSON="$issues" -- --input "$d/plan.json" --dry-run
  assert_contains "$ERR" "PLAN UPDATE epic issue #100" "plans updating the existing epic by marker"
  rm -rf "$d"
}

test_epic_real_create() {
  local d; d="$(mktemp -d)"; local log="$d/gh.log"
  write_good_plan "$d/plan.json"
  run_ct "$d/bin" FAKE_GH_ISSUES_JSON='[]' FAKE_GH_LOG="$log" FAKE_GH_COUNTER_FILE="$d/counter" \
    -- --input "$d/plan.json" --repo octo/repo
  assert_contains "$(cat "$log")" "issue create --repo octo/repo --title Example Feature" "creates the epic issue"
  assert_contains "$(cat "$log")" "--label epic" "labels the epic issue"
  rm -rf "$d"
}

test_epic_real_update() {
  local d; d="$(mktemp -d)"; local log="$d/gh.log"
  write_good_plan "$d/plan.json"
  local issues='[{"number":100,"id":9100,"body":"old body\n\n<!-- plan-to-tickets:epic:docs/superpowers/plans/2026-07-18-example.md -->"}]'
  run_ct "$d/bin" FAKE_GH_ISSUES_JSON="$issues" FAKE_GH_LOG="$log" FAKE_GH_COUNTER_FILE="$d/counter" \
    -- --input "$d/plan.json" --repo octo/repo
  assert_contains "$(cat "$log")" "issue edit 100 --repo octo/repo --title Example Feature" "updates the existing epic by number, not a new create"
  # Scoped to the epic's own title, not "issue create" anywhere: once later tasks wire
  # file_tickets into main(), this same plan's (not-yet-seeded) tickets legitimately get
  # created — only the epic itself must never be recreated.
  assert_not_contains "$(cat "$log")" "issue create --repo octo/repo --title Example Feature" "never creates a duplicate epic"
  rm -rf "$d"
}

test_epic_dry_run_create_when_absent
test_epic_dry_run_update_when_present
test_epic_real_create
test_epic_real_update

test_tickets_dry_run() {
  local d; d="$(mktemp -d)"
  write_good_plan "$d/plan.json"
  run_ct "$d/bin" FAKE_GH_ISSUES_JSON='[]' -- --input "$d/plan.json" --dry-run
  assert_contains "$ERR" 'PLAN CREATE ticket "Ticket A" (001-a)' "plans creating ticket A"
  assert_contains "$ERR" 'PLAN CREATE ticket "Ticket B" (002-b)' "plans creating ticket B"
  rm -rf "$d"
}

test_tickets_real_create_with_resolved_dependency() {
  local d; d="$(mktemp -d)"; local log="$d/gh.log"
  write_good_plan "$d/plan.json"
  run_ct "$d/bin" FAKE_GH_ISSUES_JSON='[]' FAKE_GH_LOG="$log" FAKE_GH_COUNTER_FILE="$d/counter" \
    -- --input "$d/plan.json" --repo octo/repo
  local logtext; logtext="$(cat "$log")"
  assert_contains "$logtext" "issue create --repo octo/repo --title Ticket A --body Body A" "creates ticket A"
  assert_contains "$logtext" "--label complexity:small --label priority:p1 --label model-tier:efficient" "labels ticket A"
  assert_contains "$logtext" "issue create --repo octo/repo --title Ticket B --body Body B" "creates ticket B"
  assert_contains "$logtext" "Depends on: #101" "ticket B's body resolves its dependency to a real issue number"
  assert_contains "$logtext" "Part of #100" "ticket B's body references the epic"
  rm -rf "$d"
}

test_tickets_idempotent_update() {
  local d; d="$(mktemp -d)"; local log="$d/gh.log"
  write_good_plan "$d/plan.json"
  local issues='[
    {"number":100,"id":9100,"body":"<!-- plan-to-tickets:epic:docs/superpowers/plans/2026-07-18-example.md -->"},
    {"number":101,"id":9101,"body":"Body A\n\nPart of #100\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/2026-07-18-example.md:001-a -->"},
    {"number":102,"id":9102,"body":"Body B\n\nDepends on: #101\n\nPart of #100\n<!-- plan-to-tickets:ticket:docs/superpowers/plans/2026-07-18-example.md:002-b -->"}
  ]'
  run_ct "$d/bin" FAKE_GH_ISSUES_JSON="$issues" FAKE_GH_LOG="$log" FAKE_GH_COUNTER_FILE="$d/counter" \
    -- --input "$d/plan.json" --repo octo/repo
  local logtext; logtext="$(cat "$log")"
  assert_contains "$logtext" "issue edit 101" "updates ticket A by number"
  assert_contains "$logtext" "issue edit 102" "updates ticket B by number"
  assert_not_contains "$logtext" "issue create --repo octo/repo --title Ticket" "never duplicates a ticket"
  rm -rf "$d"
}

test_tickets_dry_run
test_tickets_real_create_with_resolved_dependency
test_tickets_idempotent_update

test_sub_issue_link_success() {
  local d; d="$(mktemp -d)"; local log="$d/gh.log"
  write_good_plan "$d/plan.json"
  run_ct "$d/bin" FAKE_GH_ISSUES_JSON='[]' FAKE_GH_LOG="$log" FAKE_GH_COUNTER_FILE="$d/counter" \
    -- --input "$d/plan.json" --repo octo/repo
  local logtext; logtext="$(cat "$log")"
  assert_contains "$logtext" "api repos/octo/repo/issues/100/sub_issues -f sub_issue_id=9101" "links ticket A as a sub-issue by id (not number)"
  assert_contains "$logtext" "api repos/octo/repo/issues/100/sub_issues -f sub_issue_id=9102" "links ticket B as a sub-issue by id"
  rm -rf "$d"
}

test_sub_issue_link_dry_run() {
  local d; d="$(mktemp -d)"
  write_good_plan "$d/plan.json"
  run_ct "$d/bin" FAKE_GH_ISSUES_JSON='[]' -- --input "$d/plan.json" --dry-run
  assert_contains "$ERR" 'PLAN LINK sub-issue (001-a) under epic "Example Feature"' "plans linking ticket A"
  rm -rf "$d"
}

test_sub_issue_fallback_on_failure() {
  local d; d="$(mktemp -d)"; local log="$d/gh.log"
  write_good_plan "$d/plan.json"
  run_ct "$d/bin" FAKE_GH_ISSUES_JSON='[]' FAKE_GH_SUBISSUES_FAIL=true FAKE_GH_ISSUE_TITLE="Ticket A" \
    FAKE_GH_LOG="$log" FAKE_GH_COUNTER_FILE="$d/counter" \
    -- --input "$d/plan.json" --repo octo/repo
  assert_contains "$ERR" "Sub-issues API unavailable; falling back to checkbox list in epic body for ticket #101." "reports the fallback (non-silent)"
  local logtext; logtext="$(cat "$log")"
  assert_contains "$logtext" "issue edit 100 --repo octo/repo --body" "falls back to editing the epic body"
  assert_contains "$logtext" "### Tickets" "adds a Tickets heading"
  assert_contains "$logtext" "- [ ] #101 Ticket A" "appends a checkbox line for the ticket"
  rm -rf "$d"
}

test_sub_issue_fallback_no_duplicate_heading() {
  local d; d="$(mktemp -d)"; local log="$d/gh.log"
  # A single-ticket plan: exactly one fallback call, so the heading count below is
  # unambiguous (a multi-ticket plan would append the pre-existing heading text once
  # per ticket's independent issue-edit call, which is correct but would make a
  # log-wide count meaningless).
  cat > "$d/plan.json" <<'EOF'
{
  "repo": "octo/repo",
  "source_branch": "feature/metadata:proof#1",
  "spec_file": "docs/superpowers/specs/2026-07-18-example-design.md",
  "plan_file": "docs/superpowers/plans/2026-07-18-example.md",
  "epic": {"title": "Example Feature", "body": "Epic body text."},
  "tickets": [
    {"slug": "001-a", "title": "Ticket A", "body": "Body A",
     "labels": ["complexity:small", "priority:p1", "model-tier:efficient"], "depends_on_slugs": []}
  ]
}
EOF
  run_ct "$d/bin" FAKE_GH_ISSUES_JSON='[]' FAKE_GH_SUBISSUES_FAIL=true \
    FAKE_GH_EPIC_BODY=$'Epic body.\n\n### Tickets\n- [ ] #99 Existing ticket' \
    FAKE_GH_LOG="$log" FAKE_GH_COUNTER_FILE="$d/counter" \
    -- --input "$d/plan.json" --repo octo/repo
  local heading_count
  heading_count="$(grep -o '### Tickets' "$log" | wc -l | tr -d ' ')"
  assert_eq "$heading_count" "1" "does not add a second Tickets heading when one already exists"
  rm -rf "$d"
}

test_sub_issue_link_success
test_sub_issue_link_dry_run
test_sub_issue_fallback_on_failure
test_sub_issue_fallback_no_duplicate_heading

test_write_manifest() {
  local d; d="$(mktemp -d)"
  (cd "$d" && git init -q)
  write_good_plan "$d/plan.json"
  local outf errf; outf="$(mktemp)"; errf="$(mktemp)"
  local bindir="$d/bin"; mkdir -p "$bindir"; cp "$HERE/fake-gh" "$bindir/gh"; chmod +x "$bindir/gh"
  ( cd "$d" && \
    PATH="$bindir:$PATH" FAKE_GH_ISSUES_JSON='[]' FAKE_GH_COUNTER_FILE="$d/counter" \
    bash "$SCRIPT" --input "$d/plan.json" --repo octo/repo >"$outf" 2>"$errf" )
  local manifest="$d/docs/superpowers/tickets/2026-07-18-example.md"
  [ -f "$manifest" ] && ok "writes the manifest file" || bad "writes the manifest file" "not found: $manifest"
  local content; content="$(cat "$manifest" 2>/dev/null || true)"
  assert_eq "$(sed -n '1p' "$manifest")" "---" "manifest starts YAML front matter"
  assert_eq "$(sed -n '5p' "$manifest")" "---" "manifest closes YAML front matter"
  assert_eq "$(sed -n '2s/^source_branch: //p' "$manifest" | jq -r .)" \
    "feature/metadata:proof#1" "manifest records the exact source branch"
  assert_eq "$(sed -n '3s/^spec_file: //p' "$manifest" | jq -r .)" \
    "docs/superpowers/specs/2026-07-18-example-design.md" "manifest records the exact spec file"
  assert_eq "$(sed -n '4s/^plan_file: //p' "$manifest" | jq -r .)" \
    "docs/superpowers/plans/2026-07-18-example.md" "manifest records the exact plan file"
  assert_contains "$content" "Epic: #100" "manifest records the epic number"
  assert_contains "$content" "| #101 | complexity:small | model-tier:efficient | priority:p1 |" "manifest records ticket A's metadata"
  assert_contains "$content" "| #102 | complexity:medium | model-tier:standard | priority:p1 | #101 |" "manifest resolves ticket B's dependency to a real number"
  rm -f "$outf" "$errf"; rm -rf "$d"
}

test_manifest_skipped_on_dry_run() {
  local d; d="$(mktemp -d)"
  (cd "$d" && git init -q)
  write_good_plan "$d/plan.json"
  ( cd "$d" && PATH="$HERE/../tests:$PATH" true ) # no-op; real check below
  local bindir="$d/bin"; mkdir -p "$bindir"; cp "$HERE/fake-gh" "$bindir/gh"; chmod +x "$bindir/gh"
  ( cd "$d" && PATH="$bindir:$PATH" FAKE_GH_ISSUES_JSON='[]' bash "$SCRIPT" --input "$d/plan.json" --repo octo/repo --dry-run >/dev/null 2>/dev/null )
  [ -e "$d/docs/superpowers/tickets/2026-07-18-example.md" ] \
    && bad "dry-run does not write a manifest" "file exists" \
    || ok "dry-run does not write a manifest"
  rm -rf "$d"
}

test_write_manifest
test_manifest_skipped_on_dry_run

test_skill_documents_metadata_contract() {
  local skill; skill="$(cat "$HERE/../SKILL.md")"
  assert_contains "$skill" 'version: "0.2.0"' "skill version reflects the breaking schema change"
  assert_contains "$skill" 'git branch --show-current' "skill resolves the source branch explicitly"
  assert_contains "$skill" 'detached HEAD' "skill documents detached-HEAD handling"
  assert_contains "$skill" '"source_branch"' "skill schema requires source_branch"
  assert_contains "$skill" '"spec_file"' "skill schema requires spec_file"
  assert_contains "$skill" 'YAML front matter' "skill documents manifest metadata output"
}

test_skill_documents_metadata_contract

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
