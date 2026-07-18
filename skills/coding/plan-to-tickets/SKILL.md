---
name: plan-to-tickets
description: >-
  Turn a superpowers spec + implementation plan into a GitHub backlog: one epic issue
  for the top-level spec/plan, and complexity/model-tier/priority/dependency-tagged
  ticket sub-issues that independent workers (out of scope for this skill) can pick up.
  Use when the user wants to split an implementation plan into tickets, file a backlog
  from a plan, break a plan into GitHub issues for parallel workers, or asks to turn a
  spec+plan into an epic with sub-issues. Does not execute or assign tickets — it stops
  once the backlog exists on GitHub.
metadata:
  author: stephen-martin
  version: "0.1.0"
---

# Turn a plan into a GitHub ticket backlog

Take a superpowers spec + implementation plan (the `docs/superpowers/specs/...` +
`docs/superpowers/plans/...` pair from `brainstorming` and `writing-plans`) and file a
GitHub backlog: an epic issue for the spec/plan, plus ticket sub-issues — each tagged
with a complexity, an abstract model tier, a priority, and its dependencies on other
tickets. The bundled `scripts/create-tickets.sh` does the mechanical GitHub work; it is
**idempotent** (finds an existing epic/tickets by a hidden marker and updates them
instead of duplicating).

This skill never dispatches, assigns, or monitors work — it stops once the backlog
exists.

## When this applies

- You have a plan file (`docs/superpowers/plans/YYYY-MM-DD-<feature>.md`, the
  `### Task N` format from `writing-plans`) and its paired spec
  (`docs/superpowers/specs/YYYY-MM-DD-<feature>-design.md`).
- The target is a **GitHub** repo, `gh` is installed and authenticated, and `jq` is
  installed.

If no plan is named, use the most recently modified file under
`docs/superpowers/plans/` and confirm it with the user before proceeding. If no spec
matches the plan's `<feature>` slug, ask the user for the spec path — do not proceed
without one.

## Procedure

### 1. Read the spec and plan

Read both files in full. Extract every `### Task N` block from the plan (its `Files:`
list and every step) in order.

### 2. Decompose plan Tasks into tickets

For each Task, compute a raw signal:

- **File count** touched (`Create`/`Modify`/`Test` paths under `Files:`).
- Whether steps are fully **mechanical** (code given verbatim, matching `writing-plans`'
  "no placeholders" bar) or require **judgment** (an outcome described without full code,
  multiple existing subsystems touched, or code not shown in the task).

Classify each raw Task as tiny / right-sized / oversized, then:

1. **Merge** adjacent tiny Tasks that touch the same file/component and have no
   independent shippable value into one ticket. Never merge across unrelated
   components merely to reduce ticket count.
2. **Split** oversized Tasks along natural seams — the `Files:` boundary or independently
   testable step groups. Repeat until every resulting unit fits the complexity bound
   below.
3. **Classify final complexity**:
   - **small** — 1-2 files, fully spec'd/mechanical, no cross-cutting judgment.
   - **medium** — 3+ files, or integration/judgment across existing code, but still one
     coherent, single-sitting deliverable.
   - If a unit still doesn't fit `medium` after a split pass, split again — down to a
     single plan Step if needed. If one already-indivisible Step still reads as exceeding
     `medium` (rare), stop splitting and force it into `medium`, adding a flagged note to
     the ticket body: `⚠️ exceeds typical medium scope; could not be split further
     without breaking a single plan step — consider revising the source plan.`
     `large`/`hard` is never a valid complexity label — this forced case is the one
     exception, and it must always be visibly flagged, never silent.
4. **Classify task nature**: `text` (docs/copy/config-only), `mechanical` (isolated,
   fully spec'd code change), or `judgment` (multi-file integration, design decisions not
   fully spelled out) — from file extensions and step content.
5. **Assign a model tier**: cross complexity × task-nature against
   `references/model-tiers.md` to get the `model-tier:<tier>` label. Never name a
   specific model or vendor.
6. **Compute dependencies**: ticket B depends on ticket A when B's steps read/modify a
   file A creates, or the plan's own ordering makes B build on A's output. Tickets with
   no file/content overlap and no ordering requirement are independent — no dependency
   edge between them.
7. **Compute priority**: `p1` for tickets on the critical path or blocking multiple
   others, `p2` for normal work, `p3` for optional/polish/cleanup work the plan or spec
   calls out as such.

### 3. Build the ticket-plan JSON

Write a JSON file (e.g. to a scratch/temp path) matching this schema:

```json
{
  "repo": "owner/repo",
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

`tickets` **must** be in dependency order: every `depends_on_slugs` entry must name a
slug that appears *earlier* in the array. `repo` is optional (the script falls back to
the current repo).

### 4. Check for existing similar issues

The script's own idempotency (step 6) only recognizes issues *this skill created itself*
— it finds them by a hidden marker comment. It has no way to notice a manually-filed
issue, an issue from an unrelated plan, or a leftover from an earlier, differently
decomposed run of this same plan. Before previewing, check whether anything already
covers a candidate ticket:

```bash
gh issue list --repo <owner/repo> --state open --json number,title,url --limit 200
```

For each candidate ticket in the JSON you just built, use judgment — not a fixed keyword
rule — to compare its intent against these existing open issues. Look for issues that
plausibly cover the *same concrete piece of work*, not just superficial word overlap.
Flag anything you're not sure about rather than silently deciding either way, e.g.:

> ⚠️ possible existing duplicate: candidate ticket "Add API endpoint for user records"
> may overlap with existing #142 "Implement REST API for user records".

Carry any flags into the preview in step 5 and have the human resolve each one
explicitly: drop the candidate ticket and depend on/reference the existing issue
instead, keep both because they're actually different pieces of work, or link them as
related. **Never auto-skip or auto-merge a candidate based on this check alone** — it
surfaces a decision for the human, it doesn't make one. This check only applies to
tickets; the epic itself is already covered by its own marker-based lookup.

### 5. Preview and confirm before filing anything

Filing GitHub issues is a visible, shared-state action. Run the script in `--dry-run`
mode against the ticket-plan JSON:

```bash
skills/coding/plan-to-tickets/scripts/create-tickets.sh --input <ticket-plan.json> --dry-run
```

This both validates the JSON (invalid JSON, missing fields, or an out-of-order
dependency all fail here with a clear error) and confirms exactly what would be created
or updated. Render a human-readable table from the ticket-plan JSON itself — ticket
title, complexity, task nature, model tier, priority, dependencies, and any possible-
duplicate flag from step 4 — for the whole backlog (epic + every ticket), and ask the
user to confirm. If they request changes (re-bucket a ticket, change a tier, change
priority, drop a flagged duplicate), edit the ticket-plan JSON and re-run `--dry-run`
before proceeding. **Do not run the script for real until the user confirms.**

### 6. File the backlog

Once confirmed, run without `--dry-run`:

```bash
skills/coding/plan-to-tickets/scripts/create-tickets.sh --input <ticket-plan.json>
```

Report the epic issue link, every ticket's issue link, and the path to the manifest the
script writes (`docs/superpowers/tickets/<plan-slug>.md`). Re-running this skill against
the same plan later (e.g. after editing it) updates the same epic/tickets in place —
it will not create duplicates.

## Flags (`scripts/create-tickets.sh`)

| Flag | Effect |
|------|--------|
| `--input <file>` | Ticket-plan JSON (required) |
| `--repo <owner/repo>` | Target repo (default: `.repo` in the JSON, or current repo) |
| `--dry-run` | Print every planned `gh` call; apply nothing |

See `references/model-tiers.md` for the complexity × task-nature → model-tier table.
