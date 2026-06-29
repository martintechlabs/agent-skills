// scripts/conductor-db.ts
//
// Per-workspace ISOLATED database for Conductor (works in local AND cloud workspaces).
// Each workspace gets its own SCHEMA-ONLY Neon branch off the production branch: the full
// schema + extensions (e.g. PostGIS's spatial_ref_sys data) but ZERO production rows,
// created instantly (Neon copies no data). Provisioning then:
//   • baselines Prisma's migration history — a schema-only branch starts with an EMPTY
//     _prisma_migrations, which would otherwise break `prisma migrate dev/deploy`; and
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
// Assumes Neon (Postgres) + Prisma migrations, with `neonctl` and `tsx` available as
// project-local binaries. Adjust the PORTING KNOBS just below for your project.
//
// Baselining assumes the parent branch already contains every migration committed on this
// code branch — true for the normal Conductor flow (workspaces branch from the default
// branch; production is deployed from it). If the parent lags the code's migrations, run
// `prisma migrate reset` in the workspace to rebuild from migrations.
//
// SAFETY: every destructive op (branch delete) is guarded to only ever run against a
// disposable `conductor/*` branch — never the parent/production branch.

import { execFileSync, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'

// ── PORTING KNOBS ────────────────────────────────────────────────────────────
// How to run a project-local CLI (neonctl/prisma/tsx). Match your package manager:
//   pnpm → ['pnpm', 'exec']   npm → ['npx']   yarn → ['yarn']
const PM_EXEC = ['pnpm', 'exec']
const ENV_FILE = '.env' // file the app/Prisma/tsx auto-load DATABASE_URL from
const BRANCH_PREFIX = 'conductor/' // workspace-branch namespace (matches Neon's preview/)
const MIGRATIONS_DIR = 'prisma/migrations'
const PRISMA_SCHEMA = 'prisma/schema.prisma'
const SEED_SCRIPT = 'prisma/seed.ts'
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
 * Build the INSERT that baselines _prisma_migrations to "all migrations applied", using
 * Prisma's own checksum (sha256 hex of each migration.sql). Returns null if there are none.
 */
export function buildBaselineSql(migrations: Array<{ name: string; sql: string }>): string | null {
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

/** Read committed migrations (name + SQL) from disk, in apply order. */
function readMigrations(): Array<{ name: string; sql: string }> {
  return readdirSync(MIGRATIONS_DIR, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort()
    .flatMap((name) => {
      try {
        return [{ name, sql: readFileSync(`${MIGRATIONS_DIR}/${name}/migration.sql`, 'utf8') }]
      } catch {
        return [] // directory without a migration.sql — skip
      }
    })
}

/** A schema-only branch starts with an empty _prisma_migrations; baseline it so migrate works. */
function baselineMigrations(uri: string): void {
  const sql = buildBaselineSql(readMigrations())
  if (!sql) {
    console.log('[prisma] no migrations to baseline.')
    return
  }
  runWithRetry('prisma', ['db', 'execute', '--schema', PRISMA_SCHEMA, '--stdin'], { ...process.env, DATABASE_URL: uri }, 3, sql)
}

/**
 * Seed the workspace with test fixtures — the last step of setup.
 *
 * ── ADAPT THIS to your project's seed ──────────────────────────────────────────
 *  • No seed?  Delete this function and its call in provision().
 *  • Plain seed, no safety guard?  Replace the body with:
 *      runWithRetry('prisma', ['db', 'seed'], { ...process.env, DATABASE_URL: uri }, 2)
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

function provision(): void {
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
      console.log('[prisma] baselining migration history (schema-only branches start empty)…')
      baselineMigrations(uri)
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
    console.log('[prisma] applying any migrations beyond the baseline…')
    runWithRetry('prisma', ['migrate', 'deploy'], { ...process.env, DATABASE_URL: uri })
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

function main(): void {
  const mode = process.argv[2]
  try {
    if (mode === 'provision') provision()
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
  main()
}
