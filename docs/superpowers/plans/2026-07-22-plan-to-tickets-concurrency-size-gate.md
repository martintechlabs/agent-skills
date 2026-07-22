# plan-to-tickets Concurrency + Size Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update `plan-to-tickets` so agents maximize concurrency and minimize merge conflicts when building the ticket graph, and require early user confirmation when decomposition produces more than 20 tickets.

**Architecture:** Procedure-only change in `skills/coding/plan-to-tickets/SKILL.md`. No script or JSON-schema changes. Decomposition rules gain explicit concurrency objectives, a file/output-only dependency rule (including same-file hard deps), and a new size-gate step between building the ticket-plan JSON and the existing-issue overlap check. Existing `create-tickets.sh` tests remain the regression net that scripts were not touched.

**Tech Stack:** Markdown skill procedure; existing Bash test harness for `create-tickets.sh` (untouched code path).

## Global Constraints

- Skill-procedure change only; do not modify `scripts/create-tickets.sh`, `tests/run.sh`, or `references/model-tiers.md`.
- No new ticket-plan JSON fields (e.g. no `files_touched`).
- No soft-conflict labels; same-file co-edit is a hard dependency.
- No hard cap that silently re-merges tickets to force ≤20.
- Dependency edges: file create/read-modify, same-file modify, or named outputs only — never plan order alone.
- Size gate: `len(tickets) > 20` only (exactly 20 does not trip); fire after decomposition and after ticket-plan JSON is built, before overlap check and dry-run.
- Bump skill metadata version to `"0.3.0"`.
- Preserve existing merge/split complexity rules, model-tier assignment, idempotent filing, and final dry-run confirm gate.
- Spec source of truth: `docs/superpowers/specs/2026-07-22-plan-to-tickets-concurrency-size-gate-design.md`.

---

## File Structure

- `skills/coding/plan-to-tickets/SKILL.md` — sole implementation surface for agent procedure.
- `docs/superpowers/plans/2026-07-22-plan-to-tickets-concurrency-size-gate.md` — this plan.
- `docs/superpowers/specs/2026-07-22-plan-to-tickets-concurrency-size-gate-design.md` — already committed design; do not re-litigate.

### Task 1: Rewrite SKILL.md procedure for concurrency, deps, size gate

**Files:**
- Modify: `skills/coding/plan-to-tickets/SKILL.md`

**Interfaces:**
- Consumes: existing ticket-plan JSON schema and `create-tickets.sh` flags (unchanged).
- Produces: agent procedure v0.3.0 with concurrency objectives, hard same-file deps, file/output-only edges, and early >20 size gate.

- [ ] **Step 1: Bump metadata version**

In the YAML frontmatter, change:

```yaml
  version: "0.2.0"
```

to:

```yaml
  version: "0.3.0"
```

- [ ] **Step 2: Replace the entire `### 2. Decompose plan Tasks into tickets` section**

Replace from the heading `### 2. Decompose plan Tasks into tickets` through the end of item 7 (the priority bullet), inclusive, with:

```markdown
### 2. Decompose plan Tasks into tickets

**Objectives while building the ticket graph:**

1. **Maximize concurrency** — Prefer splits along file/component seams so
   independent tickets share no modify set and carry no false dependency edges.
2. **Minimize merge conflicts** — Tickets that would both modify the same path
   are not parallel-safe; serialize them with a hard dependency.
3. **Keep tickets right-sized** — Existing merge-tiny / split-oversized /
   small|medium rules stay in force. Concurrency is not a reason to keep
   oversized tickets or invent `large`/`hard` complexity labels.

For each Task, compute a raw signal:

- **File count** touched (`Create`/`Modify`/`Test` paths under `Files:`).
- Whether steps are fully **mechanical** (code given verbatim, matching `writing-plans`'
  "no placeholders" bar) or require **judgment** (an outcome described without full code,
  multiple existing subsystems touched, or code not shown in the task).

Classify each raw Task as tiny / right-sized / oversized, then:

1. **Merge** adjacent tiny Tasks that touch the same file/component and have no
   independent shippable value into one ticket. Prefer merging adjacent tinies that
   touch the **same** file (they would only serialize anyway). Never merge across
   unrelated components merely to reduce ticket count or to force a prettier
   parallel graph.
2. **Split** oversized Tasks along natural seams — the `Files:` boundary or
   independently testable step groups. Prefer the `Files:` boundary when both
   resulting tickets stay ≤ medium and no longer share a modify set. Repeat until
   every resulting unit fits the complexity bound below.
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
6. **Compute dependencies** — ticket B depends on ticket A **only** when at least
   one of the following is true:
   - B’s steps **read or modify a file A creates**, or
   - B’s steps **modify a file A also modifies** (same-file co-edit → hard serialize), or
   - B’s steps **clearly consume a named output** A produces (API, type, symbol,
     config key, or equivalent named in both scopes).

   **Not** a dependency: plan list order alone; vague relatedness without a
   file/named-output edge; shared **read** of a pre-existing file that neither ticket
   creates and that does not couple their edits.

   When same-file co-edit requires serialization, order among the shared-file set
   follows **plan order** (the ticket whose scope appears earlier in the plan is the
   dependency of the later one). Never leave two tickets independent if they both
   modify the same path.
7. **Compute priority**:
   - **p1** — on the critical path (longest chain of hard deps) **or** blocks
     multiple other tickets
   - **p2** — normal parallelizable work
   - **p3** — optional/polish/cleanup work the plan or spec calls out as such
```

- [ ] **Step 3: Insert the size-gate step and renumber the rest**

After `### 3. Build the ticket-plan JSON` (the whole section including the schema and the paragraph about dependency order), insert a new step **before** the current “Check for existing similar issues” section. Then renumber:

| Old | New |
|-----|-----|
| 3 Build the ticket-plan JSON | 3 (unchanged number, same content) |
| *(new)* | **4. Size gate when ticket count > 20** |
| 4 Check for existing similar issues | **5** |
| 5 Preview and confirm before filing anything | **6** |
| 6 File the backlog | **7** |

Insert this as the new step 4 (exact text):

```markdown
### 4. Size gate when ticket count > 20

After decomposition and after the ticket-plan JSON exists, count the tickets.

- If `len(tickets) ≤ 20`, skip this gate and continue to step 5.
- If `len(tickets) > 20` (exactly 20 does **not** trip), **stop** and ask the user
  **before** any `gh issue list`, `--dry-run`, or filing:

  > This plan decomposes into **N** tickets (over 20). Proceed with N, or
  > re-merge/split toward fewer?

User outcomes:

- **Proceed with N** → continue to step 5 (overlap check → dry-run preview → file).
- **Re-merge / re-split** → revise the ticket graph and ticket-plan JSON; re-count;
  if still `> 20`, run this gate again.
- **Other guidance** (cap, merge specific pairs, etc.) → apply it; re-gate if still
  `> 20`.

Do **not** silently re-merge tickets to force ≤20. This gate is agent-enforced
procedure only — the script does not enforce it.
```

- [ ] **Step 4: Fix cross-step references after renumber**

In the renumbered sections, update every internal step reference:

1. In **step 5** (was 4, existing similar issues):
   - Change `step 6` → `step 7` in the sentence about the script’s own idempotency.
   - Change `preview in step 5` → `preview in step 6`.

2. In **step 6** (was 5, preview):
   - Change `duplicate flag from step 4` → `duplicate flag from step 5`.
   - After the sentence that lists the preview table columns, add this sentence:

```markdown
Optionally include a one-line concurrency summary (e.g. count of independent
roots and critical-path length) so over-serialization is visible — no JSON schema
change required for that summary.
```

3. Confirm step 7 (file the backlog) still points at the same `create-tickets.sh` command without `--dry-run`.

- [ ] **Step 5: Sanity-check the finished SKILL.md**

Confirm all of the following by reading the file:

- Frontmatter `version` is `"0.3.0"`.
- Procedure headings are exactly: 1 Read…, 2 Decompose…, 3 Build…, 4 Size gate…, 5 Check for existing…, 6 Preview…, 7 File….
- Step 2 item 6 no longer says “the plan’s own ordering makes B build on A’s output” as a standalone dependency rule.
- Step 2 states same-file co-edit is a hard dependency.
- Step 4 uses `> 20` (not `≥ 20`).
- No remaining references to old step numbers for overlap/preview/file.
- JSON schema block is unchanged (no new fields).

- [ ] **Step 6: Run existing create-tickets tests (regression: scripts untouched)**

Run:

```bash
skills/coding/plan-to-tickets/tests/run.sh
```

Expected: all tests pass (exit 0). If anything fails, stop — scripts should not have been modified; investigate accidental edits.

- [ ] **Step 7: Commit**

```bash
git add skills/coding/plan-to-tickets/SKILL.md
git commit -m "$(cat <<'EOF'
plan-to-tickets: concurrency objectives and >20 size gate

Hard-dep same-file co-edits, file/output-only dependency edges, and early
user confirm when decomposition exceeds 20 tickets.
EOF
)"
```

---

## Self-review (plan vs spec)

| Spec requirement | Task coverage |
|------------------|---------------|
| Maximize concurrency / minimize merge conflicts as objectives | Task 1 Step 2 |
| Same-file co-edit → hard dep (plan order among set) | Task 1 Step 2 item 6 |
| Deps = create/read-modify, same-file modify, named outputs only | Task 1 Step 2 item 6 |
| Not plan-order-only deps; shared read parallel-safe | Task 1 Step 2 item 6 |
| Prefer Files: split; merge same-file tinies | Task 1 Step 2 items 1–2 |
| Critical-path-aware p1/p2/p3 | Task 1 Step 2 item 7 |
| Early size gate after decompose, before overlap/dry-run | Task 1 Step 3 |
| `> 20` only; re-gate after re-decomposition; no silent re-merge | Task 1 Step 3 |
| Optional concurrency summary at final preview | Task 1 Step 4 |
| No script/JSON schema changes | Global Constraints + Task 1 Steps 5–6 |
| Version bump 0.3.0 | Task 1 Step 1 |

Placeholder scan: none. Type/name consistency: N/A (docs-only).
