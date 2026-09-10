// scripts/neondb-branch.ts
//
// Per-workspace ISOLATED Neon database branch — for any git repo, with no orchestration tool
// required at this layer. Each workspace gets its own ORDINARY, FULL-DATA child of the configured
// production branch, pinned at a captured parent WAL LSN, whose application rows are then purged
// in a single transaction before the connection URLs are published.
//
// WHY AN ORDINARY CHILD, NOT A SCHEMA-ONLY BRANCH
// Neon schema-only branches are ROOT branches: they have no parent, and `--parent` only names the
// schema donor. Every schema-only workspace branch therefore burns one of the project's root-branch
// slots (3 on Free, 5 on Launch, 25 on Scale) and a handful of parallel workspaces is enough to hit
// ROOT_BRANCHES_LIMIT_EXCEEDED and block all provisioning. An ordinary child consumes no root slot,
// and — because it inherits the parent's rows — it inherits the ORM's migration ledger as ordinary
// row data, which removes the whole reason the previous design needed a second, disposable `tmp/*`
// full-data clone to learn the parent's true applied-migration state.
//
// PRIVACY: NOT A BOUNDARY. An ordinary child initially CONTAINS production data, and Neon's history
// window can retain that data in the branch's own snapshots even after the purge below. This design
// trades the schema-only privacy property for root-slot correctness. Do NOT treat a workspace branch
// as a redacted environment, do not "reset from parent" or restore it from production, and never
// start the app against it before provisioning completes — the purge is the only thing that removes
// production rows, and `load-env.cjs` refuses to boot until state reaches `ready`.
//
// LIFECYCLE STATE lives in .neondb/state.json (gitignored, credential-free, written atomically):
//   { "branchId": "br-…", "branchName": "workspace/…", "projectId": "…", "status": "ready" }
// branchId + projectId are IDENTITY; branchName is a display value only. Nothing is ever looked up,
// renamed or deleted by name — so a git branch change or a workspace rename never switches which
// database this workspace owns, and a name freed by one workspace and reused by another can never
// be mistaken for "our branch, renamed".
//
//   provision → `tsx scripts/neondb-branch.ts provision`   full rebuild; DISCARDS workspace data
//   sync      → `tsx scripts/neondb-branch.ts sync`        chained in front of the dev server
//   teardown  → `tsx scripts/neondb-branch.ts teardown`
//
// Requires (set in .env.neondb, your shell, or your orchestrator's env config — see SKILL.md):
//   NEON_API_KEY       – Neon API key; required by provision, sync and teardown
//   NEON_PROJECT_ID    – Neon project to branch within; same
//   NEON_PARENT_BRANCH – REQUIRED by provision; the production branch NAME or `br-…` id
//   NEON_DATABASE_NAME / NEON_ROLE_NAME – optional; only needed when the branch hosts more than
//                        one database and the first one is not the app's
//   (seed credentials) – whatever your seed needs; provision-only — see seedWorkspace() below
//
// SAFETY: every destructive control-plane call goes by branch id, and only after the branch has been
// verified disposable (not default, not primary, not protected, not the parent). The one connection
// this script opens to the parent is a single read-only `SELECT pg_current_wal_lsn()`.

import { execFileSync, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { closeSync, mkdirSync, openSync, readdirSync, readFileSync, renameSync, rmdirSync, rmSync, writeFileSync, writeSync } from 'node:fs'
import { basename, join } from 'node:path'
import { config as dotenvConfig } from 'dotenv'

// ── PORTING KNOBS ────────────────────────────────────────────────────────────
// Which ORM manages migrations. Switches the migration-ledger table that the purge preserves and
// the migrate-deploy command.
const ORM: 'prisma' | 'drizzle' = 'prisma'

// How to run a project-local CLI (prisma/drizzle-kit/tsx). Match your package manager:
//   pnpm → ['pnpm', 'exec']   npm → ['npx']   yarn → ['yarn']
const PM_EXEC = ['pnpm', 'exec']

// DATABASE_URL lands in its OWN file, not .env, so the project's real .env is never clobbered.
// NOTHING auto-loads .env.neondb — `load-env.cjs` loads it explicitly WITH OVERRIDE (an ambient
// DATABASE_URL from a shared .env would otherwise silently win) and this script passes the DB vars
// to every child process itself.
const ENV_FILE = '.env.neondb'

// EVERY env var that must point at the per-workspace branch. The project's real .env still gets
// auto-loaded by the ORM CLI/dev server, so any DB URL var it defines that is NOT listed here leaks
// the shared database into this workspace. If schema.prisma uses `directUrl = env("DIRECT_URL")` or
// `shadowDatabaseUrl = env(…)`, add those names.
const DB_ENV_VARS = ['DATABASE_URL']

const BRANCH_PREFIX = 'workspace/' // workspace-branch namespace
const MAX_SLUG = 48 // Neon-safe branch-name length budget (excluding the prefix)
const SEED_SCRIPT = 'prisma/seed.ts' // project's seed entrypoint (see seedWorkspace)

// Schemas whose BASE TABLES are application data the purge is allowed to empty. A base table in any
// other non-system schema that is not extension-owned makes provisioning FAIL CLOSED rather than
// publish a database this script cannot fully account for.
const APP_SCHEMAS = ['public']

// Tables the purge must never touch, beyond the migration ledger and extension-owned tables (which
// are detected automatically). Qualify them: 'public.some_reference_table'.
const PRESERVED_TABLES: string[] = []

// ── Drizzle-only knob (used when ORM === 'drizzle') ──────────────────────────
// Where drizzle records applied migrations. Defaults match drizzle-kit; override only if you set a
// custom migrationsSchema/migrationsTable in drizzle.config. (Prisma's `_prisma_migrations` table
// name and schema are fixed by Prisma itself — nothing to knob there.)
const DRIZZLE_MIGRATIONS_SCHEMA = 'drizzle'
const DRIZZLE_MIGRATIONS_TABLE = '__drizzle_migrations'

// A brand-new Neon compute can take a while to accept its FIRST connection. These attempts back off
// 2s, 4s, 8s, … so the total budget is minutes, not seconds. If you route any provisioning SQL
// through PrismaClient rather than the raw driver below, ALSO pass an explicit transaction maxWait:
// `prisma.$transaction(fn, { maxWait: 30_000, timeout: 60_000 })`. Prisma's default maxWait is TWO
// SECONDS, which a cold compute loses every time.
export const FIRST_CONNECTION_ATTEMPTS = 8

// If any provisioning or seeding SQL is routed through PrismaClient rather than the raw driver
// below, pass this explicitly: `prisma.$transaction(fn, { maxWait: PRISMA_TX_MAXWAIT_MS, timeout:
// 60_000 })`. Prisma's default maxWait is TWO SECONDS, which a cold Neon compute loses every time —
// the resulting "Unable to start a transaction in the given time" is the single most common
// first-run failure this skill has seen.
export const PRISMA_TX_MAXWAIT_MS = 30_000

/**
 * A single open connection to one Neon branch. `query` returns rows for a SELECT and an empty array
 * otherwise. It MUST be one dedicated session, not a pool: the purge below issues BEGIN, TRUNCATE
 * and COMMIT as separate calls, and a pool that hands each of them a different connection would
 * silently run the TRUNCATE outside the transaction.
 */
export interface SqlClient {
  query<T = Record<string, unknown>>(sql: string, params?: unknown[]): Promise<T[]>
}

/**
 * Open a connection to `uri`. Wire this to the Postgres driver the project ALREADY depends on; do
 * not add a new one. Pick the matching example, move its import to the top of the file, and drop
 * this body's throw. Note the generous connect timeout in each — a cold compute is the normal case
 * here, not the exception — and that every example opens ONE session, never a pool.
 *
 *   // pg (node-postgres):
 *   //   import { Client } from 'pg'
 *   //   const connect: SqlConnect = async (uri) => {
 *   //     const c = new Client({ connectionString: uri, connectionTimeoutMillis: 30_000 })
 *   //     await c.connect()
 *   //     return { client: { query: async (sql, params) => (await c.query(sql, params)).rows }, end: () => c.end() }
 *   //   }
 *
 *   // postgres (postgres-js) — `max: 1` keeps BEGIN/TRUNCATE/COMMIT on one connection:
 *   //   import postgres from 'postgres'
 *   //   const connect: SqlConnect = async (uri) => {
 *   //     const sqlc = postgres(uri, { connect_timeout: 30, max: 1 })
 *   //     return { client: { query: async (sql, params) => (await sqlc.unsafe(sql, params as never[])) as never }, end: () => sqlc.end() }
 *   //   }
 *
 *   // @neondatabase/serverless (Client, NOT Pool — a Pool would spread the transaction):
 *   //   import { Client } from '@neondatabase/serverless'
 *   //   const connect: SqlConnect = async (uri) => {
 *   //     const c = new Client({ connectionString: uri, connectionTimeoutMillis: 30_000 })
 *   //     await c.connect()
 *   //     return { client: { query: async (sql, params) => (await c.query(sql, params)).rows }, end: () => c.end() }
 *   //   }
 */
export type SqlConnect = (uri: string) => Promise<{ client: SqlClient; end: () => Promise<void> }>

const connect: SqlConnect = async (_uri) => {
  // FatalError so withRetry surfaces this misconfiguration immediately instead of burning minutes
  // of backoff on an error no retry can fix.
  throw new FatalError(
    'connect() is not configured. Wire it to the project\'s Postgres driver (pg / postgres / ' +
      '@neondatabase/serverless) — see the examples in the PORTING KNOBS block. Required: purging ' +
      'the inherited production rows needs real query results, not just a migration CLI.',
  )
}

/**
 * Every base table this checkout knows about, as `schema.table`. Anything else found in APP_SCHEMAS
 * that is neither the migration ledger nor extension-owned makes provisioning fail closed.
 *
 * ── ADAPT THIS to your project ────────────────────────────────────────────────
 *  • Prisma — derive it from the generated client's DMMF so it can never drift from the schema:
 *      import { Prisma } from '@prisma/client'
 *      const knownApplicationTables = async () => prismaKnownTables(Prisma.dmmf.datamodel)
 *    `prismaKnownTables` (exported below) includes implicit many-to-many join tables, which the
 *    model list alone omits — miss those and every project using an implicit m2m relation fails
 *    closed on its own join table.
 *  • Drizzle — derive it from the schema module:
 *      import * as schema from './src/db/schema'
 *      import { getTableConfig, isPgTable } from 'drizzle-orm/pg-core'
 *      const knownApplicationTables = async () =>
 *        Object.values(schema).filter(isPgTable).map((t) => {
 *          const c = getTableConfig(t)
 *          return `${c.schema ?? 'public'}.${c.name}`
 *        })
 */
const knownApplicationTables: () => Promise<string[]> = async () => {
  throw new FatalError(
    'knownApplicationTables() is not configured. Point it at your ORM\'s model list — see the ' +
      'example in the PORTING KNOBS block. The purge refuses to run without a known-table set, ' +
      'because it cannot otherwise tell an application table from something it must not empty.',
  )
}

/**
 * The table names Prisma actually creates for a datamodel: one per model (honouring `@@map`) plus
 * one per IMPLICIT many-to-many relation, which Prisma materializes as `_<RelationName>` and does
 * not list as a model. Pure, so it is unit-tested directly.
 */
export function prismaKnownTables(datamodel: {
  models: Array<{ name: string; dbName?: string | null; schema?: string | null; fields: Array<{ isList?: boolean; relationName?: string; kind?: string }> }>
}): string[] {
  const tables = new Set<string>()
  const listRelationCounts = new Map<string, number>()
  for (const model of datamodel.models) {
    const schema = model.schema || APP_SCHEMAS[0]
    tables.add(`${schema}.${model.dbName || model.name}`)
    for (const field of model.fields) {
      if (field.kind === 'object' && field.relationName && field.isList) {
        listRelationCounts.set(field.relationName, (listRelationCounts.get(field.relationName) ?? 0) + 1)
      }
    }
  }
  // A relation whose BOTH sides are lists is many-to-many. When it is implicit, Prisma owns a join
  // table named `_<relationName>`; when it is explicit, that join table is already a model above and
  // the extra name is simply absent from the database — harmless, since known-but-absent tables are
  // expected (the parent can legitimately be behind this checkout).
  for (const [relationName, sides] of listRelationCounts) {
    if (sides >= 2) tables.add(`${APP_SCHEMAS[0]}._${relationName}`)
  }
  return [...tables]
}
// ─────────────────────────────────────────────────────────────────────────────

/** The qualified migration-ledger table the purge always preserves. */
export function migrationLedgerTable(): string {
  return ORM === 'prisma' ? 'public._prisma_migrations' : `${DRIZZLE_MIGRATIONS_SCHEMA}.${DRIZZLE_MIGRATIONS_TABLE}`
}

// ── Errors ───────────────────────────────────────────────────────────────────

/** An error retrying can never fix (misconfiguration, an impossible precondition). */
export class FatalError extends Error {}

/**
 * A Neon control-plane call that failed. `ambiguous` means the request may or may not have been
 * applied — a reset connection, a response timeout, a 5xx. For a POST that creates a branch, an
 * ambiguous failure must NEVER be retried and must never be resolved by looking the name up: that
 * is exactly how a branch belonging to someone else gets adopted or deleted.
 */
export class NeonRequestError extends Error {
  constructor(
    message: string,
    readonly status: number | null,
    readonly ambiguous: boolean,
  ) {
    super(message)
  }

  /**
   * Whether re-sending could plausibly succeed. A 4xx other than 429 is Neon rejecting the request
   * outright — ROOT_BRANCHES_LIMIT_EXCEEDED arrives this way — and retrying it just burns backoff on
   * a verdict that will not change. 429 IS retryable and is NOT ambiguous: a rate-limited request
   * was refused before it was processed, so it cannot have been half-applied.
   */
  get retryable(): boolean {
    if (this.status === null) return true // a network-layer failure; ambiguity is tracked separately
    return this.status >= 500 || this.status === 429
  }
}

/** Creation intent that could not be resolved. Leaves `.neondb/state.json` at `creating`. */
export class AmbiguousCreateError extends Error {}

// ── State file ───────────────────────────────────────────────────────────────

export type LifecycleStatus = 'creating' | 'pending' | 'ready' | 'deleting'
const LIFECYCLE_STATUSES: LifecycleStatus[] = ['creating', 'pending', 'ready', 'deleting']

export interface WorkspaceState {
  branchId: string | null
  branchName: string
  projectId: string
  status: LifecycleStatus
}

/** The workspace's state directory. NEONDB_STATE_DIR is a TEST-ONLY override — never set it for real. */
export function stateDir(): string {
  return process.env.NEONDB_STATE_DIR ?? '.neondb'
}
export function stateFilePath(): string {
  return join(stateDir(), 'state.json')
}
function lockFilePath(): string {
  return join(stateDir(), 'lock')
}
/** The two files the previous design used. Detected and rejected — never interpreted. */
function legacyStateFiles(): { branch: string; check: string } {
  return { branch: join(stateDir(), 'branch'), check: join(stateDir(), 'branch-check') }
}

function fileExists(path: string): boolean {
  try {
    readFileSync(path)
    return true
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return false
    throw error
  }
}

/**
 * Refuse to run while a record from the pre-0.2 format is present.
 *
 * There is no conversion path — this skill targets fresh installs, and a branch NAME cannot prove
 * which branch a workspace owns, so adopting one automatically is exactly the ownership mistake the
 * rest of this file exists to avoid. The guard remains because the alternative is worse than an
 * error: with these files silently ignored, provisioning would create a second branch alongside the
 * old one and teardown would report "nothing to tear down", leaking a live branch (and, for
 * `.neondb/branch`, a root-branch slot) that nothing tracks any more.
 */
export function assertNoLegacyState(): void {
  const { branch, check } = legacyStateFiles()
  if (fileExists(branch)) {
    throw new FatalError(
      `Found ${branch}, a workspace record from before .neondb/state.json. This version does not ` +
        'read it — a branch name is not proof of ownership. Clean up by hand (see "Fresh installs ' +
        `only" in SKILL.md): delete the branch it names from the Neon console — it is a schema-only ` +
        `root branch, so this frees a root-branch slot — then \`rm -rf ${stateDir()}\` and run ` +
        'provision for a fresh workspace database.',
    )
  }
  if (fileExists(check)) {
    throw new FatalError(
      `Found ${check}, which names a leaked disposable clone of production left by an interrupted ` +
        'run of an earlier version. Delete the branch it names from the Neon console, then ' +
        `\`rm -rf ${stateDir()}\` — see "Fresh installs only" in SKILL.md.`,
    )
  }
}

/**
 * Parse and validate state-file contents. Strict on purpose: exactly the four documented keys, a
 * known status, and a branchId that is null if and only if the status is `creating`. Anything else
 * is a corrupted or foreign file, and interpreting it loosely is how the wrong database gets
 * published or the wrong branch gets deleted.
 */
export function parseState(raw: string): WorkspaceState {
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    throw new FatalError(`${stateFilePath()} is not valid JSON. Delete it and re-run provision.`)
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new FatalError(`${stateFilePath()} must contain a JSON object.`)
  }
  const record = parsed as Record<string, unknown>
  const expected = ['branchId', 'branchName', 'projectId', 'status']
  const unknownKeys = Object.keys(record).filter((key) => !expected.includes(key))
  if (unknownKeys.length > 0) {
    throw new FatalError(`${stateFilePath()} has unrecognized key(s): ${unknownKeys.join(', ')}.`)
  }
  for (const key of expected) {
    if (!(key in record)) throw new FatalError(`${stateFilePath()} is incomplete: missing "${key}".`)
  }
  const { branchId, branchName, projectId, status } = record
  if (typeof status !== 'string' || !LIFECYCLE_STATUSES.includes(status as LifecycleStatus)) {
    throw new FatalError(`${stateFilePath()} has an unknown status ${JSON.stringify(status)}.`)
  }
  if (typeof branchName !== 'string' || branchName === '') {
    throw new FatalError(`${stateFilePath()} has a missing or empty "branchName".`)
  }
  if (typeof projectId !== 'string' || projectId === '') {
    throw new FatalError(`${stateFilePath()} has a missing or empty "projectId".`)
  }
  if (status === 'creating') {
    if (branchId !== null) {
      throw new FatalError(`${stateFilePath()} has status "creating" but a non-null "branchId" — creation intent is unresolved and cannot carry an id.`)
    }
  } else if (typeof branchId !== 'string' || !branchId.startsWith('br-')) {
    throw new FatalError(`${stateFilePath()} has status "${status}" but "branchId" is not a Neon branch id.`)
  }
  return { branchId: branchId as string | null, branchName, projectId, status: status as LifecycleStatus }
}

/** Read state, or null when no state file exists. Rejects the legacy format before anything else. */
export function readState(): WorkspaceState | null {
  assertNoLegacyState()
  let raw: string
  try {
    raw = readFileSync(stateFilePath(), 'utf8')
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return null
    throw error
  }
  return parseState(raw)
}

/** Write state atomically (temp file + rename), so a crash mid-write can never leave a partial file. */
export function writeState(state: WorkspaceState): void {
  parseState(JSON.stringify(state)) // never persist something the reader would reject
  mkdirSync(stateDir(), { recursive: true })
  const file = stateFilePath()
  const tmp = `${file}.tmp`
  writeFileSync(tmp, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 })
  renameSync(tmp, file)
}

export function clearState(): void {
  rmSync(stateFilePath(), { force: true })
}

/**
 * Refuse to touch Neon when the recorded project is not the configured one — checked BEFORE any API
 * call, so a state file copied between checkouts pointed at different projects can never make this
 * script look a branch up, let alone delete one, in the wrong project.
 */
export function assertProjectMatches(state: WorkspaceState, projectId: string): void {
  if (state.projectId !== projectId) {
    throw new FatalError(
      `${stateFilePath()} records project "${state.projectId}" but NEON_PROJECT_ID is "${projectId}". ` +
        'Refusing to contact Neon. Point NEON_PROJECT_ID at the recorded project, or tear this ' +
        'workspace down from the checkout that owns it.',
    )
  }
}

/**
 * Remove the state directory only when it is empty — never recursively. Anything else a project
 * chose to keep in .neondb/ is not this script's to delete.
 */
export function removeStateDirIfEmpty(): boolean {
  try {
    if (readdirSync(stateDir()).length > 0) return false
    rmdirSync(stateDir())
    return true
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code
    if (code === 'ENOENT' || code === 'ENOTEMPTY') return false
    throw error
  }
}

// ── Lifecycle lock ───────────────────────────────────────────────────────────

/**
 * Serialize provision/sync/teardown against each other. Exclusive create ('wx') is the whole
 * mechanism; the PID inside exists only so a lock left behind by a killed process can be reclaimed
 * instead of bricking the workspace forever.
 */
export function acquireLock(label: string, isAlive: (pid: number) => boolean = defaultIsAlive): () => void {
  mkdirSync(stateDir(), { recursive: true })
  const file = lockFilePath()
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const fd = openSync(file, 'wx', 0o600)
      writeSync(fd, `${JSON.stringify({ pid: process.pid, label, at: new Date().toISOString() })}\n`)
      closeSync(fd)
      return () => rmSync(file, { force: true })
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error
      const holder = readLockHolder(file)
      if (holder !== null && isAlive(holder.pid)) {
        throw new FatalError(
          `Another neondb-branch command (${holder.label}, pid ${holder.pid}) is running for this ` +
            `workspace. Wait for it to finish, or remove ${file} if you are certain it is stale.`,
        )
      }
      rmSync(file, { force: true }) // stale: the recorded process is gone (or the file is garbage)
    }
  }
  throw new FatalError(`Could not acquire ${file}.`)
}

function readLockHolder(file: string): { pid: number; label: string } | null {
  try {
    const parsed = JSON.parse(readFileSync(file, 'utf8')) as { pid?: unknown; label?: unknown }
    if (typeof parsed.pid !== 'number' || !Number.isInteger(parsed.pid)) return null
    return { pid: parsed.pid, label: typeof parsed.label === 'string' ? parsed.label : 'unknown' }
  } catch {
    return null
  }
}

function defaultIsAlive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === 'EPERM' // alive, just not ours to signal
  }
}

// ── Workspace identity ───────────────────────────────────────────────────────

function requireEnv(name: string): string {
  const value = process.env[name]
  if (!value) {
    throw new FatalError(
      `${name} is required for the per-workspace Neon branch. Set it in ${ENV_FILE}, your shell ` +
        `environment, or your orchestrator's environment config (e.g. Conductor's Environment tabs).`,
    )
  }
  return value
}

function slugify(raw: string): string {
  const slug = raw
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
  if (!slug) throw new FatalError(`Could not derive a branch name from workspace identity "${raw}".`)
  return slug
}

/**
 * Stable, Neon-safe branch name for a resolved workspace identity. Unchanged from the previous
 * design on purpose — existing workspaces keep the names they already have. This is a DISPLAY name:
 * nothing is looked up, renamed or deleted by it.
 */
export function workspaceBranchName(raw: string): string {
  let slug = slugify(raw)
  if (slug.length > MAX_SLUG) {
    // Truncate, but keep distinct workspaces distinct: append a short hash of the FULL name so two
    // long names sharing a prefix don't collide onto one branch. Re-trim any separator the cut left
    // dangling so the name never ends in "-".
    const suffix = createHash('sha256').update(raw).digest('hex').slice(0, 8)
    slug = `${slug.slice(0, MAX_SLUG - suffix.length - 1).replace(/-+$/, '')}-${suffix}`
  }
  return `${BRANCH_PREFIX}${slug}`
}

export interface GitContext {
  /** true when this checkout is a linked git worktree (not the main/primary checkout) */
  isSecondaryWorktree: boolean
  /** current branch name, or null when HEAD is detached or this isn't a git repository */
  branch: string | null
}

/**
 * Workspace identity, before slugify. First match wins:
 *   1. CONDUCTOR_WORKSPACE_NAME  2. ORCA_WORKSPACE_NAME  3. WORKSPACE_NAME
 *   4. basename(cwd) for a secondary git worktree  5. the current git branch
 * WORKSPACE_NAME is only ever read from process env, NEVER from .env.neondb — that file can be
 * copied across workspaces.
 *
 * Identity decides what a NEW branch is called. It never decides which branch this workspace owns:
 * that comes from .neondb/state.json's branchId alone.
 */
export function resolveWorkspaceName(env: NodeJS.ProcessEnv, cwd: string, git: GitContext): string {
  const fromEnv = env.CONDUCTOR_WORKSPACE_NAME || env.ORCA_WORKSPACE_NAME || env.WORKSPACE_NAME
  if (fromEnv) return fromEnv
  if (git.isSecondaryWorktree) return basename(cwd)
  if (git.branch) return git.branch
  throw new FatalError(
    'Could not determine workspace identity: no CONDUCTOR_WORKSPACE_NAME / ORCA_WORKSPACE_NAME / ' +
      'WORKSPACE_NAME is set, this checkout is not a secondary git worktree, and there is no usable ' +
      'git branch (detached HEAD, or not a git repository). Check out a named branch, or set ' +
      'WORKSPACE_NAME explicitly.',
  )
}

function currentGitContext(cwd: string): GitContext {
  let gitDir: string
  try {
    gitDir = execFileSync('git', ['rev-parse', '--git-dir'], { cwd, encoding: 'utf8' }).trim()
  } catch {
    return { isSecondaryWorktree: false, branch: null }
  }
  const isSecondaryWorktree = /[\\/]worktrees[\\/]/.test(gitDir)
  let branch: string | null = null
  try {
    const ref = execFileSync('git', ['rev-parse', '--abbrev-ref', 'HEAD'], { cwd, encoding: 'utf8' }).trim()
    branch = ref === 'HEAD' ? null : ref // literal 'HEAD' means detached
  } catch {
    branch = null
  }
  return { isSecondaryWorktree, branch }
}

// ── Retry ────────────────────────────────────────────────────────────────────

/** Block for ms without a timer — this is a synchronous one-shot CLI script. */
function sleepMs(ms: number): void {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)
}

/** Backoff grows each attempt (2s, 4s, 8s, …) so a slow compute boot gets more time. */
export function backoffMs(attempt: number): number {
  return 2000 * 2 ** (attempt - 1)
}

export interface RetryOptions {
  attempts?: number
  sleep?: (ms: number) => void
  log?: (message: string) => void
  /**
   * Whether an ambiguous control-plane failure (reset socket, response timeout, 5xx) may be retried.
   * True only for operations that are safe to apply twice — reads, and deletes, whose second attempt
   * is at worst a 404. NEVER true for branch creation: re-sending a POST whose outcome is unknown is
   * exactly the blind-retry behaviour this design forbids.
   */
  retryAmbiguous?: boolean
}

/**
 * Retry an operation with exponential backoff. A FatalError is never retried; an ambiguous
 * NeonRequestError is retried only when the caller says the operation is idempotent.
 */
export async function withRetry<T>(label: string, fn: () => T | Promise<T>, options: RetryOptions = {}): Promise<T> {
  const { attempts = 6, sleep = sleepMs, log = console.log, retryAmbiguous = false } = options
  for (let attempt = 1; ; attempt++) {
    try {
      return await fn()
    } catch (error) {
      const neonError = error instanceof NeonRequestError ? error : null
      const unretryable =
        error instanceof FatalError ||
        error instanceof AmbiguousCreateError ||
        (neonError !== null && (!neonError.retryable || (neonError.ambiguous && !retryAmbiguous)))
      if (unretryable || attempt >= attempts) throw error
      const waitMs = backoffMs(attempt)
      log(`[retry] ${label}: attempt ${attempt} failed; waiting ${waitMs / 1000}s before retry…`)
      sleep(waitMs)
    }
  }
}

// ── Neon control plane ───────────────────────────────────────────────────────

export interface NeonBranch {
  id: string
  project_id: string
  name: string
  parent_id?: string | null
  parent_lsn?: string | null
  default?: boolean
  primary?: boolean
  protected?: boolean
  current_state?: string
  init_source?: string
}

export interface CreatedBranch {
  branch: NeonBranch
  connectionUri: string | null
}

export interface NeonClient {
  findBranchByName(projectId: string, name: string): Promise<NeonBranch | null>
  /** null when Neon reports the branch does not exist (404). */
  getBranchById(projectId: string, branchId: string): Promise<NeonBranch | null>
  createBranch(projectId: string, opts: { name: string; parentId: string; parentLsn: string }): Promise<CreatedBranch>
  /** 'absent' when the branch was already gone. */
  deleteBranch(projectId: string, branchId: string): Promise<'deleted' | 'absent'>
  connectionUri(projectId: string, branchId: string): Promise<string>
}

const NEON_API_BASE = process.env.NEON_API_BASE ?? 'https://console.neon.tech/api/v2'

/**
 * Network failures we can prove happened BEFORE the request reached Neon. Only these are safe to
 * retry on a POST; everything else (a reset socket, a response timeout, a 5xx) may have been applied
 * server-side and is reported as ambiguous.
 */
const PRE_REQUEST_ERROR_CODES = new Set(['ENOTFOUND', 'EAI_AGAIN', 'ECONNREFUSED', 'UND_ERR_CONNECT_TIMEOUT'])

function errorCodeChain(error: unknown): string[] {
  const codes: string[] = []
  let current: unknown = error
  for (let depth = 0; current && depth < 5; depth++) {
    const code = (current as { code?: unknown }).code
    if (typeof code === 'string') codes.push(code)
    current = (current as { cause?: unknown }).cause
  }
  return codes
}

/** The real Neon REST client. `neonctl` is deliberately not used: its `branches create --parent`
 * takes a name OR an lsn as one value, so a named parent pinned at a captured LSN is not
 * expressible through the CLI, and the REST response hands back the branch id and connection URI in
 * one round trip. */
export function createNeonRestClient(apiKey: string, fetchImpl: typeof fetch = fetch): NeonClient {
  async function request<T>(method: string, path: string, body?: unknown): Promise<{ status: number; data: T }> {
    let response: Response
    try {
      response = await fetchImpl(`${NEON_API_BASE}${path}`, {
        method,
        headers: {
          Authorization: `Bearer ${apiKey}`,
          Accept: 'application/json',
          ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      })
    } catch (error) {
      const codes = errorCodeChain(error)
      const preRequest = codes.some((code) => PRE_REQUEST_ERROR_CODES.has(code))
      throw new NeonRequestError(
        `${method} ${path} failed before a response was read (${codes.join(' → ') || (error as Error).message})`,
        null,
        !preRequest,
      )
    }
    const text = await response.text()
    let data: unknown = null
    if (text) {
      try {
        data = JSON.parse(text)
      } catch {
        data = null
      }
    }
    if (!response.ok) {
      const detail = (data as { message?: string } | null)?.message ?? text.slice(0, 300)
      // A 5xx leaves a mutating request's outcome unknown. A 4xx — 429 included — means Neon
      // rejected it before applying anything, so the outcome is known even when it is a failure.
      const ambiguous = response.status >= 500
      throw new NeonRequestError(`${method} ${path} → HTTP ${response.status}: ${detail}`, response.status, ambiguous)
    }
    return { status: response.status, data: data as T }
  }

  async function listBranches(projectId: string): Promise<NeonBranch[]> {
    const collected: NeonBranch[] = []
    let cursor: string | undefined
    for (let page = 0; page < 50; page++) {
      const query = new URLSearchParams({ limit: '400' })
      if (cursor) query.set('cursor', cursor)
      const { data } = await request<{ branches?: NeonBranch[]; pagination?: { next_cursor?: string; cursor?: string } }>(
        'GET',
        `/projects/${encodeURIComponent(projectId)}/branches?${query.toString()}`,
      )
      const branches = data?.branches
      if (!Array.isArray(branches)) {
        // An unrecognized shape must THROW, not read as "no branches" — misreading a live branch as
        // absent would make provisioning create a duplicate or teardown skip a real branch.
        throw new FatalError('Unexpected Neon list-branches response shape; cannot enumerate branches.')
      }
      collected.push(...branches)
      const next = data.pagination?.next_cursor ?? data.pagination?.cursor
      if (!next || next === cursor || branches.length === 0) break
      cursor = next
    }
    return collected
  }

  return {
    async findBranchByName(projectId, name) {
      const matches = (await listBranches(projectId)).filter((branch) => branch.name === name)
      if (matches.length > 1) {
        throw new FatalError(`Project ${projectId} has ${matches.length} branches named "${name}" — refusing to guess which one is meant.`)
      }
      return matches[0] ?? null
    },

    async getBranchById(projectId, branchId) {
      try {
        const { data } = await request<{ branch?: NeonBranch }>('GET', `/projects/${encodeURIComponent(projectId)}/branches/${encodeURIComponent(branchId)}`)
        return data?.branch ?? null
      } catch (error) {
        if (error instanceof NeonRequestError && error.status === 404) return null
        throw error
      }
    },

    async createBranch(projectId, { name, parentId, parentLsn }) {
      const { data } = await request<{ branch?: NeonBranch; connection_uris?: Array<{ connection_uri?: string }> }>(
        'POST',
        `/projects/${encodeURIComponent(projectId)}/branches`,
        { branch: { name, parent_id: parentId, parent_lsn: parentLsn }, endpoints: [{ type: 'read_write' }] },
      )
      if (!data?.branch?.id) {
        throw new FatalError('Neon accepted the branch creation but returned no branch id; cannot establish ownership.')
      }
      return { branch: data.branch, connectionUri: data.connection_uris?.[0]?.connection_uri ?? null }
    },

    async deleteBranch(projectId, branchId) {
      try {
        await request('DELETE', `/projects/${encodeURIComponent(projectId)}/branches/${encodeURIComponent(branchId)}`)
        return 'deleted'
      } catch (error) {
        if (error instanceof NeonRequestError && error.status === 404) return 'absent'
        throw error
      }
    },

    async connectionUri(projectId, branchId) {
      const databaseName = process.env.NEON_DATABASE_NAME
      const roleName = process.env.NEON_ROLE_NAME
      let database = databaseName
      let role = roleName
      if (!database || !role) {
        const { data } = await request<{ databases?: Array<{ name?: string; owner_name?: string }> }>(
          'GET',
          `/projects/${encodeURIComponent(projectId)}/branches/${encodeURIComponent(branchId)}/databases`,
        )
        const first = data?.databases?.[0]
        if (!first?.name || !first.owner_name) {
          throw new FatalError(
            `Could not determine the database/role for branch ${branchId}. Set NEON_DATABASE_NAME and NEON_ROLE_NAME explicitly.`,
          )
        }
        database = database || first.name
        role = role || first.owner_name
      }
      const query = new URLSearchParams({ branch_id: branchId, database_name: database, role_name: role })
      const { data } = await request<{ uri?: string; connection_uri?: string }>(
        'GET',
        `/projects/${encodeURIComponent(projectId)}/connection_uri?${query.toString()}`,
      )
      const uri = data?.uri ?? data?.connection_uri
      if (!uri || !uri.startsWith('postgres')) {
        throw new FatalError(`Neon did not return a postgres connection string for branch ${branchId}.`)
      }
      return uri
    },

  }
}

/**
 * Everything about the branch that must hold before this script runs a single destructive statement
 * against it. `parentLsn` is the nonce: together with the name and parent id it distinguishes the
 * branch WE just created from a same-named branch created by anyone else.
 */
export function assertOwnedDisposableBranch(
  branch: NeonBranch,
  expected: { projectId: string; name: string; parentId: string; parentLsn?: string },
): void {
  const fail = (why: string): never => {
    throw new FatalError(`Refusing to use branch ${branch.id ?? '(no id)'}: ${why}`)
  }
  if (typeof branch.id !== 'string' || !branch.id.startsWith('br-')) fail('it has no Neon branch id')
  if (branch.project_id !== expected.projectId) fail(`it belongs to project "${branch.project_id}", not "${expected.projectId}"`)
  if (branch.name !== expected.name) fail(`its name is "${branch.name}", not the expected "${expected.name}"`)
  if (!branch.name.startsWith(BRANCH_PREFIX)) fail(`its name is not under the disposable "${BRANCH_PREFIX}" namespace`)
  if (branch.id === expected.parentId) fail('it IS the parent branch')
  if (branch.parent_id !== expected.parentId) fail(`its parent is "${branch.parent_id ?? '(none — a root branch)'}", not "${expected.parentId}"`)
  if (expected.parentLsn !== undefined && branch.parent_lsn !== expected.parentLsn) {
    fail(`its parent_lsn is "${branch.parent_lsn ?? '(none)'}", not the captured "${expected.parentLsn}" — this is not the branch this run created`)
  }
  if (branch.default === true) fail('it is the project default branch')
  if (branch.primary === true) fail('it is the project primary branch')
  if (branch.protected === true) fail('it is a protected branch')
}

// ── Purge ────────────────────────────────────────────────────────────────────

export interface DiscoveredTable {
  schema: string
  name: string
  extensionOwned: boolean
}

export interface PurgePlan {
  truncate: string[]
  preserved: string[]
}

/** Double any embedded quote so a catalog-supplied identifier is a valid quoted identifier. */
export function quoteIdent(name: string): string {
  return `"${name.replace(/"/g, '""')}"`
}

function qualify(table: { schema: string; name: string }): string {
  return `${table.schema}.${table.name}`
}

/**
 * Decide what the purge empties and what it keeps — pure, so every fail-closed case is unit-tested
 * without a database.
 *
 * Preserved: the migration ledger (inherited from production and the whole point of using an
 * ordinary child), every extension-owned table (PostGIS's spatial_ref_sys and friends), and the
 * PRESERVED_TABLES knob.
 *
 * Fails closed on any base table in a non-system schema that is neither preserved nor a known
 * application table, and on any schema outside APP_SCHEMAS that holds such a table. That is the
 * "production is ahead of this checkout" case, and publishing a database with rows this script
 * cannot account for is exactly what must not happen. Known tables that are ABSENT are fine — that
 * is "production is behind this checkout", and migrate-deploy creates them after the purge.
 */
export function planPurge(
  discovered: DiscoveredTable[],
  known: string[],
  opts: { appSchemas?: string[]; preserved?: string[]; ledgerTable?: string } = {},
): PurgePlan {
  const appSchemas = new Set(opts.appSchemas ?? APP_SCHEMAS)
  const ledger = opts.ledgerTable ?? migrationLedgerTable()
  const preservedNames = new Set([ledger, ...(opts.preserved ?? PRESERVED_TABLES)])
  const knownNames = new Set(known)

  const truncate: string[] = []
  const preserved: string[] = []
  const unknownTables: string[] = []
  const unknownSchemas = new Set<string>()

  for (const table of discovered) {
    const qualified = qualify(table)
    if (table.extensionOwned || preservedNames.has(qualified)) {
      preserved.push(qualified)
      continue
    }
    if (!appSchemas.has(table.schema)) {
      unknownSchemas.add(table.schema)
      continue
    }
    if (!knownNames.has(qualified)) {
      unknownTables.push(qualified)
      continue
    }
    truncate.push(qualified)
  }

  if (unknownSchemas.size > 0 || unknownTables.length > 0) {
    const parts: string[] = []
    if (unknownSchemas.size > 0) parts.push(`schema(s) ${[...unknownSchemas].sort().join(', ')}`)
    if (unknownTables.length > 0) parts.push(`table(s) ${unknownTables.sort().join(', ')}`)
    throw new FatalError(
      `The parent branch contains ${parts.join(' and ')} that this checkout does not know about. ` +
        'Refusing to publish a workspace database holding production rows this script cannot ' +
        'account for. Either pull the migrations that define them, add them to APP_SCHEMAS / ' +
        'PRESERVED_TABLES, or widen knownApplicationTables().',
    )
  }
  return { truncate: truncate.sort(), preserved: preserved.sort() }
}

/** SQL that lists every non-system base table, flagging the ones an extension owns. */
export const DISCOVER_TABLES_SQL = `
SELECT n.nspname AS schema,
       c.relname AS name,
       EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e') AS extension_owned
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg\\_toast%'
  AND n.nspname NOT LIKE 'pg\\_temp%'
  AND NOT EXISTS (SELECT 1 FROM pg_inherits i WHERE i.inhrelid = c.oid)
ORDER BY 1, 2`

export async function discoverTables(client: SqlClient): Promise<DiscoveredTable[]> {
  const rows = await client.query<{ schema: string; name: string; extension_owned: boolean | string }>(DISCOVER_TABLES_SQL)
  return rows.map((row) => ({
    schema: row.schema,
    name: row.name,
    extensionOwned: row.extension_owned === true || row.extension_owned === 't' || row.extension_owned === 'true',
  }))
}

export function buildTruncateSql(tables: string[]): string {
  const list = tables
    .map((qualified) => {
      const separator = qualified.indexOf('.')
      return `${quoteIdent(qualified.slice(0, separator))}.${quoteIdent(qualified.slice(separator + 1))}`
    })
    .join(', ')
  return `TRUNCATE TABLE ${list} RESTART IDENTITY CASCADE`
}

export function buildCountSql(tables: string[]): string {
  return tables
    .map((qualified) => {
      const separator = qualified.indexOf('.')
      const ref = `${quoteIdent(qualified.slice(0, separator))}.${quoteIdent(qualified.slice(separator + 1))}`
      return `SELECT ${quoteLiteral(qualified)} AS qualified, count(*)::bigint AS rows FROM ${ref}`
    })
    .join('\nUNION ALL\n')
}

function quoteLiteral(value: string): string {
  return `'${value.replace(/'/g, "''")}'`
}

/**
 * Empty every application table in ONE transaction, leaving the inherited migration ledger and every
 * extension-owned table intact. Any failure rolls the whole thing back, so the branch is never left
 * half-purged — a half-purged branch is worse than an unpurged one, because it looks provisioned.
 *
 * Database operations only. No Blob deletion, no billing calls, no worker calls, no application
 * side effects of any kind: this runs against a copy of production, and firing the app's own
 * deletion hooks here would reach out and mutate shared systems.
 */
export async function purgeApplicationRows(client: SqlClient, plan: PurgePlan): Promise<void> {
  if (plan.truncate.length === 0) return
  await client.query('BEGIN')
  try {
    await client.query(buildTruncateSql(plan.truncate))
    await client.query('COMMIT')
  } catch (error) {
    try {
      await client.query('ROLLBACK')
    } catch {
      // The original error is what matters; a rollback that itself fails (dead connection) must not
      // replace it.
    }
    throw error
  }
}

/** Confirm the purge actually emptied everything before any connection URL is published. */
export async function verifyTablesEmpty(client: SqlClient, tables: string[]): Promise<void> {
  if (tables.length === 0) return
  const rows = await client.query<{ qualified: string; rows: number | string }>(buildCountSql(tables))
  const nonEmpty = rows.filter((row) => Number(row.rows) > 0).map((row) => `${row.qualified}=${row.rows}`)
  if (nonEmpty.length > 0) {
    throw new FatalError(`Purge did not empty every application table (${nonEmpty.join(', ')}) — refusing to publish this database.`)
  }
}

// ── Child processes ──────────────────────────────────────────────────────────

/** The child-process environment with every DB var pinned to the workspace branch. */
function childDbEnv(uri: string): NodeJS.ProcessEnv {
  return { ...process.env, ...Object.fromEntries(DB_ENV_VARS.map((name) => [name, uri])) }
}

/** Retry a project-local CLI — a compute that has just booted can still refuse the first attempts. */
function runWithRetry(bin: string, binArgs: string[], env: NodeJS.ProcessEnv, attempts = 3): void {
  const file = PM_EXEC[0]
  const args = [...PM_EXEC.slice(1), bin, ...binArgs]
  for (let attempt = 1; attempt <= attempts; attempt++) {
    const res = spawnSync(file, args, { stdio: 'inherit', env })
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

/** Apply migrations this checkout has that the parent had not run. Always AFTER the purge. */
function deployMigrations(uri: string): void {
  if (ORM === 'prisma') runWithRetry('prisma', ['migrate', 'deploy'], childDbEnv(uri))
  else runWithRetry('drizzle-kit', ['migrate'], childDbEnv(uri))
}

/**
 * Seed the workspace with test fixtures — the last step of provisioning.
 *
 * ── ADAPT THIS to your project's seed ──────────────────────────────────────────
 *  • No seed?  Delete this function and its call.
 *  • Plain seed, no safety guard?
 *      Prisma:  runWithRetry('prisma', ['db', 'seed'], childDbEnv(uri), 2)
 *      Drizzle: runWithRetry('tsx', [SEED_SCRIPT], childDbEnv(uri), 2)
 *  • Seed that REFUSES non-local DBs (recommended)? Authorize it for THIS branch only. The example
 *    below matches a seed that allows a remote DB when E2E_EXPECTED_DATABASE_URL === DATABASE_URL.
 */
function seedWorkspace(uri: string): void {
  if (!process.env.E2E_USER_PASSWORD) {
    console.warn('[seed] seed credentials not set — skipping seed (workspace DB will be empty). Set them in your orchestrator env to seed test fixtures.')
    return
  }
  console.log('[seed] seeding workspace fixtures…')
  runWithRetry('tsx', [SEED_SCRIPT], { ...childDbEnv(uri), E2E_EXPECTED_DATABASE_URL: uri }, 2)
}

// ── .env.neondb ──────────────────────────────────────────────────────────────

function readEnvFileRaw(path: string): string {
  try {
    return readFileSync(path, 'utf8')
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return ''
    throw error
  }
}

function withoutKeys(content: string, keys: string[]): string[] {
  const trimmed = content.replace(/\n+$/, '')
  if (trimmed === '') return []
  const keySet = new Set(keys)
  return trimmed.split('\n').filter((line) => {
    const eq = line.indexOf('=')
    return eq === -1 ? true : !keySet.has(line.slice(0, eq))
  })
}

/**
 * Upsert every NAME=value pair into `path`, preserving every other line untouched. Single-quoted
 * values: dotenv's expand step would otherwise rewrite a literal `$` inside a connection string.
 */
export function upsertEnvVars(path: string, vars: Record<string, string>): void {
  const kept = withoutKeys(readEnvFileRaw(path), Object.keys(vars))
  const appended = Object.entries(vars).map(([name, value]) => `${name}='${value}'`)
  writeFileSync(path, `${[...kept, ...appended].join('\n')}\n`, { mode: 0o600 })
}

/** Remove every line whose key is in `keys`, deleting the file if that leaves nothing behind. */
export function stripEnvVars(path: string, keys: string[]): void {
  const raw = readEnvFileRaw(path)
  if (!raw.trim()) return
  const kept = withoutKeys(raw, keys)
  if (kept.length === 0) rmSync(path, { force: true })
  else writeFileSync(path, `${kept.join('\n')}\n`, { mode: 0o600 })
}

/**
 * Which of `names` the managed env file actually defines. Deliberately reads the FILE and not
 * process.env: an ambient DATABASE_URL exported by the shell or a shared .env would otherwise
 * satisfy a check whose whole purpose is to prove this workspace has its own URL.
 */
export function managedVarsInFile(path: string, names: string[] = DB_ENV_VARS): string[] {
  const raw = readEnvFileRaw(path)
  if (!raw.trim()) return []
  const wanted = new Set(names)
  const found: string[] = []
  for (const line of raw.split('\n')) {
    const eq = line.indexOf('=')
    if (eq === -1) continue
    const key = line.slice(0, eq).trim()
    if (!wanted.has(key)) continue
    const value = line.slice(eq + 1).trim().replace(/^['"]|['"]$/g, '')
    if (value !== '') found.push(key)
  }
  return found
}

/**
 * Where the managed DB vars are written. NEONDB_BRANCH_ENV_FILE is a TEST-ONLY override — never set
 * it in a real workspace, or `load-env.cjs` and this script would disagree about which file is the
 * workspace's.
 */
export function envFilePath(): string {
  return process.env.NEONDB_BRANCH_ENV_FILE ?? ENV_FILE
}

export function loadEnvFile(): void {
  dotenvConfig({ path: envFilePath() })
}

// ── Commands ─────────────────────────────────────────────────────────────────

export interface Deps {
  neon: NeonClient
  connect: SqlConnect
  knownTables: () => Promise<string[]>
  deployMigrations: (uri: string) => void | Promise<void>
  seed: (uri: string) => void | Promise<void>
  sleep: (ms: number) => void
  log: (message: string) => void
  warn: (message: string) => void
}

/**
 * The REST client, built on first use rather than up front, so a command that legitimately has
 * nothing to do (teardown on a workspace that was never provisioned) still reports that instead of
 * demanding NEON_API_KEY first.
 */
function lazyNeonClient(): NeonClient {
  let inner: NeonClient | null = null
  const client = (): NeonClient => (inner ??= createNeonRestClient(requireEnv('NEON_API_KEY')))
  return {
    findBranchByName: (projectId, name) => client().findBranchByName(projectId, name),
    getBranchById: (projectId, branchId) => client().getBranchById(projectId, branchId),
    createBranch: (projectId, opts) => client().createBranch(projectId, opts),
    deleteBranch: (projectId, branchId) => client().deleteBranch(projectId, branchId),
    connectionUri: (projectId, branchId) => client().connectionUri(projectId, branchId),
  }
}

function defaultDeps(): Deps {
  return {
    neon: lazyNeonClient(),
    connect,
    knownTables: knownApplicationTables,
    deployMigrations,
    seed: seedWorkspace,
    sleep: sleepMs,
    log: console.log,
    warn: console.warn,
  }
}

/** Retry options for a READ or a DELETE: safe to apply twice, so an ambiguous failure may retry. */
function idempotent(deps: Deps, attempts: number): RetryOptions {
  return { attempts, sleep: deps.sleep, log: deps.log, retryAmbiguous: true }
}

/** Retry options for anything whose double-application would be a bug. */
function mutating(deps: Deps, attempts: number): RetryOptions {
  return { attempts, sleep: deps.sleep, log: deps.log, retryAmbiguous: false }
}

/** Open a connection, run `fn`, and always close — used for every SQL step below. */
async function withConnection<T>(deps: Deps, uri: string, fn: (client: SqlClient) => Promise<T>): Promise<T> {
  const { client, end } = await deps.connect(uri)
  try {
    return await fn(client)
  } finally {
    await end().catch(() => undefined)
  }
}

/** Read the parent's current WAL position. The ONLY statement this script sends to production. */
export async function captureParentLsn(deps: Deps, parentUri: string): Promise<string> {
  const rows = await withConnection(deps, parentUri, (client) => client.query<{ lsn: string }>('SELECT pg_current_wal_lsn()::text AS lsn'))
  const lsn = rows[0]?.lsn
  if (typeof lsn !== 'string' || !/^[0-9A-Fa-f]+\/[0-9A-Fa-f]+$/.test(lsn)) {
    throw new FatalError(`Could not read a WAL LSN from the parent branch (got ${JSON.stringify(lsn)}).`)
  }
  return lsn
}

/** Wait until a brand-new compute accepts a connection. Generous by design — see FIRST_CONNECTION_ATTEMPTS. */
async function waitForFirstConnection(deps: Deps, uri: string): Promise<void> {
  await withRetry('acquire first connection to the new compute', () => withConnection(deps, uri, (client) => client.query('SELECT 1')), {
    attempts: FIRST_CONNECTION_ATTEMPTS,
    sleep: deps.sleep,
    log: deps.log,
    retryAmbiguous: true,
  })
}

export async function provision(deps: Deps = defaultDeps()): Promise<void> {
  const projectId = requireEnv('NEON_PROJECT_ID')
  const apiKey = requireEnv('NEON_API_KEY')
  const parentRef = requireEnv('NEON_PARENT_BRANCH')
  const raw = resolveWorkspaceName(process.env, process.cwd(), currentGitContext(process.cwd()))
  const branchName = workspaceBranchName(raw)

  const releaseLock = acquireLock('provision')
  try {
    const existing = readState() // also rejects the legacy format
    if (existing) {
      assertProjectMatches(existing, projectId)
      if (existing.status === 'creating') {
        throw new FatalError(
          `${stateFilePath()} records an UNRESOLVED branch creation (status "creating", no id): a ` +
            'previous provision could not confirm whether Neon created its branch. Refusing to ' +
            'create another one, and refusing to guess by name. Look for a branch named ' +
            `"${existing.branchName}" in project ${projectId}; if it exists and is yours, delete it ` +
            `in the Neon console, then delete ${stateFilePath()} and re-run provision.`,
        )
      }
    }

    // Resolve the parent and capture its LSN BEFORE destroying anything. If production is
    // unreachable or misconfigured, the workspace still has the database it had.
    deps.log(`[neon] resolving parent branch "${parentRef}"…`)
    const parent = await withRetry(
      'resolve parent branch',
      async () => {
        const found = parentRef.startsWith('br-')
          ? await deps.neon.getBranchById(projectId, parentRef)
          : await deps.neon.findBranchByName(projectId, parentRef)
        if (!found) throw new FatalError(`Parent branch "${parentRef}" was not found in project ${projectId}.`)
        return found
      },
      idempotent(deps, 3),
    )

    const parentUri = await withRetry('fetch parent connection string', () => deps.neon.connectionUri(projectId, parent.id), idempotent(deps, 5))
    const parentLsn = await withRetry('capture parent WAL LSN', () => captureParentLsn(deps, parentUri), idempotent(deps, FIRST_CONNECTION_ATTEMPTS))
    deps.log(`[neon] parent ${parent.name} (${parent.id}) is at LSN ${parentLsn}`)

    if (existing) {
      // Every run is a full rebuild. Delete by ID: the recorded name may be stale, and a name is
      // never proof of ownership.
      deps.log(`[neon] deleting recorded branch ${existing.branchId} (${existing.branchName}) to rebuild from scratch…`)
      await withRetry('delete recorded branch', () => deps.neon.deleteBranch(projectId, existing.branchId as string), idempotent(deps, 3))
      stripEnvVars(envFilePath(), DB_ENV_VARS)
      clearState()
    }

    // Creation intent is recorded BEFORE the POST, so an interrupted or ambiguous creation is always
    // visible afterwards instead of silently leaking a branch nothing tracks.
    writeState({ branchId: null, branchName, projectId, status: 'creating' })

    deps.log(`[neon] creating ordinary child branch ${branchName} off ${parent.name} at ${parentLsn}…`)
    let created: CreatedBranch
    try {
      created = await withRetry('create branch', () => deps.neon.createBranch(projectId, { name: branchName, parentId: parent.id, parentLsn }), mutating(deps, 3))
    } catch (error) {
      if (error instanceof NeonRequestError && error.ambiguous) {
        throw new AmbiguousCreateError(
          `Neon did not confirm whether it created "${branchName}" (${error.message}). Creation ` +
            `intent has been kept in ${stateFilePath()} as status "creating". This is NOT retried ` +
            'automatically and the branch is NOT looked up by name: a branch with that name may ' +
            `belong to another workspace. Check project ${projectId} in the Neon console, delete ` +
            `"${branchName}" if it is yours, then delete ${stateFilePath()} and re-run provision.`,
        )
      }
      throw error
    }

    // Verify before anything destructive touches it.
    try {
      assertOwnedDisposableBranch(created.branch, { projectId, name: branchName, parentId: parent.id, parentLsn })
    } catch (error) {
      // The id came back from our own POST, so this branch IS ours — but it is not what we asked
      // for. Clean it up when it is provably disposable; when it is not (it came back flagged
      // default/primary/protected, or in another project) leave it strictly alone and hand the
      // problem to a human.
      const disposable =
        created.branch.project_id === projectId &&
        typeof created.branch.name === 'string' &&
        created.branch.name.startsWith(BRANCH_PREFIX) &&
        created.branch.default !== true &&
        created.branch.primary !== true &&
        created.branch.protected !== true &&
        typeof created.branch.id === 'string' &&
        created.branch.id.startsWith('br-')
      if (disposable) {
        try {
          await withRetry('delete unverifiable branch', () => deps.neon.deleteBranch(projectId, created.branch.id), idempotent(deps, 3))
          clearState()
        } catch (cleanupError) {
          deps.warn(`[neondb-branch] WARNING: could not delete unverifiable branch ${created.branch.id} (${cleanupError instanceof Error ? cleanupError.message : cleanupError}).`)
        }
      }
      throw new FatalError(
        `${error instanceof Error ? error.message : error} — Neon reported creating branch ` +
          `${created.branch.id ?? '(no id)'}${disposable ? ', which has been deleted again' : '; delete it in the console if it is yours'}. ` +
          `Re-run provision once the cause is understood.`,
      )
    }
    const branchId = created.branch.id
    writeState({ branchId, branchName, projectId, status: 'pending' })
    deps.log(`[neon] created ${branchId} (parent ${created.branch.parent_id} @ ${created.branch.parent_lsn})`)

    try {
      const uri = created.connectionUri ?? (await withRetry('fetch connection string', () => deps.neon.connectionUri(projectId, branchId), idempotent(deps, 5)))
      await waitForFirstConnection(deps, uri)

      const known = await deps.knownTables()
      deps.log('[purge] emptying inherited production rows (migration ledger preserved)…')
      const plan = await withConnection(deps, uri, async (client) => {
        const discovered = await discoverTables(client)
        const purgePlan = planPurge(discovered, known)
        await purgeApplicationRows(client, purgePlan)
        await verifyTablesEmpty(client, purgePlan.truncate)
        return purgePlan
      })
      deps.log(`[purge] emptied ${plan.truncate.length} table(s); preserved ${plan.preserved.length} (${plan.preserved.join(', ') || 'none'})`)

      // Migrate and seed reach the branch through their child-process environment only — the
      // provisioning migrator is the ONE thing allowed to touch a pending branch.
      deps.log(`[${ORM}] applying migrations this checkout has that the parent did not…`)
      await deps.deployMigrations(uri)
      await deps.seed(uri)

      // Publishing is the last thing that happens before `ready`, and it happens only after the
      // purge was verified. Until this point nothing outside provisioning can reach the branch.
      upsertEnvVars(envFilePath(), {
        ...Object.fromEntries(DB_ENV_VARS.map((name) => [name, uri])),
        NEON_API_KEY: apiKey,
        NEON_PROJECT_ID: projectId,
        NEON_PARENT_BRANCH: parentRef,
      })
      deps.log(`[neondb-branch] wrote ${DB_ENV_VARS.join(', ')} and Neon credentials → ${envFilePath()}`)

      writeState({ branchId, branchName, projectId, status: 'ready' })
      deps.log('✅ [neondb-branch] workspace database ready.')
    } catch (error) {
      deps.warn('[neondb-branch] setup failed after the branch was created — deleting it so the next attempt starts clean.')
      try {
        await withRetry('delete branch after failed setup', () => deps.neon.deleteBranch(projectId, branchId), idempotent(deps, 3))
        stripEnvVars(envFilePath(), DB_ENV_VARS)
        clearState()
      } catch (cleanupError) {
        // Cleanup failed: KEEP the recovery state so teardown can still find the branch by id, and
        // say so loudly. Silently dropping the record is how a branch leaks forever.
        deps.warn(
          `[neondb-branch] WARNING: could not delete branch ${branchId} ` +
            `(${cleanupError instanceof Error ? cleanupError.message : cleanupError}). ` +
            `${stateFilePath()} still records it — run teardown to remove it.`,
        )
      }
      throw error
    }
  } finally {
    releaseLock()
  }
}

export async function sync(deps: Deps = defaultDeps()): Promise<void> {
  const releaseLock = acquireLock('sync')
  try {
    const state = readState()
    if (!state) {
      throw new FatalError('Workspace not provisioned — run `db:provision` (or `worktree:setup`) before starting the dev server.')
    }
    if (state.status !== 'ready') {
      throw new FatalError(
        `Workspace database is in state "${state.status}", not "ready" — the app must not start ` +
          'against it. Re-run `db:provision` to rebuild it (or `teardown` to release it).',
      )
    }
    const missingUrls = DB_ENV_VARS.filter((name) => !managedVarsInFile(envFilePath()).includes(name))
    if (missingUrls.length > 0) {
      throw new FatalError(
        `${envFilePath()} does not define ${missingUrls.join(', ')} for this workspace. Re-run ` +
          '`db:provision`. (An ambient DATABASE_URL does not count — that is the shared database.)',
      )
    }

    const projectId = requireEnv('NEON_PROJECT_ID')
    requireEnv('NEON_API_KEY')
    assertProjectMatches(state, projectId)

    const branch = await withRetry('verify recorded branch', () => deps.neon.getBranchById(projectId, state.branchId as string), idempotent(deps, 3))
    if (!branch) {
      throw new FatalError(`Recorded branch ${state.branchId} no longer exists in Neon — re-run \`db:provision\` to recreate it.`)
    }

    // The NAME may have changed on either side. Neon's is authoritative for display; a name that now
    // matches some other workspace's identity is NOT a reason to switch branches.
    if (branch.name !== state.branchName) {
      deps.log(`[neondb-branch] recorded branch ${state.branchId} is now named "${branch.name}" (was "${state.branchName}") — refreshing the display name.`)
      writeState({ ...state, branchName: branch.name })
    }

    // Purely informational. Identity is not ownership: an unresolvable identity (detached HEAD) is
    // no reason to block a workspace whose recorded branch is verified and ready.
    let currentIdentityName: string | null = null
    try {
      currentIdentityName = workspaceBranchName(resolveWorkspaceName(process.env, process.cwd(), currentGitContext(process.cwd())))
    } catch {
      currentIdentityName = null
    }
    if (currentIdentityName !== null && currentIdentityName !== branch.name) {
      deps.log(
        `[neondb-branch] this checkout's identity would name a branch "${currentIdentityName}", but ` +
          `it owns ${state.branchId} ("${branch.name}"). Keeping the recorded database — a git ` +
          'branch change or workspace rename never switches database ownership. Run `db:provision` ' +
          'if you deliberately want a fresh database for the new identity.',
      )
    }
  } finally {
    releaseLock()
  }
}

export async function teardown(deps: Deps = defaultDeps()): Promise<void> {
  const releaseLock = acquireLock('teardown')
  let released = false
  try {
    const state = readState() // also rejects the legacy format
    if (!state) {
      deps.log('[neondb-branch] nothing recorded for this workspace — nothing to tear down.')
      stripEnvVars(envFilePath(), DB_ENV_VARS)
      return
    }
    const projectId = requireEnv('NEON_PROJECT_ID')
    requireEnv('NEON_API_KEY')
    assertProjectMatches(state, projectId)

    if (state.status === 'creating') {
      throw new FatalError(
        `${stateFilePath()} records an UNRESOLVED branch creation (status "creating", no id). There ` +
          'is no id to delete and a name is not proof of ownership, so teardown will not guess. ' +
          `Check project ${projectId} for a branch named "${state.branchName}", delete it in the ` +
          `Neon console if it is yours, then delete ${stateFilePath()}.`,
      )
    }

    const branchId = state.branchId as string
    writeState({ ...state, status: 'deleting' })

    deps.log(`[neon] deleting branch ${branchId} (${state.branchName})…`)
    const outcome = await withRetry('delete branch', () => deps.neon.deleteBranch(projectId, branchId), idempotent(deps, 4))
    if (outcome === 'absent') deps.log(`[neondb-branch] branch ${branchId} was already gone — treating as torn down.`)

    // Neon deletes are asynchronous, and a lost or delayed response says nothing about whether the
    // branch is gone: confirm by reading it back, and keep the `deleting` record until it is absent.
    await withRetry(
      'confirm branch deletion',
      async () => {
        const still = await deps.neon.getBranchById(projectId, branchId)
        if (still) throw new Error(`branch ${branchId} still present (state: ${still.current_state ?? 'unknown'})`)
      },
      idempotent(deps, 5),
    )

    stripEnvVars(envFilePath(), DB_ENV_VARS)
    clearState()
    releaseLock()
    released = true
    // Only after the lock file itself is gone can the directory be empty. Never recursive: anything
    // else the project keeps in .neondb/ is not ours to delete.
    if (removeStateDirIfEmpty()) deps.log(`[neondb-branch] removed empty ${stateDir()}/`)
    deps.log('✅ [neondb-branch] workspace database torn down.')
  } finally {
    if (!released) releaseLock()
  }
}

async function main(): Promise<void> {
  loadEnvFile() // .env.neondb, never overriding an already-set var
  const mode = process.argv[2]
  try {
    if (mode === 'provision') await provision()
    else if (mode === 'teardown') await teardown()
    else if (mode === 'sync') await sync()
    else {
      console.error('Usage: tsx scripts/neondb-branch.ts <provision|sync|teardown>')
      process.exit(2)
    }
  } catch (error) {
    console.error(`❌ [neondb-branch] ${mode ?? '(no mode)'} failed:`, error instanceof Error ? error.message : error)
    process.exit(1)
  }
}

// Run only when executed directly, so unit tests can import the helpers above without the CLI.
if (process.argv[1] && /neondb-branch\.[cm]?[jt]s$/.test(process.argv[1])) {
  void main()
}
