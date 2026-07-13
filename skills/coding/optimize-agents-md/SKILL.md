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
- "create autonomous agent rules for this pnpm monorepo"

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
   - **Stale** — references tooling, commands, or files that no longer match the repo (e.g. mentions `yarn` but the repo now has `pnpm-lock.yaml`) (see Heuristics → Staleness).
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
