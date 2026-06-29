---
name: conductor-neon-db
description: >-
  Set up fully isolated per-workspace databases for Conductor: each workspace gets its own
  instant schema-only Neon branch off production (full schema, zero production data), with
  Prisma migration history baselined and test fixtures seeded, plus the .conductor/settings.toml
  that wires setup/run/archive. Manual-only — run in a Neon + Prisma project to add the setup.
disable-model-invocation: true
---

# Per-workspace isolated databases for Conductor (Neon + Prisma)

## What this sets up

Every Conductor workspace — local and cloud, identically — gets its **own** database, so
parallel agents never read or write the same rows. On workspace setup, `scripts/conductor-db.ts`:

1. Creates an **instant schema-only Neon branch** off the production branch — the full schema
   and extensions (e.g. PostGIS reference data), but **zero production rows**. Neon copies no
   data, so this is fast and cheap, and no production data ever lands in a dev workspace.
2. **Baselines** Prisma's migration history (see "Why" below).
3. **Seeds** test fixtures.
4. Writes the branch's connection string to `.env` as `DATABASE_URL`.

On archive, the branch is deleted. The whole thing is driven by `.conductor/settings.toml`.

## When this applies

- The project's database is on **Neon** (branching is a Neon feature).
- Migrations are managed by **Prisma**.
- `neonctl` and `tsx` are available as project-local dev dependencies, plus a Node package
  manager (pnpm/npm/yarn).

If the stack is different (not Neon, or not Prisma), the exact mechanics here don't transfer —
adapt the script's knobs, or tell the user this skill assumes Neon + Prisma and stop.

## Why schema-only + baseline (the one non-obvious part)

A schema-only Neon branch gives you the schema and extensions but an **empty `_prisma_migrations`
table** (the migration history is table *data*, which schema-only doesn't copy). If you leave it
empty, `prisma migrate dev/deploy` think nothing is applied, try to recreate every table, and
fail because the tables already exist. So provisioning **baselines** the history: it computes
Prisma's own checksum (sha256 of each `migration.sql`) and inserts a row per migration, marking
them all applied. After that, `prisma migrate status` reports "up to date" and `migrate dev`
works normally. (PostGIS's `spatial_ref_sys` is repopulated for free by the extension — no
special handling needed.)

This baseline assumes the **parent branch already contains the code's committed migrations** —
true for the normal Conductor flow (workspaces branch from the default branch; production is
deployed from it). If the parent ever lags, `prisma migrate reset` in the workspace rebuilds.

## Setup

### 1. Preflight

Confirm the project is Neon + Prisma and find the package manager (lockfile: `pnpm-lock.yaml`
→ pnpm, `package-lock.json` → npm, `yarn.lock` → yarn). Ensure `neonctl` and `tsx` are dev
dependencies (`<pm> add -D neonctl tsx` if missing). Identify the Neon project's **production
branch name** (`neonctl branches list --project-id <id>` — it's the one marked default/primary).

### 2. Add the provisioning script

Copy `scripts/conductor-db.ts` (bundled with this skill) into the project's `scripts/`. Then
adjust the **PORTING KNOBS** block at the top:
- `PM_EXEC` — your package manager's exec form (`['pnpm','exec']` / `['npx']` / `['yarn']`).
- `SEED_SCRIPT` and the `seedWorkspace()` body — adapt to the project's seed (see step 6).
- The other paths (`MIGRATIONS_DIR`, `PRISMA_SCHEMA`, `ENV_FILE`) only change if non-standard.

Optionally copy the bundled `tests/conductor-db.test.ts` into the project's test directory —
it locks the two safety-critical bits (the `conductor/*`-only deletion guard and the checksum
format). Keeping these tested is the main reason this is TypeScript and not a shell script.

### 3. Track the shared settings file in git

Conductor reads `.conductor/settings.toml` from the repo, so it must be committed — but the
per-workspace `.env` and any local overrides must not be. If `.gitignore` ignores all of
`.conductor/`, replace that with:

```gitignore
# Conductor: track the shared settings.toml; keep local overrides + the generated .env untracked
.conductor/*
!.conductor/settings.toml
```

Also make sure `.env*` is gitignored (the script writes a real `.env`). Verify with
`git check-ignore -v .conductor/settings.toml` (should print the `!` negation = NOT ignored).

### 4. Create `.conductor/settings.toml`

```toml
"$schema" = "https://conductor.build/schemas/settings.repo.schema.json"

# Local and cloud workspaces behave identically: setup installs deps, generates the Prisma
# client, then provisions an isolated SCHEMA-ONLY Neon branch (scripts/conductor-db.ts),
# baselines its migration history, and seeds fixtures. archive deletes the branch.
# Secrets come from Conductor's Environment tabs — NEVER commit them here, and NEVER put
# DATABASE_URL there (the setup script owns it).

[scripts]
setup = "corepack enable pnpm && pnpm install --frozen-lockfile && pnpm exec prisma generate && pnpm exec tsx scripts/conductor-db.ts provision"
archive = "pnpm exec tsx scripts/conductor-db.ts teardown"
run = "pnpm dev --port $CONDUCTOR_PORT"
run_mode = "concurrent"
```

Adapt the `setup`/`run` commands to the project's package manager and dev server. `run_mode`
can be `concurrent` because each workspace has its own DB and its own `$CONDUCTOR_PORT`.

### 5. Tell the user the Conductor environment variables to set

These go in **Conductor → Settings → Environment**, in **both the Local and Cloud tabs** (a
cloud workspace can't see the Mac, so it needs them too). They are secrets — do NOT commit them.

| Variable | Purpose |
|---|---|
| `NEON_API_KEY` | Neon API key (create one in the Neon console) |
| `NEON_PROJECT_ID` | the Neon project id |
| `NEON_PARENT_BRANCH` | branch to clone, e.g. `production` |
| *(the app's secrets)* | `AUTH_SECRET`/API keys/etc. — whatever the app needs to boot |
| *(seed credentials)* | only if seeding (step 6) |

**Do NOT add `DATABASE_URL`** — the script writes it per workspace. A value in the env tabs
lands in `process.env` and overrides the isolated branch, silently collapsing every workspace
back onto one shared database.

### 6. Wire up seeding (adapt to the project)

`seedWorkspace()` runs the project's seed against the new branch as the last setup step. Most
seeds have (or should have) a guard that refuses non-local databases to prevent accidental
production seeding — authorize it for **this branch only** (never production). The bundled
script shows the pattern for a seed that allows a remote DB when `E2E_EXPECTED_DATABASE_URL ===
DATABASE_URL`. If the project's seed is a plain `prisma db seed` with no guard, simplify the body
to `runWithRetry('prisma', ['db', 'seed'], { ...process.env, DATABASE_URL: uri }, 2)`. If there's
no seed, delete `seedWorkspace()` and its call.

### 7. Verify

- `<pm> exec tsc --noEmit` (and run the bundled test if you copied it).
- **Protect the production branch in Neon** (console → branch → Protect, or
  `neonctl branches set-protection`) so nothing can delete or reset it at the platform level.
- For end-to-end confidence against real Neon, follow `references/verify.md` — it provisions a
  throwaway branch, confirms the schema-only + baseline + seed flow, and deletes it.

## Safety model

The script can't harm production, by construction:
- **Name guard** (`assertDisposableChildBranch`, unit-tested): every destructive op refuses to
  run unless the target starts with `conductor/` and isn't the parent. `production` can't match.
- **Child-only targeting**: baseline/seed/migrate only ever use the freshly-created
  `conductor/<slug>` branch's connection string — never the parent's.
- **Self-destruct on failure**: if baseline or seed fails on a new branch, the branch is deleted
  so a half-set-up branch is never reused.
- **Reuse preserves data**: re-provisioning an existing workspace branch keeps its data (only
  runs `migrate deploy`); it never re-seeds or re-baselines.
- Plus the Neon-side **branch protection** on production (step 7).

## Gotchas

- **`DATABASE_URL` must not be in Conductor's env tabs** (step 5) — it overrides the per-workspace branch.
- **Seeding is opt-in**: if the seed credential isn't set, provisioning logs a warning and the
  workspace comes up empty rather than failing setup. Set it to seed.
- **Baseline assumption**: parent (production) must contain the code's committed migrations; if
  it lags, `prisma migrate reset` in the workspace rebuilds cleanly.
- **Branches branch from the default branch** in Conductor, which is why parent == code migrations
  in the normal case.
