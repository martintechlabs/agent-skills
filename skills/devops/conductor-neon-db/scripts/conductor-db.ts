// scripts/conductor-db.ts
//
// Per-workspace ISOLATED database for Conductor (works in local AND cloud workspaces).
// Each workspace gets its own SCHEMA-ONLY Neon branch off the production branch: the full
// schema + extensions (e.g. PostGIS's spatial_ref_sys data) but ZERO production rows, created
// instantly (Neon copies no data).
//
// provision() is a full, deterministic rebuild — EVERY run, not just the first, deletes whatever
// branch is currently recorded for this workspace (if any) and creates a fresh one. Any data
// written into the workspace branch through normal app usage is discarded on every re-run — the
// branch is disposable by design; there is no "reuse an existing branch" path. This also handles
// a renamed workspace for free: the OLD recorded branch gets deleted, and the new one is created
// fresh under the current name — no rename API call needed.
//
// A schema-only branch starts with an EMPTY migrations table (even if the parent's isn't), which
// would otherwise make the migrator either re-run every migration against tables that already
// exist (if the parent has real schema) and fail, or silently believe a falsely assumed history
// is real — e.g. if the parent hasn't actually run every migration committed on this code branch
// yet, baselining from local migration files would falsely mark those as applied without ever
// running them. So before deploying migrations, provision() learns the parent's TRUE
// applied-migration set: it clones the parent again — this time WITH data, into a second,
// equally disposable `tmp/*` branch — reads that clone's real migration-ledger rows (row data is
// the only source of truth for "what really ran"; a schema-only clone strips it, even for this
// table), deletes the clone, and seeds the workspace branch's ledger with exactly those rows.
// The ORM's migrate-deploy then applies whatever's genuinely still missing — correct whether the
// parent has every migration, none of them, or is only partway caught up.
//
// 'pending'/'ready' in the state file tracks whether a rebuild is mid-flight — sync() (see
// below) refuses to start the dev server against a branch caught mid-rebuild by a kill.
//
// provision() also records the exact branch name it used in .conductor/db-branch (gitignored) so
// teardown finds the SAME branch even if the workspace is renamed in Conductor afterward — a
// rename changes CONDUCTOR_WORKSPACE_NAME, which would otherwise make teardown re-derive a
// DIFFERENT slug and silently miss the real branch (see readBranchState()).
//
// Conductor has no "workspace renamed" event, so `sync` piggybacks on `run` instead — the only
// hook that fires repeatedly through a workspace's life. It compares the recorded branch name
// against one freshly derived from CONDUCTOR_WORKSPACE_NAME, and if a rename happened since the
// last check, renames the Neon branch to match (a real rename, not delete+recreate — data and
// DATABASE_URL are untouched, since Neon connection strings key off the branch's compute
// endpoint, not its name). Purely cosmetic: teardown works correctly with or without it, since it
// always trusts whatever .conductor/db-branch last recorded.
//
//   setup   → `tsx scripts/conductor-db.ts provision`
//   run     → `tsx scripts/conductor-db.ts sync` (prepended to the dev server command)
//   archive → `tsx scripts/conductor-db.ts teardown`
//
// Requires (set as Conductor environment variables — Local tab for local workspaces, Cloud tab
// for cloud workspaces). Missing NEON_API_KEY / NEON_PROJECT_ID, or a failed branch delete, fails
// provision/teardown loudly (non-zero exit) instead of warning-and-continuing — a swallowed
// failure here is exactly how Neon branches leaked past Conductor's archive step before (teardown
// of an ALREADY-ABSENT branch is fine, though: an absent branch cannot leak). `sync`'s rename part
// is the one best-effort exception — it warns and no-ops on failure, since a cosmetic naming sync
// must never block the dev server — but sync DOES fail hard when .env.neondb is missing
// (unprovisioned workspace), see sync():
//   NEON_API_KEY       – Neon API key (read by neonctl); required by provision AND teardown
//   NEON_PROJECT_ID    – Neon project to branch within; required by provision AND teardown
//   NEON_PARENT_BRANCH – REQUIRED by provision (no default); branch to clone, e.g. "production".
//                        teardown/sync only use it for the production-safety guard, if set.
//   (seed credentials) – whatever your seed needs; provision-only — see seedWorkspace() below
//
// Assumes Neon (Postgres) with migrations managed by EITHER Prisma OR Drizzle (set ORM below),
// with `neonctl` and `tsx` available as project-local binaries. BOTH ORMs need the project's own
// Postgres driver wired into execSql() — reading the parent's true migration ledger back needs a
// real query result, which neither `prisma db execute` nor `drizzle-kit` gives you. Adjust the
// PORTING KNOBS just below for your project.
//
// SAFETY: every destructive op (branch delete/rename) is guarded to only ever run against a
// disposable `conductor/*` workspace branch or a disposable `tmp/*` check branch — never the
// parent/production branch. provision() never opens a connection to the parent directly, only to
// the disposable check branch cloned from it.

import { execFileSync, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'

// ── PORTING KNOBS ────────────────────────────────────────────────────────────
// Which ORM manages migrations. Switches the ledger table + baseline SQL shape throughout.
const ORM: 'prisma' | 'drizzle' = 'prisma'

// How to run a project-local CLI (neonctl/prisma/drizzle-kit/tsx). Match your package manager:
//   pnpm → ['pnpm', 'exec']   npm → ['npx']   yarn → ['yarn']
const PM_EXEC = ['pnpm', 'exec']
// DATABASE_URL lands in its OWN file, not .env, so the project's real .env is never clobbered.
// NOTHING auto-loads .env.neondb — the run script loads it explicitly with override
// (dotenv -e .env.neondb -o --; without -o an ambient DATABASE_URL would silently win) and this
// script passes the DB vars to every child process itself. Anything else that needs the
// workspace DB (a manual `prisma studio`, an e2e runner) must load it the same way.
const ENV_FILE = '.env.neondb'
// EVERY env var that must point at the per-workspace branch. The project's real .env still gets
// auto-loaded by the ORM CLI/dev server, so any DB URL var it defines that is NOT listed here
// leaks the shared database into this workspace. If schema.prisma uses
// `directUrl = env("DIRECT_URL")` or `shadowDatabaseUrl = env(...)`, add those names.
const DB_ENV_VARS = ['DATABASE_URL']
const BRANCH_PREFIX = 'conductor/' // workspace-branch namespace (matches Neon's preview/)
const CHECK_BRANCH_PREFIX = 'tmp/' // disposable per-run branch used only to read the parent's true migration ledger
const MAX_SLUG = 48 // Neon-safe branch-name length budget (excluding either prefix)
const SEED_SCRIPT = 'prisma/seed.ts' // project's seed entrypoint (see seedWorkspace)

// ── Drizzle-only knob (used when ORM === 'drizzle') ──────────────────────────
// Where drizzle records applied migrations. Defaults match drizzle-kit; override only if you set
// a custom migrationsSchema/migrationsTable in drizzle.config. (Prisma's `_prisma_migrations`
// table name is fixed by Prisma itself — nothing to knob there.)
const DRIZZLE_MIGRATIONS_SCHEMA = 'drizzle'
const DRIZZLE_MIGRATIONS_TABLE = '__drizzle_migrations'

/**
 * Execute SQL against a Neon branch and return whatever rows it produces. Used both to READ the
 * parent's true applied-migration ledger (via a disposable full-data clone; see
 * seedTrueBaseline) and to WRITE the baseline INSERT built from those rows — required for BOTH
 * ORMs, since reading a ledger back needs a real query result, not just a migration CLI. Wire
 * this to the Postgres driver the project ALREADY depends on; do not add a new one. Pick the
 * matching example, move its import to the top of the file, drop the body's throw:
 *
 *   // pg (node-postgres):
 *   //   import { Client } from 'pg'
 *   //   async function execSql(uri, sql) {
 *   //     const c = new Client({ connectionString: uri }); await c.connect()
 *   //     try { return (await c.query(sql)).rows } finally { await c.end() }
 *   //   }
 *
 *   // postgres (postgres-js):
 *   //   import postgres from 'postgres'
 *   //   async function execSql(uri, sql) {
 *   //     const c = postgres(uri); try { return await c.unsafe(sql) } finally { await c.end() }
 *   //   }
 *
 *   // @neondatabase/serverless (Pool — wire-compatible with node-postgres):
 *   //   import { Pool } from '@neondatabase/serverless'
 *   //   async function execSql(uri, sql) {
 *   //     const p = new Pool({ connectionString: uri })
 *   //     try { return (await p.query(sql)).rows } finally { await p.end() }
 *   //   }
 *
 * Left unconfigured it raises a clear error rather than inventing a driver dependency.
 */
async function execSql<T = Record<string, unknown>>(_uri: string, _sql: string): Promise<T[]> {
  // FatalError so the retry wrapper surfaces this misconfiguration immediately instead of
  // burning a minute of backoff on an error no retry can fix.
  throw new FatalError(
    'execSql() is not configured. Wire it to the project\'s Postgres driver (pg / postgres / ' +
      '@neondatabase/serverless) — see the example in the PORTING KNOBS block. Required for both ' +
      'Prisma and Drizzle projects: reading back the true migration ledger needs a real query ' +
      'result, not just a migration CLI.',
  )
}

/**
 * The parent's true applied-migration set for Drizzle, read from a full-data clone of it (never
 * from the parent directly — see seedTrueBaseline). Row data — not schema — is the only source
 * of truth for "what really ran": a schema-only clone strips row data, even for this table
 * itself. A missing table (Postgres error code 42P01 — the parent has never had any migration
 * applied) is not an error: it means the true set is empty.
 */
async function readTrueDrizzleLedger(uri: string): Promise<Array<{ hash: string; created_at: string | number }>> {
  try {
    return await execSql<{ hash: string; created_at: string | number }>(
      uri,
      `SELECT hash, created_at FROM "${DRIZZLE_MIGRATIONS_SCHEMA}"."${DRIZZLE_MIGRATIONS_TABLE}" ORDER BY created_at`,
    )
  } catch (error) {
    if ((error as { code?: string }).code === '42P01') return []
    throw error
  }
}

/**
 * The parent's true applied-migration set for Prisma, read the same way. Only rows Prisma itself
 * considers genuinely applied — `finished_at` set, never rolled back — count, mirroring what
 * `prisma migrate status` uses, so a partially-applied or rolled-back migration on the parent
 * isn't falsely baselined as done.
 */
async function readTruePrismaLedger(uri: string): Promise<Array<{ checksum: string; migration_name: string }>> {
  try {
    return await execSql<{ checksum: string; migration_name: string }>(
      uri,
      'SELECT checksum, migration_name FROM "_prisma_migrations" ' +
        'WHERE finished_at IS NOT NULL AND rolled_back_at IS NULL ORDER BY started_at',
    )
  } catch (error) {
    if ((error as { code?: string }).code === '42P01') return []
    throw error
  }
}
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Where provision() records the branch it used. Resolved at call time so tests can point it at a
 * sandbox via CONDUCTOR_DB_STATE_FILE (test-only override — never set it in Conductor).
 */
function stateFilePath(): string {
  return process.env.CONDUCTOR_DB_STATE_FILE ?? '.conductor/db-branch'
}

/** The child-process environment with every DB var pinned to the workspace branch. */
function childDbEnv(uri: string): NodeJS.ProcessEnv {
  return { ...process.env, ...Object.fromEntries(DB_ENV_VARS.map((name) => [name, uri])) }
}

/**
 * Whether this workspace shows any trace of a provisioned branch: the generated env file, or a
 * `.env` written by the PRE-.env.neondb version of this script (identified by its header
 * comment). Used by teardown to distinguish "never provisioned — nothing to clean" from "a
 * branch may exist — failing to delete it would leak".
 */
function provisionedEnvTraceExists(): boolean {
  if (existsSync(ENV_FILE)) return true
  try {
    return readFileSync('.env', 'utf8').includes('Generated by scripts/conductor-db.ts')
  } catch (error) {
    // Only a missing .env means "no trace". An unreadable one (EACCES, EISDIR) must NOT be
    // silently read as never-provisioned — that would let teardown skip a live branch.
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return false
    throw error
  }
}

/**
 * Remove every env file this script (or its pre-.env.neondb predecessor, identified by its
 * header comment) generated. Env file first, state record last — see the teardown comment.
 */
function removeGeneratedEnvFiles(): void {
  rmSync(ENV_FILE, { force: true })
  try {
    if (readFileSync('.env', 'utf8').includes('Generated by scripts/conductor-db.ts')) {
      rmSync('.env', { force: true })
    }
  } catch {
    // Missing or unreadable .env — nothing we can (or should) remove.
  }
}

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

/** The raw slug for the current workspace, before any length handling. */
function workspaceSlug(): string {
  const raw = process.env.CONDUCTOR_WORKSPACE_NAME
  if (!raw) {
    // Deliberately NOT requireEnv: Conductor injects this variable itself. Telling the user to
    // add it to the env tabs would pin every workspace to ONE shared slug (and one branch).
    throw new Error(
      'CONDUCTOR_WORKSPACE_NAME is not set — this script must run inside a Conductor workspace ' +
        '(Conductor injects it automatically). Do NOT add it to the Conductor env tabs.',
    )
  }
  const slug = raw
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
  if (!slug) {
    throw new Error(`Could not derive a branch name from CONDUCTOR_WORKSPACE_NAME="${raw}".`)
  }
  return slug
}

/**
 * Shared by workspaceBranchName() and checkBranchName() — same slug/truncation/collision-hash
 * logic under a different disposable-branch prefix.
 */
function branchNameWithPrefix(prefix: string): string {
  const raw = process.env.CONDUCTOR_WORKSPACE_NAME ?? ''
  let slug = workspaceSlug()
  if (slug.length > MAX_SLUG) {
    // Truncate, but keep distinct workspaces distinct: append a short hash of the FULL name so
    // two long names that share a prefix don't collide onto the same branch (which would break
    // isolation and let one workspace's teardown delete another's branch). Re-trim any separator
    // the cut left dangling so the name never ends in "-".
    const suffix = createHash('sha256').update(raw).digest('hex').slice(0, 8)
    slug = `${slug.slice(0, MAX_SLUG - suffix.length - 1).replace(/-+$/, '')}-${suffix}`
  }
  return `${prefix}${slug}`
}

/** Stable, Neon-safe branch name derived from the workspace name. */
export function workspaceBranchName(): string {
  return branchNameWithPrefix(BRANCH_PREFIX)
}

/**
 * The disposable branch used once per provision() run to learn the parent's true
 * applied-migration state (see seedTrueBaseline). Same derivation as workspaceBranchName(),
 * under CHECK_BRANCH_PREFIX — deterministic, not random, so a leftover from a killed run is found
 * by name and replaced rather than accumulating orphans.
 */
export function checkBranchName(): string {
  return branchNameWithPrefix(CHECK_BRANCH_PREFIX)
}

/**
 * The name an EARLIER version of this script (flat `.slice(0, 48)` truncation, no hash suffix)
 * would have derived, or null when it matches the current derivation. Teardown and sync check it
 * as a fallback so upgrading doesn't orphan long-named workspaces provisioned before the state
 * file existed.
 */
export function legacyWorkspaceBranchName(): string | null {
  const flat = `${BRANCH_PREFIX}${workspaceSlug().slice(0, MAX_SLUG)}`
  return flat === workspaceBranchName() ? null : flat
}

/**
 * Persist the exact branch name provision() used. Reading this back in teardown() (instead of
 * re-deriving via workspaceBranchName()) makes teardown immune to a workspace rename changing
 * CONDUCTOR_WORKSPACE_NAME between provision and archive.
 *
 * The optional second line is a setup-phase marker: 'pending' means the branch was created but
 * baseline+seed have not completed (a crash in that window is the ONLY way a half-set-up branch
 * can survive, since caught failures self-destruct the branch). This does not gate WHETHER
 * provision() rebuilds — it always does — it exists so sync()'s hard gate (setupIsPending()) can
 * refuse to start the dev server against a branch caught mid-rebuild. A file without a marker —
 * e.g. written by an earlier version of this script — is treated as 'ready', so an upgrade
 * doesn't spuriously block sync() on a workspace that finished setup under the old format.
 */
export function writeBranchState(branchName: string, phase: 'pending' | 'ready' = 'ready'): void {
  const file = stateFilePath()
  mkdirSync(dirname(file), { recursive: true })
  // Write-then-rename so a crash mid-write can't leave a truncated/garbage state file.
  const tmp = `${file}.tmp`
  writeFileSync(tmp, `${branchName}\n${phase}\n`, { mode: 0o600 })
  renameSync(tmp, file)
}

/** Single reader for the state file; the exported helpers below are thin views over it. */
function readStateFile(): { branch: string; phase: 'pending' | 'ready' } | null {
  try {
    const lines = readFileSync(stateFilePath(), 'utf8').split('\n')
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

/** Sibling of the workspace-branch state file, for the disposable check branch instead. */
function checkBranchStateFilePath(): string {
  return `${stateFilePath()}-check`
}

/**
 * Persist the check branch's exact name for its lifetime — written BEFORE it's created, cleared
 * AFTER it's successfully deleted. Mirrors why writeBranchState() persists the workspace branch's
 * name: without this, a leaked check branch (created but never cleaned up, e.g. by a kill) can
 * only ever be found by re-deriving checkBranchName() from the CURRENT CONDUCTOR_WORKSPACE_NAME —
 * which misses it entirely if the workspace is renamed before the next provision()/teardown()
 * call, since a renamed workspace derives a different name.
 */
export function writeCheckBranchState(branchName: string): void {
  const file = checkBranchStateFilePath()
  mkdirSync(dirname(file), { recursive: true })
  const tmp = `${file}.tmp`
  writeFileSync(tmp, `${branchName}\n`, { mode: 0o600 })
  renameSync(tmp, file)
}

/** The check branch name a previous run persisted, or null if none is recorded. */
export function readCheckBranchState(): string | null {
  try {
    const name = readFileSync(checkBranchStateFilePath(), 'utf8').trim()
    return name || null
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return null
    throw error
  }
}

/** Clear the persisted check branch record — call once it's confirmed deleted (or absent). */
export function clearCheckBranchState(): void {
  rmSync(checkBranchStateFilePath(), { force: true })
}

/**
 * Hard safety guard. Destructive operations (deleting or renaming a branch) must only ever
 * target a disposable per-workspace `conductor/*` branch or a disposable `tmp/*` check branch —
 * never the parent (production). Throws otherwise.
 */
export function assertDisposableChildBranch(branchName: string, parentBranch: string): void {
  if (!branchName.startsWith(BRANCH_PREFIX) && !branchName.startsWith(CHECK_BRANCH_PREFIX)) {
    throw new Error(
      `Refusing destructive op on "${branchName}": not a "${BRANCH_PREFIX}" workspace branch ` +
        `or a "${CHECK_BRANCH_PREFIX}" check branch.`,
    )
  }
  if (parentBranch && branchName === parentBranch) {
    throw new Error(`Refusing destructive op on "${branchName}": it is the parent branch.`)
  }
}

/**
 * Stricter than assertDisposableChildBranch: a check-branch reference must be tmp/*-prefixed
 * specifically — never conductor/* (a workspace branch name), even though that alone would
 * satisfy the generic guard above. Without this, a corrupted or hand-edited
 * .conductor/db-branch-check record that happens to hold a conductor/*-prefixed value (e.g. this
 * workspace's own branch name) would be accepted as a "valid" check branch and deleted by
 * check-branch cleanup logic — which runs independently of, and potentially before, the actual
 * workspace branch's own guarded delete path.
 */
export function assertDisposableCheckBranch(branchName: string, parentBranch: string): void {
  if (!branchName.startsWith(CHECK_BRANCH_PREFIX)) {
    throw new Error(`Refusing destructive op on "${branchName}": not a "${CHECK_BRANCH_PREFIX}" check branch.`)
  }
  assertDisposableChildBranch(branchName, parentBranch)
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
 * Whether the workspace branch already exists. Uses `branches list` (which throws on any neonctl
 * failure) so a transient error is NOT silently misread as "branch absent" — that would
 * spuriously trigger a create that then fails "branch already exists".
 */
function branchExists(projectId: string, branchName: string): boolean {
  const parsed = JSON.parse(neon(['branches', 'list', '--project-id', projectId, '--output', 'json'])) as
    | Array<{ name?: string }>
    | { branches?: Array<{ name?: string }> }
  const branches = Array.isArray(parsed) ? parsed : parsed?.branches
  if (!Array.isArray(branches)) {
    // An unrecognized shape must THROW, not read as "absent" — misreading a live branch as
    // absent would make teardown skip it (leak) or provision try to re-create it.
    throw new Error('Unexpected `neonctl branches list --output json` output shape; cannot determine branch existence.')
  }
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
 * An error retrying can never fix (misconfiguration, an impossible precondition). withRetry
 * rethrows it immediately instead of burning backoff sleeps on it.
 */
export class FatalError extends Error {}

/**
 * Retry an operation (sync or async) with the exponential backoff above. Used around the Neon
 * API steps of provisioning (branch create/rename, connection-string fetch, execSql) — a branch
 * whose compute is still booting can transiently refuse all of them. A FatalError is never
 * retried. `sleep` is injectable for tests only.
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
      if (error instanceof FatalError || attempt >= attempts) throw error
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
  // The existence checks run INSIDE the retry (a transient list failure must not abort the
  // rename), but conditions retrying can never fix are FatalError — surfaced immediately.
  await withRetry('rename branch', () => {
    const fromExists = branchExists(projectId, from)
    const toExists = branchExists(projectId, to)
    if (fromExists && toExists) {
      throw new FatalError(
        `Cannot rename branch "${from}" → "${to}": both already exist in project ${projectId}. ` +
          `"${to}" is likely a leftover from an earlier workspace — delete or rename it in the ` +
          `Neon console (neonctl branches list --project-id ${projectId}), then retry.`,
      )
    }
    if (fromExists) {
      neon(['branches', 'rename', from, to, '--project-id', projectId])
      return
    }
    if (!toExists) {
      throw new FatalError(`neither "${from}" nor "${to}" exists in project ${projectId}`)
    }
    // from gone, to present: a previous attempt actually renamed — done.
  }, 3)
}

/**
 * Delete a workspace branch, retried (a just-created branch can transiently refuse deletion
 * while its create/compute operations are still running) and idempotent under retry (an attempt
 * that "failed" after actually deleting reads as done on the next attempt).
 */
async function deleteBranch(projectId: string, branchName: string, opts: { inherit?: boolean } = {}): Promise<void> {
  await withRetry('delete branch', () => {
    if (branchExists(projectId, branchName)) {
      neon(['branches', 'delete', branchName, '--project-id', projectId], opts)
    }
  }, 3)
}

/**
 * Retry a project-local CLI — a branch compute that's never been connected to (just created, or
 * just renamed) can take a while to finish booting. When `input` is given it is piped to the
 * command's stdin.
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
 * Replace the generated env file (.env.neondb) with one that points at this workspace's own Neon
 * branch. The file is entirely ours — the project's real .env is never touched. Any pre-existing
 * file or stale symlink is removed first so we always write a real, workspace-local file.
 */
function writeDatabaseUrl(uri: string): void {
  rmSync(ENV_FILE, { force: true })
  // Single quotes: dotenv-cli runs dotenv-expand on load, which would rewrite `$…` inside a
  // double-quoted value; single-quoted values are taken literally.
  writeFileSync(
    ENV_FILE,
    `# Generated by scripts/conductor-db.ts for this Conductor workspace. Do not commit.\n` +
      DB_ENV_VARS.map((name) => `${name}='${uri}'\n`).join(''),
    { mode: 0o600 },
  )
}

/**
 * Build the INSERT that seeds the workspace branch's Drizzle ledger with EXACTLY what's
 * genuinely applied on the parent — rows captured verbatim from readTrueDrizzleLedger, not
 * derived from local migration files. Returns null if the parent has nothing applied yet —
 * nothing to baseline; deployMigrations() creates everything for real. Idempotent (WHERE NOT
 * EXISTS on hash) as defense-in-depth, though in practice the workspace branch's ledger is
 * always empty at this point (freshly created — see provision()).
 */
export function buildDrizzleLedgerBaselineSql(rows: Array<{ hash: string; created_at: string | number }>): string | null {
  if (rows.length === 0) return null
  const values = rows
    .map(({ hash, created_at }) => {
      if (!/^[0-9a-f]{64}$/.test(hash)) {
        throw new FatalError(`Migration ledger row has a non-hex hash (${JSON.stringify(hash)}) — refusing to splice it into SQL.`)
      }
      const createdAt = typeof created_at === 'string' ? Number(created_at) : created_at
      if (!Number.isSafeInteger(createdAt) || createdAt < 0) {
        throw new FatalError(`Migration ledger row has a non-integer created_at (${JSON.stringify(created_at)}) — refusing to splice it into SQL.`)
      }
      return `('${hash}', ${createdAt})`
    })
    .join(',\n')
  const qualified = `"${DRIZZLE_MIGRATIONS_SCHEMA}"."${DRIZZLE_MIGRATIONS_TABLE}"`
  return (
    `CREATE SCHEMA IF NOT EXISTS "${DRIZZLE_MIGRATIONS_SCHEMA}";\n` +
    `CREATE TABLE IF NOT EXISTS ${qualified} (id SERIAL PRIMARY KEY, hash text NOT NULL, created_at bigint);\n` +
    `INSERT INTO ${qualified} (hash, created_at)\n` +
    'SELECT m.hash, m.created_at\n' +
    `FROM (VALUES\n${values}\n) AS m(hash, created_at)\n` +
    `WHERE NOT EXISTS (SELECT 1 FROM ${qualified} e WHERE e.hash = m.hash);`
  )
}

/**
 * Same idea for Prisma: seeds `_prisma_migrations` with the checksum + migration_name rows
 * readTruePrismaLedger captured from the parent's true ledger, not recomputed from local
 * migration.sql files. Returns null if the parent has nothing genuinely applied yet. Idempotent
 * (WHERE NOT EXISTS on migration_name), same reasoning as the Drizzle variant.
 */
export function buildPrismaLedgerBaselineSql(rows: Array<{ checksum: string; migration_name: string }>): string | null {
  if (rows.length === 0) return null
  const values = rows
    .map(({ checksum, migration_name }) => {
      if (!/^[0-9a-f]{64}$/.test(checksum)) {
        throw new FatalError(`Migration ledger row has a non-hex checksum (${JSON.stringify(checksum)}) — refusing to splice it into SQL.`)
      }
      const safeName = migration_name.replace(/'/g, "''") // double single quotes for a valid SQL string literal
      return `('${checksum}', '${safeName}')`
    })
    .join(',\n')
  return (
    'INSERT INTO "_prisma_migrations" ' +
    '(id, checksum, finished_at, migration_name, logs, rolled_back_at, started_at, applied_steps_count)\n' +
    'SELECT gen_random_uuid()::text, m.checksum, now(), m.migration_name, NULL, NULL, now(), 1\n' +
    `FROM (VALUES\n${values}\n) AS m(checksum, migration_name)\n` +
    'WHERE NOT EXISTS (SELECT 1 FROM "_prisma_migrations" e WHERE e.migration_name = m.migration_name);'
  )
}

/** Apply any migrations pulled into this workspace since its branch was created. */
function deployMigrations(uri: string): void {
  if (ORM === 'prisma') {
    runWithRetry('prisma', ['migrate', 'deploy'], childDbEnv(uri))
  } else {
    runWithRetry('drizzle-kit', ['migrate'], childDbEnv(uri))
  }
}

/**
 * Learn the parent's TRUE applied-migration set via a disposable full-data clone, then seed the
 * workspace branch's (currently empty) ledger with exactly that — never with an assumption
 * derived from local migration files. This is what actually fixes "the parent hasn't run every
 * migration yet" drift: a schema-only branch's ledger starts empty regardless of the parent's
 * real state, so baselining from local files would falsely mark migrations applied that the
 * parent never ran, and the ORM would silently no-op instead of creating the missing tables. The
 * check branch is always fresh: delete-if-present before creating, never reused, since a leaked
 * one from an interrupted run could hold a stale snapshot of the parent's true state.
 */
async function seedTrueBaseline(projectId: string, parent: string, uri: string): Promise<void> {
  // Handle a leftover from a previous, incomplete run first. Prefer the PERSISTED name over the
  // freshly-derived one: it's written below before the branch is created, specifically so a
  // leaked branch is still findable even if the workspace was renamed since (checkBranchName()
  // alone would derive a different name and miss it — see writeCheckBranchState()'s docstring).
  const previousCheckName = readCheckBranchState()
  if (previousCheckName) {
    // A corrupted/hand-edited record must not brick provisioning — it gets overwritten by
    // writeCheckBranchState() below regardless. Matches provision()'s identical handling of a
    // corrupted WORKSPACE-branch record.
    let previousUsable = true
    try {
      assertDisposableCheckBranch(previousCheckName, parent)
    } catch (error) {
      previousUsable = false
      console.warn(
        `[conductor-db] ignoring unusable ${checkBranchStateFilePath()} record "${previousCheckName}" ` +
          `(${error instanceof Error ? error.message : error}) — it will be overwritten.`,
      )
    }
    if (previousUsable) {
      // No try/finally here deliberately: only clear the record after a CONFIRMED delete (or
      // confirmed absence) below. If branchExists()/deleteBranch() throws, clearCheckBranchState()
      // is never reached and the record survives — so a still-live leaked branch never loses its
      // only tracking record just because this attempt to clean it up failed.
      if (await withRetry('check for stale check branch', () => branchExists(projectId, previousCheckName), 3)) {
        console.log(`[neon] deleting stale check branch ${previousCheckName}…`)
        await deleteBranch(projectId, previousCheckName)
      }
      clearCheckBranchState()
    }
  }

  const checkName = checkBranchName()
  writeCheckBranchState(checkName) // before creating — see writeCheckBranchState()'s docstring
  console.log(`[neon] creating check branch ${checkName} off ${parent} (full data, disposable)…`)
  await withRetry(
    'create check branch',
    () => {
      if (!branchExists(projectId, checkName)) {
        neon(['branches', 'create', '--project-id', projectId, '--name', checkName, '--parent', parent, '--output', 'json'])
      }
    },
    3,
  )

  // Tracks whether the try block itself failed, so the finally block below can tell "a cleanup
  // failure on top of a real error" (log it, let the original error through) apart from "cleanup
  // is the ONLY failure" (this file's policy is to fail loudly on a branch-delete failure, same
  // as everywhere else — swallowing it unconditionally would just trade the original masking bug
  // for silently leaving a leak unreported).
  let failed = false
  try {
    const checkUri = await withRetry('fetch check branch connection string', () => getConnectionString(projectId, checkName))
    if (ORM === 'prisma') {
      const trueRows = await withRetry('read true migration ledger', () => readTruePrismaLedger(checkUri), 6)
      const sql = buildPrismaLedgerBaselineSql(trueRows)
      if (sql) {
        await withRetry('seed true baseline', () => execSql(uri, sql), 6)
      } else {
        console.log('[prisma] parent has no applied migrations yet — nothing to baseline.')
      }
    } else {
      const trueRows = await withRetry('read true migration ledger', () => readTrueDrizzleLedger(checkUri), 6)
      const sql = buildDrizzleLedgerBaselineSql(trueRows)
      if (sql) {
        await withRetry('seed true baseline', () => execSql(uri, sql), 6)
      } else {
        console.log('[drizzle] parent has no applied migrations yet — nothing to baseline.')
      }
    }
  } catch (error) {
    failed = true
    throw error
  } finally {
    try {
      assertDisposableCheckBranch(checkName, parent)
      await deleteBranch(projectId, checkName)
      clearCheckBranchState()
    } catch (cleanupError) {
      if (failed) {
        // A real error is already propagating — don't let this cleanup failure replace it (a
        // throw in `finally` would). The persisted record (still in place) means teardown()'s
        // own leaked-check-branch sweep will find and remove it on a later archive.
        console.error(
          `[conductor-db] WARNING: could not delete check branch ${checkName} while handling ` +
            `another error; it may be orphaned (${cleanupError instanceof Error ? cleanupError.message : cleanupError}). ` +
            `teardown()'s sweep will catch it on a later archive.`,
        )
      } else {
        // Nothing else went wrong — this cleanup failure IS the failure. Fail loudly, matching
        // this file's policy elsewhere, instead of silently leaving a leak unreported.
        throw cleanupError
      }
    }
  }
}

/**
 * Seed the workspace with test fixtures — the last step of setup, after the true baseline and
 * migrate-deploy above.
 *
 * ── ADAPT THIS to your project's seed ──────────────────────────────────────────
 *  • No seed?  Delete this function and its call in provision().
 *  • Plain seed, no safety guard?  Replace the body with:
 *      Prisma:  runWithRetry('prisma', ['db', 'seed'], childDbEnv(uri), 2)
 *      Drizzle: runWithRetry('tsx', [SEED_SCRIPT], childDbEnv(uri), 2)
 *  • Seed that REFUSES non-local DBs (recommended — stops accidental prod seeding)?
 *      Authorize it for THIS branch only. The example below matches a seed that allows a remote
 *      DB when E2E_EXPECTED_DATABASE_URL === DATABASE_URL, gated on a password.
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
  runWithRetry('tsx', [SEED_SCRIPT], { ...childDbEnv(uri), E2E_EXPECTED_DATABASE_URL: uri }, 2)
}

async function provision(): Promise<void> {
  const projectId = requireEnv('NEON_PROJECT_ID')
  requireEnv('NEON_API_KEY') // consumed by neonctl from the environment
  const parent = requireEnv('NEON_PARENT_BRANCH')
  const branchName = workspaceBranchName()
  assertDisposableChildBranch(branchName, parent)

  // Every run is a full rebuild — delete whatever's currently recorded (if it still exists),
  // regardless of name or phase. This also handles a renamed workspace for free: the OLD
  // recorded name gets deleted here, and a fresh branch gets created below under the CURRENT
  // derived name — no rename API call, no orphan. Any data written into the workspace branch
  // since it was created is discarded by design (see the header comment).
  const recorded = readBranchState()
  if (recorded) {
    let recordedUsable = true
    try {
      assertDisposableChildBranch(recorded, parent)
    } catch (error) {
      // A corrupted/hand-edited record must not brick provisioning with a confusing "refusing
      // destructive op" — it will simply be overwritten by the fresh create below.
      recordedUsable = false
      console.warn(
        `[conductor-db] ignoring unusable ${stateFilePath()} record "${recorded}" ` +
          `(${error instanceof Error ? error.message : error}) — it will be overwritten.`,
      )
    }
    if (recordedUsable && (await withRetry('check recorded branch', () => branchExists(projectId, recorded), 3))) {
      console.log(`[neon] deleting recorded branch ${recorded} to rebuild from scratch…`)
      await deleteBranch(projectId, recorded)
    }
  }

  writeBranchState(branchName, 'pending') // sync()'s hard gate needs this window covered
  console.log(`[neon] creating schema-only branch ${branchName} off ${parent}…`)
  // Idempotent under retry: if a create "fails" after actually creating (e.g. a timeout on the
  // response), the next attempt sees the branch and doesn't re-create it.
  await withRetry(
    'create branch',
    () => {
      if (!branchExists(projectId, branchName)) {
        neon(['branches', 'create', '--project-id', projectId, '--name', branchName, '--parent', parent, '--schema-only', '--output', 'json'])
      }
    },
    3,
  )

  // Everything after a successful create is wrapped so that ANY failure (connection-string
  // fetch, writing the env file, true-baseline, migrate, seed) triggers the cleanup below —
  // otherwise a create followed by a transient error would leak the branch.
  try {
    const uri = await withRetry('fetch connection string', () => getConnectionString(projectId, branchName))
    writeDatabaseUrl(uri)
    console.log(`[conductor-db] wrote DATABASE_URL for ${branchName} → ${ENV_FILE}`)

    console.log(`[${ORM}] learning the parent's true applied-migration state…`)
    await seedTrueBaseline(projectId, parent, uri)

    console.log(`[${ORM}] applying any migrations beyond the baseline…`)
    deployMigrations(uri)

    seedWorkspace(uri)
    writeBranchState(branchName, 'ready')
  } catch (error) {
    console.error('[conductor-db] setup failed — deleting the branch so the next attempt starts clean.')
    try {
      await deleteBranch(projectId, branchName)
      // Env file first, state record last — a crash between the two leaves the record
      // (harmless, self-corrects on the next provision), rather than an env file with no
      // record, which would slip past sync's gates and boot the app against a dead endpoint.
      rmSync(ENV_FILE, { force: true })
      rmSync(stateFilePath(), { force: true })
    } catch {
      console.error(
        `[conductor-db] WARNING: could not delete branch ${branchName}; ` +
          `keeping ${stateFilePath()} so the next provision/teardown can find it.`,
      )
    }
    throw error
  }

  console.log('✅ [conductor-db] workspace database ready.')
}

async function teardown(): Promise<void> {
  // Missing Neon credentials: if there is also no trace of a provisioned branch (no state file,
  // no generated env file, no check-branch record), the workspace never got a database — archive
  // must not error. But with a recorded/possible branch, failing loudly is the point: skipping
  // here is exactly how branches used to leak past archive.
  if (!process.env.NEON_PROJECT_ID || !process.env.NEON_API_KEY) {
    if (!readBranchState() && !provisionedEnvTraceExists() && !readCheckBranchState()) {
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

  // Best-effort: the check branch seedTrueBaseline() creates (a disposable full-data clone of
  // the parent, used to learn its true migration state) is normally cleaned up by that same
  // function. If provision() was killed between creating it and its own cleanup, it survives
  // until noticed — sweep for it here too so archiving still catches it. Prefer the PERSISTED
  // name (survives a workspace rename since) over the freshly-derived one, falling back to the
  // derived name only if nothing was ever persisted (e.g. no incomplete run). This must never
  // block cleanup of the actual workspace branch below: an unusable CONDUCTOR_WORKSPACE_NAME
  // just means there's nothing derivable to check, not a reason to fail.
  try {
    const checkName = readCheckBranchState() ?? checkBranchName()
    let checkNameUsable = true
    try {
      assertDisposableCheckBranch(checkName, parent)
    } catch (error) {
      // A corrupted/hand-edited record isn't a real branch reference worth preserving (a
      // genuinely-written one is always tmp/*-prefixed) — clear it so this warning doesn't
      // repeat on every future archive with no way to self-heal.
      checkNameUsable = false
      console.warn(
        `[conductor-db] ignoring unusable ${checkBranchStateFilePath()} record "${checkName}" ` +
          `(${error instanceof Error ? error.message : error}) — clearing it.`,
      )
      clearCheckBranchState()
    }
    if (checkNameUsable) {
      if (await withRetry('check for leaked check branch', () => branchExists(projectId, checkName), 3)) {
        console.log(`[neon] deleting leaked check branch ${checkName}…`)
        await deleteBranch(projectId, checkName, { inherit: true })
      }
      // Only clear after a CONFIRMED delete (or confirmed absence) — if branchExists()/
      // deleteBranch() above throws, this is never reached and the record survives so a
      // still-live leaked branch isn't forgotten just because this attempt failed.
      clearCheckBranchState()
    }
  } catch (error) {
    console.warn(
      `[conductor-db] WARNING: could not check for/delete a leaked check branch: ` +
        `${error instanceof Error ? error.message : error}`,
    )
  }

  // Prefer the name provision() actually used — CONDUCTOR_WORKSPACE_NAME may have changed since
  // (the workspace was renamed), which would otherwise re-derive a different slug and miss the
  // real branch. The derived names (current scheme AND the pre-hash-suffix legacy scheme) are
  // kept as fallbacks for workspaces provisioned before the state file existed, and for a record
  // left stale by a crash between rename and re-record.
  const recorded = readBranchState()
  let derived: string | null = null
  let legacy: string | null = null
  try {
    derived = workspaceBranchName()
    legacy = legacyWorkspaceBranchName()
  } catch {
    // CONDUCTOR_WORKSPACE_NAME unset/unusable — proceed with the recorded name alone.
  }
  // A corrupted record (or one naming the parent) must not abort teardown outright — skip it
  // with a warning and let the other candidates be tried; the guard still makes it undeletable.
  let recordUnusable = false
  const candidates = [...new Set([recorded, derived, legacy])]
    .filter((name): name is string => Boolean(name))
    .filter((name) => {
      try {
        assertDisposableChildBranch(name, parent)
        return true
      } catch (error) {
        if (name === recorded) recordUnusable = true
        console.warn(`[conductor-db] ignoring candidate "${name}": ${error instanceof Error ? error.message : error}`)
        return false
      }
    })
  if (candidates.length === 0) {
    // No record AND no generated env file means provisioning never got anywhere (e.g. the
    // workspace name never yielded a usable slug) — there is no branch to leak; don't block
    // archive. With either trace present, a branch may exist somewhere: fail loudly.
    if (!recorded && !provisionedEnvTraceExists()) {
      console.warn('[conductor-db] no branch was ever recorded or provisioned for this workspace — nothing to clean.')
      return
    }
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
    if (recordUnusable) {
      // The record existed but was unusable, and nothing matches the derived names — the real
      // branch may live under a name we can no longer see. Cleaning up here would destroy the
      // only evidence a branch was provisioned; fail loudly instead.
      throw new Error(
        `The ${stateFilePath()} record was unusable and no branch matches this workspace's ` +
          `derived names (checked: ${candidates.join(', ')}). Find and delete the branch ` +
          `manually (neonctl branches list --project-id ${projectId}), then remove ` +
          `${stateFilePath()} and re-run archive.`,
      )
    }
    if (!recorded && provisionedEnvTraceExists()) {
      // A generated env file proves a branch was provisioned, but nothing was recorded and no
      // branch matches this workspace's current or legacy names — classic pre-state-file
      // workspace renamed before upgrading. Exiting 0 here would silently leak its branch.
      throw new Error(
        'A generated env file shows this workspace was provisioned, but no branch matches its ' +
          `current or legacy names (checked: ${candidates.join(', ')}) — it was likely renamed ` +
          `before upgrading to this script version. Find and delete the branch manually ` +
          `(neonctl branches list --project-id ${projectId}), then remove the generated env ` +
          'file(s) and re-run archive.',
      )
    }
    console.log(`[conductor-db] no workspace branch found (checked: ${candidates.join(', ')}) — nothing to delete.`)
    removeGeneratedEnvFiles()
    rmSync(stateFilePath(), { force: true })
    return
  }

  console.log(`[neon] deleting branch ${target}…`)
  await deleteBranch(projectId, target, { inherit: true })
  // Env files first (leaving one would let sync()'s gates pass and boot the dev server against
  // the deleted branch's dead endpoint), the state record LAST — a crash between the two leaves
  // the harmless record, and the next teardown finds the branch already absent and cleans up.
  removeGeneratedEnvFiles()
  rmSync(stateFilePath(), { force: true })
  console.log('✅ [conductor-db] deleted the workspace database branch.')
}

/**
 * Runs before every dev-server start. Hard gates throw (blocking the dev server, deliberately);
 * the rename catch-up is best-effort:
 *
 * 1. HARD GATE (throws): refuse to start if .env.neondb is missing. `dotenv -e` silently
 *    proceeds when the file doesn't exist, so without this check a workspace whose provisioning
 *    failed would boot against whatever DATABASE_URL leaks in from the ambient env — the exact
 *    shared-database collision this whole setup exists to prevent.
 * 2. HARD GATE (throws): refuse to start a workspace whose setup is still marked 'pending' — the
 *    branch is mid-rebuild; provision must recover it first.
 * 3. Rename catch-up (best-effort, never throws): Conductor has no rename event, so this is
 *    where the Neon branch's name is brought back in line with the workspace. Any failure here
 *    only leaves the Neon console's branch name cosmetically stale.
 * 4. HARD GATE (throws on definitive absence): the recorded branch must still exist in Neon —
 *    otherwise .env.neondb points at a dead endpoint and the app would boot into opaque
 *    connection errors. A transient verification failure only warns.
 */
async function sync(): Promise<void> {
  if (!existsSync(ENV_FILE)) {
    throw new Error(
      `${ENV_FILE} not found — this workspace's database was never provisioned, provisioning ` +
        `failed, or the workspace predates this script version (which wrote .env instead). ` +
        `In every case the fix is the same: re-run workspace setup (scripts/conductor-db.ts ` +
        `provision — this rebuilds the workspace branch from scratch, discarding any data in ` +
        `it) before starting the dev server. Starting without ${ENV_FILE} would silently use a ` +
        `shared/ambient DATABASE_URL.`,
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
    await renameCatchUp(projectId)
  } catch (error) {
    console.warn(`[conductor-db] WARNING: branch rename sync failed: ${error instanceof Error ? error.message : error}`)
  }

  // HARD GATE 4: the branch the env file points at must still exist — a teardown that died
  // between delete and file cleanup (or a console-side delete) leaves a valid-looking
  // .env.neondb aimed at a dead endpoint, and the dev server would boot into opaque connection
  // errors. Definitive absence fails the run; a transient check failure does not. If no record
  // could be established at all (renameCatchUp found no live branch either), the env file is
  // unaccounted for — fail rather than boot into the same dead endpoint.
  const finalRecord = readBranchState()
  if (!finalRecord) {
    throw new FatalError(
      `${ENV_FILE} exists but no branch is recorded for this workspace and none was found ` +
        `under its derived names — the branch was likely deleted by an interrupted archive. ` +
        `Re-run workspace setup (scripts/conductor-db.ts provision) to recreate it, or delete ` +
        `${ENV_FILE} if the workspace is being retired.`,
    )
  }
  try {
    if (!(await withRetry('verify branch exists', () => branchExists(projectId, finalRecord), 2))) {
      throw new FatalError(
        `Recorded branch ${finalRecord} no longer exists in Neon — it was deleted out-of-band ` +
          `(or a previous archive was interrupted). Re-run workspace setup ` +
          `(scripts/conductor-db.ts provision) to recreate it before starting the dev server.`,
      )
    }
  } catch (error) {
    if (error instanceof FatalError) throw error
    console.warn(
      `[conductor-db] WARNING: could not verify branch ${finalRecord} still exists: ` +
        `${error instanceof Error ? error.message : error}`,
    )
  }
}

/** sync()'s best-effort rename catch-up — see sync() for the failure rules. */
async function renameCatchUp(projectId: string): Promise<void> {
  const recorded = readBranchState()
  const current = workspaceBranchName()
  if (!recorded) {
    // Workspace provisioned before the state file existed: record the name now, while the
    // derived slug still matches the live branch, so a later rename can't orphan it. Long names
    // may live under the OLD flat-truncation scheme — check that name too.
    const live = [current, legacyWorkspaceBranchName()]
      .filter((name): name is string => Boolean(name))
      .find((name) => branchExists(projectId, name))
    if (live) {
      assertDisposableChildBranch(live, process.env.NEON_PARENT_BRANCH ?? '')
      writeBranchState(live)
      console.log(`[conductor-db] recorded existing branch ${live} → ${stateFilePath()}`)
    }
    return
  }
  if (recorded === current) return // no rename since the last check

  assertDisposableChildBranch(recorded, process.env.NEON_PARENT_BRANCH ?? '')
  assertDisposableChildBranch(current, process.env.NEON_PARENT_BRANCH ?? '')

  // Self-heal a record left stale by a crash between a rename and its re-record: if the recorded
  // branch is gone but one under the current name exists, just re-record.
  if (!branchExists(projectId, recorded) && branchExists(projectId, current)) {
    writeBranchState(current)
    console.log(`[conductor-db] record was stale — re-recorded live branch ${current}.`)
    return
  }

  console.log(`[neon] workspace renamed — renaming branch ${recorded} → ${current}…`)
  await renameBranch(projectId, recorded, current)
  writeBranchState(current)
  console.log('✅ [conductor-db] branch renamed to match the workspace.')
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
