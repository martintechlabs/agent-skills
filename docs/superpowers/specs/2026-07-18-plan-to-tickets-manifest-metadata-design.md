# plan-to-tickets manifest metadata — Design

**Date:** 2026-07-18
**Status:** Approved

## Purpose

Extend `plan-to-tickets` so its ticket-plan input and generated Markdown manifest
carry explicit source provenance. Downstream tools must be able to identify the
source branch, specification, and implementation plan without inferring them from
the current checkout or from filename conventions.

## Input contract

The ticket-plan JSON requires these non-empty string fields at its top level:

```json
{
  "repo": "owner/repo",
  "source_branch": "feature/example",
  "spec_file": "docs/superpowers/specs/example-design.md",
  "plan_file": "docs/superpowers/plans/example.md"
}
```

`repo` remains optional. `source_branch`, `spec_file`, and `plan_file` are required.
The skill populates them explicitly; the script does not infer or rewrite them.

When building the ticket-plan JSON, the skill obtains the current branch with
`git branch --show-current`. If the checkout is detached and the command returns no
branch, the skill asks the user for the source branch instead of emitting `HEAD` or
guessing a branch name. The spec and plan paths are the exact repository-relative
paths the skill read.

## Validation and failure behavior

After parsing the JSON and before ensuring labels or filing issues, the script
validates each required metadata field. A field that is absent, null, not a string,
or empty causes a non-zero exit with a field-specific error. Validation happens
before any GitHub mutation.

There is no compatibility fallback for legacy ticket-plan JSON. Callers must add
the explicit fields, which gives downstream consumers a reliable schema instead of
conditionally present provenance.

## Manifest output

The generated `docs/superpowers/tickets/<plan-slug>.md` begins with YAML front
matter containing the values copied verbatim from the ticket-plan JSON:

```yaml
---
source_branch: "feature/example"
spec_file: "docs/superpowers/specs/example-design.md"
plan_file: "docs/superpowers/plans/example.md"
---
```

The implementation emits safely quoted YAML string scalars so branch names and
paths containing YAML-significant characters remain parseable. The existing
human-readable heading, epic reference, and ticket table follow the front matter
unchanged.

`plan_file` remains the identity key for hidden issue markers and the source of the
manifest filename. This preserves the existing idempotency behavior. Dry runs
validate the metadata but continue to skip manifest creation.

## Files and components

- `skills/coding/plan-to-tickets/SKILL.md` documents branch discovery, detached-HEAD
  handling, the required JSON fields, and the manifest metadata contract.
- `skills/coding/plan-to-tickets/scripts/create-tickets.sh` validates the fields and
  writes them as manifest front matter.
- `skills/coding/plan-to-tickets/tests/run.sh` updates existing fixtures and adds
  metadata validation and manifest regression coverage.
- The existing plan-to-tickets design and implementation-plan documents remain
  historical records and are not rewritten.

## Tests

The shell test suite will prove that:

1. Existing successful flows use the new required schema.
2. Missing, null, non-string, and empty required metadata is rejected before an
   issue or label mutation is attempted.
3. A successful real run writes parseable YAML front matter containing the exact
   `source_branch`, `spec_file`, and `plan_file` values.
4. Dry-run behavior remains non-mutating while enforcing the metadata validation.
5. Existing issue-marker, dependency, sub-issue, and manifest-table behavior remains
   unchanged.

## Non-goals

- Deriving the source branch or spec path inside the script.
- Adding timestamps, commit SHAs, schema versions, or other provenance fields.
- Changing issue marker formats, manifest filenames, or ticket decomposition.
- Migrating previously generated manifests.
