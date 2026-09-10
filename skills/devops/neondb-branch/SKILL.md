---
name: neondb-branch
description: >-
  Set up fully isolated per-workspace Neon databases for any git repo: each workspace gets its own
  ordinary child branch of production, pinned at a captured parent WAL LSN, whose inherited
  production rows are purged in one transaction while the migration ledger is kept — so no extra
  root-branch slot is consumed (schema-only branches are root branches and cause
  ROOT_BRANCHES_LIMIT_EXCEEDED) and the ORM's applied-migration history is production's real one, not
  an assumption. Lifecycle lives in .neondb/state.json (branchId + projectId + status), so a git
  branch change or workspace rename never switches database ownership. Works with Prisma or Drizzle.
  No orchestration tool required — plain package.json scripts drive provision/sync/teardown, with
  workspace identity resolved from Conductor, Orca, a general WORKSPACE_NAME, or the current git
  branch. Ships ready-to-use Conductor and Orca config templates. provision() fully rebuilds the
  branch on every run. Manual-only — run in a Neon + Prisma or Neon + Drizzle project to add the
  setup.
disable-model-invocation: true
metadata:
  author: martintechlabs
  version: "0.2.0"
---

# Per-workspace isolated Neon databases (Prisma or Drizzle, any git repo)

## What this sets up

Every workspace — a Conductor workspace, an Orca worktree, or a plain git checkout on its own
branch — gets its **own** database, so parallel agents never read or write the same rows.
`provision()` is a **full, deterministic rebuild — every run, not just the first**: it deletes the
branch currently recorded for the workspace and creates a fresh one. Data written into the workspace
branch through normal app usage is discarded on every re-run; the branch is disposable by design.

Each `provision()` run:

1. Resolves the configured production branch and captures its current WAL LSN.
2. Creates an **ordinary, full-data child** of that branch, pinned at that LSN, via the Neon REST
   API — so the branch has a real `parent_id` and `parent_lsn` and consumes **no root-branch slot**.
3. **Verifies** the returned branch (id, exact name, parent, captured LSN, and that it is not
   default/primary/protected) before running a single destructive statement against it.
4. **Purges** every application row in one transaction, preserving the inherited migration ledger and
   every extension-owned table, then confirms the application tables are empty.
5. Publishes `DATABASE_URL` (and any other `DB_ENV_VARS`) to `.env.neondb` — only now, after the
   purge is verified.
6. Applies migrations this checkout has that production did not, then **seeds** test fixtures.
7. Records `status: "ready"` in `.neondb/state.json`.

## Why an ordinary child, and what it costs you

Neon **schema-only branches are root branches**: they have no parent, and `--parent` only names the
schema donor. Root-branch allowances are 3 (Free), 5 (Launch), 25 (Scale) per project, so a handful
of parallel workspaces is enough to hit `ROOT_BRANCHES_LIMIT_EXCEEDED` and block all provisioning.
An ordinary child consumes no root slot.

It also removes an entire mechanism. A schema-only branch starts with an **empty** migrations table,
because migration history is table *data*. The previous design compensated by cloning production a
second time, with data, into a disposable `tmp/*` branch purely to read the real ledger rows back.
An ordinary child inherits that ledger directly — so the second clone, the ledger read, and the
baseline INSERT are all gone.

> ### ⚠️ A workspace branch is not a privacy boundary
>
> An ordinary child **initially contains production data**, and Neon's history window can retain
> that data in the branch's own snapshots **even after the purge**. The purge empties the current
> state; it does not erase history.
>
> Consequences to take seriously:
>
> - **Never start the app against a branch that has not finished provisioning.** `load-env.cjs`
>   refuses to boot unless `.neondb/state.json` reads `ready`, and `sync` gates the same way. Do not
>   remove either guard, and do not hand-write a `DATABASE_URL` that bypasses them.
> - **Never "Reset from parent" or restore a workspace branch from production.** That re-materializes
>   every production row and nothing purges it afterwards — provisioning is the only code path that
>   purges, and it only runs on a branch it just created.
> - **Do not treat these branches as redacted** for compliance, demos, screen-sharing, or handing a
>   connection string to a third party.
> - If you need a genuine no-production-data guarantee, schema-only branching is the only Neon
>   mechanism that provides it — at the cost of a root-branch slot per workspace and the ledger
>   problem above.

## Lifecycle state: `.neondb/state.json`

```json
{
  "branchId": "br-dawn-river-arrz6rux",
  "branchName": "workspace/martintechlabs-feature-x",
  "projectId": "orange-forest-39329018",
  "status": "ready"
}
```

- **`branchId` and `projectId` are identity.** Every lookup and every delete goes by id.
- **`branchName` is a display value**, refreshed from Neon on `sync`. Nothing is ever found, renamed
  or deleted by name.
- **`status`** is `creating` → `pending` → `ready`, and `deleting` on the way out. `branchId` is
  `null` if and only if the status is `creating`.
- Written atomically, mode 0600, and **credential-free**. `.neondb/` is gitignored.
- Parsed strictly — exactly those four keys, a known status, and a `projectId` matching
  `NEON_PROJECT_ID`, all checked **before** any Neon API call.

| Status | Meaning | Who may touch the branch |
|---|---|---|
| `creating` | A create was issued and never confirmed | Nobody. Resolve by hand. |
| `pending` | Created and verified; purge/migrate/seed in flight | Only the provisioning migrator |
| `ready` | Purged, migrated, seeded | The app |
| `deleting` | Teardown in flight | Only teardown |

`provision`, `sync` and `teardown` serialize on `.neondb/lock`.

### Renaming never moves a database

A git branch changes on every `git checkout`, not just a deliberate rename. Because ownership is a
branch **id**, none of that matters: `sync` verifies the recorded id, refreshes the display name from
Neon, and logs a note if the current identity would name a different branch. It never renames on
Neon, and it never adopts a branch that happens to carry the name this checkout derives — that is how
a name freed by one workspace and reused by another would silently steal a database.

To move a workspace onto a fresh database under a new identity, run `db:provision`. That is the
deliberate path, and it discards the old branch's data.

## Workspace identity

Identity decides what a **new** branch is called. It never decides which branch a workspace owns.

| Order | Source | When it applies |
|---|---|---|
| 1 | `CONDUCTOR_WORKSPACE_NAME` | Conductor injects this automatically |
| 2 | `ORCA_WORKSPACE_NAME` | Set by Orca or the project, when present |
| 3 | `WORKSPACE_NAME` | General ambient override for custom tools or CI |
| 4 | Checkout directory basename | A secondary git worktree with none of the above set |
| 5 | Current git branch | A plain single-clone checkout with none of the above set |

`WORKSPACE_NAME` is **never** read from `.env.neondb` — that file can be copied across workspaces.
Set it in your shell, CI config, or orchestrator env instead.

## Environment variables

| Variable | Required by | Notes |
|---|---|---|
| `NEON_API_KEY` | all commands | Mirrored into `.env.neondb` so an orchestrator's archive hook is self-sufficient |
| `NEON_PROJECT_ID` | all commands | Must match `state.json`'s `projectId`, or the command refuses before calling Neon |
| `NEON_PARENT_BRANCH` | `provision` | The production branch **name or `br-…` id**. Prefer the id: it is resolved with a direct lookup, skipping the branch listing entirely, and it cannot be pointed at the wrong branch by a rename. |
| `NEON_DATABASE_NAME` / `NEON_ROLE_NAME` | optional | Only needed when a branch hosts more than one database and the first is not the app's |
| seed credentials | `provision` | Whatever the project's seed needs; absent means "skip seeding" |

`WORKSPACE_NAME` is read from the process environment only, never from `.env.neondb`.

## When this applies

- The project's database is on **Neon** (branching is a Neon feature).
- Migrations are managed by **Prisma** or **Drizzle** (set the `ORM` knob).
- `tsx` and `dotenv` are available as project-local dev dependencies, plus a Node package manager.
  The script talks to Neon over the REST API with Node's built-in `fetch` — **`neonctl` is not
  required**, because `branches create --parent` accepts a name *or* an LSN as a single value and
  cannot express "this named parent, pinned at that LSN".
- **Both ORMs** need the project's existing Postgres driver wired into the `connect()` knob.

If the stack is different (not Neon, or not Prisma/Drizzle), the mechanics here don't transfer —
adapt the knobs, or tell the user this skill assumes Neon + Prisma/Drizzle and stop.

## Setup

### 1. Preflight

Confirm the project is Neon + Prisma **or** Neon + Drizzle, and find the package manager (lockfile:
`pnpm-lock.yaml` → pnpm, `package-lock.json` → npm, `yarn.lock` → yarn). Ensure `tsx` and `dotenv`
are dev dependencies. Note which Postgres driver the project already uses. Identify the Neon
project's **production branch name** and confirm it is **protected** in the Neon console.

### 2. Add the provisioning script

Copy `scripts/neondb-branch.ts` and `scripts/load-env.cjs` into the project's `scripts/`. Adjust the
**PORTING KNOBS** block at the top of `neondb-branch.ts`:

- `ORM` — `'prisma'` or `'drizzle'`.
- `PM_EXEC` — your package manager's exec form (`['pnpm','exec']` / `['npx']` / `['yarn']`).
- **Wire `connect()`** to the project's Postgres driver and remove its throw. It must return **one
  dedicated session, never a pool** — the purge issues `BEGIN`, `TRUNCATE` and `COMMIT` as separate
  calls, and a pool would spread them across connections. Use a generous connect timeout (30s); a
  cold compute is the normal case here.
- **Wire `knownApplicationTables()`** to the ORM's own model list, and remove its throw. For Prisma,
  `prismaKnownTables(Prisma.dmmf.datamodel)` is exported for exactly this and includes implicit
  many-to-many join tables — miss those and every project with an implicit m2m relation fails closed
  on its own join table. `Prisma.dmmf` comes from the `prisma-client-js` generator; on the newer
  `prisma-client` generator, read the datamodel with `getDMMF` from `@prisma/internals` instead. For
  Drizzle, map the schema module through `getTableConfig`.
- `APP_SCHEMAS` — schemas whose base tables the purge may empty (defaults to `public`).
- `PRESERVED_TABLES` — anything else the purge must keep. The migration ledger and every
  extension-owned table (PostGIS's `spatial_ref_sys` and friends) are detected automatically.
- `SEED_SCRIPT` and the `seedWorkspace()` body — adapt to the project's seed.
- `DB_ENV_VARS` — every env var that must point at the workspace branch (defaults to just
  `DATABASE_URL`; add `DIRECT_URL`/`shadowDatabaseUrl` if your schema references them). **Mirror the
  same list in `load-env.cjs`.**

Copy `tests/neondb-branch.test.ts` and `tests/purge.test.ts` into the project's test directory
(adjust the import paths). They lock the safety-critical behaviour: the lifecycle transitions,
ownership by id, the fail-closed purge, and the rollback.

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

Add the same `NODE_OPTIONS` prefix to `build`/`start`, to any seed script run outside provisioning,
and to the **integration/e2e test runner** — a test suite that loads the ambient `DATABASE_URL`
instead is running against the shared database. `load-env.cjs` hard-fails when the workspace is not
`ready`, so a runner that has not been provisioned stops rather than falling through.

For Prisma's CLI (`migrate`/`db execute`/`studio`) outside `dev`, add to `prisma.config.ts`:

```ts
import { config as loadEnv } from 'dotenv'
loadEnv({ path: '.env.neondb', override: true })
loadEnv()
```

`override: true` matters: without it an ambient `DATABASE_URL` wins and the CLI operates on the
shared database. (Drizzle has no equivalent config hook — source `.env.neondb` explicitly for any ad
hoc `drizzle-kit` invocation.)

### 4. Prisma: raise the transaction `maxWait`

Prisma's default interactive-transaction `maxWait` is **two seconds**, which a freshly-created Neon
compute loses every time — the resulting *"Unable to start a transaction in the given time"* is this
skill's most common first-run failure. Anywhere the app or seed opens a transaction:

```ts
await prisma.$transaction(async (tx) => { /* … */ }, { maxWait: 30_000, timeout: 60_000 })
```

The script exports `PRISMA_TX_MAXWAIT_MS` (30s) so the value has one home.

### 5. Orchestrator config (optional — both shipped, use what applies)

**Conductor** — copy `references/conductor-settings.toml.example` to `.conductor/settings.toml`:

```toml
"$schema" = "https://conductor.build/schemas/settings.repo.schema.json"

[scripts]
setup = "corepack enable pnpm && pnpm worktree:setup"
archive = "pnpm worktree:archive"
run = "pnpm worktree:sync && pnpm dev --port $CONDUCTOR_PORT"
run_mode = "concurrent"
```

`run_mode = "concurrent"` is safe because each workspace has its own branch and `$CONDUCTOR_PORT`.
**Never put `DATABASE_URL` in Conductor's Environment tabs** — `load-env.cjs` overrides it anyway,
but a stray value there is a trap for every other tool. Put `NEON_API_KEY`/`NEON_PROJECT_ID`/
`NEON_PARENT_BRANCH` in **both** Local and Cloud tabs (or in `.env.neondb` directly).

**Orca** — copy `references/orca.yaml.example` to `orca.yaml`:

```yaml
scripts:
  setup: |
    corepack enable pnpm && pnpm worktree:setup
  archive: |
    pnpm worktree:archive
```

Orca has no `run` hook — the gate lives in the `dev` script's `sync &&` prefix and in
`load-env.cjs`, which is why both are universal rather than orchestrator-specific.

Track `.conductor/settings.toml` in git; gitignore `.neondb/` and `.env.neondb` (verify with
`git check-ignore .neondb .env.neondb`).

### 6. Wire up seeding

`seedWorkspace()` runs the project's seed against the new branch as the last provisioning step. Most
seeds have (or should have) a guard that refuses non-local databases; authorize it for **this branch
only**, never production. If there's no seed, delete `seedWorkspace()` and its call.

### 7. Verify

- `<pm> exec tsc --noEmit`, and run the bundled tests.
- Confirm the production branch is **protected** in Neon.
- For end-to-end confidence against real Neon, follow `references/verify.md`.

## Fresh installs only

This version targets repos that do not already have the skill installed. There is **no migration
path** from 0.1.x and no conversion command: a branch *name* is not proof of ownership, so adopting
one automatically would be the exact mistake the rest of the design avoids.

If you do drop it into a repo that already ran 0.1.x, every command stops with an error rather than
proceeding, because `.neondb/branch` (and possibly `.neondb/branch-check`) is still there. Silently
ignoring those files would create a second branch alongside the old one and make teardown report
"nothing to tear down", leaking a live branch — and, for `.neondb/branch`, the root-branch slot this
change exists to reclaim. Resolve it by hand, per workspace: delete the branch named in the file from
the Neon console, remove the file, and run `db:provision` for a fresh workspace database. That
discards the workspace's development data, which is the normal `provision()` contract anyway.

## Safety model

- **Ownership is a branch id, verified.** Every destructive call takes a `br-…` id from
  `state.json`. Before any destructive SQL, the branch's id, exact name, `parent_id`, captured
  `parent_lsn`, and disposable status are all checked. The captured LSN is what distinguishes the
  branch this run created from a same-named branch created by anyone else.
- **Fail-closed purge.** A base table that is neither a known application table, the migration
  ledger, extension-owned, nor explicitly preserved stops provisioning. A schema outside
  `APP_SCHEMAS` does the same. Known tables that are *absent* are fine — that is production being
  behind this checkout, and migrate-deploy creates them after the purge.
- **Purge is database-only.** One transaction, `TRUNCATE … RESTART IDENTITY CASCADE`, rolled back on
  any error. It never calls the application's own deletion paths — no Blob deletes, no billing
  calls, no worker dispatch — because it runs against a copy of production and those would reach out
  and mutate shared systems.
- **URLs publish only after the purge is verified.** Until then the branch is reachable solely by the
  provisioning migrator, through the URI in its child-process environment.
- **No blind retries on creation.** Only failures provably raised before the request reached Neon are
  retried. An ambiguous outcome leaves `status: "creating"` and fails loudly; the branch is never
  looked up, adopted, or deleted by name.
- **Failed cleanup keeps recovery state.** A teardown that cannot delete stays at `deleting` with the
  id intact. A provision whose cleanup fails keeps the record and warns.
- **`.neondb` is never removed recursively.** Teardown releases the lock, then removes the directory
  only if it is empty.
- **The only statement sent to production** is a read-only `SELECT pg_current_wal_lsn()`.
- Plus the Neon-side **branch protection** on production.

## Gotchas

- **A workspace branch holds production data until the purge finishes, and its history may hold it
  afterwards.** See the warning above. This is the central trade-off of this design.
- **`provision()` discards workspace data on every re-run.** Anything you need across rebuilds goes
  in the seed script, not in ad hoc rows.
- **`.env.neondb`'s `DATABASE_URL` is managed** — hand-edit the other vars freely, but not that one.
- **`DB_ENV_VARS` lives in two files.** `scripts/neondb-branch.ts` and `scripts/load-env.cjs` must
  agree; a var listed in one and not the other leaks the shared database.
- **`connect()` must not be a pool.** A pooled adapter runs the purge's `TRUNCATE` outside its
  transaction, which silently defeats the rollback.
- **Prisma's 2-second transaction `maxWait`** is the most common first-run failure. See step 4.
- **Cold computes are expected** — the first connection to a brand-new branch is retried with
  exponential backoff over several minutes.
- **Seeding is opt-in** — if the seed credential isn't set, provisioning logs a warning and the
  workspace comes up empty rather than failing.
- **`tests/run.sh` needs the network** (it installs a throwaway harness), unlike this repo's other
  test suites. It needs no Neon credentials and no live database.
