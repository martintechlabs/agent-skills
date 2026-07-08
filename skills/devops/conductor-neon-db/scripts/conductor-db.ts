// scripts/conductor-db.ts
//
// Per-workspace ISOLATED database for Conductor (works in local AND cloud workspaces).
// Each workspace gets its own SCHEMA-ONLY Neon branch off the production branch: the full
// schema + extensions (e.g. PostGIS's spatial_ref_sys data) but ZERO production rows,
// created instantly (Neon copies no data). Provisioning then:
//   • baselines the ORM's migration history — a schema-only branch starts with an EMPTY
//     migrations table, which would otherwise make the migrator re-run every migration
//     against tables that already exist and fail. First-time setup is tracked with a
//     'pending' marker in the state file, so a provision killed mid-setup is RECOVERED on
//     the next run (idempotent baseline + seed) — while a fully set-up branch is never
//     re-baselined (stamping unapplied migrations would silently skip them); and
//   • seeds test fixtures (the last step of setup); and
//   • records the exact branch name it used in .conductor/db-branch (gitignored) so teardown
//     finds the SAME branch even if the workspace is renamed in Conductor afterward — a rename
//     changes CONDUCTOR_WORKSPACE_NAME, which would otherwise make teardown re-derive a
//     DIFFERENT slug and silently miss the real branch (see readBranchState()).
//
// Conductor has no "workspace renamed" event, so `sync` piggybacks on `run` instead — the only
// hook that fires repeatedly through a workspace's life. It compares the recorded branch name
// against one freshly derived from CONDUCTOR_WORKSPACE_NAME, and if a rename happened since the
// last check, renames the Neon branch to match (a real rename, not delete+recreate — data and
// DATABASE_URL are untouched, since Neon connection strings key off the branch's compute
// endpoint, not its name). Purely cosmetic: teardown works correctly with or without it, since
// it always trusts whatever .conductor/db-branch last recorded.
//
//   setup   → `tsx scripts/conductor-db.ts provision`
//   run     → `tsx scripts/conductor-db.ts sync` (prepended to the dev server command)
//   archive → `tsx scripts/conductor-db.ts teardown`
//
// Requires (set as Conductor environment variables — Local tab for local workspaces, Cloud tab
// for cloud workspaces). Missing NEON_API_KEY / NEON_PROJECT_ID, or a failed branch delete,
// fails provision/teardown loudly (non-zero exit) instead of warning-and-continuing — a
// swallowed failure here is exactly how Neon branches leaked past Conductor's archive step
// before (teardown of an ALREADY-ABSENT branch is fine, though: an absent branch cannot leak).
// `sync`'s rename part is the one best-effort exception — it warns and no-ops on failure, since
// a cosmetic naming sync must never block the dev server — but sync DOES fail hard when
// .env.neondb is missing (unprovisioned workspace), see sync():
//   NEON_API_KEY       – Neon API key (read by neonctl); required by provision AND teardown
//   NEON_PROJECT_ID    – Neon project to branch within; required by provision AND teardown
//   NEON_PARENT_BRANCH – REQUIRED by provision (no default); branch to clone, e.g. "production".
//                        teardown/sync only use it for the production-safety guard, if set.
//   (seed credentials) – whatever your seed needs; provision-only — see seedWorkspace() below
//
// Assumes Neon (Postgres) with migrations managed by EITHER Prisma OR Drizzle (set ORM below),
// with `neonctl` and `tsx` available as project-local binaries. The Drizzle path additionally
// needs the project's own Postgres driver wired into execSql() (Drizzle has no `prisma db
// execute` equivalent). Adjust the PORTING KNOBS just below for your project.
//
// Baselining assumes the parent branch already contains every migration committed on this
// code branch — true for the normal Conductor flow (workspaces branch from the default
// branch; production is deployed from it). If the parent lags the code's migrations, run the
// ORM's reset in the workspace — ALWAYS through the generated env file, e.g.
// `dotenv -e .env.neondb -- prisma migrate reset` (a bare reset would auto-load the project's
// real .env and destroy whatever shared database it points at).
//
// SAFETY: every destructive op (branch delete/rename) is guarded to only ever run against a
// disposable `conductor/*` branch — never the parent/production branch. The baseline is
// RECONSTRUCTED from the repo's migration files — provisioning never reads from production.

import { execFileSync, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'

// ── PORTING KNOBS ────────────────────────────────────────────────────────────
// Which ORM manages migrations. Switches the baseline + reuse logic throughout.
const ORM: 'prisma' | 'drizzle' = 'prisma'

// How to run a project-local CLI (neonctl/prisma/drizzle-kit/tsx). Match your package manager:
//   pnpm → ['pnpm', 'exec']   npm → ['npx']   yarn → ['yarn']
const PM_EXEC = ['pnpm', 'exec']
// DATABASE_URL lands in its OWN file, not .env, so the project's real .env is never clobbered.
// NOTHING auto-loads .env.neondb — the run script loads it explicitly (dotenv -e .env.neondb --)
// and this script passes DATABASE_URL to every child process itself. Anything else that needs
// the workspace DB (a manual `prisma studio`, an e2e runner) must load it the same way.
const ENV_FILE = '.env.neondb'
const BRANCH_STATE_FILE = '.conductor/db-branch' // records the branch provision() used; see readBranchState()
const BRANCH_PREFIX = 'conductor/' // workspace-branch namespace (matches Neon's preview/)
const MAX_SLUG = 48 // Neon-safe branch-name length budget (excluding the BRANCH_PREFIX)
const SEED_SCRIPT = 'prisma/seed.ts' // project's seed entrypoint (see seedWorkspace)

// ── Prisma knobs (used when ORM === 'prisma') ────────────────────────────────
const PRISMA_MIGRATIONS_DIR = 'prisma/migrations'
const PRISMA_SCHEMA = 'prisma/schema.prisma'

// ── Drizzle knobs (used when ORM === 'drizzle') ──────────────────────────────
// Folder drizzle-kit writes migrations to (contains meta/_journal.json and <tag>.sql files).
const DRIZZLE_MIGRATIONS_DIR = 'drizzle'
// Where drizzle records applied migrations. Defaults match drizzle-kit; override only if you
// set a custom migrationsSchema/migrationsTable in drizzle.config.
const DRIZZLE_MIGRATIONS_SCHEMA = 'drizzle'
const DRIZZLE_MIGRATIONS_TABLE = '__drizzle_migrations'

/**
 * Execute SQL against a Neon branch — used by the Drizzle baseline, which (unlike Prisma's
 * `db execute`) has no built-in CLI to run arbitrary SQL. Wire this to the Postgres driver the
 * project ALREADY depends on; do not add a new one. Pick the matching example, move its import
 * to the top of the file, drop the body's throw:
 *
 *   // @neondatabase/serverless (HTTP, nothing to close — ideal for a one-shot script):
 *   //   import { neon } from '@neondatabase/serverless'
 *   //   async function execSql(uri, sql) { await neon(uri)(sql) }
 *
 *   // postgres (postgres-js):
 *   //   import postgres from 'postgres'
 *   //   async function execSql(uri, sql) {
 *   //     const c = postgres(uri); try { await c.unsafe(sql) } finally { await c.end() }
 *   //   }
 *
 *   // pg (node-postgres):
 *   //   import { Client } from 'pg'
 *   //   async function execSql(uri, sql) {
 *   //     const c = new Client({ connectionString: uri }); await c.connect()
 *   //     try { await c.query(sql) } finally { await c.end() }
 *   //   }
 *
 * Left unconfigured it raises a clear error rather than inventing a driver dependency.
 */
async function execSql(_uri: string, _sql: string): Promise<void> {
  throw new Error(
    'ORM is "drizzle" but execSql() is not configured. Wire it to the project\'s Postgres driver ' +
      '(@neondatabase/serverless / postgres / pg) — see the example in the PORTING KNOBS block.',
  )
}
// ─────────────────────────────────────────────────────────────────────────────

function requireEnv(name: string): string {
  const value = process.env[name]
  if (!value) {
    throw new Error(
      `${name} is required for Conductor's per-workspace Neon branch. ` +
        `Add it as a Conductor environment variable (Local tab for local, Cloud tab for cloud).`,
    )
  }
  return value
}

/** Stable, Neon-safe branch name derived from the workspace name. */
export function workspaceBranchName(): string {
  const raw = requireEnv('CONDUCTOR_WORKSPACE_NAME')
  let slug = raw
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
  if (!slug) {
    throw new Error(`Could not derive a branch name from CONDUCTOR_WORKSPACE_NAME="${raw}".`)
  }
  if (slug.length > MAX_SLUG) {
    // Truncate, but keep distinct workspaces distinct: append a short hash of the FULL name so
    // two long names that share a prefix don't collide onto the same branch (which would break
    // isolation and let one workspace's teardown delete another's branch). Re-trim any
    // separator the cut left dangling so the name never ends in "-".
    const suffix = createHash('sha256').update(raw).digest('hex').slice(0, 8)
    slug = `${slug.slice(0, MAX_SLUG - suffix.length - 1).replace(/-+$/, '')}-${suffix}`
  }
  return `${BRANCH_PREFIX}${slug}`
}

/**
 * Persist the exact branch name provision() used. Reading this back in teardown() (instead of
 * re-deriving via workspaceBranchName()) makes teardown immune to a workspace rename changing
 * CONDUCTOR_WORKSPACE_NAME between provision and archive.
 *
 * The optional second line is a setup-phase marker: 'pending' means the branch was created but
 * baseline+seed have not completed (a crash in that window is the ONLY way a half-set-up branch
 * can survive, since caught failures self-destruct the branch). A file without a marker — e.g.
 * written by an earlier version of this script — is treated as 'ready', so upgrading never
 * re-seeds or re-baselines a live branch.
 */
export function writeBranchState(branchName: string, phase: 'pending' | 'ready' = 'ready'): void {
  mkdirSync(dirname(BRANCH_STATE_FILE), { recursive: true })
  // Write-then-rename so a crash mid-write can't leave a truncated/garbage state file.
  const tmp = `${BRANCH_STATE_FILE}.tmp`
  writeFileSync(tmp, `${branchName}\n${phase}\n`, { mode: 0o600 })
  renameSync(tmp, BRANCH_STATE_FILE)
}

/** Single reader for the state file; the exported helpers below are thin views over it. */
function readStateFile(): { branch: string; phase: 'pending' | 'ready' } | null {
  try {
    const lines = readFileSync(BRANCH_STATE_FILE, 'utf8').split('\n')
    const branch = lines[0].trim()
    if (!branch) return null
    return { branch, phase: lines[1]?.trim() === 'pending' ? 'pending' : 'ready' }
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return null
    throw error
  }
}

/** The branch name provision() recorded, or null if absent — e.g. a workspace provisioned before this file existed, in which case the caller should fall back to re-deriving it. */
export function readBranchState(): string | null {
  return readStateFile()?.branch ?? null
}

/** Whether the recorded branch was created but never finished baseline+seed (see writeBranchState). */
export function setupIsPending(): boolean {
  return readStateFile()?.phase === 'pending'
}

/**
 * Hard safety guard. Destructive operations (deleting or renaming a branch) must only ever
 * target a disposable per-workspace `conductor/*` branch — never the parent (production).
 * Throws otherwise.
 */
export function assertDisposableChildBranch(branchName: string, parentBranch: string): void {
  if (!branchName.startsWith(BRANCH_PREFIX)) {
    throw new Error(`Refusing destructive op on "${branchName}": not a "${BRANCH_PREFIX}" workspace branch.`)
  }
  if (parentBranch && branchName === parentBranch) {
    throw new Error(`Refusing destructive op on "${branchName}": it is the parent branch.`)
  }
}

/** Run a project-local CLI. Captures stdout by default; `inherit` streams output to the user. */
function pmExec(bin: string, args: string[], opts: { inherit?: boolean } = {}): string {
  const result = execFileSync(PM_EXEC[0], [...PM_EXEC.slice(1), bin, ...args], {
    encoding: 'utf8',
    env: process.env,
    // Big enough that a large project's `branches list --output json` can't hit the 1 MiB
    // default and make an existing branch look absent via a spawn failure.
    maxBuffer: 64 * 1024 * 1024,
    ...(opts.inherit ? { stdio: 'inherit' as const } : {}),
  })
  return result ?? ''
}

/** Run neonctl (it reads NEON_API_KEY from the environment) and return stdout. Throws on error. */
function neon(args: string[], opts: { inherit?: boolean } = {}): string {
  return pmExec('neonctl', args, opts)
}

/**
 * Whether the workspace branch already exists. Uses `branches list` (which throws on any
 * neonctl failure) so a transient error is NOT silently misread as "branch absent" — that
 * would spuriously trigger a create that then fails "branch already exists".
 */
function branchExists(projectId: string, branchName: string): boolean {
  const parsed = JSON.parse(neon(['branches', 'list', '--project-id', projectId, '--output', 'json'])) as
    | Array<{ name?: string }>
    | { branches?: Array<{ name?: string }> }
  const branches = Array.isArray(parsed) ? parsed : (parsed.branches ?? [])
  return branches.some((b) => b.name === branchName)
}

function getConnectionString(projectId: string, branchName: string): string {
  const uri = neon(['connection-string', branchName, '--project-id', projectId]).trim()
  if (!uri.startsWith('postgres')) {
    throw new Error(`neonctl did not return a postgres connection string (got ${uri.length} chars).`)
  }
  return uri
}

/** Block for ms without a timer — this is a synchronous one-shot CLI script. */
function sleepMs(ms: number): void {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)
}

/** Retry backoff: grows each attempt (2s, 4s, 8s, …) so a slow compute boot gets more time
 * without making genuine failures wait as long up front. */
function backoffMs(attempt: number): number {
  return 2000 * 2 ** (attempt - 1)
}

/**
 * Retry an operation (sync or async) with the exponential backoff above. Used around the Neon
 * API steps of provisioning (branch create/rename, connection-string fetch, the Drizzle
 * baseline's execSql) — a branch whose compute is still booting can transiently refuse all of
 * them. `sleep` is injectable for tests only.
 */
export async function withRetry<T>(
  label: string,
  fn: () => T | Promise<T>,
  attempts = 6,
  sleep: (ms: number) => void = sleepMs,
): Promise<T> {
  for (let attempt = 1; ; attempt++) {
    try {
      return await fn()
    } catch (error) {
      if (attempt >= attempts) throw error
      const waitMs = backoffMs(attempt)
      console.log(`[retry] ${label}: attempt ${attempt} failed; waiting ${waitMs / 1000}s before retry…`)
      sleep(waitMs)
    }
  }
}

/**
 * Rename a workspace branch, idempotently under retry: an attempt that "failed" after actually
 * renaming (e.g. a timeout on the response) is detected as already-done on the next attempt.
 * Callers decide how loud a final failure is (provision throws, sync warns).
 */
async function renameBranch(projectId: string, from: string, to: string): Promise<void> {
  await withRetry('rename branch', () => {
    if (branchExists(projectId, from)) {
      neon(['branches', 'rename', from, to, '--project-id', projectId])
    } else if (!branchExists(projectId, to)) {
      throw new Error(`neither "${from}" nor "${to}" exists in project ${projectId}`)
    }
  }, 3)
}

/**
 * Retry a project-local CLI — a branch compute that's never been connected to (just created,
 * or just renamed) can take a while to finish booting. When `input` is given it is piped to
 * the command's stdin (used to feed SQL to `prisma db execute --stdin`).
 */
function runWithRetry(bin: string, binArgs: string[], env: NodeJS.ProcessEnv, attempts = 3, input?: string): void {
  const file = PM_EXEC[0]
  const args = [...PM_EXEC.slice(1), bin, ...binArgs]
  for (let attempt = 1; attempt <= attempts; attempt++) {
    const res = spawnSync(
      file,
      args,
      input === undefined ? { stdio: 'inherit', env } : { stdio: ['pipe', 'inherit', 'inherit'], env, input },
    )
    if (res.error) throw new Error(`Failed to spawn ${file}: ${res.error.message}`)
    if (res.status === 0) return
    if (attempt === attempts) {
      const reason = res.signal ? `killed by signal ${res.signal}` : `exit code ${res.status}`
      throw new Error(`Command failed after ${attempts} attempts (${reason}): ${bin} ${binArgs.join(' ')}`)
    }
    const waitMs = backoffMs(attempt)
    console.log(`[retry] attempt ${attempt} failed; waiting ${waitMs / 1000}s before retry…`)
    sleepMs(waitMs)
  }
}

/**
 * Replace the generated env file (.env.neondb) with one that points at this workspace's own
 * Neon branch. The file is entirely ours — the project's real .env is never touched. Any
 * pre-existing file or stale symlink is removed first so we always write a real,
 * workspace-local file.
 */
function writeDatabaseUrl(uri: string): void {
  rmSync(ENV_FILE, { force: true })
  // Single quotes: dotenv-cli runs dotenv-expand on load, which would rewrite `$…` inside a
  // double-quoted value; single-quoted values are taken literally.
  writeFileSync(
    ENV_FILE,
    `# Generated by scripts/conductor-db.ts for this Conductor workspace. Do not commit.\n` +
      `DATABASE_URL='${uri}'\n`,
    { mode: 0o600 },
  )
}

/**
 * Build the INSERT that baselines Prisma's _prisma_migrations to "all migrations applied",
 * using Prisma's own checksum (sha256 hex of each migration.sql). Returns null if none.
 *
 * Idempotent: only inserts migrations not already recorded (`WHERE NOT EXISTS` on
 * migration_name), so it is safe to run on a fresh branch AND on one that was created but
 * never fully baselined (recovering it) without duplicating rows.
 */
export function buildPrismaBaselineSql(migrations: Array<{ name: string; sql: string }>): string | null {
  if (migrations.length === 0) return null
  const rows = migrations
    .map(({ name, sql }) => {
      const checksum = createHash('sha256').update(sql).digest('hex') // [0-9a-f]{64} — injection-safe
      const safeName = name.replace(/'/g, "''") // double single quotes for a valid SQL string literal
      return `('${checksum}', '${safeName}')`
    })
    .join(',\n')
  return (
    'INSERT INTO "_prisma_migrations" ' +
    '(id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count)\n' +
    'SELECT gen_random_uuid()::text, m.checksum, now(), m.migration_name, NULL, NULL, now(), 1\n' +
    `FROM (VALUES\n${rows}\n) AS m(checksum, migration_name)\n` +
    'WHERE NOT EXISTS (SELECT 1 FROM "_prisma_migrations" e WHERE e.migration_name = m.migration_name);'
  )
}

/**
 * Build the INSERT that baselines Drizzle's migrations table to "all migrations applied". Each
 * row is (hash = sha256 hex of the migration .sql file's contents, created_at = the journal's
 * `when` ms timestamp) — exactly what drizzle-kit would have written. drizzle-kit decides what
 * to run by the latest created_at, so the timestamps must come from the journal, not now().
 * Prepends CREATE SCHEMA/TABLE IF NOT EXISTS so it works even on the rare branch whose
 * schema-only copy somehow lacks the (empty) migrations table. Returns null if none.
 *
 * Idempotent: only inserts migrations not already recorded (`WHERE NOT EXISTS` on hash), so it
 * is safe to run on a fresh branch AND on one that was created but never fully baselined
 * (recovering it) without duplicating rows.
 */
export function buildDrizzleBaselineSql(migrations: Array<{ sql: string; when: number }>): string | null {
  if (migrations.length === 0) return null
  const rows = migrations
    .map(({ sql, when }) => {
      const hash = createHash('sha256').update(sql).digest('hex') // [0-9a-f]{64} — injection-safe
      return `('${hash}', ${when})`
    })
    .join(',\n')
  const qualified = `"${DRIZZLE_MIGRATIONS_SCHEMA}"."${DRIZZLE_MIGRATIONS_TABLE}"`
  return (
    `CREATE SCHEMA IF NOT EXISTS "${DRIZZLE_MIGRATIONS_SCHEMA}";\n` +
    `CREATE TABLE IF NOT EXISTS ${qualified} (id SERIAL PRIMARY KEY, hash text NOT NULL, created_at bigint);\n` +
    `INSERT INTO ${qualified} (hash, created_at)\n` +
    'SELECT m.hash, m.created_at\n' +
    `FROM (VALUES\n${rows}\n) AS m(hash, created_at)\n` +
    `WHERE NOT EXISTS (SELECT 1 FROM ${qualified} e WHERE e.hash = m.hash);`
  )
}

/**
 * Read committed Prisma migrations (name + SQL) from disk. Sorted by directory name — order is
 * used only to build the (order-independent) baseline INSERT, NOT to derive execution order,
 * so a mis-timestamped directory name is harmless here.
 */
export function readPrismaMigrations(): Array<{ name: string; sql: string }> {
  return readdirSync(PRISMA_MIGRATIONS_DIR, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort()
    .flatMap((name) => {
      try {
        return [{ name, sql: readFileSync(`${PRISMA_MIGRATIONS_DIR}/${name}/migration.sql`, 'utf8') }]
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === 'ENOENT') return [] // directory without a migration.sql — skip
        throw new Error(`Failed to read migration.sql for "${name}": ${error instanceof Error ? error.message : error}`)
      }
    })
}

/**
 * Read committed Drizzle migrations from disk, in apply order. The journal (meta/_journal.json)
 * is the source of truth for order and each migration's `when` timestamp; the SQL lives in the
 * sibling `<tag>.sql` file.
 */
export function readDrizzleMigrations(): Array<{ sql: string; when: number }> {
  const journalPath = `${DRIZZLE_MIGRATIONS_DIR}/meta/_journal.json`
  let journal: { entries?: Array<{ tag: string; when: number }> }
  try {
    journal = JSON.parse(readFileSync(journalPath, 'utf8'))
  } catch (error) {
    throw new Error(`Could not read Drizzle journal at ${journalPath}: ${error instanceof Error ? error.message : error}`)
  }
  return (journal.entries ?? []).map(({ tag, when }) => ({
    sql: readFileSync(`${DRIZZLE_MIGRATIONS_DIR}/${tag}.sql`, 'utf8'),
    when,
  }))
}

/**
 * A schema-only branch starts with an empty migrations table; baseline it (idempotently) so
 * the migrator works. Uses more retry attempts than other callers: this is the FIRST
 * connection after branch creation (or a rename — see sync()), most likely to race a compute
 * that hasn't finished booting yet.
 */
async function baselineMigrations(uri: string): Promise<void> {
  if (ORM === 'prisma') {
    const sql = buildPrismaBaselineSql(readPrismaMigrations())
    if (!sql) {
      console.log('[prisma] no migrations to baseline.')
      return
    }
    runWithRetry('prisma', ['db', 'execute', '--schema', PRISMA_SCHEMA, '--stdin'], { ...process.env, DATABASE_URL: uri }, 6, sql)
    return
  }
  // drizzle: no `db execute` CLI — run the baseline via the project's own Postgres driver,
  // with the same cold-compute retry budget as the Prisma path.
  const sql = buildDrizzleBaselineSql(readDrizzleMigrations())
  if (!sql) {
    console.log('[drizzle] no migrations to baseline.')
    return
  }
  await withRetry('baseline via execSql', () => execSql(uri, sql), 6)
}

/** Apply any migrations pulled into this workspace since its branch was created. */
function deployMigrations(uri: string): void {
  if (ORM === 'prisma') {
    runWithRetry('prisma', ['migrate', 'deploy'], { ...process.env, DATABASE_URL: uri })
  } else {
    runWithRetry('drizzle-kit', ['migrate'], { ...process.env, DATABASE_URL: uri })
  }
}

/**
 * Seed the workspace with test fixtures — the last step of setup.
 *
 * ── ADAPT THIS to your project's seed ──────────────────────────────────────────
 *  • No seed?  Delete this function and its call in provision().
 *  • Plain seed, no safety guard?  Replace the body with:
 *      Prisma:  runWithRetry('prisma', ['db', 'seed'], { ...process.env, DATABASE_URL: uri }, 2)
 *      Drizzle: runWithRetry('tsx', [SEED_SCRIPT], { ...process.env, DATABASE_URL: uri }, 2)
 *  • Seed that REFUSES non-local DBs (recommended — stops accidental prod seeding)?
 *      Authorize it for THIS branch only. The example below matches a seed that allows a
 *      remote DB when E2E_EXPECTED_DATABASE_URL === DATABASE_URL, gated on a password.
 */
function seedWorkspace(uri: string): void {
  if (!process.env.E2E_USER_PASSWORD) {
    console.warn(
      '[seed] seed credentials not set — skipping seed (workspace DB will be empty). ' +
        'Set them in Conductor env to seed test fixtures.',
    )
    return
  }
  console.log('[seed] seeding workspace fixtures…')
  runWithRetry('tsx', [SEED_SCRIPT], { ...process.env, DATABASE_URL: uri, E2E_EXPECTED_DATABASE_URL: uri }, 2)
}

async function provision(): Promise<void> {
  const projectId = requireEnv('NEON_PROJECT_ID')
  requireEnv('NEON_API_KEY') // consumed by neonctl from the environment
  const parent = requireEnv('NEON_PARENT_BRANCH')
  const branchName = workspaceBranchName()
  assertDisposableChildBranch(branchName, parent)

  // Rename-aware: if a previous provision recorded a DIFFERENT branch that still exists, the
  // workspace was renamed between setups. Rename that branch to the new name (data preserved)
  // instead of creating a second branch and orphaning the first. A rename that ultimately
  // fails while the old branch still exists must THROW, not warn-and-continue — continuing
  // would create a fresh branch and overwrite the state file, i.e. the only record of a live
  // branch that still holds this workspace's data.
  const recorded = readBranchState()
  if (recorded && recorded !== branchName) {
    assertDisposableChildBranch(recorded, parent)
    if (await withRetry('check recorded branch', () => branchExists(projectId, recorded), 3)) {
      console.log(`[neon] workspace renamed — renaming branch ${recorded} → ${branchName}…`)
      await renameBranch(projectId, recorded, branchName)
    }
    // Recorded branch gone (e.g. deleted out-of-band): fall through and derive fresh below.
  }

  let created = false
  if (await withRetry('check branch exists', () => branchExists(projectId, branchName), 3)) {
    console.log(`[neon] reusing existing branch ${branchName}`)
  } else {
    // Record 'pending' BEFORE creating: a kill mid-create then leaves a record instead of an
    // untracked branch that the next provision would mistake for a fully set-up one.
    writeBranchState(branchName, 'pending')
    console.log(`[neon] creating schema-only branch ${branchName} off ${parent}…`)
    // Idempotent under retry: if a create "fails" after actually creating (e.g. a timeout on
    // the response), the next attempt sees the branch and doesn't re-create it.
    await withRetry('create branch', () => {
      if (!branchExists(projectId, branchName)) {
        neon(['branches', 'create', '--project-id', projectId, '--name', branchName, '--parent', parent, '--schema-only', '--output', 'json'])
      }
    }, 3)
    created = true
  }

  // A 'pending' marker means a previous run crashed between create and the end of baseline+seed
  // (caught failures self-destruct the branch, so only an uncatchable kill leaves this state).
  // Recover by re-running the full first-time setup against the existing branch.
  const recovering = !created && setupIsPending()

  // Everything after a successful create is wrapped so that ANY failure (recording state,
  // fetching the connection string, writing the env file, baseline, seed, migrate) triggers the
  // cleanup below — otherwise a create followed by a transient error would leak the branch.
  try {
    // Record the name NOW, not re-derived later — see writeBranchState(). 'pending' until the
    // first-time setup (baseline + seed) completes.
    writeBranchState(branchName, created || recovering ? 'pending' : 'ready')

    // The endpoint of a just-created branch may still be provisioning — retry the fetch.
    const uri = await withRetry('fetch connection string', () => getConnectionString(projectId, branchName))
    writeDatabaseUrl(uri)
    console.log(`[conductor-db] wrote DATABASE_URL for ${branchName} → ${ENV_FILE}`)

    if (created || recovering) {
      // First-time setup (or its crash recovery): baseline the empty migration history, then
      // seed. The baseline is idempotent (WHERE NOT EXISTS), so recovery never duplicates rows.
      if (recovering) console.log('[conductor-db] previous setup never completed — recovering this branch.')
      console.log(`[${ORM}] baselining migration history…`)
      await baselineMigrations(uri)
      seedWorkspace(uri)
      writeBranchState(branchName, 'ready')
    } else {
      // Reuse of a fully set-up branch (KEEPS its data): apply any migrations committed since
      // the branch was created. NEVER re-baseline here — stamping a migration the branch has
      // not actually run would make migrate-deploy skip it and silently drift the schema.
      console.log(`[${ORM}] applying any migrations committed beyond the baseline…`)
      deployMigrations(uri)
    }
  } catch (error) {
    if (created) {
      // Only ever delete a branch WE just created; never a reused branch (it holds real data).
      console.error('[conductor-db] new-branch setup failed — deleting it so the next attempt starts clean.')
      try {
        neon(['branches', 'delete', branchName, '--project-id', projectId])
        // Delete succeeded: drop the record and the env file pointing at the dead endpoint.
        rmSync(BRANCH_STATE_FILE, { force: true })
        rmSync(ENV_FILE, { force: true })
      } catch {
        // Delete failed: the branch still exists, so KEEP the state file (marked 'pending') —
        // it is the only record that lets a later provision recover or teardown delete it.
        console.error(
          `[conductor-db] WARNING: could not delete just-created branch ${branchName}; ` +
            `keeping ${BRANCH_STATE_FILE} so the next provision/teardown can find it.`,
        )
      }
    }
    throw error
  }

  console.log('✅ [conductor-db] workspace database ready.')
}

async function teardown(): Promise<void> {
  // Missing Neon credentials: if there is also no trace of a provisioned branch (no state
  // file, no generated env file), the workspace never got a database — archive must not error.
  // But with a recorded/possible branch, failing loudly is the point: skipping here is exactly
  // how branches used to leak past archive.
  if (!process.env.NEON_PROJECT_ID || !process.env.NEON_API_KEY) {
    if (!readBranchState() && !existsSync(ENV_FILE)) {
      console.warn('[conductor-db] NEON_PROJECT_ID / NEON_API_KEY not set and no provisioned branch recorded — nothing to clean.')
      return
    }
    throw new Error(
      'NEON_PROJECT_ID / NEON_API_KEY are required to delete this workspace\'s Neon branch ' +
        '(a branch record exists). Set them in Conductor env and re-run archive, or the branch will leak.',
    )
  }
  const projectId = requireEnv('NEON_PROJECT_ID')
  const parent = process.env.NEON_PARENT_BRANCH ?? ''

  // Prefer the name provision() actually used — CONDUCTOR_WORKSPACE_NAME may have changed since
  // (the workspace was renamed), which would otherwise re-derive a different slug and miss the
  // real branch. The derived name is kept as a fallback for workspaces provisioned before the
  // state file existed, and for a record left stale by a crash between rename and re-record.
  const recorded = readBranchState()
  let derived: string | null = null
  try {
    derived = workspaceBranchName()
  } catch {
    // CONDUCTOR_WORKSPACE_NAME unset/unusable — proceed with the recorded name alone.
  }
  // A corrupted record (or one naming the parent) must not abort teardown outright — skip it
  // with a warning and let the other candidate be tried; the guard still makes it undeletable.
  const candidates = [...new Set([recorded, derived])]
    .filter((name): name is string => Boolean(name))
    .filter((name) => {
      try {
        assertDisposableChildBranch(name, parent)
        return true
      } catch (error) {
        console.warn(`[conductor-db] ignoring candidate "${name}": ${error instanceof Error ? error.message : error}`)
        return false
      }
    })
  if (candidates.length === 0) {
    throw new Error(
      'Cannot determine this workspace\'s branch: no usable .conductor/db-branch record and no ' +
        'usable CONDUCTOR_WORKSPACE_NAME to derive it from. Delete the branch manually ' +
        `(neonctl branches list --project-id ${projectId}) before archiving.`,
    )
  }

  // Idempotent: a branch that was never created (setup failed early) or is already gone
  // (self-destructed, or a previous teardown died between delete and state cleanup) is not an
  // error — an absent branch cannot leak. Real delete failures below still exit non-zero.
  let target: string | null = null
  for (const name of candidates) {
    if (await withRetry('check branch exists', () => branchExists(projectId, name), 3)) {
      target = name
      break
    }
  }
  if (!target) {
    console.log(`[conductor-db] no workspace branch found (checked: ${candidates.join(', ')}) — nothing to delete.`)
    rmSync(BRANCH_STATE_FILE, { force: true })
    rmSync(ENV_FILE, { force: true })
    return
  }

  console.log(`[neon] deleting branch ${target}…`)
  neon(['branches', 'delete', target, '--project-id', projectId], { inherit: true })
  rmSync(BRANCH_STATE_FILE, { force: true })
  // Also drop the generated env file: leaving it would let sync()'s provisioning gate pass and
  // boot the dev server against the deleted branch's dead endpoint.
  rmSync(ENV_FILE, { force: true })
  console.log('✅ [conductor-db] deleted the workspace database branch.')
}

/**
 * Runs before every dev-server start. Two jobs with different failure rules:
 *
 * 1. HARD GATE (throws): refuse to start the dev server if .env.neondb is missing. `dotenv -e`
 *    silently proceeds when the file doesn't exist, so without this check a workspace whose
 *    provisioning failed would boot against whatever DATABASE_URL leaks in from the ambient
 *    env — the exact shared-database collision this whole setup exists to prevent.
 * 2. Rename catch-up (best-effort, never throws): Conductor has no rename event, so this is
 *    where the Neon branch's name is brought back in line with the workspace. Any failure here
 *    only leaves the Neon console's branch name cosmetically stale.
 */
async function sync(): Promise<void> {
  if (!existsSync(ENV_FILE)) {
    throw new Error(
      `${ENV_FILE} not found — this workspace's database was never provisioned (or provisioning failed). ` +
        `Re-run workspace setup (scripts/conductor-db.ts provision) before starting the dev server; ` +
        `starting without it would silently use a shared/ambient DATABASE_URL.`,
    )
  }
  if (setupIsPending()) {
    throw new Error(
      'This workspace\'s database setup never completed (state is "pending" — a previous ' +
        'provision was interrupted before baseline/seed finished). Re-run workspace setup ' +
        '(scripts/conductor-db.ts provision) to recover it before starting the dev server.',
    )
  }
  const projectId = process.env.NEON_PROJECT_ID
  if (!projectId || !process.env.NEON_API_KEY) {
    console.warn('[conductor-db] NEON_PROJECT_ID / NEON_API_KEY not set — skipping branch rename sync.')
    return
  }
  try {
    const recorded = readBranchState()
    const current = workspaceBranchName()
    if (!recorded) {
      // Workspace provisioned before the state file existed: record the name now, while the
      // derived slug still matches the live branch, so a later rename can't orphan it.
      if (branchExists(projectId, current)) {
        assertDisposableChildBranch(current, process.env.NEON_PARENT_BRANCH ?? '')
        writeBranchState(current)
        console.log(`[conductor-db] recorded existing branch ${current} → ${BRANCH_STATE_FILE}`)
      }
      return
    }
    if (recorded === current) return // no rename since the last check

    assertDisposableChildBranch(recorded, process.env.NEON_PARENT_BRANCH ?? '')
    assertDisposableChildBranch(current, process.env.NEON_PARENT_BRANCH ?? '')

    // Self-heal a record left stale by a crash between a rename and its re-record: if the
    // recorded branch is gone but one under the current name exists, just re-record.
    if (!branchExists(projectId, recorded) && branchExists(projectId, current)) {
      writeBranchState(current)
      console.log(`[conductor-db] record was stale — re-recorded live branch ${current}.`)
      return
    }

    console.log(`[neon] workspace renamed — renaming branch ${recorded} → ${current}…`)
    await renameBranch(projectId, recorded, current)
    writeBranchState(current)
    console.log('✅ [conductor-db] branch renamed to match the workspace.')
  } catch (error) {
    console.warn(`[conductor-db] WARNING: branch rename sync failed: ${error instanceof Error ? error.message : error}`)
  }
}

async function main(): Promise<void> {
  const mode = process.argv[2]
  try {
    if (mode === 'provision') await provision()
    else if (mode === 'teardown') await teardown()
    else if (mode === 'sync') await sync()
    else {
      console.error('Usage: tsx scripts/conductor-db.ts <provision|teardown|sync>')
      process.exit(2)
    }
  } catch (error) {
    console.error(`❌ [conductor-db] ${mode ?? '(no mode)'} failed:`, error instanceof Error ? error.message : error)
    process.exit(1)
  }
}

// Run only when executed directly (e.g. `tsx scripts/conductor-db.ts provision`),
// so unit tests can import the pure helpers above without triggering the CLI.
if (process.argv[1] && /conductor-db\.[cm]?[jt]s$/.test(process.argv[1])) {
  void main()
}
