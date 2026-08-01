// Unit tests for the safety-critical pure helpers in scripts/neondb-branch.ts.
// When you copy this into a project, adjust the import path to your layout
// (e.g. `../../scripts/neondb-branch` from `__tests__/scripts/`). Runs under Jest or Vitest.
import { createHash } from 'node:crypto'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  assertDisposableChildBranch,
  assertDisposableCheckBranch,
  buildDrizzleLedgerBaselineSql,
  buildPrismaLedgerBaselineSql,
  checkBranchName,
  clearCheckBranchState,
  FatalError,
  loadEnvFile,
  readBranchState,
  readCheckBranchState,
  resolveWorkspaceName,
  setupIsPending,
  stripEnvVars,
  upsertEnvVars,
  withRetry,
  workspaceBranchName,
  writeBranchState,
  writeCheckBranchState,
  type GitContext,
} from '../scripts/neondb-branch'

describe('neondb-branch helpers', () => {
  const ORIGINAL_ENV = process.env
  let sandbox: string

  // Point the state-file helpers at a throwaway directory (via the script's test-only
  // NEONDB_BRANCH_STATE_FILE override) so the tests can never touch — or destroy, if the run is
  // interrupted — the REAL .neondb/branch of the workspace they happen to run inside.
  // (No process.chdir(): it is unsupported in worker threads, e.g. Vitest's threads pool.)
  beforeAll(() => {
    sandbox = mkdtempSync(join(tmpdir(), 'neondb-branch-test-'))
    ORIGINAL_ENV.NEONDB_BRANCH_STATE_FILE = join(sandbox, '.neondb', 'branch')
  })

  beforeEach(() => {
    process.env = { ...ORIGINAL_ENV }
  })

  afterAll(() => {
    delete ORIGINAL_ENV.NEONDB_BRANCH_STATE_FILE
    process.env = ORIGINAL_ENV
    rmSync(sandbox, { recursive: true, force: true })
  })

  describe('resolveWorkspaceName (workspace identity precedence)', () => {
    const worktree: GitContext = { isSecondaryWorktree: true, branch: 'martintechlabs/feature-x' }
    const singleClone: GitContext = { isSecondaryWorktree: false, branch: 'martintechlabs/feature-x' }
    const noIdentity: GitContext = { isSecondaryWorktree: false, branch: null }

    it('prefers CONDUCTOR_WORKSPACE_NAME over every other source', () => {
      const env = { CONDUCTOR_WORKSPACE_NAME: 'conductor-ws', ORCA_WORKSPACE_NAME: 'orca-ws', WORKSPACE_NAME: 'general-ws' }
      expect(resolveWorkspaceName(env, '/work/trees/mojarra', worktree)).toBe('conductor-ws')
    })

    it('prefers ORCA_WORKSPACE_NAME over WORKSPACE_NAME and checkout signals', () => {
      const env = { ORCA_WORKSPACE_NAME: 'orca-ws', WORKSPACE_NAME: 'general-ws' }
      expect(resolveWorkspaceName(env, '/work/trees/mojarra', worktree)).toBe('orca-ws')
    })

    it('falls back to WORKSPACE_NAME when no tool-specific var is set', () => {
      expect(resolveWorkspaceName({ WORKSPACE_NAME: 'general-ws' }, '/work/trees/mojarra', worktree)).toBe('general-ws')
    })

    it('falls back to the checkout directory basename for a secondary git worktree with no env vars', () => {
      expect(resolveWorkspaceName({}, '/Users/dev/workspaces/mojarra', worktree)).toBe('mojarra')
    })

    it('falls back to the current git branch for a plain single-clone checkout with no env vars', () => {
      expect(resolveWorkspaceName({}, '/Users/dev/myrepo', singleClone)).toBe('martintechlabs/feature-x')
    })

    it('throws a clear error when nothing resolves (no env vars, not a worktree, detached HEAD)', () => {
      expect(() => resolveWorkspaceName({}, '/Users/dev/myrepo', noIdentity)).toThrow(/Could not determine workspace identity/)
    })
  })

  describe('workspaceBranchName / checkBranchName (given an already-resolved raw identity)', () => {
    it('slugifies a short identity into a clean workspace/ branch (no hash suffix)', () => {
      expect(workspaceBranchName('My Cool Feature!')).toBe('workspace/my-cool-feature')
    })

    it('collapses separator runs and trims leading/trailing separators', () => {
      expect(workspaceBranchName('  Feature / 123 -- test  ')).toBe('workspace/feature-123-test')
    })

    it('truncates an over-long identity and appends a hash suffix, never ending in a separator', () => {
      const raw = 'a'.repeat(100)
      const name = workspaceBranchName(raw)
      expect(name).toMatch(/^workspace\/a{39}-[0-9a-f]{8}$/)
      expect(name).not.toMatch(/-$/)
      expect(name.length).toBeLessThanOrEqual('workspace/'.length + 48)
    })

    it('re-trims a separator left dangling by truncation before the hash (no "--")', () => {
      const raw = 'a'.repeat(38) + ' ' + 'b'.repeat(20)
      const name = workspaceBranchName(raw)
      expect(name).toMatch(/^workspace\/a{38}-[0-9a-f]{8}$/)
      expect(name).not.toContain('--')
    })

    it('gives distinct branches to distinct long identities sharing a truncated prefix (no collision)', () => {
      const prefix = 'shared-prefix-that-is-definitely-longer-than-forty-eight-characters-'
      expect(workspaceBranchName(`${prefix}alpha`)).not.toBe(workspaceBranchName(`${prefix}beta`))
    })

    it('throws when the identity has no usable characters', () => {
      expect(() => workspaceBranchName('@@@')).toThrow(/Could not derive a branch name/)
    })

    it('checkBranchName shares workspaceBranchName\'s slug but under the tmp/ prefix', () => {
      expect(checkBranchName('My Cool Feature!')).toBe('tmp/my-cool-feature')
      expect(checkBranchName('My Cool Feature!')).not.toBe(workspaceBranchName('My Cool Feature!'))
    })

    it('truncates and hashes independently of workspaceBranchName, never colliding across the two prefixes', () => {
      const raw = 'a'.repeat(100)
      expect(checkBranchName(raw)).toMatch(/^tmp\/a{39}-[0-9a-f]{8}$/)
      expect(checkBranchName(raw).slice('tmp/'.length)).toBe(workspaceBranchName(raw).slice('workspace/'.length))
    })
  })

  describe('assertDisposableChildBranch (production-safety guard)', () => {
    it('allows a workspace/ workspace branch', () => {
      expect(() => assertDisposableChildBranch('workspace/my-feature', 'production')).not.toThrow()
    })

    it('allows a tmp/ check branch', () => {
      expect(() => assertDisposableChildBranch('tmp/my-feature', 'production')).not.toThrow()
    })

    it('refuses a branch that is neither workspace/ nor tmp/ prefixed (e.g. production)', () => {
      expect(() => assertDisposableChildBranch('production', 'production')).toThrow(/workspace branch/)
      expect(() => assertDisposableChildBranch('development', 'production')).toThrow(/workspace branch/)
    })

    it('refuses operating on the parent branch even if it were workspace/ prefixed', () => {
      expect(() => assertDisposableChildBranch('workspace/x', 'workspace/x')).toThrow(/parent branch/)
    })
  })

  describe('assertDisposableCheckBranch (stricter: tmp/ only, not workspace/)', () => {
    it('allows a tmp/ check branch', () => {
      expect(() => assertDisposableCheckBranch('tmp/my-feature', 'production')).not.toThrow()
    })

    it('refuses a workspace/ workspace branch even though assertDisposableChildBranch would allow it', () => {
      expect(() => assertDisposableCheckBranch('workspace/my-feature', 'production')).toThrow(/check branch/)
    })

    it('refuses operating on the parent branch', () => {
      expect(() => assertDisposableCheckBranch('tmp/x', 'tmp/x')).toThrow(/parent branch/)
    })
  })

  describe('readBranchState / writeBranchState / setupIsPending (rename- and crash-safety)', () => {
    // The suite-level sandbox (above) means there is no real state file to protect here; each
    // test starts from whatever the previous one wrote, so clean up after each.
    afterEach(() => {
      rmSync(process.env.NEONDB_BRANCH_STATE_FILE!, { force: true })
    })

    it('returns null when no state file has been written', () => {
      expect(readBranchState()).toBeNull()
    })

    it('creates the .neondb directory if missing and round-trips the branch name', () => {
      writeBranchState('workspace/my-feature')
      expect(readBranchState()).toBe('workspace/my-feature')
    })

    it('survives a simulated rename — teardown reads the ORIGINAL name, not one re-derived from a new identity', () => {
      writeBranchState(workspaceBranchName('original-name'))

      expect(workspaceBranchName('renamed-workspace')).toBe('workspace/renamed-workspace') // re-deriving now gives a DIFFERENT (wrong) name
      expect(readBranchState()).toBe('workspace/original-name') // but the recorded name is still correct
    })

    it('defaults to ready — no file, and a plain write, are both "setup complete"', () => {
      expect(setupIsPending()).toBe(false) // absent file
      writeBranchState('workspace/my-feature') // default phase: ready
      expect(setupIsPending()).toBe(false)
    })

    it('tracks the pending → ready lifecycle provision() uses for crash recovery', () => {
      writeBranchState('workspace/my-feature', 'pending') // written right after branch create
      expect(setupIsPending()).toBe(true)
      expect(readBranchState()).toBe('workspace/my-feature')
      writeBranchState('workspace/my-feature', 'ready') // written after baseline + deploy + seed succeed
      expect(setupIsPending()).toBe(false)
    })
  })

  describe('readCheckBranchState / writeCheckBranchState / clearCheckBranchState (check-branch leak tracking)', () => {
    afterEach(() => {
      clearCheckBranchState()
    })

    it('returns null when nothing is recorded', () => {
      expect(readCheckBranchState()).toBeNull()
    })

    it('round-trips the check branch name, independent of the workspace-branch state file', () => {
      writeBranchState('workspace/my-feature')
      writeCheckBranchState('tmp/my-feature')
      expect(readCheckBranchState()).toBe('tmp/my-feature')
      expect(readBranchState()).toBe('workspace/my-feature') // unaffected by the check-branch record
    })

    it('clears cleanly, leaving the workspace-branch record untouched', () => {
      writeBranchState('workspace/my-feature')
      writeCheckBranchState('tmp/my-feature')
      clearCheckBranchState()
      expect(readCheckBranchState()).toBeNull()
      expect(readBranchState()).toBe('workspace/my-feature')
    })
  })

  describe('withRetry (cold-compute backoff)', () => {
    it('returns the result on first success without sleeping', async () => {
      const waits: number[] = []
      await expect(withRetry('op', () => 'ok', 3, (ms) => waits.push(ms))).resolves.toBe('ok')
      expect(waits).toEqual([])
    })

    it('retries transient failures with exponential backoff (2s, 4s, …), then succeeds', async () => {
      const waits: number[] = []
      let calls = 0
      const result = await withRetry(
        'op',
        () => {
          calls += 1
          if (calls < 3) throw new Error('the endpoint is not ready yet')
          return 'ok'
        },
        5,
        (ms) => waits.push(ms),
      )
      expect(result).toBe('ok')
      expect(calls).toBe(3)
      expect(waits).toEqual([2000, 4000])
    })

    it('retries a rejected async operation the same way (used for the execSql true-baseline read/write)', async () => {
      const waits: number[] = []
      let calls = 0
      const result = await withRetry(
        'op',
        async () => {
          calls += 1
          if (calls < 2) throw new Error('compute still booting')
          return 'ok'
        },
        3,
        (ms) => waits.push(ms),
      )
      expect(result).toBe('ok')
      expect(waits).toEqual([2000])
    })

    it('rejects with the last error once attempts are exhausted', async () => {
      const waits: number[] = []
      await expect(
        withRetry(
          'op',
          () => {
            throw new Error('still booting')
          },
          3,
          (ms) => waits.push(ms),
        ),
      ).rejects.toThrow('still booting')
      expect(waits).toEqual([2000, 4000])
    })

    it('never retries a FatalError — misconfiguration surfaces immediately, with no backoff', async () => {
      const waits: number[] = []
      let calls = 0
      await expect(
        withRetry(
          'op',
          () => {
            calls += 1
            throw new FatalError('execSql() is not configured')
          },
          6,
          (ms) => waits.push(ms),
        ),
      ).rejects.toThrow('execSql() is not configured')
      expect(calls).toBe(1)
      expect(waits).toEqual([])
    })
  })

  describe('buildPrismaLedgerBaselineSql (seeds _prisma_migrations from the parent\'s TRUE ledger)', () => {
    it('returns null when the parent has nothing genuinely applied yet', () => {
      expect(buildPrismaLedgerBaselineSql([])).toBeNull()
    })

    it('emits one _prisma_migrations row per captured ledger row, verbatim (no local re-derivation)', () => {
      const rows = [
        { checksum: createHash('sha256').update('a').digest('hex'), migration_name: '0001_init' },
        { checksum: createHash('sha256').update('b').digest('hex'), migration_name: '0002_more' },
      ]
      const sql = buildPrismaLedgerBaselineSql(rows)!
      expect(sql).toContain('INSERT INTO "_prisma_migrations"')
      for (const { checksum, migration_name } of rows) {
        expect(sql).toContain(`'${migration_name}'`)
        expect(sql).toContain(checksum)
      }
    })

    it('is idempotent — only inserts migrations not already recorded', () => {
      const sql = buildPrismaLedgerBaselineSql([{ checksum: 'a'.repeat(64), migration_name: '0001_init' }])!
      expect(sql).toMatch(/WHERE NOT EXISTS/i)
      expect(sql).toContain('e.migration_name = m.migration_name')
    })

    it('escapes single quotes in migration names (valid SQL literal)', () => {
      const sql = buildPrismaLedgerBaselineSql([{ checksum: 'a'.repeat(64), migration_name: "0001_o'brien" }])!
      expect(sql).toContain("'0001_o''brien'")
    })

    it('rejects a non-hex checksum instead of splicing it into SQL', () => {
      expect(() =>
        buildPrismaLedgerBaselineSql([{ checksum: "'); DROP SCHEMA public CASCADE; --", migration_name: '0001_init' }]),
      ).toThrow(/non-hex checksum/)
    })
  })

  describe('buildDrizzleLedgerBaselineSql (seeds drizzle.__drizzle_migrations from the parent\'s TRUE ledger)', () => {
    it('returns null when the parent has nothing genuinely applied yet', () => {
      expect(buildDrizzleLedgerBaselineSql([])).toBeNull()
    })

    it('targets drizzle.__drizzle_migrations and ensures the table exists', () => {
      const sql = buildDrizzleLedgerBaselineSql([{ hash: createHash('sha256').update('x').digest('hex'), created_at: 1700000000000 }])!
      expect(sql).toContain('CREATE SCHEMA IF NOT EXISTS "drizzle"')
      expect(sql).toContain('CREATE TABLE IF NOT EXISTS "drizzle"."__drizzle_migrations"')
      expect(sql).toContain('INSERT INTO "drizzle"."__drizzle_migrations" (hash, created_at)')
    })

    it('emits one row per captured ledger row, verbatim (no local re-derivation)', () => {
      const rows = [
        { hash: createHash('sha256').update('a').digest('hex'), created_at: 1700000000000 },
        { hash: createHash('sha256').update('b').digest('hex'), created_at: 1700000005000 },
      ]
      const sql = buildDrizzleLedgerBaselineSql(rows)!
      for (const { hash, created_at } of rows) {
        expect(sql).toContain(`('${hash}', ${created_at})`)
      }
    })

    it('accepts a stringified created_at (as Postgres bigint columns come back over some drivers)', () => {
      const hash = createHash('sha256').update('x').digest('hex')
      const sql = buildDrizzleLedgerBaselineSql([{ hash, created_at: '1700000000000' }])!
      expect(sql).toContain(`('${hash}', 1700000000000)`)
    })

    it('is idempotent — only inserts migrations not already recorded', () => {
      const sql = buildDrizzleLedgerBaselineSql([{ hash: 'a'.repeat(64), created_at: 1700000000000 }])!
      expect(sql).toMatch(/WHERE NOT EXISTS/i)
      expect(sql).toContain('e.hash = m.hash')
    })

    it('rejects a non-hex hash instead of splicing it into SQL', () => {
      expect(() =>
        buildDrizzleLedgerBaselineSql([{ hash: "'); DROP SCHEMA public CASCADE; --", created_at: 1700000000000 }]),
      ).toThrow(/non-hex hash/)
    })

    it('rejects a created_at that is not a plain non-negative integer instead of splicing it into SQL', () => {
      const hash = 'a'.repeat(64)
      expect(() => buildDrizzleLedgerBaselineSql([{ hash, created_at: NaN }])).toThrow(/non-integer created_at/)
      expect(() => buildDrizzleLedgerBaselineSql([{ hash, created_at: 1700000000000.5 }])).toThrow(/non-integer created_at/) // Postgres would silently round it
      expect(() => buildDrizzleLedgerBaselineSql([{ hash, created_at: 1e21 }])).toThrow(/non-integer created_at/) // serializes as "1e+21", not a bigint literal
      expect(() => buildDrizzleLedgerBaselineSql([{ hash, created_at: -1 }])).toThrow(/non-integer created_at/)
      expect(() => buildDrizzleLedgerBaselineSql([{ hash, created_at: "0),('x',0); DROP SCHEMA public CASCADE; --" }])).toThrow(
        /non-integer created_at/,
      )
    })
  })

  describe('upsertEnvVars / stripEnvVars (.env.neondb is upserted in place, never truncated)', () => {
    let envFile: string

    beforeEach(() => {
      envFile = join(sandbox, `.env.neondb.${Math.random().toString(36).slice(2)}`)
    })

    afterEach(() => {
      rmSync(envFile, { force: true })
    })

    it('creates the file with the given vars when none existed', () => {
      upsertEnvVars(envFile, { DATABASE_URL: 'postgres://a', NEON_API_KEY: 'k' })
      const content = readFileSync(envFile, 'utf8')
      expect(content).toContain("DATABASE_URL='postgres://a'")
      expect(content).toContain("NEON_API_KEY='k'")
    })

    it('updates an existing key in place, preserving unrelated lines', () => {
      writeFileSync(envFile, "# a comment\nDATABASE_URL='old'\nOTHER_VAR='keep-me'\n")
      upsertEnvVars(envFile, { DATABASE_URL: 'postgres://new' })
      const content = readFileSync(envFile, 'utf8')
      expect(content).toContain('# a comment')
      expect(content).toContain("DATABASE_URL='postgres://new'")
      expect(content).not.toContain('old')
      expect(content).toContain("OTHER_VAR='keep-me'")
    })

    it('appends a var that is not present yet, preserving everything else', () => {
      writeFileSync(envFile, "OTHER_VAR='keep-me'\n")
      upsertEnvVars(envFile, { DATABASE_URL: 'postgres://a' })
      const content = readFileSync(envFile, 'utf8')
      expect(content).toContain("OTHER_VAR='keep-me'")
      expect(content).toContain("DATABASE_URL='postgres://a'")
    })

    it('upserts multiple keys in one call (DATABASE_URL plus the three Neon control vars)', () => {
      upsertEnvVars(envFile, {
        DATABASE_URL: 'postgres://a',
        NEON_API_KEY: 'k',
        NEON_PROJECT_ID: 'p',
        NEON_PARENT_BRANCH: 'production',
      })
      const content = readFileSync(envFile, 'utf8')
      for (const line of ["DATABASE_URL='postgres://a'", "NEON_API_KEY='k'", "NEON_PROJECT_ID='p'", "NEON_PARENT_BRANCH='production'"]) {
        expect(content).toContain(line)
      }
    })

    it('stripEnvVars removes just the given keys, preserving the rest', () => {
      writeFileSync(envFile, "DATABASE_URL='postgres://a'\nNEON_API_KEY='k'\n")
      stripEnvVars(envFile, ['DATABASE_URL'])
      const content = readFileSync(envFile, 'utf8')
      expect(content).not.toContain('DATABASE_URL')
      expect(content).toContain("NEON_API_KEY='k'")
    })

    it('stripEnvVars deletes the file entirely when nothing is left', () => {
      writeFileSync(envFile, "DATABASE_URL='postgres://a'\n")
      stripEnvVars(envFile, ['DATABASE_URL'])
      expect(existsSync(envFile)).toBe(false)
    })

    it('stripEnvVars is a no-op when the file does not exist', () => {
      expect(() => stripEnvVars(envFile, ['DATABASE_URL'])).not.toThrow()
      expect(existsSync(envFile)).toBe(false)
    })
  })

  describe('main() loads .env.neondb before dispatching (never overriding an already-set var)', () => {
    let envFile: string

    beforeEach(() => {
      envFile = join(sandbox, '.env.neondb')
      process.env.NEONDB_BRANCH_ENV_FILE = envFile
    })

    afterEach(() => {
      delete process.env.NEONDB_BRANCH_ENV_FILE
      delete process.env.NEON_PROJECT_ID
      rmSync(envFile, { force: true })
    })

    it('populates process.env from the file when the var is not already set', () => {
      writeFileSync(envFile, "NEON_PROJECT_ID='from-file'\n")
      loadEnvFile()
      expect(process.env.NEON_PROJECT_ID).toBe('from-file')
    })

    it('never overrides a var already present in process.env', () => {
      process.env.NEON_PROJECT_ID = 'from-shell'
      writeFileSync(envFile, "NEON_PROJECT_ID='from-file'\n")
      loadEnvFile()
      expect(process.env.NEON_PROJECT_ID).toBe('from-shell')
    })

    it('is a no-op when the file does not exist', () => {
      expect(() => loadEnvFile()).not.toThrow()
    })
  })
})
