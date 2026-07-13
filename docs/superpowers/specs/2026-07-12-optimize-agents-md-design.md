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

The skill also takes on a second, related job: keeping CLAUDE.md and
AGENTS.md from drifting apart. AGENTS.md is the single source of truth;
CLAUDE.md becomes a one-line pointer (`@AGENTS.md`) wherever it exists or is
needed, at every directory level the skill touches.

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

> Audit and improve a repo's AGENTS.md file so coding agents operate with
> high autonomy, smart defaults, and strong repo-specific guardrails —
> patching gaps in an existing file rather than replacing it, and
> generating one from scratch only when none exists. Also keeps CLAUDE.md
> from duplicating AGENTS.md: collapses it to a one-line pointer
> (`@AGENTS.md`). Use when auditing an AGENTS.md, asking "is my AGENTS.md
> any good," filling gaps in agent rules, reconciling CLAUDE.md and
> AGENTS.md, or still when setting up AGENTS.md for a repo that has none.
> Triggered by requests like "audit my AGENTS.md," "optimize AGENTS.md,"
> "fill gaps in AGENTS.md," "set up AGENTS.md for this repo," "bootstrap
> agent rules for this project," or the /optimize-agents-md command.

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
4. **Re-inspect the repo.** Same detection as the fallback path (package
   manager, framework, test stack, database layer, monorepo shape) so any
   proposed addition/edit is grounded in what's actually there, not
   assumed.
5. **Patch, don't rewrite.** For sections classified thin/generic, missing,
   or stale, propose a targeted addition or edit scoped to just that
   section. Leave adequate sections untouched. Stale sections are flagged
   explicitly (what's stale, why, what it should say now) rather than
   silently changed.
6. **Reconcile CLAUDE.md, per directory level.**
   - If CLAUDE.md exists with real content: diff it against the
     (possibly just-patched) AGENTS.md at the same level. Anything present
     only in CLAUDE.md gets folded into the AGENTS.md patch from step 5.
     Genuine contradictions (not just gaps) are flagged for the user
     instead of auto-resolved.
   - Once AGENTS.md is the source of truth at that level, collapse
     CLAUDE.md to a single line: `@AGENTS.md`.
   - If CLAUDE.md doesn't exist at that level, create it with that same
     single line.
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

### CLAUDE.md pointer hygiene
- AGENTS.md is always the canonical file; CLAUDE.md is never a second
  place to maintain rules.
- A CLAUDE.md that is anything other than a single `@AGENTS.md` line (plus
  optional Claude-Code-only content the user explicitly wants kept
  separate) is a hygiene finding, not silently rewritten without being
  called out.

## Quality bar

Existing bullets carry over. Add:

- Preserves the existing file's structure and voice where it's already
  good — patches don't rewrite what isn't broken.
- Never silently deletes existing guardrails; removals are flagged, not
  assumed.
- Never lets CLAUDE.md and AGENTS.md drift out of sync — one is always a
  pointer to the other.

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
  `| [\`optimize-agents-md\`](skills/coding/optimize-agents-md/SKILL.md) | Audits and patches a repo's AGENTS.md against a canonical section checklist, generating one from scratch only if none exists, and keeps CLAUDE.md as a one-line pointer to it. |`

## Open decisions (proceeding with these unless vetoed)

- **Name:** `optimize-agents-md`.
- **README.md:** deleted, not migrated.
- **Contradiction handling:** CLAUDE.md/AGENTS.md content gaps auto-merge
  into AGENTS.md; true contradictions are surfaced, never auto-resolved.
- **CLAUDE.md stub creation:** always ensured, even where CLAUDE.md never
  existed before.
