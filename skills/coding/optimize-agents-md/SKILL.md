---
name: bootstrap-agents-md
description: Create or upgrade a repo's AGENTS.md files so coding agents operate with high autonomy, smart defaults, and strong repo-specific guardrails. Use when setting up AGENTS.md for a new or existing project, bootstrapping agent rules, upgrading a repo for autonomous agents, or deciding whether nested per-app/package AGENTS.md files are needed in a monorepo. Triggered by requests like "set up AGENTS.md for this repo," "bootstrap agent rules for this project," "create a reusable AGENTS.md," "upgrade this repo for autonomous agents," or the /bootstrap-agents-md command. Covers inspecting the repo to infer package manager, framework, test stack, and database layer, then generating autonomy policy, subagent policy, validation strategy, environment variable rules, and database safety rules tailored to what's actually in the repo.
metadata:
  author: stephen-martin
  version: "0.1.0"
---

# Bootstrap AGENTS.md

Create or upgrade AGENTS.md files for a new or existing project so coding agents operate with high autonomy, smart defaults, and strong repo-specific guardrails.

## Triggers

- "set up AGENTS.md for this repo"
- "bootstrap agent rules for this project"
- "create a reusable AGENTS.md"
- "upgrade this repo for autonomous agents"
- "/bootstrap-agents-md"

## Instructions

1. Inspect the repository before writing anything.
   - Read `package.json`, workspace config, lockfiles, top-level app/package folders, framework config, test config, database config, and key docs.
   - Detect the package manager, runtime, framework, test stack, database layer, monorepo shape, and deployment tooling.
   - Identify whether the repo is single-app or monorepo.

2. Infer the operating model.
   - Determine whether the codebase favors fast iteration, safety, strong typing, TDD, heavy CI, or infra caution.
   - Reuse project terminology and existing command names.
   - Prefer existing conventions over generic boilerplate.

3. Generate a root `AGENTS.md`.
   The root file should include:
   - Operating mode
   - Autonomy policy
   - Decision rules
   - Subagent policy
   - Validation strategy
   - Package manager commands
   - Testing guidance
   - Environment variable rules
   - Database and migration safety rules
   - Implementation guidelines
   - Review checklist
   - References to deeper docs

4. Add nested `AGENTS.md` files when useful.
   Create app- or package-level `AGENTS.md` files when:
   - The repo is a monorepo.
   - Different apps use different frameworks or commands.
   - Backend and frontend have materially different rules.
   - A package has special testing, build, or deployment constraints.

5. Optimize for autonomous execution.
   The generated AGENTS.md files must:
   - Encourage forward progress.
   - Allow subagents for parallelizable work.
   - Minimize unnecessary clarification questions.
   - Escalate only for destructive, schema, security, billing, auth, privacy, infra, or production-impacting changes.

6. Keep files concise and practical.
   - Prefer direct bullets over long prose.
   - Put concrete commands near the top.
   - Link to deeper docs instead of duplicating large reference material.
   - Keep the root AGENTS.md short enough to stay useful during normal runs.

7. Ask only targeted questions if essential information cannot be inferred.
   Good examples:
   - "Should migrations require explicit approval?"
   - "Do you want nested AGENTS.md files per app/package?"
   - "Should dependency additions require approval or just major deps?"

8. Produce output in this order:
   - A short summary of what was detected.
   - The proposed root `AGENTS.md`.
   - Any proposed nested `AGENTS.md` files.
   - A brief note on what was inferred vs explicitly confirmed.

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
- If test patterns differ by app/package, push those rules into nested `AGENTS.md` files.

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

## Output template

Use this structure in generated root `AGENTS.md` files:

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
- and is short enough that agents will actually follow it.

## Example invocation

User: "Set up AGENTS.md for this repo"
User: "Create autonomous agent rules for this pnpm monorepo"
User: "/bootstrap-agents-md"
