---
name: conductor-neon-db
description: >-
  Set up fully isolated per-workspace databases for Conductor: each workspace gets its own
  instant schema-only Neon branch off production (full schema, zero production data), baselined
  against production's TRUE applied-migration state — not assumed from local files — via a
  disposable full-data check branch (Prisma or Drizzle), with test fixtures seeded, plus the
  .conductor/settings.toml that wires setup/run/archive. provision() fully rebuilds the branch on
  every run. Manual-only — run in a Neon + Prisma or Neon + Drizzle project to add the setup.
disable-model-invocation: true
---

# Per-workspace isolated databases for Conductor (Neon + Prisma or Drizzle)

## What this sets up

Every Conductor workspace — local and cloud, identically — gets its **own** database, so
parallel agents never read or write the same rows. `provision()` (`setup`) is a **full,
deterministic rebuild — every run, not just the first**: it deletes whatever branch is currently
recorded for the workspace (if any) and creates a fresh one. Any data written into the workspace
branch through normal app usage is discarded on every re-run — the branch is disposable by
design; there is no "reuse an existing branch, keep its data" path. Each run:

1. Creates an **instant schema-only Neon branch** off the production branch — the full schema
   and extensions (e.g. PostGIS reference data), but **zero production rows**. Neon copies no
   data, so this is fast and cheap, and no production data ever lands in a dev workspace.
2. **Baselines the ORM's migration history against production's TRUE applied-migration
   state** — Prisma or Drizzle (see "Why" below) — by cloning production a *second* time, this
   time **with data**, into a disposable `tmp/*` check branch, reading that clone's real ledger
   rows, seeding the workspace branch's (empty) ledger with exactly those rows, then deleting the
   check branch. The ORM's migrate-deploy then applies whatever's genuinely still missing. A
   `pending` marker in the state file covers the whole rebuild window; a provision killed
   mid-flight is recovered on the next run by deleting whatever's there and starting over —
   there's nothing to "recover" more gently, since the branch is disposable by design.
3. **Seeds** test fixtures.
4. Writes the branch's connection string to `.env.neondb` as `DATABASE_URL` (its own file — the
   project's real `.env` is never touched; the run script loads it via `dotenv -e .env.neondb -o`).
5. Records the branch name in `.conductor/db-branch` (gitignored) so archive deletes the **same**
   branch even if the workspace is renamed later — a rename changes `CONDUCTOR_WORKSPACE_NAME`,
   which would otherwise re-derive a different slug and silently miss the real branch.

On every dev-server start, `sync` refuses to start an unprovisioned or half-rebuilt workspace
(missing `.env.neondb`, or a setup still marked `pending` → hard non-zero exit, because
`dotenv -e` silently proceeds without the file and the app would boot against a shared/ambient
`DATABASE_URL`, or against an unbaselined, unseeded branch), then best-effort renames the Neon
branch to match a renamed workspace (Conductor has no rename event, so it piggybacks on `run` —
a real Neon rename, not delete+recreate, so data and `DATABASE_URL` are untouched). On archive,
the branch is deleted — **loudly**: a missing `NEON_API_KEY`/`NEON_PROJECT_ID` or a failed
delete exits non-zero instead of warning-and-continuing, because silently swallowed teardown
failures are exactly how Neon branches leak past Conductor's archive step. (An already-absent
branch is "nothing to clean", not an error — teardown stays idempotent. Archive also sweeps for
a leaked `tmp/*` check branch, in case a provision was killed between creating one and cleaning
it up.) The whole thing is driven by `.conductor/settings.toml`.

## When this applies

- The project's database is on **Neon** (branching is a Neon feature).
- Migrations are managed by **Prisma** or **Drizzle** (set the `ORM` knob in the script).
- `neonctl` and `tsx` are available as project-local dev dependencies, plus a Node package
  manager (pnpm/npm/yarn). **Both ORMs** need the project's existing Postgres driver
  (`@neondatabase/serverless` / `postgres` / `pg`) wired into the script's `execSql()` knob —
  reading production's true migration ledger back needs a real query result, which neither
  `prisma db execute` nor `drizzle-kit` gives you.

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
run every migration committed on this code branch, and never checks. If it hasn't (a migration
merged but not yet deployed, or production simply behind), that migration gets falsely marked
applied without ever running on the workspace branch, and the app breaks the moment it touches
whatever that migration created — silently, since the migrator now believes it's "up to date".

So provisioning learns production's **true** applied-migration set instead of assuming it:

1. Clone production a *second* time — this time **with data** — into a disposable `tmp/*` check
   branch. Row data is the only source of truth for "what really ran"; a schema-only clone
   strips it, even for the migrations table itself.
2. Read that clone's real migration-ledger rows.
3. Delete the check branch — production itself is never connected to directly, only this
   disposable clone of it.
4. Seed the workspace branch's (empty) ledger with **exactly those rows**, verbatim — not
   recomputed from local files.
5. Run the ORM's migrate-deploy, which now applies whatever's genuinely still missing. Correct
   whether production has every migration, none of them, or is only partway caught up — and
   self-healing: once production catches up, the next `provision()` run picks up the corrected
   true state automatically, no manual fix needed.

The two ORMs differ only in the ledger table and the row shape — both read from the check branch
and write into the workspace branch, never from local files:

- **Prisma** — `_prisma_migrations`. Only rows Prisma itself considers genuinely applied
  (`finished_at` set, `rolled_back_at` null — the same definition `prisma migrate status` uses)
  count as "true". The captured `checksum` and `migration_name` are inserted verbatim. After
  baselining, `prisma migrate status` reports "up to date" for whatever's actually there, and
  `migrate deploy` applies the rest.
- **Drizzle** — `drizzle.__drizzle_migrations`. Each captured row is `hash` + `created_at`,
  inserted verbatim. drizzle-kit decides what to run by the **latest `created_at`**, so this must
  be the value production's own ledger recorded, not a value re-derived from the journal. After
  baselining, `drizzle-kit migrate` applies whatever's still missing.

(PostGIS's `spatial_ref_sys` is repopulated for free by the extension — no special handling, ORM
either way.)

## General Conductor patterns (beyond Neon)

The mechanics above are Neon + Prisma/Drizzle-specific, but four things this skill had to solve
are true of **any** Conductor integration with an externally-provisioned resource — worth
knowing even if the project's stack doesn't match "When this applies".

### Pattern: database branch-per-workspace, as an alternative to `run_mode = "nonconcurrent"`

Conductor's default guidance for a project with a database is `run_mode = "nonconcurrent"` —
run one workspace at a time so they can't collide on the same rows. That default exists only
because the database is *shared*; concurrency itself isn't the problem. If the database backend
supports cheap, instant branching — Neon's copy-on-write branches, or similar systems — give
each workspace its own branch in `setup`, point that workspace at only its own branch, and
delete the branch in `archive` — see "What this sets up" above for the concrete mechanics. Once
the database is workspace-scoped, the
reason for `nonconcurrent` is gone and `run_mode = "concurrent"` is safe again. This skill's Neon
implementation is one instance of the pattern — treat it as a template for any project sitting on
a branchable database.

### Fact: Conductor has no workspace-rename lifecycle hook

Conductor exposes `setup`, `run`, and `archive` — nothing fires specifically on a rename. Anything
that must survive a rename (an external resource keyed by workspace name, like the Neon branch
here) has to detect the rename itself. `run` is the only hook that recurs through a workspace's
whole life (`setup` runs once, `archive` runs at the end), so it's the only place to catch up:
record whatever identifier you derived at setup time, and on every `run` re-derive that identifier
from the current environment and compare it to the recorded one. A mismatch means the workspace
was renamed since the last `run`; reconcile the external resource, then update the record. See
`sync`/`renameCatchUp()` in step 4 for the concrete version of this — record vs. re-derive,
compare, reconcile — but the technique applies to any Conductor integration that needs to notice
a rename, not just databases.

### Note: don't branch on `CONDUCTOR_IS_LOCAL` unless local and cloud actually diverge

Conductor sets `CONDUCTOR_IS_LOCAL` so scripts can tell a local workspace from a cloud one, which
makes it tempting to fork setup/run/archive logic on it. Skip that unless the two environments
genuinely need different behavior. When the provisioning API you're calling is the same
call — same HTTP/CLI request — regardless of where the workspace runs, local and cloud workspaces
should do exactly the same thing: set the same secrets in **both** the Local and Cloud tabs of
Conductor's Environment settings (step 5) and let the script run unmodified either way. Reach for
`CONDUCTOR_IS_LOCAL` only when the two environments truly can't share a code path (e.g. a
local-only filesystem path).

### Pattern: chain a verify/sync step before the real command in `run`

Any workspace that depends on an externally-provisioned resource — a DB branch, a bucket, a
search index, a tunnel — needs that resource re-checked on *every* `run`, not just trusted after
`setup`: a workspace can be renamed, the resource can be deleted out-of-band, or setup can have
been interrupted and never finished. Chain a lightweight verify/sync step in front of the real
dev command: `run = "<verify-or-sync-command> && <env-load> -- <dev-command>"` (concretely here:
`tsx scripts/conductor-db.ts sync && dotenv -e .env.neondb -o -- <dev-command>`, step 4). The
verify step should hard-fail (non-zero exit, blocking the dev server) if the resource isn't safe
to use, and can separately best-effort-reconcile cosmetic drift — like the rename catch-up above —
without failing the whole chain over a non-critical hiccup.

## Setup

### 1. Preflight

Confirm the project is Neon + Prisma **or** Neon + Drizzle, and find the package manager
(lockfile: `pnpm-lock.yaml` → pnpm, `package-lock.json` → npm, `yarn.lock` → yarn). Ensure
`neonctl`, `tsx`, and `dotenv-cli` are dev dependencies (`<pm> add -D neonctl tsx dotenv-cli`
if missing — `dotenv-cli` is what loads the generated `.env.neondb` into the dev server, since
nothing auto-loads a non-`.env` file). Note which Postgres driver the project already uses
(`@neondatabase/serverless` / `postgres` / `pg`) — **regardless of ORM** you'll wire it into
`execSql()` in step 2; don't add a new one. Identify the Neon project's **production branch
name** (`neonctl branches list --project-id <id>` — it's the one marked default/primary).

### 2. Add the provisioning script

Copy `scripts/conductor-db.ts` (bundled with this skill) into the project's `scripts/`. Then
adjust the **PORTING KNOBS** block at the top:
- `ORM` — set to `'prisma'` or `'drizzle'`. This switches the ledger table and baseline SQL
  shape throughout.
- `PM_EXEC` — your package manager's exec form (`['pnpm','exec']` / `['npx']` / `['yarn']`).
- `SEED_SCRIPT` and the `seedWorkspace()` body — adapt to the project's seed (see step 6).
- **Wire `execSql()`** to the project's Postgres driver (an example for each driver is in the
  block) and remove its throw — **required for both ORMs now**, not just Drizzle: it both reads
  the true migration ledger back from the disposable check branch and writes the baseline INSERT
  built from those rows. Left unconfigured it raises a clear error.
- **Drizzle only:** `DRIZZLE_MIGRATIONS_SCHEMA`/`DRIZZLE_MIGRATIONS_TABLE` only if you set a
  custom `migrationsSchema`/`migrationsTable` in `drizzle.config`. (Prisma's `_prisma_migrations`
  table name is fixed by Prisma itself — nothing to knob there.)
- `DB_ENV_VARS` — **every** env var that must point at the workspace branch. Defaults to just
  `DATABASE_URL`; if `schema.prisma` uses `directUrl = env("DIRECT_URL")` or
  `shadowDatabaseUrl = env(...)`, add those names, or the project's real `.env` (which the ORM
  CLI still auto-loads) supplies them and migrations silently target the **shared** database.
- `ENV_FILE` (`.env.neondb`) only changes if non-standard — if you do change it, change the
  `dotenv -e` reference in the `run` script (step 4) to match. The state file lives at
  `.conductor/db-branch` (tests may relocate it via `CONDUCTOR_DB_STATE_FILE`; never set that
  in Conductor). Its sibling `.conductor/db-branch-check` tracks the disposable check branch
  across the true-baseline step — same gitignore treatment as the main state file (step 3).

Copy the bundled `tests/conductor-db.test.ts` into the project's test directory — it locks the
safety-critical bits (the `conductor/*`/`tmp/*`-only deletion guard, the slug-collision hash,
the rename-surviving branch-state file, and both ORMs' idempotent true-ledger baseline row
format). Keeping these tested is the main reason this is TypeScript and not a shell script.

### 3. Track the shared settings file in git

Conductor reads `.conductor/settings.toml` from the repo, so it must be committed — but the
per-workspace `.env.neondb`, the `.conductor/db-branch` state file, and any local overrides
must not be. If `.gitignore` ignores all of `.conductor/`, replace that with:

```gitignore
# Conductor: track the shared settings.toml; keep local overrides + generated state untracked
.conductor/*
!.conductor/settings.toml
```

If the repo instead tracks `.conductor/` contents individually (no blanket ignore), you MUST
still add an explicit ignore for the state file — a committed `.conductor/db-branch` puts one
workspace's branch name into every other workspace's checkout, where teardown/sync would trust
it and could delete or rename a *different* workspace's live branch:

```gitignore
.conductor/db-branch*
```

(The `*` also covers the transient `.conductor/db-branch.tmp` the atomic write uses, and the
sibling `.conductor/db-branch-check` + `.conductor/db-branch-check.tmp` that track the disposable
check branch during the true-baseline step — a crash can leave any of them behind, and each
holds a real branch name.) Also make sure `.env*` is gitignored
(it covers the generated `.env.neondb`). Verify with
`git check-ignore -v .conductor/settings.toml` (should print the `!` negation = NOT ignored)
and `git check-ignore .conductor/db-branch` (must print the path = ignored).

### 4. Create `.conductor/settings.toml`

```toml
"$schema" = "https://conductor.build/schemas/settings.repo.schema.json"

# Local and cloud workspaces behave identically: setup installs deps, generates the Prisma
# client, then FULLY REBUILDS an isolated SCHEMA-ONLY Neon branch (scripts/conductor-db.ts) —
# every run, discarding any data from a prior run — baselines its migration history against
# production's TRUE applied-migration state (via a disposable full-data check branch, never
# production directly), and seeds fixtures. archive deletes the branch.
# run refuses to start if .env.neondb is missing (unprovisioned workspace), then best-effort
# syncs the Neon branch's name to match the workspace (Conductor has no rename event, so this
# catches up on the next dev-server start after a rename), then loads the generated
# .env.neondb and starts the dev server.
# Secrets come from Conductor's Environment tabs — NEVER commit them here, and NEVER put
# DATABASE_URL there (the setup script owns it).

[scripts]
setup = "corepack enable pnpm && pnpm install --frozen-lockfile && pnpm exec prisma generate && pnpm exec tsx scripts/conductor-db.ts provision"
archive = "pnpm exec tsx scripts/conductor-db.ts teardown"
run = "pnpm exec tsx scripts/conductor-db.ts sync && pnpm exec dotenv -e .env.neondb -o -- pnpm dev --port $CONDUCTOR_PORT"
run_mode = "concurrent"
```

Adapt the `setup`/`run` commands to the project's package manager and dev server. **For Drizzle**,
drop the `prisma generate` step (Drizzle has no client-generate step — `drizzle-kit generate`
produces migration *files* at dev time and doesn't belong in workspace setup). `run_mode` can be
`concurrent` because each workspace has its own DB and its own `$CONDUCTOR_PORT`. Re-running
`setup` manually (not just via Conductor's own lifecycle) also fully rebuilds the branch —
expected, not a bug; see Safety model. `sync`'s
rename part is internally best-effort — it warns and exits 0 on any failure, so a Neon hiccup
can never block the dev server over a cosmetic branch rename. Its **hard gates** are
deliberate, though — it exits non-zero when the workspace database isn't safe to use:
`.env.neondb` missing (provisioning never succeeded — and `dotenv -e` silently proceeds
without the file, which would boot the app against a shared/ambient `DATABASE_URL`), setup
still marked `pending` (an interrupted provision left an unbaselined, unseeded branch), or the
recorded branch no longer existing in Neon (the env file points at a dead endpoint). Each
error names the fix — almost always "re-run workspace setup".

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
to `runWithRetry('prisma', ['db', 'seed'], childDbEnv(uri), 2)`; a Drizzle project typically
seeds via a tsx script — `runWithRetry('tsx', [SEED_SCRIPT], childDbEnv(uri), 2)`. Always build
the env with `childDbEnv(uri)` (not a hand-rolled `{ ...process.env, DATABASE_URL: uri }`) so
every var in `DB_ENV_VARS` — e.g. a `DIRECT_URL` — is pinned to the branch too. If there's no
seed, delete `seedWorkspace()` and its call.

### 7. Verify

- `<pm> exec tsc --noEmit` (and run the bundled test if you copied it).
- **Protect the production branch in Neon** (console → branch → Protect, or
  `neonctl branches set-protection`) so nothing can delete or reset it at the platform level.
- For end-to-end confidence against real Neon, follow `references/verify.md` — it provisions a
  throwaway branch, confirms the schema-only → true-ledger baseline → migrate-deploy → seed
  flow, and deletes both it and the disposable check branch.

## Safety model

The script can't harm production, by construction:
- **Name guard** (`assertDisposableChildBranch`, unit-tested): every destructive op (delete
  **and** rename) refuses to run unless the target starts with `conductor/` (workspace branch)
  **or** `tmp/` (disposable check branch) and isn't the parent. `production` can't match. A
  stricter sibling, `assertDisposableCheckBranch` (also unit-tested), further requires `tmp/`
  specifically wherever only a check branch is a valid target — so a corrupted check-branch
  record that happens to hold a `conductor/*` name (e.g. this workspace's own branch) can't be
  accepted as a "valid" check branch and deleted by check-branch cleanup logic.
- **Child-only targeting, never the parent directly**: every SQL connection — baseline read,
  baseline write, migrate, seed — targets either the workspace branch or the disposable check
  branch's connection string. `provision()` never opens a connection to the parent; it only ever
  clones it (schema-only for the workspace branch, full-data for the check branch) and reads the
  clone.
- **No slug collisions** (unit-tested): over-long workspace names are truncated with a short
  hash of the full name appended, under **each** prefix independently (`conductor/` and `tmp/`
  share the same derivation — see `branchNameWithPrefix`), so two long names sharing a prefix
  can't land on the same branch — which would break isolation and let one workspace's teardown
  delete another's.
- **Self-destruct on failure**: if *anything* after branch creation fails (connection-string
  fetch, `.env.neondb` write, true-baseline, migrate, seed), the just-created workspace branch is
  deleted — along with its state file and the stale `.env.neondb` — so a half-set-up branch is
  never left masquerading as done, never leaked, and never leaves an env file pointing at a dead
  endpoint. If that cleanup delete itself fails, the state file is deliberately *kept* (still
  marked `pending`) so a later provision or teardown can still find the surviving branch.
  `seedTrueBaseline()`'s own disposable check branch has the identical self-destruct: its
  `finally` block deletes it whether the baseline read/write succeeded or failed, and a cleanup
  failure there fails loudly too (unless it's piggybacking on an already-in-flight failure, in
  which case teardown's sweep — below — is the backstop, not a swallowed error).
- **Every `provision()` run is a full, deterministic rebuild — by design, not a bug**: it always
  deletes whatever branch is currently recorded for the workspace (if it still exists) and
  creates a fresh one, discarding any data written into it since the last provision. There is no
  "reuse a ready branch and keep its data" path. This also means baselining is never done
  against a *reused* branch's already-partially-applied state — every baseline write targets a
  branch whose ledger is provably empty (freshly created), so the idempotent `WHERE NOT EXISTS`
  in the baseline SQL is defense-in-depth, not something normally exercised.
- **True-ledger baseline, not a local-file assumption**: the workspace branch's migration ledger
  is seeded from rows read out of a disposable full-data clone of production — never
  reconstructed from the repo's migration files. This is what prevents the schema drift bug this
  mechanism replaced: baselining from local files assumes production has run every migration
  committed on this code branch, and is silently wrong the moment that's false (see "Why" above).
- **Rename-safe, idempotent teardown** (unit-tested state handling): provision records the
  exact branch name in `.conductor/db-branch`; teardown prefers that record over re-deriving
  from `CONDUCTOR_WORKSPACE_NAME` (and checks both when they differ), so renaming a workspace
  can't orphan its Neon branch. A workspace rename is now handled for free by the rebuild itself:
  provision deletes whatever's recorded under the OLD name (if it still exists) and creates fresh
  under the CURRENT derived name — no rename API call, no orphan. Teardown is **loud** on real
  failures (missing Neon credentials or a failed delete exit non-zero) but treats an
  already-absent branch as "nothing to clean" — an absent branch cannot leak, and archive of a
  never-provisioned workspace must not error. Teardown also **sweeps for a leaked `tmp/*` check
  branch** (preferring its own persisted record, falling back to the derived name), in case a
  provision was killed between creating one and its own cleanup.
- **`sync` is fenced**: it guards *both* the recorded and the derived name before renaming, and
  is best-effort — any failure only leaves a cosmetically stale branch name in the Neon console.
- Plus the Neon-side **branch protection** on production (step 7).

## Gotchas

- **`file_include_globs` is top-level only** — it does not go inside `[scripts]`. Conductor's
  settings schema sets `additionalProperties: false` on `[scripts]`, so nesting it there fails
  schema validation, but the failure isn't surfaced as an obvious "unknown key at line N" — it
  just silently doesn't do what you expect. If the project needs Conductor to carry a gitignored
  file (e.g. `.env.local`) into every new workspace, add `file_include_globs` as its own key in
  `.conductor/settings.toml`, a sibling of `[scripts]`, not a child of it:
  ```toml
  file_include_globs = """
  .env.local
  """

  [scripts]
  setup = "..."
  ```
- **`DATABASE_URL` must not be in Conductor's env tabs** (step 5) — it overrides the per-workspace branch.
- **`directUrl` / `shadowDatabaseUrl` leak the shared DB** if not covered: the ORM CLI and dev
  server still auto-load the project's real `.env`, so any DB URL var defined there that isn't
  in `DB_ENV_VARS` (step 2) wins for that connection — e.g. Prisma would run migrations over a
  shared `DIRECT_URL` while `DATABASE_URL` correctly points at the branch. List every DB URL
  var the schema references in `DB_ENV_VARS`.
- **Nothing auto-loads `.env.neondb`**: the script passes `DATABASE_URL` to every child process
  it spawns, and the `run` script loads the file via `dotenv -e .env.neondb -o --`. Anything else
  that needs the workspace DB (a manual `prisma studio`, an e2e runner, a one-off script) needs
  the same `dotenv -e .env.neondb -o --` prefix — a bare `pnpm exec prisma studio` will not see
  it, and a bare destructive command (`prisma migrate reset`, `db push`) hits whatever the real
  `.env` points at. Consider adding a package.json wrapper (e.g.
  `"db": "dotenv -e .env.neondb -o --"`) so `pnpm db prisma studio` is the easy path.
- **`provision()` discards workspace data on every re-run — not just after a crash**: every
  `setup` run deletes whatever branch is currently recorded and creates a fresh one. Any row
  written into the workspace database through normal app usage (not just seed fixtures) is gone
  the next time setup runs, whether that's Conductor re-running it, a manual re-run to pick up a
  new migration, or anything else. There is no "reuse and keep the data" mode. If you need to
  poke at data and keep it across a setup re-run, that data belongs in the seed script (which
  re-applies every run), not in ad hoc rows.
- **Upgrading from the old data-preserving version of this script**: an earlier version of this
  mechanism reused a fully set-up branch and preserved its data across re-provisions, baselining
  only from local migration files. If a project is upgrading from that version, the **first**
  setup run under this version will delete and rebuild every existing live workspace's branch —
  intended (it's also what fixes the baseline-drift bug that motivated this rewrite), but worth
  flagging to anyone with data sitting in a workspace branch they were relying on.
- **Upgrading from a pre-state-file version of this script**: existing workspaces have `.env`
  (not `.env.neondb`) and no state record, so the first dev-server start fails `sync`'s gate —
  by design. **Re-run workspace setup once per live workspace** to recover: provision rebuilds
  the branch from scratch (see above — this also discards whatever was in the old `.env`-era
  branch), writes `.env.neondb`, and records the state file; from then on renames are safe. Long
  workspace names provisioned under the old flat 48-char truncation are found automatically
  (provision, sync, and teardown all check the legacy name as a fallback) — but if two live
  pre-upgrade workspaces already share a flat-truncated name, they were already sharing one
  branch under the old scheme; the hash suffix only prevents new collisions going forward.
- **Cold computes are expected**: a branch whose compute has never been connected to (just
  created) can take a while to boot. Provisioning retries with exponential backoff (2s, 4s, 8s,
  …) around branch create, both connection-string fetches (workspace branch and check branch),
  and — with the biggest budget, 6 attempts — the true-baseline read and write, which are the
  first real connections to each branch. Slow first provisions are normal; only repeated
  exhaustion is an error.
- **Seeding is opt-in**: if the seed credential isn't set, provisioning logs a warning and the
  workspace comes up empty rather than failing setup. Set it to seed.
- **A `tmp/*` branch appears briefly in the Neon console during every provision**: this is the
  disposable full-data check branch used to read production's true migration ledger — it's
  created, read, and deleted within one `provision()` run. Seeing one linger past a run finishing
  means it leaked (an interrupted provision, or a cleanup delete that itself failed); the next
  `provision()` or `archive` cleans it up (see Safety model's teardown sweep). Never manually
  delete a `tmp/*` branch while a provision is in flight — let the script's own guarded cleanup
  handle it.
- **`execSql` is required for both ORMs now**, not just Drizzle: unlike the old file-derived
  baseline (Prisma could run its INSERT via `prisma db execute --stdin`, no driver needed),
  reading production's true migration ledger back needs a real query result, which neither
  `prisma db execute` nor `drizzle-kit` gives you — only the project's own Postgres driver does.
  Left unconfigured, provisioning fails fast with a clear remediation message.
- **Renaming a workspace is safe but eventually consistent**: teardown targets the recorded
  branch; a rename between provision runs is absorbed for free by the next full rebuild (the OLD
  recorded branch is deleted, a fresh one is created under the CURRENT name); and between
  rebuilds, the Neon branch name itself catches up on the next dev-server start (`sync`'s
  best-effort rename). One caveat: don't create a *new* workspace under a just-vacated name until
  the renamed workspace's dev server has restarted once (so `sync` moved its branch) — branch
  identity is name-keyed, and the new workspace would otherwise adopt the old workspace's
  still-unrenamed branch.
- **Branches branch from the default branch** in Conductor — the check branch and the workspace
  branch both clone whatever `NEON_PARENT_BRANCH` names, normally the same default/production
  branch the code branch itself is based on.
