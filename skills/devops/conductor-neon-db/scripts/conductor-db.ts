// scripts/conductor-db.ts
//
// Per-workspace ISOLATED database for Conductor (works in local AND cloud workspaces).
// Each workspace gets its own SCHEMA-ONLY Neon branch off the production branch: the full
// schema + extensions (e.g. PostGIS's spatial_ref_sys data) but ZERO production rows,
// created instantly (Neon copies no data). Provisioning then:
//   • baselines the ORM's migration history — a schema-only branch starts with an EMPTY
//     migrations table, which would otherwise make the migrator re-run every migration
//     against tables that already exist and fail; and
//   • seeds test fixtures (the last step of setup).
// The branch is deleted when the workspace is archived.
//
//   setup   → `tsx scripts/conductor-db.ts provision`
//   archive → `tsx scripts/conductor-db.ts teardown`
//
// Requires (set as Conductor environment variables — Local tab for local workspaces,
// Cloud tab for cloud workspaces):
//   NEON_API_KEY       – Neon API key (read by neonctl)
//   NEON_PROJECT_ID    – Neon project to branch within
//   NEON_PARENT_BRANCH – REQUIRED (no default); branch to clone, e.g. "production"
//   (seed credentials) – whatever your seed needs — see seedWorkspace() below
//
// Assumes Neon (Postgres) with migrations managed by EITHER Prisma OR Drizzle (set ORM below),
// with `neonctl` and `tsx` available as project-local binaries. The Drizzle path additionally
// needs the project's own Postgres driver wired into execSql() (Drizzle has no `prisma db
// execute` equivalent). Adjust the PORTING KNOBS just below for your project.
//
// Baselining assumes the parent branch already contains every migration committed on this
// code branch — true for the normal Conductor flow (workspaces branch from the default
// branch; production is deployed from it). If the parent lags the code's migrations, run the
// ORM's reset (`prisma migrate reset` / `drizzle-kit push` from scratch) in the workspace.
//
// SAFETY: every destructive op (branch delete) is guarded to only ever run against a
// disposable `conductor/*` branch — never the parent/production branch. The baseline is
// RECONSTRUCTED from the repo's migration files — provisioning never reads from production.

import { execFileSync, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'

// ── PORTING KNOBS ────────────────────────────────────────────────────────────
// Which ORM manages migrations. Switches the baseline + reuse logic throughout.
const ORM: 'prisma' | 'drizzle' = 'prisma'

// How to run a project-local CLI (neonctl/prisma/drizzle-kit/tsx). Match your package manager:
//   pnpm → ['pnpm', 'exec']   npm → ['npx']   yarn → ['yarn']
const PM_EXEC = ['pnpm', 'exec']
const ENV_FILE = '.env' // file the app/ORM/tsx auto-load DATABASE_URL from
const BRANCH_PREFIX = 'conductor/' // workspace-branch namespace (matches Neon's preview/)
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
      `${name} is required to provision a per-workspace Neon branch. ` +
        `Add it as a Conductor environment variable (Local tab for local, Cloud tab for cloud).`,
    )
  }
  return value
}

/** Stable, Neon-safe branch name derived from the workspace name. */
export function workspaceBranchName(): string {
  const raw = requireEnv('CONDUCTOR_WORKSPACE_NAME')
  const slug = raw
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 48)
  if (!slug) {
    throw new Error(`Could not derive a branch name from CONDUCTOR_WORKSPACE_NAME="${raw}".`)
  }
  return `${BRANCH_PREFIX}${slug}`
}

/**
 * Hard safety guard. Destructive operations (deleting a branch) must only ever target a
 * disposable per-workspace `conductor/*` branch — never the parent (production). Throws
 * otherwise.
 */
export function assertDisposableChildBranch(branchName: string, parentBranch: string): void {
  if (!branchName.startsWith(BRANCH_PREFIX)) {
    throw new Error(`Refusing destructive op on "${branchName}": not a "${BRANCH_PREFIX}" workspace branch.`)
  }
  if (parentBranch && branchName === parentBranch) {
    throw new Error(`Refusing destructive op on "${branchName}": it is the parent branch.`)
  }
}

/** Run a project-local CLI, capturing stdout. */
function pmExec(bin: string, args: string[]): string {
  return execFileSync(PM_EXEC[0], [...PM_EXEC.slice(1), bin, ...args], { encoding: 'utf8', env: process.env })
}

/** Run neonctl (it reads NEON_API_KEY from the environment) and return stdout. */
function neon(args: string[]): string {
  return pmExec('neonctl', args)
}

function getConnectionString(projectId: string, branchName: string): string {
  const uri = neon(['connection-string', branchName, '--project-id', projectId]).trim()
  if (!uri.startsWith('postgres')) {
    throw new Error(`neonctl did not return a postgres connection string (got ${uri.length} chars).`)
  }
  return uri
}

/**
 * Retry a project-local CLI — a freshly created branch compute may be cold. When `input` is
 * given it is piped to the command's stdin (used to feed SQL to `prisma db execute --stdin`).
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
    console.log(`[retry] attempt ${attempt} failed; waiting before retry…`)
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 3000)
  }
}

/**
 * Replace .env with one that points at this workspace's own Neon branch. The workspace has
 * no committed .env (it is gitignored); any pre-existing file or stale symlink is removed
 * first so we always write a real, workspace-local file.
 */
function writeDatabaseUrl(uri: string): void {
  rmSync(ENV_FILE, { force: true })
  writeFileSync(
    ENV_FILE,
    `# Generated by scripts/conductor-db.ts for this Conductor workspace. Do not commit.\n` +
      `DATABASE_URL="${uri}"\n`,
    { mode: 0o600 },
  )
}

/**
 * Build the INSERT that baselines Prisma's _prisma_migrations to "all migrations applied",
 * using Prisma's own checksum (sha256 hex of each migration.sql). Returns null if none.
 */
export function buildPrismaBaselineSql(migrations: Array<{ name: string; sql: string }>): string | null {
  if (migrations.length === 0) return null
  const values = migrations
    .map(({ name, sql }) => {
      const checksum = createHash('sha256').update(sql).digest('hex')
      return `(gen_random_uuid()::text, '${checksum}', now(), '${name}', NULL, NULL, now(), 1)`
    })
    .join(',\n')
  return (
    'INSERT INTO "_prisma_migrations" ' +
    '(id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count) VALUES\n' +
    `${values};`
  )
}

/**
 * Build the INSERT that baselines Drizzle's migrations table to "all migrations applied". Each
 * row is (hash = sha256 hex of the migration .sql file's contents, created_at = the journal's
 * `when` ms timestamp) — exactly what drizzle-kit would have written. drizzle-kit decides what
 * to run by the latest created_at, so the timestamps must come from the journal, not now().
 * Prepends CREATE SCHEMA/TABLE IF NOT EXISTS so it works even on the rare branch whose
 * schema-only copy somehow lacks the (empty) migrations table. Returns null if none.
 */
export function buildDrizzleBaselineSql(migrations: Array<{ sql: string; when: number }>): string | null {
  if (migrations.length === 0) return null
  const values = migrations
    .map(({ sql, when }) => {
      const hash = createHash('sha256').update(sql).digest('hex')
      return `('${hash}', ${when})`
    })
    .join(',\n')
  const qualified = `"${DRIZZLE_MIGRATIONS_SCHEMA}"."${DRIZZLE_MIGRATIONS_TABLE}"`
  return (
    `CREATE SCHEMA IF NOT EXISTS "${DRIZZLE_MIGRATIONS_SCHEMA}";\n` +
    `CREATE TABLE IF NOT EXISTS ${qualified} (id SERIAL PRIMARY KEY, hash text NOT NULL, created_at bigint);\n` +
    `INSERT INTO ${qualified} (hash, created_at) VALUES\n${values};`
  )
}

/** Read committed Prisma migrations (name + SQL) from disk, in apply order. */
function readPrismaMigrations(): Array<{ name: string; sql: string }> {
  return readdirSync(PRISMA_MIGRATIONS_DIR, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort()
    .flatMap((name) => {
      try {
        return [{ name, sql: readFileSync(`${PRISMA_MIGRATIONS_DIR}/${name}/migration.sql`, 'utf8') }]
      } catch {
        return [] // directory without a migration.sql — skip
      }
    })
}

/**
 * Read committed Drizzle migrations from disk, in apply order. The journal (meta/_journal.json)
 * is the source of truth for order and each migration's `when` timestamp; the SQL lives in the
 * sibling `<tag>.sql` file.
 */
function readDrizzleMigrations(): Array<{ sql: string; when: number }> {
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

/** A schema-only branch starts with an empty migrations table; baseline it so the migrator works. */
async function baselineMigrations(uri: string): Promise<void> {
  if (ORM === 'prisma') {
    const sql = buildPrismaBaselineSql(readPrismaMigrations())
    if (!sql) {
      console.log('[prisma] no migrations to baseline.')
      return
    }
    runWithRetry('prisma', ['db', 'execute', '--schema', PRISMA_SCHEMA, '--stdin'], { ...process.env, DATABASE_URL: uri }, 3, sql)
    return
  }
  // drizzle: no `db execute` CLI — run the baseline via the project's own Postgres driver.
  const sql = buildDrizzleBaselineSql(readDrizzleMigrations())
  if (!sql) {
    console.log('[drizzle] no migrations to baseline.')
    return
  }
  await execSql(uri, sql)
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

  let uri: string
  let created = false
  try {
    // Idempotent: if the workspace was set up before, reuse its branch (and KEEP its data).
    uri = getConnectionString(projectId, branchName)
    console.log(`[neon] reusing existing branch ${branchName}`)
  } catch {
    console.log(`[neon] creating schema-only branch ${branchName} off ${parent}…`)
    neon(['branches', 'create', '--project-id', projectId, '--name', branchName, '--parent', parent, '--schema-only', '--output', 'json'])
    uri = getConnectionString(projectId, branchName)
    created = true
  }

  writeDatabaseUrl(uri)
  console.log(`[conductor-db] wrote DATABASE_URL for ${branchName} → ${ENV_FILE}`)

  if (created) {
    // A fresh schema-only branch needs its migration history baselined and then a seed.
    // Treat the two as atomic: if either fails, delete the branch so the next provision
    // starts clean rather than reusing a half-set-up branch.
    try {
      console.log(`[${ORM}] baselining migration history (schema-only branches start empty)…`)
      await baselineMigrations(uri)
      seedWorkspace(uri)
    } catch (error) {
      console.error('[conductor-db] new-branch setup failed — deleting it so the next attempt starts clean.')
      try {
        neon(['branches', 'delete', branchName, '--project-id', projectId])
      } catch {
        /* best effort */
      }
      throw error
    }
  } else {
    // Reuse: apply any migrations pulled into this workspace since the branch was created.
    console.log(`[${ORM}] applying any migrations beyond the baseline…`)
    deployMigrations(uri)
  }

  console.log('✅ [conductor-db] workspace database ready.')
}

function teardown(): void {
  const projectId = process.env.NEON_PROJECT_ID
  if (!projectId || !process.env.NEON_API_KEY) {
    console.warn('[conductor-db] NEON_PROJECT_ID / NEON_API_KEY not set — skipping branch teardown.')
    return
  }
  const branchName = workspaceBranchName()
  assertDisposableChildBranch(branchName, process.env.NEON_PARENT_BRANCH ?? '')
  console.log(`[neon] deleting branch ${branchName}…`)
  try {
    execFileSync(PM_EXEC[0], [...PM_EXEC.slice(1), 'neonctl', 'branches', 'delete', branchName, '--project-id', projectId], {
      stdio: 'inherit',
      env: process.env,
    })
    console.log('✅ [conductor-db] deleted the workspace database branch.')
  } catch (error) {
    console.error(
      `[conductor-db] WARNING: could not delete branch ${branchName}. ` +
        `List leftovers with: neonctl branches list --project-id ${projectId}`,
      error,
    )
  }
}

async function main(): Promise<void> {
  const mode = process.argv[2]
  try {
    if (mode === 'provision') await provision()
    else if (mode === 'teardown') teardown()
    else {
      console.error('Usage: tsx scripts/conductor-db.ts <provision|teardown>')
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
