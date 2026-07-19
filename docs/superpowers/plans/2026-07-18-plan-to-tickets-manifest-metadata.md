# plan-to-tickets Manifest Metadata Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Require explicit source-branch, spec-file, and plan-file provenance in every ticket-plan JSON and copy it into machine-readable front matter in the generated ticket manifest.

**Architecture:** Keep provenance authoring in the agent-facing `SKILL.md`: the agent resolves the current branch and records the exact spec and plan paths. The Bash script treats those values as required input, validates them before any GitHub mutation, and copies their JSON-quoted values into YAML front matter while continuing to use `plan_file` as the idempotency and filename key.

**Tech Stack:** Bash 3.2-compatible shell, `jq`, Markdown with YAML front matter, the existing plain-Bash test harness and fake `gh` CLI.

## Global Constraints

- `source_branch`, `spec_file`, and `plan_file` are required top-level, non-empty JSON strings.
- `repo` remains optional.
- The script must not derive, normalize, or rewrite provenance values.
- A detached checkout must cause the skill to ask the user for `source_branch`; it must not emit `HEAD` or guess a branch.
- Required-field validation must finish before any label, issue, or sub-issue mutation.
- Legacy ticket-plan JSON without the new fields is rejected; there is no fallback.
- `plan_file` remains the issue-marker identity key and manifest-filename source.
- Dry runs validate metadata but do not write a manifest.
- Do not add timestamps, commit SHAs, schema versions, migrations, or unrelated refactors.
- Preserve macOS system Bash 3.2 compatibility; do not add associative arrays, `mapfile`, or `readarray`.

---

## File Structure

- `skills/coding/plan-to-tickets/scripts/create-tickets.sh` owns mechanical JSON validation and manifest rendering.
- `skills/coding/plan-to-tickets/tests/run.sh` owns fake-GitHub regression coverage and all ticket-plan fixtures.
- `skills/coding/plan-to-tickets/SKILL.md` owns agent-side branch discovery, detached-HEAD handling, and the public ticket-plan/manifest contract.
- `docs/superpowers/plans/2026-07-18-plan-to-tickets-manifest-metadata.md` records this execution plan and is committed with the documentation task.

### Task 1: Require explicit provenance in ticket-plan JSON

**Files:**
- Modify: `skills/coding/plan-to-tickets/tests/run.sh:117-169,319-344`
- Modify: `skills/coding/plan-to-tickets/scripts/create-tickets.sh:69-99`

**Interfaces:**
- Consumes: `$PLAN_JSON`, populated from `--input` by `load_plan()`.
- Produces: `validate_metadata()`, which exits `1` unless `.source_branch`, `.spec_file`, and `.plan_file` are non-empty JSON strings.
- Preserves: `validate_dependency_order()` and all existing marker/dependency behavior.

- [ ] **Step 1: Update valid fixtures and add the failing metadata-validation test**

Add the three required fields to `write_good_plan`, `write_bad_dependency_plan`, and the inline single-ticket JSON in `test_sub_issue_fallback_no_duplicate_heading`. In each object, place these lines after `repo`:

```json
  "source_branch": "feature/metadata:proof#1",
  "spec_file": "docs/superpowers/specs/2026-07-18-example-design.md",
  "plan_file": "docs/superpowers/plans/2026-07-18-example.md",
```

Remove the old standalone `plan_file` line from each object so the key occurs once.

Add this test after `test_dependency_validation_passes` and invoke it with the other input-validation tests:

```bash
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
```

Add the invocation after `test_dependency_validation_passes`:

```bash
test_required_metadata_validation
```

- [ ] **Step 2: Run the suite to verify the new test fails for the intended reason**

Run:

```bash
bash skills/coding/plan-to-tickets/tests/run.sh
```

Expected: FAIL. The 12 invalid cases report `RC=0` instead of `1`, and the fake-`gh` log shows mutations because `validate_metadata` does not exist yet. Existing tests continue to pass with the updated valid fixtures.

- [ ] **Step 3: Add the minimal metadata validator before repo resolution and dependency validation**

Change `load_plan()` and add `validate_metadata()` immediately before `validate_dependency_order()`:

```bash
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
```

This placement permits the existing read-only `gh auth status` preflight, but stops before `ensure_labels`, `file_epic`, `file_tickets`, or `write_manifest`.

- [ ] **Step 4: Run the suite to verify required metadata is enforced**

Run:

```bash
bash skills/coding/plan-to-tickets/tests/run.sh
```

Expected: PASS with `125 passed, 0 failed`.

- [ ] **Step 5: Commit the validation change**

```bash
git add skills/coding/plan-to-tickets/tests/run.sh skills/coding/plan-to-tickets/scripts/create-tickets.sh
git commit -m "plan-to-tickets: require source provenance metadata"
```

### Task 2: Emit safely quoted YAML manifest metadata

**Files:**
- Modify: `skills/coding/plan-to-tickets/tests/run.sh:351-367`
- Modify: `skills/coding/plan-to-tickets/scripts/create-tickets.sh:278-306`

**Interfaces:**
- Consumes: already-validated `.source_branch`, `.spec_file`, and `.plan_file` strings in `$PLAN_JSON`.
- Produces: the first five lines of every real-run manifest as YAML front matter with JSON-compatible double-quoted scalar values.
- Preserves: the existing heading, epic reference, ticket table, filename, and dry-run skip behavior.

- [ ] **Step 1: Extend the manifest regression test before changing the renderer**

In `test_write_manifest()`, add these assertions immediately after loading `content` and before the existing epic/table assertions:

```bash
  assert_eq "$(sed -n '1p' "$manifest")" "---" "manifest starts YAML front matter"
  assert_eq "$(sed -n '5p' "$manifest")" "---" "manifest closes YAML front matter"
  assert_eq "$(sed -n '2s/^source_branch: //p' "$manifest" | jq -r .)" \
    "feature/metadata:proof#1" "manifest records the exact source branch"
  assert_eq "$(sed -n '3s/^spec_file: //p' "$manifest" | jq -r .)" \
    "docs/superpowers/specs/2026-07-18-example-design.md" "manifest records the exact spec file"
  assert_eq "$(sed -n '4s/^plan_file: //p' "$manifest" | jq -r .)" \
    "docs/superpowers/plans/2026-07-18-example.md" "manifest records the exact plan file"
```

Using `jq -r` on each emitted scalar proves that the value is valid JSON string syntax. JSON double-quoted strings are valid YAML double-quoted scalars, including the fixture's YAML-significant `:` and `#` branch characters.

- [ ] **Step 2: Run the suite to verify the manifest test fails**

Run:

```bash
bash skills/coding/plan-to-tickets/tests/run.sh
```

Expected: FAIL only on the five new front-matter assertions because the manifest currently starts with `# Tickets filed for ...`.

- [ ] **Step 3: Render provenance before the existing human-readable manifest body**

Replace `write_manifest()` with:

```bash
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
```

`jq -c` supplies JSON quoting and escaping for the YAML scalar values. The separate raw `plan_file` reads preserve the existing heading and filename exactly.

- [ ] **Step 4: Run the suite to verify manifest metadata and legacy content**

Run:

```bash
bash skills/coding/plan-to-tickets/tests/run.sh
```

Expected: PASS with `130 passed, 0 failed`; the original epic and ticket-table assertions pass unchanged.

- [ ] **Step 5: Commit the manifest change**

```bash
git add skills/coding/plan-to-tickets/tests/run.sh skills/coding/plan-to-tickets/scripts/create-tickets.sh
git commit -m "plan-to-tickets: write source metadata to manifests"
```

### Task 3: Publish the agent-facing metadata contract

**Files:**
- Modify: `skills/coding/plan-to-tickets/tests/run.sh:382-386`
- Modify: `skills/coding/plan-to-tickets/SKILL.md:11-13,44-47,91-114,169-172`
- Commit: `docs/superpowers/plans/2026-07-18-plan-to-tickets-manifest-metadata.md`

**Interfaces:**
- Consumes: the approved design and the validated/rendered script contract from Tasks 1-2.
- Produces: `SKILL.md` version `0.2.0`, instructing agents how to populate every required field and interpret the manifest.
- Preserves: ticket decomposition, preview confirmation, duplicate checking, and filing procedures.

- [ ] **Step 1: Add a failing contract-documentation test**

Add this test before the final test summary and invoke it after the function:

```bash
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
```

- [ ] **Step 2: Run the suite to verify the documentation contract fails**

Run:

```bash
bash skills/coding/plan-to-tickets/tests/run.sh
```

Expected: FAIL on the six new documentation assertions because `SKILL.md` is still version `0.1.0` and does not describe the new metadata.

- [ ] **Step 3: Update the skill version and source-reading procedure**

Change the frontmatter version to:

```yaml
metadata:
  author: stephen-martin
  version: "0.2.0"
```

Replace procedure step 1 with:

````markdown
### 1. Read the spec and plan, and record their provenance

Read both files in full. Record their exact repository-relative paths. Extract every
`### Task N` block from the plan (its `Files:` list and every step) in order.

Resolve the source branch explicitly:

```bash
git branch --show-current
```

Use the command's output as `source_branch`. If it is empty because the checkout is at
detached HEAD, ask the user for the source branch — never emit `HEAD` or guess a branch.
````

- [ ] **Step 4: Update the public JSON schema and required-field explanation**

In procedure step 3, replace the opening object fields with:

```json
{
  "repo": "owner/repo",
  "source_branch": "feature/example",
  "spec_file": "docs/superpowers/specs/YYYY-MM-DD-<feature>-design.md",
  "plan_file": "docs/superpowers/plans/YYYY-MM-DD-<feature>.md",
  "epic": { "title": "string", "body": "string (goal/architecture summary, links to the committed spec+plan files, a compact table of tickets: title/complexity/model tier/priority)" },
  "tickets": [
    {
      "slug": "001-short-slug",
      "title": "string",
      "body": "string — the concrete files and steps/code for this ticket's scope, reconstructed from the merged/split plan Tasks (self-contained per writing-plans' zero-context bar). Do NOT include Depends-on/Part-of/marker lines — the script adds those.",
      "labels": ["complexity:small", "priority:p1", "model-tier:efficient"],
      "depends_on_slugs": []
    }
  ]
}
```

Replace the paragraph after the schema with:

```markdown
`source_branch`, `spec_file`, and `plan_file` are required non-empty strings. Copy the
branch and exact repository-relative paths recorded in step 1; the script never infers
or rewrites them. `tickets` **must** be in dependency order: every
`depends_on_slugs` entry must name a slug that appears *earlier* in the array. `repo`
is optional (the script falls back to the current repo).
```

- [ ] **Step 5: Document the emitted manifest metadata**

Replace the first sentence of the reporting paragraph in procedure step 6 with:

```markdown
Report the epic issue link, every ticket's issue link, and the path to the manifest the
script writes (`docs/superpowers/tickets/<plan-slug>.md`). The manifest begins with
YAML front matter containing the exact `source_branch`, `spec_file`, and `plan_file`
values from the ticket-plan JSON. Re-running this skill against the same plan later
(e.g. after editing it) updates the same epic/tickets in place — it will not create
duplicates.
```

- [ ] **Step 6: Run the suite and static contract checks**

Run:

```bash
bash skills/coding/plan-to-tickets/tests/run.sh
bash -n skills/coding/plan-to-tickets/scripts/create-tickets.sh
bash -n skills/coding/plan-to-tickets/tests/run.sh
git diff --check
```

Expected: the suite reports `136 passed, 0 failed`; both syntax checks and `git diff --check` exit `0` with no output.

- [ ] **Step 7: Review the completed diff against the approved contract**

Run:

```bash
git diff -- skills/coding/plan-to-tickets/SKILL.md \
  skills/coding/plan-to-tickets/scripts/create-tickets.sh \
  skills/coding/plan-to-tickets/tests/run.sh \
  docs/superpowers/plans/2026-07-18-plan-to-tickets-manifest-metadata.md
```

Expected: only the required schema, pre-mutation validation, manifest front matter, tests, version bump, and this implementation plan appear. Confirm that marker strings still use `plan_file` and no fallback or extra provenance fields were added.

- [ ] **Step 8: Commit the skill contract and implementation plan**

```bash
git add skills/coding/plan-to-tickets/SKILL.md \
  skills/coding/plan-to-tickets/tests/run.sh \
  docs/superpowers/plans/2026-07-18-plan-to-tickets-manifest-metadata.md
git commit -m "plan-to-tickets: document manifest metadata contract"
```

## Final Verification

Run fresh after all three commits:

```bash
bash skills/coding/plan-to-tickets/tests/run.sh
bash -n skills/coding/plan-to-tickets/scripts/create-tickets.sh
bash -n skills/coding/plan-to-tickets/tests/run.sh
git diff --check HEAD~3..HEAD
git status --short
```

Expected:

- `136 passed, 0 failed`.
- Both Bash syntax checks exit `0` with no output.
- `git diff --check HEAD~3..HEAD` exits `0` with no output.
- `git status --short` is empty.
