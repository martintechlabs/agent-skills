# plan-to-tickets — Concurrency objectives + ticket-count size gate

**Date:** 2026-07-22
**Category:** `coding`
**Status:** Approved design
**Amends:** `docs/superpowers/specs/2026-07-18-plan-to-tickets-design.md`

## Purpose

Tighten `plan-to-tickets` so ticket decomposition, priorities, and the dependency
graph deliberately **maximize concurrency** while **minimizing merge conflicts**,
and so a large backlog (**more than 20 tickets**) requires an **early human
confirm** before overlap checks, dry-run, or filing.

This is a skill-procedure change only (Approach 1). The bundled
`scripts/create-tickets.sh` JSON schema and mechanics are unchanged.

## Non-goals

- No new ticket-plan JSON fields (e.g. `files_touched`).
- No new script flags or graph validators in `create-tickets.sh`.
- No soft-conflict labels or preview-only “risk” edges as a substitute for
  same-file hard dependencies.
- No hard cap that silently re-merges tickets to force ≤20.
- Does not change `execute-tickets`, `epic-manager`, or model-tier mapping.

## Goals

While building the ticket graph, the agent must:

1. **Maximize concurrency** — Prefer splits along file/component seams so
   independent tickets share no modify set and carry no false dependency edges.
2. **Minimize merge conflicts** — Tickets that would both modify the same path
   must not be treated as parallel-safe; serialize them with a hard dependency.
3. **Keep tickets right-sized** — Existing merge-tiny / split-oversized /
   small|medium rules remain in force. Concurrency is not a reason to keep
   oversized tickets or invent `large`/`hard` complexity labels.

## Dependency rule (replaces plan-order-or-file wording)

Ticket **B** depends on ticket **A** only when at least one of the following is true:

- B’s steps **read or modify a file A creates**, or
- B’s steps **modify a file A also modifies** (same-file co-edit → hard serialize), or
- B’s steps **clearly consume a named output** A produces (API, type, symbol,
  config key, or equivalent named in both scopes).

**Not** a dependency:

- Plan list order alone
- Vague relatedness without a file or named-output edge
- Shared **read** of a pre-existing file that neither ticket creates and that does
  not couple their edits (both only read the same upstream file is parallel-safe)

When same-file co-edit requires serialization, order among the shared-file set
follows **plan order** (the ticket whose scope appears earlier in the plan is
the dependency of the later one).

## Split / merge under concurrency

- Prefer split at `Files:` boundaries when both resulting tickets stay ≤ medium
  and no longer share a modify set.
- Prefer merge of adjacent tinies that touch the **same** file (they would only
  serialize and have no independent shippable value).
- Never merge unrelated components merely to reduce ticket count or to force a
  prettier parallel graph.
- Never leave two tickets independent if they both modify the same path.

## Priority (concurrency-aware critical path)

Unchanged labels; make the critical-path read explicit:

- **p1** — On the critical path (longest chain of hard deps) **or** blocks
  multiple other tickets
- **p2** — Normal parallelizable work
- **p3** — Optional / polish / cleanup the plan or spec calls out as such

Priority remains a proposal, adjustable at the final preview gate.

## Early ticket-count size gate

**When:** Immediately after decomposition (merge/split/classify/deps/priority)
and **before** the existing-issue overlap check and `--dry-run` preview.

**Predicate:** `len(tickets) > 20` (exactly 20 does **not** trip the gate).

**Behavior:** Stop and ask the user, e.g.:

> This plan decomposes into **N** tickets (over 20). Proceed with N, or
> re-merge/split toward fewer?

**User outcomes:**

| Response | Next step |
|----------|-----------|
| Proceed with N | Continue to overlap check → dry-run → full preview → file |
| Re-merge / re-split | Revise the ticket graph; re-count; if still > 20, gate again |
| Other guidance (cap, merge specific pairs, etc.) | Apply guidance; re-gate if still > 20 |

If `len(tickets) ≤ 20`, skip this gate and continue with the existing overlap
check and dry-run preview.

This gate is agent-enforced procedure only — not script-enforced.

## Final preview (unchanged requirement)

Filing still requires the existing dry-run + human confirmation. Optionally
include a one-line concurrency summary (e.g. count of independent roots /
critical-path length) in the preview table so over-serialization is visible.
No schema change required for that summary.

## Files to change (implementation)

| File | Change |
|------|--------|
| `skills/coding/plan-to-tickets/SKILL.md` | Rewrite dependency + concurrency rules in decompose step; insert size-gate step before overlap check; renumber subsequent steps; bump metadata version (e.g. `0.3.0`). |
| This design doc | Source of truth for the amendment |

**Unchanged:** `scripts/create-tickets.sh`, its tests, `references/model-tiers.md`,
sibling skills.

## Success criteria

- Agent emits hard deps only for file/create/modify and named-output edges,
  including same-file modify serialization.
- Agent does not invent dependencies from plan order alone.
- Agent asks before overlap/dry-run when ticket count > 20, and re-gates after
  re-decomposition if still over the threshold.
- Existing `create-tickets.sh` tests continue to pass without modification.

## Testing notes

Procedure-only change. Implementation may verify with a manual or
pressure-style scenario (many same-file tinies + multi-file independent work +
high ticket count). No new bash harness requirement for this amendment.
