# Optimize AGENTS.md Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework the (currently untracked, uncommitted) `bootstrap-agents-md` skill into `optimize-agents-md` — a skill that audits and patches an existing AGENTS.md for a fast, safe SDLC (aligned with superpowers disciplines), falls back to from-scratch generation only when no AGENTS.md exists, keeps CLAUDE.md as a thin pointer, and splits overgrown files into linked docs.

**Architecture:** This is a documentation/prompt skill, not executable code — there's no application logic to unit test. The "implementation" is entirely: (1) git-tracking and renaming the skill directory, (2) rewriting `SKILL.md`'s frontmatter and body to match the approved design spec, (3) registering the skill in the repo's own index (`README.md`, `skills.sh.json`), and (4) verifying the rewritten skill actually produces correct behavior by running it against a synthetic scratch repo via a subagent — this is the skill-equivalent of "run the test and watch it pass" (see `superpowers:writing-skills`'s testing-by-application-scenario guidance for technique skills).

**Tech Stack:** Markdown (SKILL.md, README.md), JSON (skills.sh.json), git.

**Spec:** `docs/superpowers/specs/2026-07-12-optimize-agents-md-design.md` (already committed on this branch).

---

### Task 1: Track and rename the skill directory

**Files:**
- Modify (git mv): `skills/coding/bootstrap-agents-md/` → `skills/coding/optimize-agents-md/`
- Delete: `skills/coding/optimize-agents-md/README.md`

The `bootstrap-agents-md` directory is currently untracked in git (it was copied in during this session but never committed). It must be `git add`ed before it can be `git mv`ed.

- [ ] **Step 1: Confirm current state**

Run: `git status`
Expected: on branch `optimize-agents-md`, with `skills/coding/bootstrap-agents-md/` listed as an untracked directory containing `.DS_Store`, `README.md`, `SKILL.md`, `references/templates.md`.

- [ ] **Step 2: Remove the stray .DS_Store**

Run: `rm skills/coding/bootstrap-agents-md/.DS_Store`

- [ ] **Step 3: Track the directory, then rename it**

```bash
git add skills/coding/bootstrap-agents-md/
git mv skills/coding/bootstrap-agents-md skills/coding/optimize-agents-md
```

- [ ] **Step 4: Delete the redundant README**

```bash
git rm skills/coding/optimize-agents-md/README.md
```

- [ ] **Step 5: Verify directory contents**

Run: `ls skills/coding/optimize-agents-md/ skills/coding/optimize-agents-md/references/`
Expected: `SKILL.md` and `references/` in the first listing, `templates.md` in the second. No `README.md`, no `.DS_Store`.

- [ ] **Step 6: Commit**

```bash
git commit -m "Rename bootstrap-agents-md to optimize-agents-md, drop redundant README"
```

---

### Task 2: Rewrite SKILL.md

**Files:**
- Modify: `skills/coding/optimize-agents-md/SKILL.md` (full rewrite)

- [ ] **Step 1: Write the complete new SKILL.md**

Replace the entire file content with:

```markdown
---
name: optimize-agents-md
description: Audit and patch a repo's AGENTS.md for a fast, safe SDLC — filling gaps and fixing stale or conflicting sections in an existing file rather than replacing it, falling back to generating one from scratch only if none exists. Checks that autonomy, validation, and subagent policies reinforce rather than undercut TDD, brainstorming-before-creative-work, verification-before-completion, and subagent dispatch, and splits an overgrown file into linked docs/ reference material. Also collapses CLAUDE.md to a one-line pointer (@AGENTS.md), plus a superpowers tie-in note when that plugin is active. Use when auditing, optimizing, or filling gaps in an AGENTS.md, checking it plays well with superpowers/TDD/subagents, reconciling CLAUDE.md with AGENTS.md, or setting one up for a repo that has none — including the /optimize-agents-md command.
metadata:
  author: stephen-martin
  version: "0.1.0"
---

# Optimize AGENTS.md

Audit an existing AGENTS.md and patch its gaps — or generate one from scratch if none exists — so coding agents operate with high autonomy, smart defaults, and strong repo-specific guardrails, in a way that actively speeds up the SDLC rather than just reading as "autonomy-friendly." Keep CLAUDE.md as a thin pointer to AGENTS.md rather than a second copy of the rules.

## Triggers

- "audit my AGENTS.md"
- "optimize AGENTS.md for this repo"
- "is my AGENTS.md any good?"
- "fill gaps in AGENTS.md"
- "make sure my AGENTS.md plays well with superpowers"
- "reconcile CLAUDE.md and AGENTS.md"
- "set up AGENTS.md for this repo"
- "bootstrap agent rules for this project"
- "/optimize-agents-md"

## Instructions

1. Locate every AGENTS.md in the repo (root and nested), and check whether a sibling CLAUDE.md exists at each directory level.

2. If no AGENTS.md exists anywhere, generate one from scratch (fallback path):
   - Inspect the repo: read `package.json`, workspace config, lockfiles, top-level app/package folders, framework config, test config, database config, and key docs. Detect the package manager, runtime, framework, test stack, database layer, monorepo shape, and deployment tooling.
   - Infer the operating model: does the codebase favor fast iteration, safety, strong typing, TDD, heavy CI, or infra caution? Reuse project terminology and existing command names.
   - Generate a root AGENTS.md using the Output template below.
   - Add nested AGENTS.md files when the repo is a monorepo, different apps use different frameworks/commands, or a package has special testing/build/deployment constraints.
   - Skip to step 7 for the CLAUDE.md pass.

3. If an AGENTS.md exists, audit it. Classify every section from the canonical checklist — Operating mode, Autonomy policy, Decision rules, Subagent policy, Validation strategy, Package manager commands, Testing guidance, Environment variable rules, Database and migration safety, Implementation guidelines, Review checklist, References — as one of:
   - **Adequate** — present, specific to this repo, matches current tooling.
   - **Thin/generic** — present but boilerplate, doesn't reflect this repo's actual commands/conventions.
   - **Missing** — section absent entirely.
   - **Stale** — references tooling, commands, or files that no longer match the repo (e.g. mentions `yarn` but the repo now has `pnpm-lock.yaml`).
   - **Conflicting** — the section's own words work against a fast, safe SDLC (see Heuristics → Superpowers alignment).

4. Re-inspect the repo (same detection as the fallback path) so any proposed addition or edit is grounded in what's actually there, not assumed.

5. Patch, don't rewrite. For sections classified thin/generic, missing, or stale, propose a targeted addition or edit scoped to just that section — leave adequate sections untouched. Flag stale sections explicitly (what's stale, why, what it should say now). Flag conflicting sections with the specific discipline they undercut and a proposed rewording — never silently override a rule the user may have written on purpose.

6. Check length; propose doc-splitting if needed. If the file (root or nested) has grown long, or a section is dominated by reference material rather than day-to-day decision guidance, propose extracting that material to a linked doc — see Heuristics → Length and reference-doc splitting — and leave a short summary + link in its place. Never split silently.

7. Reconcile CLAUDE.md at every directory level touched — see Heuristics → CLAUDE.md pointer hygiene for the exact pointer content and when the superpowers tie-in line applies.

8. Escalate only when essential. Ask targeted questions only for things that can't be inferred. Good examples:
   - "Should migrations require explicit approval?"
   - "Do you want nested AGENTS.md files per app/package?"
   - "Should dependency additions require approval or just major deps?"

9. Produce output in this order:
   - A section-by-section audit table (adequate / thin / missing / stale / conflicting) for each AGENTS.md found, plus CLAUDE.md pointer status per directory.
   - The proposed patch — only the sections being added or changed, not a full file dump, unless most sections are missing (then show the full proposed file). Include any proposed doc-splitting.
   - Nested-file findings, if monorepo.
   - A note on what was inferred vs. explicitly confirmed.

## Heuristics

### Package manager
- If `pnpm-lock.yaml` exists, use pnpm only.
- If `packageManager` is pinned in `package.json`, follow it strictly.
- Never mention alternative package managers unless the repo uses them.

### Monorepo detection
Treat as a monorepo if any of these exist:
- `pnpm-workspace.yaml`
- `turbo.json`
- `nx.json`
- `apps/` and `packages/` at the repo root

### Testing
- Prefer targeted tests before full suites.
- Reuse existing test commands from `package.json`.
- If coverage gates exist, mention them.
- If test patterns differ by app/package, push those rules into nested AGENTS.md files.

### Database
- If migrations exist, treat them as approval-gated by default.
- If ORM/tooling is present, name the actual files and commands.
- Prefer additive schema changes over destructive ones.

### Environment variables
- Require `.env.example` when the project uses env vars.
- Require new env vars to be documented in the same change.
- Never allow secrets to be committed.

### Subagents
Use subagents by default for:
- repo exploration
- implementation planning
- frontend/backend split work
- test writing
- review and validation

Avoid subagents for:
- tiny one-file edits
- tightly coupled debugging
- trivial text changes

### Staleness
- Cross-check every concrete command, file path, and tool name mentioned in AGENTS.md against what's actually in the repo right now.
- Flag anything that names a package manager, framework, test runner, or file that isn't present, or that conflicts with a lockfile/config that says otherwise.
- Don't guess *why* it's stale (renamed dependency vs. abandoned tooling) — just flag it and let the user confirm the fix.

### Superpowers alignment
The point of this category is speed with safety: every check here exists because getting it wrong makes the SDLC *slower*, not just messier.

- **Autonomy policy vs. TDD/verification** — flag language that tells the agent to skip tests, skip confirming its own work, or treat "fast" as an excuse to not verify. TDD and verification-before-completion exist to catch regressions before they compound into slower rework later.
- **Validation strategy vs. real commands** — the Validation strategy section should name this repo's actual test/build/typecheck commands (not "run tests" as a generic phrase), so the TDD loop and verification-before-completion have something concrete to execute.
- **Subagent policy vs. dispatch patterns** — flag a blanket "don't use subagents" or "always work solo" rule. Naming specific tasks that shouldn't be delegated (tightly coupled debugging, tiny edits) is fine; an absolute ban that blocks legitimately parallelizable work is not.
- **Decision rules vs. brainstorming** — flag instructions that push the agent to start implementing ambiguous/creative work immediately with no room for clarifying questions or a design step first.
- Don't invent a superpowers reference inside AGENTS.md itself to fix these — AGENTS.md stays tool-agnostic. Reword the policy in generic terms ("write a test before implementing," "run the full suite before declaring done") that satisfy the discipline either way.

### Length and reference-doc splitting
AGENTS.md is read on every run — it stays useful only if it stays short enough that the agent actually reads and follows it.

- **Trigger:** the file (root or nested) has grown long overall, or a section is dominated by reference material — exhaustive command lists, full API/config docs, long tables — rather than the handful of decisions an agent needs on a normal run.
- **Where extracted docs go:** reuse the repo's existing `docs/` directory and its subfolder conventions if one exists. If there's no `docs/` directory at all, create `docs/agents/<topic>.md`.
- **What stays inline:** a short summary plus a link, e.g. "See `docs/agents/testing.md` for the full test matrix." The summary must still carry the actual decision-relevant guidance — splitting moves *reference* material out, not the guidance itself.
- Distinct from nested AGENTS.md files: nested files carry different *operating rules* for a different app/package; doc-splitting carries *reference material* out of one file that's grown too long.
- Always a proposal, never silent.

### CLAUDE.md pointer hygiene
- AGENTS.md is always the canonical file; CLAUDE.md is never a second place to maintain rules.
- A CLAUDE.md that is anything other than the pointer below (plus optional Claude-Code-only content the user explicitly wants kept separate) is a hygiene finding, not silently rewritten without being called out.
- Default pointer:
  ```
  @AGENTS.md
  ```
- When superpowers is active this session (its skills, e.g. `superpowers:using-superpowers`, appear in the available-skills list), append one line:
  ```
  @AGENTS.md

  This repo's AGENTS.md is written to align with the superpowers skill system (TDD, brainstorming, verification-before-completion, systematic-debugging, subagent dispatch) — no separate instructions needed here.
  ```
- If superpowers isn't active this session, don't add the line — leave CLAUDE.md as the bare pointer.
- If CLAUDE.md already exists with real content: diff it against AGENTS.md first. Anything present only in CLAUDE.md gets folded into the AGENTS.md patch (step 5). Genuine contradictions (not just gaps) are flagged for the user instead of auto-resolved. Only after that collapse CLAUDE.md to the pointer above.

## Output template

Use this structure when generating a root AGENTS.md from scratch (fallback path):

1. Framework/runtime warning block if needed
2. Operating mode
3. Autonomy policy
4. Decision rules
5. Subagent policy
6. Validation strategy
7. Package manager
8. Testing
9. Environment variables
10. Database
11. Implementation guidelines
12. Review checklist
13. References

## Quality bar

A good result:
- sounds like it belongs to this repo,
- uses real commands from the repo,
- allows autonomous work,
- uses subagents intelligently,
- avoids generic fluff,
- keeps risky actions gated,
- is short enough that agents will actually follow it,
- preserves the existing file's structure and voice where it's already good — patches don't rewrite what isn't broken,
- never silently deletes existing guardrails; removals are flagged, not assumed,
- never lets CLAUDE.md and AGENTS.md drift out of sync — one is always a pointer to the other,
- optimizes for a fast *and* safe SDLC — autonomy, validation, and subagent policies reinforce TDD, brainstorming-before-creative-work, verification-before-completion, and subagent dispatch rather than quietly undercutting them,
- stays short enough to actually be read every run — heavy reference material lives in linked docs, not inline.

## Example invocations

User: "Audit my AGENTS.md"
User: "Is my AGENTS.md any good?"
User: "Optimize AGENTS.md for this repo"
User: "Fill gaps in AGENTS.md"
User: "Make sure my AGENTS.md works well with superpowers/TDD/subagents"
User: "Reconcile CLAUDE.md and AGENTS.md"
User: "Set up AGENTS.md for this repo"
User: "Create autonomous agent rules for this pnpm monorepo"
User: "/optimize-agents-md"
```

- [ ] **Step 2: Verify frontmatter is well-formed**

Run: `head -8 skills/coding/optimize-agents-md/SKILL.md`
Expected: `---`, then `name: optimize-agents-md`, `description: ...` (one unbroken line), `metadata:`, `  author: stephen-martin`, `  version: "0.1.0"`, `---`.

- [ ] **Step 3: Verify description length is under the 1024-char frontmatter budget**

Run: `awk '/^description:/{print length($0)}' skills/coding/optimize-agents-md/SKILL.md`
Expected: a number under 1024 (the `name`/`metadata` fields are tiny, so the description line alone is the binding constraint).

- [ ] **Step 4: Verify no stale step-numbering or references survived from the old file**

Run: `grep -n "step 5\|step 6\|step 7" skills/coding/optimize-agents-md/SKILL.md`
Expected: only the intentional cross-references inside the Instructions numbered list itself (step 7 mentioned once in step 2's fallback path, matching the actual step 7 CLAUDE.md heading).

- [ ] **Step 5: Commit**

```bash
git add skills/coding/optimize-agents-md/SKILL.md
git commit -m "Rewrite optimize-agents-md as an audit/patch skill aligned with superpowers SDLC disciplines"
```

---

### Task 3: Register the skill in the repo's index

**Files:**
- Modify: `skills.sh.json:26-34` (the `"Coding"` grouping)
- Modify: `README.md:54-62` (the `### Coding` section)

- [ ] **Step 1: Add to skills.sh.json**

In `skills.sh.json`, change the `"Coding"` grouping's `skills` array from:

```json
      "skills": [
        "consult-codex",
        "codex-review",
        "ship-ready-pr-loop"
      ]
```

to:

```json
      "skills": [
        "consult-codex",
        "codex-review",
        "ship-ready-pr-loop",
        "optimize-agents-md"
      ]
```

- [ ] **Step 2: Verify JSON is still valid**

Run: `python3 -m json.tool skills.sh.json > /dev/null && echo OK`
Expected: `OK`

- [ ] **Step 3: Add a row to README.md's Coding table**

In `README.md`, after the `ship-ready-pr-loop` row (currently the last row of the `### Coding` table), add:

```markdown
| [`optimize-agents-md`](skills/coding/optimize-agents-md/SKILL.md) | Audits and patches a repo's AGENTS.md for a fast, safe SDLC — reinforcing TDD, brainstorming, verification, and subagent dispatch — generating one from scratch only if none exists, and keeps CLAUDE.md as a one-line pointer to it. |
```

- [ ] **Step 4: Verify the table row renders correctly**

Run: `grep -n "optimize-agents-md" README.md`
Expected: one match, inside the `### Coding` table (between the `ship-ready-pr-loop` row and the `### DevOps` heading).

- [ ] **Step 5: Commit**

```bash
git add skills.sh.json README.md
git commit -m "Register optimize-agents-md in the repo's skill index"
```

---

### Task 4: Verify the rewritten skill actually works

**Files:**
- Create (scratch, not committed): a synthetic sample repo under the scratchpad directory
- No repo files modified in this task unless Step 3 surfaces a real gap in SKILL.md

This is a documentation/prompt skill — there's no unit-testable code. The equivalent of "run the test and watch it pass" is: give a fresh subagent (no memory of this conversation or the design process) a synthetic repo with a thin, generic AGENTS.md, tell it to use the `optimize-agents-md` skill on it, and check the output actually matches what the skill promises — an audit table, a scoped patch (not a full rewrite), correct CLAUDE.md handling, and a superpowers-alignment finding if the sample file has an autonomy-vs-TDD conflict baked in.

- [ ] **Step 1: Build a synthetic scratch repo**

```bash
mkdir -p /private/tmp/claude-501/-Users-smartin-Projects-mtl-agent-skills/6f2d68eb-a860-468e-85e8-c2d112ab037a/scratchpad/sample-repo
cd /private/tmp/claude-501/-Users-smartin-Projects-mtl-agent-skills/6f2d68eb-a860-468e-85e8-c2d112ab037a/scratchpad/sample-repo
cat > package.json <<'EOF'
{
  "name": "sample-repo",
  "packageManager": "pnpm@9.0.0",
  "scripts": {
    "test": "vitest run",
    "build": "tsc -b"
  }
}
EOF
touch pnpm-lock.yaml
cat > AGENTS.md <<'EOF'
# AGENTS.md

Work fast. Don't waste time writing tests before shipping — just get the
feature in and we'll add tests later if it breaks.

Never use subagents, always do everything yourself in one thread.
EOF
cat > CLAUDE.md <<'EOF'
Work fast. Don't waste time writing tests before shipping — just get the
feature in and we'll add tests later if it breaks. Also: use yarn for
installs.
EOF
cd -
```

Expected: no errors; `ls /private/tmp/claude-501/-Users-smartin-Projects-mtl-agent-skills/6f2d68eb-a860-468e-85e8-c2d112ab037a/scratchpad/sample-repo` shows `package.json`, `pnpm-lock.yaml`, `AGENTS.md`, `CLAUDE.md`.

This sample deliberately has: a Conflicting Autonomy policy (discourages tests), a Conflicting Subagent policy (blanket ban), a CLAUDE.md with content not in AGENTS.md (yarn mention — also Stale, since the repo uses pnpm), and everything else Missing.

- [ ] **Step 2: Dispatch a fresh subagent to run the skill against it**

Use the Agent tool (`subagent_type: "general-purpose"`) with this prompt:

```
Load the optimize-agents-md skill from
/Users/smartin/Projects/mtl/agent-skills/skills/coding/optimize-agents-md/SKILL.md
(use the Skill tool if it's registered in your environment; otherwise Read
the file directly and follow its Instructions exactly).

Apply it to the repo at
/private/tmp/claude-501/-Users-smartin-Projects-mtl-agent-skills/6f2d68eb-a860-468e-85e8-c2d112ab037a/scratchpad/sample-repo/
(files: package.json, pnpm-lock.yaml, AGENTS.md, CLAUDE.md).

Produce the skill's full output: the section-by-section audit table, the
proposed patch, and the CLAUDE.md reconciliation. Do not modify any files —
just report what you would propose. Return the full output as your final
message.
```

- [ ] **Step 3: Review the subagent's output against these checks**

- [ ] Audit table classifies the Autonomy policy section as **Conflicting** (discourages tests) — not silently accepted as "adequate."
- [ ] Audit table classifies the Subagent policy content as **Conflicting** (blanket ban) — not silently accepted.
- [ ] Audit table flags the CLAUDE.md `yarn` mention as **Stale** (repo has `pnpm-lock.yaml`/`packageManager: pnpm`) rather than proposing to keep it.
- [ ] The proposed patch rewords the Autonomy/Subagent sections in **generic** terms (e.g. "write a test before implementing," names specific non-delegable tasks) — it does **not** insert a literal "superpowers" or "TDD skill" reference into the AGENTS.md patch itself.
- [ ] CLAUDE.md reconciliation folds anything CLAUDE.md-only (once corrected for staleness) into the AGENTS.md patch, then proposes collapsing CLAUDE.md to `@AGENTS.md` (plus the superpowers tie-in line, since this session has superpowers active).
- [ ] The output is a **patch**, not a full rewritten AGENTS.md dump (most sections here are legitimately missing, so a full-file proposal is actually acceptable per the skill's own step 9 exception — confirm the subagent explains *why* it chose full-file vs. patch, rather than defaulting to one without reasoning).

If any check fails, that's a real gap in `SKILL.md`'s Instructions or Heuristics — go back to Task 2, fix the specific wording that caused the miss, and re-run Steps 1–3 of this task before proceeding.

- [ ] **Step 4: Clean up the scratch repo**

```bash
rm -rf /private/tmp/claude-501/-Users-smartin-Projects-mtl-agent-skills/6f2d68eb-a860-468e-85e8-c2d112ab037a/scratchpad/sample-repo
```

- [ ] **Step 5: If Step 3 required a SKILL.md fix, commit it**

```bash
git add skills/coding/optimize-agents-md/SKILL.md
git commit -m "Fix optimize-agents-md gap found during application-scenario verification"
```

(Skip this step if Step 3 passed with no changes needed.)

---

### Task 5: Final check and handoff

- [ ] **Step 1: Confirm the branch state**

Run: `git log --oneline main..optimize-agents-md` and `git status`
Expected: a clean working tree, and a commit list showing the 3 spec commits plus this plan's implementation commits, all on `optimize-agents-md` — none on `main`.

- [ ] **Step 2: Diff review**

Run: `git diff main...optimize-agents-md --stat`
Expected: changes confined to `docs/superpowers/specs/...`, `docs/superpowers/plans/...`, `skills/coding/optimize-agents-md/**`, `skills.sh.json`, `README.md`. No unrelated files touched.

Do not push or open a PR as part of this plan — confirm with the user first (per repo convention, pushing/opening a PR is a separate, explicit step).
