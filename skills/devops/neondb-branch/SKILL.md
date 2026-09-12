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
  version: "0.2.1"
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
5. Applies migrations this checkout has that production did not, then **seeds** test fixtures.
6. Publishes `DATABASE_URL` (and any other `DB_ENV_VARS`) to `.env.neondb` after those steps succeed.
7. Records `status: "ready"` in `.neondb/state.json`.

## Why an ordinary child

Neon **schema-only branches are root branches**: they have no parent, and `--parent` only names the
schema donor. Root-branch allowances are 3 (Free), 5 (Launch), 25 (Scale) per project, so a handful
of parallel workspaces is enough to hit `ROOT_BRANCHES_LIMIT_EXCEEDED` and block all provisioning.
An ordinary child consumes no root slot.

It also removes an entire mechanism. A schema-only branch starts with an **empty** migrations table,
because migration history is table *data*. The previous design compensated by cloning production a
second time, with data, into a disposable `tmp/*` branch purely to read the real ledger rows back.
An ordinary child inherits that ledger directly — so the second clone, the ledger read, and the
baseline INSERT are all gone.

Purging empties current application tables; it does not erase [Neon's restore history](https://neon.com/docs/manage/projects),
which may retain inherited production data. A `ready` child is therefore not a redacted environment
or a privacy boundary for demos, compliance, or third-party sharing.

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

`provision`, `sync` and `teardown` serialize on `.neondb/lock`. A short-lived `.neondb/lock-guard`
serializes acquisition and stale-lock reclamation. An unreadable lock or a leftover guard stops
the command: stop all lifecycle commands and inspect it before manually removing a stale file.

A separate `neondb-workspace.json` ownership receipt lives in the directory returned by
`git rev-parse --absolute-git-dir`. For a linked worktree this is its private Git metadata, not the
shared common directory. The receipt records branch/project IDs, creation parent/LSN, and the
published database host/port/name without credentials. Copying `.neondb/` or `.env.neondb` from
another checkout cannot authorize deletion or startup: every command checks the local receipt,
and startup also checks the configured project and URL target. A workspace move or Git branch
rename retains the receipt. Missing or mismatched receipts require manual recovery; never copy a
receipt to adopt another workspace's branch. This protects against accidental copies, not someone
who can rewrite both workspace files and private Git metadata.

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
| `NEON_DATABASE_NAME` / `NEON_ROLE_NAME` | conditional | Multiple databases require `NEON_DATABASE_NAME`; otherwise the sole database is selected. The role defaults to the selected database's owner. Set `NEON_ROLE_NAME` to use a different role. |
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

Copy `scripts/neondb-branch.ts`, `scripts/load-env.cjs`, and `scripts/workspace-state.cjs` into the
project's `scripts/`. The last file shares strict state and ownership validation between the CLI
and startup loader. Keep all three together. Adjust the
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
  For multi-schema Prisma projects, implicit join tables use the schema of the alphabetically
  first participating model; include that schema in `APP_SCHEMAS`.
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

## What changed in 0.2.0, and why

**The symptom:** provisioning starts failing with `ROOT_BRANCHES_LIMIT_EXCEEDED`, usually once three
or four workspaces exist at once. Nothing in the project looks near a limit, because the Branches
page shows far fewer branches than the plan allows.

**The cause:** Neon caps how many *root* branches a project may have — branches with no parent, each
starting an independent line of data. The allowance is small and it is per project:

| Plan | Root branches per project |
|---|---|
| Free | 3 |
| Launch | 5 |
| Scale | 25 |

Versions up to 0.1.x created each workspace branch with `--schema-only`. Schema-only branches **are
root branches**: passing `--parent` names the schema donor, not a parent, and the resulting branch
has no `parent_id` at all. So every workspace was quietly spending one of those few slots, and the
project ran out long before it ran out of branches. The general branch limit is generous; the root
limit is not, which is why the ceiling arrives without warning.

**The fix:** 0.2.0 creates an ordinary child of production instead, which costs no root slot, and
purges the production rows it inherits. That also deleted the disposable `tmp/*` clone the old design
needed, since an ordinary child inherits the migration ledger directly. See "Why an ordinary child"
above.

Alongside it, tracking moved from `.neondb/branch` (a branch *name*, plus an undocumented marker
line) to `.neondb/state.json`, keyed on the branch **id**. A name is not proof of ownership: the old
design renamed live branches to follow git-branch changes, so a name freed by one workspace and
reused by another was indistinguishable from "our branch, renamed".

## Fresh installs only

This version targets repos that do not already have the skill installed. There is **no migration
path** from 0.1.x and no conversion command: a branch *name* is not proof of ownership, so adopting
one automatically would be the exact mistake the rest of the design avoids.

If you drop it into a repo that already ran 0.1.x, every command stops with an error while
`.neondb/branch` or `.neondb/branch-check` is present. That is deliberate — ignoring those files
would create a second branch beside the old one and make teardown report "nothing to tear down",
leaking a live branch and the root-branch slot this change exists to reclaim.

**Clean up by hand. It is three steps and it is fine to do this way.**

### 1. Find every branch the old system created

Old workspace branches are schema-only, so Neon reports them as `init_source: parent-schema` with no
parent. Leftover ledger clones are named `tmp/*`. This lists both:

```bash
curl -sS -H "Authorization: Bearer $NEON_API_KEY" \
  "https://console.neon.tech/api/v2/projects/$NEON_PROJECT_ID/branches" |
  jq -r '.branches[]
         | select(.init_source == "parent-schema" or (.name | startswith("tmp/")))
         | [.id, .name, .init_source] | @tsv'
```

In the Neon console the same branches are the ones showing no parent on the Branches page.

### 2. Delete them

```bash
curl -sS -X DELETE -H "Authorization: Bearer $NEON_API_KEY" \
  "https://console.neon.tech/api/v2/projects/$NEON_PROJECT_ID/branches/<br-id>"
```

Or click Delete on each in the console. **Check the list before deleting** — anything you kept
deliberately as a schema-only branch shows up in the same filter. Deleting a workspace branch
discards that workspace's development data, which is the normal `provision()` contract anyway. Stop
any dev server pointed at one first.

### 3. Remove the old state directory in each workspace

```bash
rm -rf .neondb
```

Then run `pnpm db:provision` for a fresh workspace database. Each freed schema-only branch returns a
root-branch slot.

## Safety model

- **Ownership is a branch id, verified.** Every destructive call takes a `br-…` id from
  `state.json` and checks its per-worktree receipt; deletion also revalidates the receipt's
  creation parent and LSN. Before any destructive SQL, the branch's id, exact name, `parent_id`, captured
  `parent_lsn`, and disposable status are all checked. The captured LSN is what distinguishes the
  branch this run created from a same-named branch created by anyone else.
- **Fail-closed purge.** A base table that is neither a known application table, the migration
  ledger, extension-owned, nor explicitly preserved stops provisioning. A schema outside
  `APP_SCHEMAS` does the same. Known tables that are *absent* are fine — that is production being
  behind this checkout, and migrate-deploy creates them after the purge.
- **Purge is database-only.** One transaction, `TRUNCATE … RESTART IDENTITY RESTRICT`, rolled back on
  any error. Foreign keys within the application table set work; references from preserved tables
  fail rather than silently emptying those tables. It never calls the application's own deletion paths — no Blob deletes, no billing
  calls, no worker dispatch — because it runs against a copy of production and those would reach out
  and mutate shared systems. Enabled application `ON TRUNCATE` triggers on purge targets or their
  descendants stop provisioning before those hooks can run. Materialized views are classified too:
  their stored rows require explicit preservation or a project-specific purge design.
- **URLs publish only after the purge is verified.** Until then the branch is reachable solely by the
  provisioning migrator, through the URI in its child-process environment. `load-env.cjs` refuses to
  boot unless `.neondb/state.json` reads `ready`, and `sync` gates the same way — do not remove either
  guard, and do not hand-write a `DATABASE_URL` that bypasses them.
- **Failed purges withdraw URLs and trigger cleanup.** If emptying the child fails, provisioning
  warns that production rows are still on that branch, withdraws `DATABASE_URL` (and every other
  `DB_ENV_VARS` entry) so nothing can connect, and tries to delete the branch. If deletion also fails,
  the leftover-branch warning says the same: do not connect; teardown or delete it in Neon. Being
  stuck with no database is the intended outcome. If a filesystem error prevents URL withdrawal,
  provisioning reports it with repair instructions and still attempts branch deletion, preserving
  the original setup error and any unfinished cleanup state. If Neon confirms the branch is gone
  but local cleanup fails, the error identifies the local path/permissions to repair before retrying
  teardown; it does not claim the deleted branch still holds rows.
- **Never "Reset from parent" or restore a workspace branch from production.** That reloads the
  parent's current rows and nothing purges them afterwards — provisioning is the only code path that
  purges, and it only runs on a branch it just created.
- **No blind retries on creation.** Only failures provably raised before the request reached Neon are
  retried. An ambiguous outcome leaves `status: "creating"` and fails loudly; the branch is never
  looked up, adopted, or deleted by name.
- **Failed cleanup keeps recovery state.** A teardown that cannot delete stays at `deleting` with the
  id intact. Rebuild and failed-setup cleanup use the same rule: recheck the branch's identity and
  disposable status, record `deleting`, and confirm absence before clearing state. An unverifiable
  creation response retains `creating` for manual recovery and never authorizes deletion.
- **`.neondb` is never removed recursively.** Teardown releases the lock, then removes the directory
  only if it is empty.
- **The only statement sent to production** is a read-only `SELECT pg_current_wal_lsn()`.
- Plus the Neon-side **branch protection** on production.

## Gotchas

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
