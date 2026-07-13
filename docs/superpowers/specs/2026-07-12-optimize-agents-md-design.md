# optimize-agents-md — Design

**Date:** 2026-07-12
**Category:** `coding`
**Status:** Approved design, pending spec review

## Purpose

Rework the existing `bootstrap-agents-md` skill into `optimize-agents-md`: a
skill whose primary job is auditing and improving an AGENTS.md file that
already exists (even a thin or generic one), rather than always generating a
fresh file. Creating a file from scratch becomes the fallback path for repos
that have none, not the headline behavior.

**The actual goal underneath all of this is a fast SDLC.** AGENTS.md is
useful only insofar as it makes the coding agent operate quickly *and*
safely on this specific repo. The single biggest lever for that, for an
agent running under the superpowers plugin, is whether AGENTS.md's own
policies reinforce or fight the disciplines superpowers already enforces —
TDD (write the test first), brainstorming before creative/ambiguous work,
verification-before-completion (prove it works before claiming done),
systematic-debugging, and subagent dispatch for parallelizable work. A
repo's AGENTS.md that blanket-discourages tests, forbids subagents, or
tells the agent to skip confirmation in ways that undercut those
disciplines is actively slowing the SDLC down, even though it reads as
"autonomy-friendly." So the audit checklist gets a dedicated category for
this (see Heuristics → Superpowers alignment), and it's the first thing
called out in the audit summary, not a footnote.

The skill also takes on a second, related job: keeping CLAUDE.md and
AGENTS.md from drifting apart. AGENTS.md is the single source of truth and
stays tool-agnostic (portable to any agent, not just Claude Code);
CLAUDE.md becomes a one-line pointer (`@AGENTS.md`) wherever it exists or is
needed, at every directory level the skill touches — plus a short
superpowers tie-in line when the current session shows superpowers is
active (see Heuristics → CLAUDE.md pointer hygiene). Keeping the
superpowers-specific mention in CLAUDE.md rather than AGENTS.md preserves
AGENTS.md's portability while still making the tie-in explicit for the
agent that's actually running right now.

## Non-goals

- Not a generic AGENTS.md linter/validator library — it's a Claude Code
  skill, not a standalone tool.
- Does not touch config files or docs other than AGENTS.md/CLAUDE.md (e.g.
  it does not rewrite READMEs or CONTRIBUTING.md).
- Does not resolve genuine content contradictions between CLAUDE.md and
  AGENTS.md unilaterally — those are surfaced for the user, not
  auto-decided.

## Rename

- Directory: `skills/coding/bootstrap-agents-md` → `skills/coding/optimize-agents-md`.
- Frontmatter `name`: `bootstrap-agents-md` → `optimize-agents-md`.
- H1: `# Bootstrap AGENTS.md` → `# Optimize AGENTS.md`.
- `references/templates.md` moves with the directory unchanged — its
  snippets (operating mode, autonomy policy, subagent policy, validation
  strategy, database safety, environment variables) are reused by both the
  patch path and the from-scratch fallback path.
- `README.md` is deleted. No sibling skill (`consult-codex`, `codex-review`)
  has one; it duplicated SKILL.md and would drift out of sync with this
  rework. SKILL.md's frontmatter `description` is the discovery mechanism.

## Frontmatter `description`

Leads with audit/optimize phrasing, keeps the old bootstrap triggers since
they still work via the fallback path:

> Audit and improve a repo's AGENTS.md file for a fast, safe SDLC —
> patching gaps in an existing file rather than replacing it, generating
> one from scratch only when none exists, and making sure its autonomy,
> validation, and subagent policies reinforce rather than fight
> disciplines like TDD, brainstorming-before-creative-work,
> verification-before-completion, and subagent dispatch. Also keeps
> CLAUDE.md from duplicating AGENTS.md: collapses it to a one-line pointer
> (`@AGENTS.md`), plus a short superpowers tie-in note when that plugin is
> active. Use when auditing an AGENTS.md, asking "is my AGENTS.md any
> good," filling gaps in agent rules, making sure AGENTS.md works well with
> superpowers/TDD/subagents, reconciling CLAUDE.md and AGENTS.md, or still
> when setting up AGENTS.md for a repo that has none. Triggered by requests
> like "audit my AGENTS.md," "optimize AGENTS.md," "fill gaps in
> AGENTS.md," "make sure my AGENTS.md plays well with superpowers," "set up
> AGENTS.md for this repo," "bootstrap agent rules for this project," or
> the /optimize-agents-md command.

## Workflow

Replaces the current 8-step "Instructions" list.

1. **Locate files.** Find every AGENTS.md in the repo (root + nested) and,
   for each, check whether a sibling CLAUDE.md exists at the same
   directory level.
2. **No AGENTS.md anywhere → fallback.** Run the original from-scratch flow
   unchanged: inspect the repo (package manager, runtime, framework, test
   stack, database layer, monorepo shape), infer the operating model, and
   generate root + nested AGENTS.md files using the existing Heuristics and
   Output template. Skip to step 6 for the CLAUDE.md pass.
3. **AGENTS.md exists → audit.** For each existing AGENTS.md, classify every
   section from the canonical checklist (Operating mode, Autonomy policy,
   Decision rules, Subagent policy, Validation strategy, Package manager
   commands, Testing guidance, Environment variable rules, Database and
   migration safety, Implementation guidelines, Review checklist,
   References) as one of:
   - **Adequate** — present, specific to this repo, matches current tooling.
   - **Thin/generic** — present but boilerplate, doesn't reflect this repo's
     actual commands/conventions.
   - **Missing** — section absent entirely.
   - **Stale** — references tooling, commands, or files that no longer
     match the repo (e.g. mentions `yarn` but the repo now has
     `pnpm-lock.yaml`).
   - **Conflicting** — the section's own words work against a fast, safe
     SDLC: it blanket-discourages tests, forbids subagents outright, tells
     the agent to skip verification, or otherwise reads as
     autonomy-friendly while quietly undercutting TDD,
     brainstorming-before-creative-work, verification-before-completion, or
     subagent dispatch. See Heuristics → Superpowers alignment.
4. **Re-inspect the repo.** Same detection as the fallback path (package
   manager, framework, test stack, database layer, monorepo shape) so any
   proposed addition/edit is grounded in what's actually there, not
   assumed.
5. **Patch, don't rewrite.** For sections classified thin/generic, missing,
   or stale, propose a targeted addition or edit scoped to just that
   section. Leave adequate sections untouched. Stale sections are flagged
   explicitly (what's stale, why, what it should say now) rather than
   silently changed. Conflicting sections are flagged with the specific
   discipline they undercut and a proposed rewording — never silently
   overridden, since the user may have written that rule on purpose.
6. **Reconcile CLAUDE.md, per directory level.**
   - If CLAUDE.md exists with real content: diff it against the
     (possibly just-patched) AGENTS.md at the same level. Anything present
     only in CLAUDE.md gets folded into the AGENTS.md patch from step 5.
     Genuine contradictions (not just gaps) are flagged for the user
     instead of auto-resolved.
   - Once AGENTS.md is the source of truth at that level, collapse
     CLAUDE.md to: `@AGENTS.md`, plus — only if the current session shows
     the superpowers plugin is active (its skills, e.g.
     `superpowers:using-superpowers`, appear in the available-skills list)
     — one short line underneath noting that AGENTS.md's policies are
     written to align with it (see Heuristics → CLAUDE.md pointer
     hygiene for the exact wording). If superpowers isn't active this
     session, don't add the line — leave CLAUDE.md as the bare pointer.
   - If CLAUDE.md doesn't exist at that level, create it with the same
     content as above.
   - Applies at root and at every nested app/package directory that has
     its own AGENTS.md.
7. **Escalate only when essential**, same policy as today: ask targeted
   questions only for things that can't be inferred (e.g. "should
   migrations require explicit approval?").
8. **Output order:**
   - Section-by-section audit table (adequate / thin / missing / stale) for
     each AGENTS.md found, plus CLAUDE.md pointer status per directory.
   - Proposed patch: only the sections being added or changed, not a full
     file dump — unless most sections are missing, in which case show the
     full proposed file.
   - Nested-file findings, if monorepo.
   - Note on what was inferred vs. what needs explicit confirmation.

## Heuristics

Existing subsections (Package manager, Monorepo detection, Testing,
Database, Environment variables, Subagents) carry over unchanged — they
apply identically whether generating fresh or patching.

New subsection:

### Staleness
- Cross-check every concrete command, file path, and tool name mentioned in
  AGENTS.md against what's actually in the repo right now.
- Flag anything that names a package manager, framework, test runner, or
  file that isn't present, or that conflicts with a lockfile/config that
  says otherwise.
- Don't guess *why* it's stale (renamed dependency vs. abandoned tooling) —
  just flag it and let the user confirm the fix.

### Superpowers alignment
The point of this category is speed with safety: every check here exists
because getting it wrong makes the SDLC *slower*, not just messier.

- **Autonomy policy vs. TDD/verification** — flag language that tells the
  agent to skip tests, skip confirming its own work, or treat "fast" as an
  excuse to not verify. TDD and verification-before-completion exist to
  catch regressions before they compound into slower rework later; an
  AGENTS.md that discourages them isn't actually buying speed.
- **Validation strategy vs. real commands** — the Validation strategy
  section should name this repo's actual test/build/typecheck commands
  (not "run tests" as a generic phrase), so the TDD red-green-refactor
  loop and verification-before-completion have something concrete to
  execute.
- **Subagent policy vs. dispatch patterns** — flag a blanket "don't use
  subagents" or "always work solo" rule. It's fine (good, even) to name
  specific tasks that shouldn't be delegated (tightly coupled debugging,
  tiny edits) — that's compatible with the dispatch model. What's flagged
  is an absolute ban that would block legitimately parallelizable work
  (e.g. independent frontend/backend changes, multi-file test writing).
- **Decision rules vs. brainstorming** — flag instructions that push the
  agent to start implementing ambiguous/creative work immediately with no
  room for clarifying questions or a design step first. Escalation for
  destructive/security/infra actions (already covered elsewhere in the
  checklist) is a separate, and fine, kind of "stop and ask."
- Don't invent a superpowers reference inside AGENTS.md itself to fix
  these — AGENTS.md stays tool-agnostic. The fix is rewording the policy
  in generic terms ("write a test before implementing," "run the full
  suite before declaring done") that happen to satisfy the discipline
  either way.

### CLAUDE.md pointer hygiene
- AGENTS.md is always the canonical file; CLAUDE.md is never a second
  place to maintain rules.
- A CLAUDE.md that is anything other than the pointer described below
  (plus optional Claude-Code-only content the user explicitly wants kept
  separate) is a hygiene finding, not silently rewritten without being
  called out.
- **Default pointer:** `@AGENTS.md`.
- **When superpowers is active this session** (its skills are present in
  the available-skills list), append one line:
  ```
  @AGENTS.md

  This repo's AGENTS.md is written to align with the superpowers skill
  system (TDD, brainstorming, verification-before-completion,
  systematic-debugging, subagent dispatch) — no separate instructions
  needed here.
  ```
  This is the one place the superpowers plugin gets named explicitly,
  since CLAUDE.md is already Claude-Code-specific by nature — unlike
  AGENTS.md, there's no portability to protect.
- If superpowers isn't active this session, don't add the line — a repo
  worked on by an agent without the plugin shouldn't carry a reference to
  it that agent can't act on.

## Quality bar

Existing bullets carry over. Add:

- Preserves the existing file's structure and voice where it's already
  good — patches don't rewrite what isn't broken.
- Never silently deletes existing guardrails; removals are flagged, not
  assumed.
- Never lets CLAUDE.md and AGENTS.md drift out of sync — one is always a
  pointer to the other.
- Optimizes for a fast *and* safe SDLC — autonomy, validation, and
  subagent policies reinforce TDD, brainstorming-before-creative-work,
  verification-before-completion, and subagent dispatch rather than
  quietly undercutting them in the name of "autonomy."

## Output template

Unchanged for the fallback (from-scratch) path — reuses the existing
13-item structure. The patch path doesn't use this template directly; it
emits per-section diffs keyed to the same canonical section list instead.

## Example invocations

Add optimize-framed examples alongside the existing bootstrap ones:

- "Audit my AGENTS.md"
- "Is my AGENTS.md any good?"
- "Optimize AGENTS.md for this repo"
- "Fill gaps in AGENTS.md"
- "Reconcile CLAUDE.md and AGENTS.md"
- "Make sure my AGENTS.md works well with superpowers/TDD/subagents"

(Existing bootstrap-phrased examples stay, since they still resolve via the
fallback path.)

## Registration

`bootstrap-agents-md` was never registered in the repo's own index — it
predates this rework and isn't listed in `README.md` or `skills.sh.json`.
Register it as `optimize-agents-md` while we're renaming, so it's actually
installable via `npx skills add`:

- `skills.sh.json`: add `"optimize-agents-md"` to the `"Coding"` grouping's
  `skills` array (alongside `consult-codex`, `codex-review`,
  `ship-ready-pr-loop`).
- `README.md`: add a row to the `### Coding` table:
  `| [\`optimize-agents-md\`](skills/coding/optimize-agents-md/SKILL.md) | Audits and patches a repo's AGENTS.md for a fast, safe SDLC — reinforcing TDD, brainstorming, verification, and subagent dispatch — generating one from scratch only if none exists, and keeps CLAUDE.md as a one-line pointer to it. |`

## Open decisions (proceeding with these unless vetoed)

- **Name:** `optimize-agents-md`.
- **README.md:** deleted, not migrated.
- **Contradiction handling:** CLAUDE.md/AGENTS.md content gaps auto-merge
  into AGENTS.md; true contradictions are surfaced, never auto-resolved.
- **CLAUDE.md stub creation:** always ensured, even where CLAUDE.md never
  existed before.
- **Superpowers coupling:** AGENTS.md stays tool-agnostic (its policies are
  reworded to satisfy TDD/verification/subagent-dispatch generically); the
  explicit superpowers reference lives only in CLAUDE.md, and only when
  the current session shows the plugin is active.
