---
name: conductor-neon-db
description: >-
  Set up fully isolated per-workspace databases for Conductor: each workspace gets its own
  instant schema-only Neon branch off production (full schema, zero production data), with the
  ORM's migration history baselined (Prisma or Drizzle) and test fixtures seeded, plus the
  .conductor/settings.toml that wires setup/run/archive. Manual-only — run in a Neon + Prisma
  or Neon + Drizzle project to add the setup.
disable-model-invocation: true
---

# Per-workspace isolated databases for Conductor (Neon + Prisma or Drizzle)

## What this sets up

Every Conductor workspace — local and cloud, identically — gets its **own** database, so
parallel agents never read or write the same rows. On workspace setup, `scripts/conductor-db.ts`:

1. Creates an **instant schema-only Neon branch** off the production branch — the full schema
   and extensions (e.g. PostGIS reference data), but **zero production rows**. Neon copies no
   data, so this is fast and cheap, and no production data ever lands in a dev workspace.
2. **Baselines** the ORM's migration history — Prisma or Drizzle (see "Why" below). The
   baseline is idempotent, so re-provisioning also recovers a branch whose first setup died
   halfway.
3. **Seeds** test fixtures.
4. Writes the branch's connection string to `.env.neondb` as `DATABASE_URL` (its own file — the
   project's real `.env` is never touched; the run script loads it via `dotenv -e .env.neondb`).
5. Records the branch name in `.conductor/db-branch` (gitignored) so archive deletes the **same**
   branch even if the workspace is renamed later — a rename changes `CONDUCTOR_WORKSPACE_NAME`,
   which would otherwise re-derive a different slug and silently miss the real branch.

On every dev-server start, a best-effort `sync` renames the Neon branch to match a renamed
workspace (Conductor has no rename event, so it piggybacks on `run` — a real Neon rename, not
delete+recreate, so data and `DATABASE_URL` are untouched). On archive, the branch is deleted —
**loudly**: a missing `NEON_API_KEY`/`NEON_PROJECT_ID` or a failed delete exits non-zero instead
of warning-and-continuing, because silently swallowed teardown failures are exactly how Neon
branches leak past Conductor's archive step. The whole thing is driven by
`.conductor/settings.toml`.

## When this applies

- The project's database is on **Neon** (branching is a Neon feature).
- Migrations are managed by **Prisma** or **Drizzle** (set the `ORM` knob in the script).
- `neonctl` and `tsx` are available as project-local dev dependencies, plus a Node package
  manager (pnpm/npm/yarn). For **Drizzle** you also need the project's existing Postgres driver
  (`@neondatabase/serverless` / `postgres` / `pg`) wired into the script's `execSql()` knob —
  Drizzle has no `prisma db execute` equivalent for running the baseline INSERT.

If the stack is different (not Neon, or not Prisma/Drizzle), the exact mechanics here don't
transfer — adapt the script's knobs, or tell the user this skill assumes Neon + Prisma/Drizzle
and stop.

## Why schema-only + baseline (the one non-obvious part)

A schema-only Neon branch gives you the schema and extensions but an **empty migrations table**
(the migration history is table *data*, which schema-only doesn't copy). If you leave it empty,
the migrator thinks nothing is applied, tries to recreate every table, and fails because the
tables already exist. So provisioning **baselines** the history — reconstructing it from the
repo's own migration files, marking every migration applied. It **never reads from production**;
the migration files are the source of truth. The two ORMs differ only in the table and the row:

- **Prisma** — the `_prisma_migrations` table. Each row's `checksum` is Prisma's own sha256 hex
  of the `migration.sql`. After baselining, `prisma migrate status` reports "up to date" and
  `migrate dev` works normally.
- **Drizzle** — the `drizzle.__drizzle_migrations` table. Each row is `hash` (sha256 hex of the
  migration's `.sql` file) plus `created_at` (the `when` timestamp from `meta/_journal.json`) —
  exactly what drizzle-kit would have written. drizzle-kit decides what to run by the **latest
  `created_at`**, so the timestamps must come from the journal, not `now()`. After baselining,
  `drizzle-kit migrate` finds nothing to apply.

(PostGIS's `spatial_ref_sys` is repopulated for free by the extension — no special handling, ORM
either way.)

This baseline assumes the **parent branch already contains the code's committed migrations** —
true for the normal Conductor flow (workspaces branch from the default branch; production is
deployed from it). If the parent ever lags, rebuild in the workspace (`prisma migrate reset`, or
drop the branch and re-provision for Drizzle).

## Setup

### 1. Preflight

Confirm the project is Neon + Prisma **or** Neon + Drizzle, and find the package manager
(lockfile: `pnpm-lock.yaml` → pnpm, `package-lock.json` → npm, `yarn.lock` → yarn). Ensure
`neonctl`, `tsx`, and `dotenv-cli` are dev dependencies (`<pm> add -D neonctl tsx dotenv-cli`
if missing — `dotenv-cli` is what loads the generated `.env.neondb` into the dev server, since
nothing auto-loads a non-`.env` file). For Drizzle,
note which Postgres driver the project already uses (`@neondatabase/serverless` / `postgres` /
`pg`) — you'll wire it into `execSql()` in step 2; don't add a new one. Identify the Neon
project's **production branch name** (`neonctl branches list --project-id <id>` — it's the one
marked default/primary).

### 2. Add the provisioning script

Copy `scripts/conductor-db.ts` (bundled with this skill) into the project's `scripts/`. Then
adjust the **PORTING KNOBS** block at the top:
- `ORM` — set to `'prisma'` or `'drizzle'`. This switches the baseline + reuse logic throughout.
- `PM_EXEC` — your package manager's exec form (`['pnpm','exec']` / `['npx']` / `['yarn']`).
- `SEED_SCRIPT` and the `seedWorkspace()` body — adapt to the project's seed (see step 6).
- **Prisma:** `PRISMA_MIGRATIONS_DIR`, `PRISMA_SCHEMA` only change if non-standard.
- **Drizzle:** `DRIZZLE_MIGRATIONS_DIR` (the folder with `meta/_journal.json` + `<tag>.sql`),
  and `DRIZZLE_MIGRATIONS_SCHEMA`/`DRIZZLE_MIGRATIONS_TABLE` only if you set a custom
  `migrationsSchema`/`migrationsTable` in `drizzle.config`. **Wire `execSql()`** to the
  project's Postgres driver (an example for each driver is in the block) and remove its throw —
  this is what runs the baseline INSERT. Left unconfigured it raises a clear error.
- `ENV_FILE` (`.env.neondb`) and `BRANCH_STATE_FILE` (`.conductor/db-branch`) only change if
  non-standard — if you do change `ENV_FILE`, change the `dotenv -e` reference in the `run`
  script (step 4) to match.

Copy the bundled `tests/conductor-db.test.ts` into the project's test directory — it locks the
safety-critical bits (the `conductor/*`-only deletion guard, the slug-collision hash, the
rename-surviving branch-state file, and both ORMs' idempotent baseline row format). Keeping
these tested is the main reason this is TypeScript and not a shell script.

### 3. Track the shared settings file in git

Conductor reads `.conductor/settings.toml` from the repo, so it must be committed — but the
per-workspace `.env.neondb`, the `.conductor/db-branch` state file, and any local overrides
must not be. If `.gitignore` ignores all of `.conductor/`, replace that with:

```gitignore
# Conductor: track the shared settings.toml; keep local overrides + generated state untracked
.conductor/*
!.conductor/settings.toml
```

(The `.conductor/*` rule is also what keeps the generated `.conductor/db-branch` untracked.)
Also make sure `.env*` is gitignored (it covers the generated `.env.neondb`). Verify with
`git check-ignore -v .conductor/settings.toml` (should print the `!` negation = NOT ignored).

### 4. Create `.conductor/settings.toml`

```toml
"$schema" = "https://conductor.build/schemas/settings.repo.schema.json"

# Local and cloud workspaces behave identically: setup installs deps, generates the Prisma
# client, then provisions an isolated SCHEMA-ONLY Neon branch (scripts/conductor-db.ts),
# baselines its migration history, and seeds fixtures. archive deletes the branch.
# run first syncs the Neon branch's name to match the workspace (Conductor has no rename
# event, so this catches up on the next dev-server start after a rename — best-effort, never
# blocks the dev server), then loads the generated .env.neondb and starts the dev server.
# Secrets come from Conductor's Environment tabs — NEVER commit them here, and NEVER put
# DATABASE_URL there (the setup script owns it).

[scripts]
setup = "corepack enable pnpm && pnpm install --frozen-lockfile && pnpm exec prisma generate && pnpm exec tsx scripts/conductor-db.ts provision"
archive = "pnpm exec tsx scripts/conductor-db.ts teardown"
run = "pnpm exec tsx scripts/conductor-db.ts sync && pnpm exec dotenv -e .env.neondb -- pnpm dev --port $CONDUCTOR_PORT"
run_mode = "concurrent"
```

Adapt the `setup`/`run` commands to the project's package manager and dev server. **For Drizzle**,
drop the `prisma generate` step (Drizzle has no client-generate step — `drizzle-kit generate`
produces migration *files* at dev time and doesn't belong in workspace setup). `run_mode` can be
`concurrent` because each workspace has its own DB and its own `$CONDUCTOR_PORT`. `sync` is
chained with `&&` but is internally best-effort — it warns and exits 0 on any failure, so a
Neon hiccup can never block the dev server over a cosmetic branch rename.

### 5. Tell the user the Conductor environment variables to set

These go in **Conductor → Settings → Environment**, in **both the Local and Cloud tabs** (a
cloud workspace can't see the Mac, so it needs them too). They are secrets — do NOT commit them.

| Variable | Purpose |
|---|---|
| `NEON_API_KEY` | Neon API key (create one in the Neon console) — required by provision **and** teardown (teardown fails loudly without it, by design) |
| `NEON_PROJECT_ID` | the Neon project id — required by provision **and** teardown |
| `NEON_PARENT_BRANCH` | branch to clone, e.g. `production` (provision-only; teardown/sync use it just for the safety guard) |
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
to `runWithRetry('prisma', ['db', 'seed'], { ...process.env, DATABASE_URL: uri }, 2)`; a Drizzle
project typically seeds via a tsx script — `runWithRetry('tsx', [SEED_SCRIPT], { ...process.env,
DATABASE_URL: uri }, 2)`. If there's no seed, delete `seedWorkspace()` and its call.

### 7. Verify

- `<pm> exec tsc --noEmit` (and run the bundled test if you copied it).
- **Protect the production branch in Neon** (console → branch → Protect, or
  `neonctl branches set-protection`) so nothing can delete or reset it at the platform level.
- For end-to-end confidence against real Neon, follow `references/verify.md` — it provisions a
  throwaway branch, confirms the schema-only + baseline + seed flow, and deletes it.

## Safety model

The script can't harm production, by construction:
- **Name guard** (`assertDisposableChildBranch`, unit-tested): every destructive op (delete
  **and** rename) refuses to run unless the target starts with `conductor/` and isn't the
  parent. `production` can't match.
- **Child-only targeting**: baseline/seed/migrate only ever use the freshly-created
  `conductor/<slug>` branch's connection string — never the parent's.
- **No slug collisions** (unit-tested): over-long workspace names are truncated with a short
  hash of the full name appended, so two long names sharing a prefix can't land on the same
  branch — which would break isolation and let one workspace's teardown delete another's.
- **Self-destruct on failure**: if *anything* after branch creation fails (connection-string
  fetch, `.env.neondb` write, baseline, seed), the just-created branch and its state file are
  deleted so a half-set-up branch is never reused — and never leaked. Only a branch this run
  created is ever deleted here; a reused branch (which holds real data) is left alone.
- **Reuse preserves data**: re-provisioning an existing workspace branch keeps its data — it
  re-runs only the *idempotent* baseline (`WHERE NOT EXISTS`, recovering a branch whose first
  setup died mid-way) and the ORM's migrate-deploy (`prisma migrate deploy` /
  `drizzle-kit migrate`); it never re-seeds.
- **Rename-safe teardown** (unit-tested): provision records the exact branch name in
  `.conductor/db-branch`; teardown prefers that record over re-deriving from
  `CONDUCTOR_WORKSPACE_NAME`, so renaming a workspace can't orphan its Neon branch. Teardown is
  also **loud**: missing Neon credentials or a failed delete exit non-zero instead of
  warning-and-returning.
- **`sync` is fenced**: it guards *both* the recorded and the derived name before renaming, and
  is best-effort — any failure only leaves a cosmetically stale branch name in the Neon console.
- Plus the Neon-side **branch protection** on production (step 7).

## Gotchas

- **`DATABASE_URL` must not be in Conductor's env tabs** (step 5) — it overrides the per-workspace branch.
- **Nothing auto-loads `.env.neondb`**: the script passes `DATABASE_URL` to every child process
  it spawns, and the `run` script loads the file via `dotenv -e .env.neondb --`. Anything else
  that needs the workspace DB (a manual `prisma studio`, an e2e runner, a one-off script) needs
  the same `dotenv -e .env.neondb --` prefix — a bare `pnpm exec prisma studio` will not see it.
- **Cold computes are expected**: a branch whose compute has never been connected to (just
  created, or just renamed) can take a while to boot. Provisioning retries with exponential
  backoff (2s, 4s, 8s, …) around branch create, the connection-string fetch, and — with the
  biggest budget, 6 attempts — the baseline, which is the first real connection. Slow first
  provisions are normal; only repeated exhaustion is an error.
- **Seeding is opt-in**: if the seed credential isn't set, provisioning logs a warning and the
  workspace comes up empty rather than failing setup. Set it to seed.
- **Renaming a workspace is safe but eventually consistent**: teardown always targets the
  recorded branch, and the Neon branch name itself catches up on the next dev-server start
  (`sync`). Workspaces provisioned before the state file existed fall back to re-deriving the
  name — fine as long as they weren't renamed.
- **Baseline assumption**: parent (production) must contain the code's committed migrations; if
  it lags, rebuild in the workspace (`prisma migrate reset`, or drop the branch and re-provision
  for Drizzle).
- **Drizzle needs `execSql` wired** (step 2): unlike Prisma's `db execute`, Drizzle has no SQL-
  runner CLI, so the baseline INSERT runs through the project's own Postgres driver. Left
  unconfigured, provisioning fails fast with a clear remediation message.
- **Branches branch from the default branch** in Conductor, which is why parent == code migrations
  in the normal case.
