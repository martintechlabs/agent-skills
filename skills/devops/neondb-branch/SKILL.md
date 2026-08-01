---
name: neondb-branch
description: >-
  Set up fully isolated per-workspace Neon databases for any git repo: each workspace gets its
  own instant schema-only Neon branch off production (full schema, zero production data),
  baselined against production's TRUE applied-migration state — not assumed from local files —
  via a disposable full-data check branch (Prisma or Drizzle), with test fixtures seeded. No
  orchestration tool required — plain package.json scripts drive provision/sync/teardown, with
  workspace identity resolved from Conductor, Orca, a general WORKSPACE_NAME, or (for a plain
  single-clone checkout) the current git branch. Ships ready-to-use Conductor and Orca config
  templates too. provision() fully rebuilds the branch on every run. Manual-only — run in a
  Neon + Prisma or Neon + Drizzle project to add the setup.
disable-model-invocation: true
metadata:
  author: martintechlabs
  version: "0.1.0"
---

# Per-workspace isolated Neon databases (Prisma or Drizzle, any git repo)

## What this sets up

Every workspace — a Conductor workspace, an Orca worktree, or a plain git checkout on its own
branch — gets its **own** database, so parallel agents never read or write the same rows.
`provision()` is a **full, deterministic rebuild — every run, not just the first**: it deletes
whatever branch is currently recorded for the workspace (if any) and creates a fresh one. Any
data written into the workspace branch through normal app usage is discarded on every re-run —
the branch is disposable by design; there is no "reuse an existing branch, keep its data" path.

Each `provision()` run:

1. Creates an **instant schema-only Neon branch** off the parent (production) branch — full
   schema and extensions (e.g. PostGIS reference data), **zero production rows**. Neon copies no
   data, so this is fast and cheap.
2. **Baselines the ORM's migration history against production's TRUE applied-migration state** —
   by cloning production a *second* time, this time **with data**, into a disposable `tmp/*`
   check branch, reading that clone's real ledger rows, seeding the workspace branch's (empty)
   ledger with exactly those rows, then deleting the check branch. The ORM's migrate-deploy then
   applies whatever's genuinely still missing.
3. **Seeds** test fixtures.
4. Upserts `DATABASE_URL` (and any other `DB_ENV_VARS`) plus `NEON_API_KEY`/`NEON_PROJECT_ID`/
   `NEON_PARENT_BRANCH` into `.env.neondb` (its own file — your real `.env` is never touched),
   preserving anything else already in that file. This keeps `.env.neondb` self-sufficient for
   later `sync`/`teardown` calls regardless of how they're invoked.
5. Records the branch name in `.neondb/branch` (gitignored) so teardown deletes the **same**
   branch even after an identity change (e.g. a Conductor workspace rename).

## Workspace identity

There is no single required environment variable. Identity resolves through a precedence chain,
first match wins:

| Order | Source | When it applies |
|---|---|---|
| 1 | `CONDUCTOR_WORKSPACE_NAME` | Conductor injects this automatically |
| 2 | `ORCA_WORKSPACE_NAME` | Set by Orca or the project, when present |
| 3 | `WORKSPACE_NAME` | General ambient override for custom tools, tests, or a project that wants one name for every tool |
| 4 | Checkout directory basename | A secondary git worktree with none of the above set — stable across a `git checkout` inside it |
| 5 | Current git branch | A plain single-clone checkout with none of the above set — here "the workspace" genuinely *is* the branch |

`WORKSPACE_NAME` is **never** read from `.env.neondb` — that file can be copied or reused across
workspaces, which would collide two of them onto the same Neon branch. Set it in your shell,
CI config, or orchestrator env instead.

### Renaming: deliberate vs. incidental

A git branch changes on every `git checkout`, not just a deliberate rename. Treating every branch
change as "follow the rename" would mean checking out `main` to peek at something and running
`pnpm dev` silently renaming your feature branch's live Neon branch. So renaming is split:

- **`provision()`** is the deliberate path: it always deletes whatever's recorded and creates
  fresh under the current identity. Re-running it after `git branch -m old new` (or a Conductor
  workspace rename) is how you move this workspace's Neon branch to follow the change —
  discarding whatever data was in the old branch.
- **`sync()`** (chained in front of the dev server) is a passive verifier. It hard-gates unsafe
  states (never provisioned, setup interrupted, the recorded branch is gone) and, once past
  those, **best-effort renames** the live Neon branch when identity has moved on — unless the
  target name is already a *different* live branch, in which case it hard-gates instead (two
  previously-provisioned workspaces colliding, not a rename).

## When this applies

- The project's database is on **Neon** (branching is a Neon feature).
- Migrations are managed by **Prisma** or **Drizzle** (set the `ORM` knob in the script).
- `neonctl`, `tsx`, and `dotenv` are available as project-local dev dependencies, plus a Node
  package manager (pnpm/npm/yarn). **Both ORMs** need the project's existing Postgres driver
  (`@neondatabase/serverless` / `postgres` / `pg`) wired into the script's `execSql()` knob —
  reading production's true migration ledger back needs a real query result.

If the stack is different (not Neon, or not Prisma/Drizzle), the exact mechanics here don't
transfer — adapt the script's knobs, or tell the user this skill assumes Neon + Prisma/Drizzle
and stop.

## Why schema-only + baseline (the one non-obvious part)

A schema-only Neon branch gives you the schema and extensions but an **empty migrations table**
(the migration history is table *data*, which schema-only doesn't copy). If you leave it empty,
the migrator thinks nothing is applied, tries to recreate every table, and fails because the
tables already exist.

The naive fix — baseline by reconstructing the ledger from the **repo's own migration files**,
marking every committed migration applied — has a real bug: it assumes production has actually
run every migration committed on this code branch, and never checks. If it hasn't, that migration
gets falsely marked applied without ever running on the workspace branch, and the app breaks the
moment it touches whatever that migration created — silently, since the migrator now believes
it's "up to date".

So provisioning learns production's **true** applied-migration set instead of assuming it:

1. Clone production a *second* time — this time **with data** — into a disposable `tmp/*` check
   branch. Row data is the only source of truth for "what really ran"; a schema-only clone strips
   it, even for the migrations table itself.
2. Read that clone's real migration-ledger rows.
3. Delete the check branch — production itself is never connected to directly, only this
   disposable clone of it.
4. Seed the workspace branch's (empty) ledger with **exactly those rows**, verbatim — not
   recomputed from local files.
5. Run the ORM's migrate-deploy, which now applies whatever's genuinely still missing.

The two ORMs differ only in the ledger table and the row shape — both read from the check branch
and write into the workspace branch, never from local files:

- **Prisma** — `_prisma_migrations`. Only rows Prisma itself considers genuinely applied
  (`finished_at` set, `rolled_back_at` null) count. The captured `checksum` and `migration_name`
  are inserted verbatim.
- **Drizzle** — `drizzle.__drizzle_migrations`. Each captured row is `hash` + `created_at`,
  inserted verbatim. drizzle-kit decides what to run by the **latest `created_at`**, so this must
  be the value production's own ledger recorded.

## Setup

### 1. Preflight

Confirm the project is Neon + Prisma **or** Neon + Drizzle, and find the package manager
(lockfile: `pnpm-lock.yaml` → pnpm, `package-lock.json` → npm, `yarn.lock` → yarn). Ensure
`neonctl`, `tsx`, and `dotenv` are dev dependencies (`<pm> add -D neonctl tsx dotenv` if missing).
Note which Postgres driver the project already uses — you'll wire it into `execSql()` in step 2.
Identify the Neon project's **production branch name** (`neonctl branches list --project-id <id>`
— the one marked default/primary).

### 2. Add the provisioning script

Copy `scripts/neondb-branch.ts` and `scripts/load-env.cjs` (both bundled with this skill) into
the project's `scripts/`. Adjust the **PORTING KNOBS** block at the top of `neondb-branch.ts`:

- `ORM` — `'prisma'` or `'drizzle'`.
- `PM_EXEC` — your package manager's exec form (`['pnpm','exec']` / `['npx']` / `['yarn']`).
- `SEED_SCRIPT` and the `seedWorkspace()` body — adapt to the project's seed.
- **Wire `execSql()`** to the project's Postgres driver and remove its throw.
- **Drizzle only:** `DRIZZLE_MIGRATIONS_SCHEMA`/`DRIZZLE_MIGRATIONS_TABLE` only if customized.
- `DB_ENV_VARS` — every env var that must point at the workspace branch (defaults to just
  `DATABASE_URL`; add `DIRECT_URL`/`shadowDatabaseUrl` if your schema references them).

Copy `tests/neondb-branch.test.ts` into the project's test directory (adjust the import path to
your layout) — it locks the safety-critical bits: the identity precedence chain, the
`workspace/*`/`tmp/*`-only deletion guard, the `.env.neondb` upsert/strip behavior, and both
ORMs' idempotent true-ledger baseline row format.

### 3. Wire up `package.json`

```jsonc
{
  "scripts": {
    "db:provision": "tsx scripts/neondb-branch.ts provision",
    "db:sync": "tsx scripts/neondb-branch.ts sync",
    "db:teardown": "tsx scripts/neondb-branch.ts teardown",

    "worktree:setup": "<pm install> && <orm generate, if prisma> && tsx scripts/neondb-branch.ts provision",
    "worktree:sync": "tsx scripts/neondb-branch.ts sync",
    "worktree:archive": "tsx scripts/neondb-branch.ts teardown",

    "dev": "tsx scripts/neondb-branch.ts sync && NODE_OPTIONS='--require ./scripts/load-env.cjs' <your original dev command>"
  }
}
```

`db:*` is the plain-install surface. `worktree:*` is the same three commands under a shared
vocabulary both Conductor and Orca call — see step 4. Plain-clone users can ignore `worktree:*`
entirely. **`dev`'s `sync &&` prefix is not optional** — `load-env.cjs`'s fallback to your dev
server's own `.env` loading is only safe because `sync` hard-gates first; never ship a `dev`
script that skips it.

Add the same `NODE_OPTIONS='--require ./scripts/load-env.cjs'` prefix to `build`/`start`/seed
scripts if you want provisioned-workspace parity there too. For Prisma's CLI (`migrate`/
`db execute`/`studio`) outside `dev`, add to `prisma.config.ts`:

```ts
import { config as loadEnv } from 'dotenv'
loadEnv({ path: '.env.neondb' })
loadEnv()
```

(Drizzle has no equivalent config-loading hook — source `.env.neondb` explicitly for any ad hoc
`drizzle-kit` invocation outside `dev`.)

### 4. Orchestrator config (optional — both shipped, use what applies)

**Conductor** — copy `references/conductor-settings.toml.example` to
`.conductor/settings.toml`:

```toml
"$schema" = "https://conductor.build/schemas/settings.repo.schema.json"

[scripts]
setup = "corepack enable pnpm && pnpm worktree:setup"
archive = "pnpm worktree:archive"
run = "pnpm worktree:sync && pnpm dev --port $CONDUCTOR_PORT"
run_mode = "concurrent"
```

`run_mode = "concurrent"` is safe because each workspace has its own Neon branch and
`$CONDUCTOR_PORT`. **Never put `DATABASE_URL` in Conductor's Environment tabs** — it would
override the per-workspace branch. Put `NEON_API_KEY`/`NEON_PROJECT_ID`/`NEON_PARENT_BRANCH` in
**both** Local and Cloud tabs (or in `.env.neondb` directly) — `provision()` mirrors them into
`.env.neondb` regardless, so `archive` is self-sufficient even if Conductor's archive process is
ever missing env vars.

**Orca** — copy `references/orca.yaml.example` to `orca.yaml`:

```yaml
scripts:
  setup: |
    corepack enable pnpm && pnpm worktree:setup
  archive: |
    pnpm worktree:archive
```

Orca has no `run` hook — `sync`'s hard gate lives entirely in the `dev` script from step 3, which
is why that `sync &&` prefix is universal rather than orchestrator-specific.

Track `.conductor/settings.toml` in git (needed for cloud workspaces to read it) but gitignore
everything else generated: `.neondb/`, `.env.neondb` (already covered by `.env*` in most
`.gitignore`s — verify with `git check-ignore .env.neondb`).

### 5. Wire up seeding (adapt to the project)

`seedWorkspace()` runs the project's seed against the new branch as the last setup step. Most
seeds have (or should have) a guard that refuses non-local databases; authorize it for **this
branch only** (never production). If there's no seed, delete `seedWorkspace()` and its call.

### 6. Verify

- `<pm> exec tsc --noEmit` (and run the bundled test if you copied it).
- **Protect the production branch in Neon** (console → branch → Protect, or
  `neonctl branches set-protection`).
- For end-to-end confidence against real Neon, follow `references/verify.md`.

## Safety model

- **Name guard**: every destructive op (delete and rename) refuses to run unless the target
  starts with `workspace/` (workspace branch) or `tmp/` (disposable check branch) and isn't the
  parent.
- **Child-only targeting, never the parent directly**: every SQL connection targets either the
  workspace branch or the disposable check branch — `provision()` never opens a connection to the
  parent, only clones it.
- **No slug collisions**: over-long identities are truncated with a content hash appended, under
  each prefix independently.
- **Self-destruct on failure**: if anything after branch creation fails, the just-created
  workspace branch is deleted, and its state record plus branch-specific `.env.neondb` vars are
  cleaned up (Neon control vars are kept, so the next attempt doesn't need them re-supplied).
- **Every `provision()` run is a full, deterministic rebuild** — no "reuse a ready branch and keep
  its data" path exists.
- **True-ledger baseline, not a local-file assumption** — see "Why schema-only + baseline" above.
- **Guarded rename, never a silent collision**: `sync()` refuses to rename onto a name that's
  already a different live branch — see "Renaming: deliberate vs. incidental" above.
- Plus the Neon-side **branch protection** on production (step 6).

## Gotchas

- **`.env.neondb`'s DATABASE_URL is managed by this script** — hand-edit the other vars freely,
  but don't hand-edit `DATABASE_URL`; the next `provision()` overwrites it anyway.
- **`provision()` discards workspace data on every re-run** — any row written through normal app
  usage (not just seed fixtures) is gone the next time setup runs. If you need data to persist
  across a re-provision, put it in the seed script, not in ad hoc rows.
- **A plain single-clone checkout ties identity to the git branch** — switching branches without
  running `db:provision` for the new one will hit `sync`'s hard gate (unprovisioned) rather than
  silently reusing or renaming the previous branch's database.
- **Cold computes are expected** — a branch whose compute has never been connected to can take a
  while to boot; provisioning retries with exponential backoff around every Neon API step.
- **Seeding is opt-in** — if the seed credential isn't set, provisioning logs a warning and the
  workspace comes up empty rather than failing setup.
- **A `tmp/*` branch appears briefly during every provision** — it's the disposable check branch
  used to read the true migration ledger; seeing one linger past a run means it leaked (an
  interrupted provision), and the next `provision()`/`teardown()` sweeps it up automatically.
- **`execSql` is required for both ORMs** — reading the true migration ledger back needs a real
  query result, which neither `prisma db execute` nor `drizzle-kit` gives you.
