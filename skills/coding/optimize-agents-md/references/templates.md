# Template snippets

## Operating mode

```md
# Operating mode

This repo prefers an autonomous senior-engineer workflow.

- Make the best reasonable decision from the codebase, docs, tests, and existing patterns.
- Use subagents when work can be parallelized or split into clear scopes.
- Do not stop for confirmation unless the action is destructive, irreversible, security-sensitive, or changes external systems/contracts.
- Prefer forward progress over excessive clarification.
- Prefer small, reversible changes over speculative rewrites.
- Briefly note assumptions in the plan, then proceed.
```

## Autonomy policy

```md
## Autonomy policy

Allowed without asking:
- Read any repo file.
- Search the codebase, configs, tests, and docs.
- Update code, tests, docs, and non-secret config.
- Run targeted lint, typecheck, build, and test commands.
- Add missing tests for changed behavior.
- Spawn subagents for planning, implementation, validation, and review.
- Make reasonable local decisions that follow existing repo conventions.

Ask before:
- Deleting large sections of code.
- Introducing breaking API or contract changes.
- Editing auth, billing, privacy, permissions, or security-critical behavior.
- Creating or applying database migrations.
- Running destructive scripts or commands.
- Changing CI, deployment, infra, or production configuration.
- Adding new dependencies when an equivalent project dependency or existing utility already exists.
```

## Subagent policy

```md
## Subagent policy

Use subagents by default for work that can be cleanly decomposed.

Good subagent use cases:
- Researching framework or library docs.
- Mapping relevant files before implementation.
- Frontend/backend splits.
- Large refactors across isolated modules.
- Writing or repairing tests in parallel with implementation.
- Independent review/verification passes.

Avoid subagents for:
- Tiny one-file edits.
- Highly coupled debugging that requires one continuous thread.
- Tasks where delegation overhead exceeds execution value.

Preferred delegation pattern:
- Planner subagent: identify touched files, constraints, risks, and a compact task list.
- Implementer subagent(s): make scoped code changes.
- Test subagent: add or update targeted tests.
- Reviewer subagent: check correctness, regressions, and obvious performance/security issues.
```

## Validation strategy

```md
## Validation strategy

Validate the smallest useful scope first, then broaden only as needed.

Preferred order:
1. File-level or targeted test.
2. Related package/app test suite.
3. Typecheck/lint for changed surface.
4. Full suite only for cross-cutting or risky changes.

Batch validation near the end instead of after every tiny edit unless the change is risky.
```

## Database safety

```md
## Database safety rules

- Query changes and schema inspection are allowed without asking.
- Any schema migration, destructive data change, or backfill requires explicit approval before execution.
- Prefer additive migrations over destructive ones.
- Never point tests at development or production data.
- Never bypass the project database helpers when an established path already exists.
```

## Environment variables

```md
# Environment variables

There must always be a committed **`.env.example`** documenting every environment variable the app reads.

Rules:
- Include a short comment for each variable describing purpose and whether it is required.
- Keep `.env.example` in sync with code changes.
- When code starts reading a new variable, add it to `.env.example` in the same change.
- Real values live in `.env.local` and must never be committed.
- Start with `cp .env.example .env.local`.
- Do not invent fake defaults for required config; fail with a clear, actionable error instead.
```
