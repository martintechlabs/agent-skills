// Unit tests for the safety-critical pure helpers in scripts/conductor-db.ts.
// When you copy this into a project, adjust the import path to your layout
// (e.g. `../../scripts/conductor-db` from `__tests__/scripts/`). Runs under Jest or Vitest.
import { createHash } from 'node:crypto'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  assertDisposableChildBranch,
  buildDrizzleBaselineSql,
  buildPrismaBaselineSql,
  readBranchState,
  setupIsPending,
  withRetry,
  workspaceBranchName,
  writeBranchState,
} from '../scripts/conductor-db'

describe('conductor-db helpers', () => {
  const ORIGINAL_ENV = process.env
  const ORIGINAL_CWD = process.cwd()
  let sandbox: string

  // The state-file helpers read/write .conductor/db-branch relative to the CWD. Run the whole
  // suite from a throwaway directory so the tests can never touch (or destroy, if interrupted)
  // the REAL state file of the workspace they happen to run inside.
  beforeAll(() => {
    sandbox = mkdtempSync(join(tmpdir(), 'conductor-db-test-'))
    process.chdir(sandbox)
  })

  beforeEach(() => {
    process.env = { ...ORIGINAL_ENV }
  })

  afterAll(() => {
    process.env = ORIGINAL_ENV
    process.chdir(ORIGINAL_CWD)
    rmSync(sandbox, { recursive: true, force: true })
  })

  describe('workspaceBranchName', () => {
    it('slugifies a short workspace name into a clean conductor/ branch (no hash suffix)', () => {
      process.env.CONDUCTOR_WORKSPACE_NAME = 'My Cool Feature!'
      expect(workspaceBranchName()).toBe('conductor/my-cool-feature')
    })

    it('collapses separator runs and trims leading/trailing separators', () => {
      process.env.CONDUCTOR_WORKSPACE_NAME = '  Feature / 123 -- test  '
      expect(workspaceBranchName()).toBe('conductor/feature-123-test')
    })

    it('truncates an over-long name and appends a hash suffix, never ending in a separator', () => {
      process.env.CONDUCTOR_WORKSPACE_NAME = 'a'.repeat(100)
      const name = workspaceBranchName()
      expect(name).toMatch(/^conductor\/a{39}-[0-9a-f]{8}$/)
      expect(name).not.toMatch(/-$/)
      expect(name.length).toBeLessThanOrEqual('conductor/'.length + 48)
    })

    it('re-trims a separator left dangling by truncation before the hash (no "--")', () => {
      // slug "a*38-b*20" is 59 chars; slice(0, 39) lands on the "-", which must be trimmed off.
      process.env.CONDUCTOR_WORKSPACE_NAME = 'a'.repeat(38) + ' ' + 'b'.repeat(20)
      const name = workspaceBranchName()
      expect(name).toMatch(/^conductor\/a{38}-[0-9a-f]{8}$/)
      expect(name).not.toContain('--')
    })

    it('gives distinct branches to distinct long names sharing a truncated prefix (no collision)', () => {
      const prefix = 'shared-prefix-that-is-definitely-longer-than-forty-eight-characters-'
      process.env.CONDUCTOR_WORKSPACE_NAME = `${prefix}alpha`
      const a = workspaceBranchName()
      process.env.CONDUCTOR_WORKSPACE_NAME = `${prefix}beta`
      const b = workspaceBranchName()
      expect(a).not.toBe(b)
    })

    it('throws a clear error when the workspace name is missing', () => {
      delete process.env.CONDUCTOR_WORKSPACE_NAME
      expect(() => workspaceBranchName()).toThrow(/CONDUCTOR_WORKSPACE_NAME is required/)
    })

    it('throws when the name has no usable characters', () => {
      process.env.CONDUCTOR_WORKSPACE_NAME = '@@@'
      expect(() => workspaceBranchName()).toThrow(/Could not derive a branch name/)
    })
  })

  describe('assertDisposableChildBranch (production-safety guard)', () => {
    it('allows a conductor/ workspace branch', () => {
      expect(() => assertDisposableChildBranch('conductor/my-feature', 'production')).not.toThrow()
    })

    it('refuses a branch that is not conductor/ prefixed (e.g. production)', () => {
      expect(() => assertDisposableChildBranch('production', 'production')).toThrow(/workspace branch/)
      expect(() => assertDisposableChildBranch('development', 'production')).toThrow(/workspace branch/)
    })

    it('refuses operating on the parent branch even if it were conductor/ prefixed', () => {
      expect(() => assertDisposableChildBranch('conductor/x', 'conductor/x')).toThrow(/parent branch/)
    })
  })

  describe('readBranchState / writeBranchState / setupIsPending (rename- and crash-safety)', () => {
    // The suite-level chdir sandbox (above) means there is no real state file to protect here;
    // each test starts from whatever the previous one wrote, so clean up after each.
    afterEach(() => {
      rmSync('.conductor/db-branch', { force: true })
    })

    it('returns null when no state file has been written', () => {
      expect(readBranchState()).toBeNull()
    })

    it('creates the .conductor directory if missing and round-trips the branch name', () => {
      writeBranchState('conductor/my-feature')
      expect(readBranchState()).toBe('conductor/my-feature')
    })

    it('survives a simulated rename — teardown reads the ORIGINAL name, not one re-derived from a new CONDUCTOR_WORKSPACE_NAME', () => {
      process.env.CONDUCTOR_WORKSPACE_NAME = 'original-name'
      writeBranchState(workspaceBranchName())

      process.env.CONDUCTOR_WORKSPACE_NAME = 'renamed-workspace'
      expect(workspaceBranchName()).toBe('conductor/renamed-workspace') // re-deriving now gives a DIFFERENT (wrong) name
      expect(readBranchState()).toBe('conductor/original-name') // but the recorded name is still correct
    })

    it('defaults to ready — no file, and a plain write, are both "setup complete"', () => {
      expect(setupIsPending()).toBe(false) // absent file
      writeBranchState('conductor/my-feature') // default phase: ready
      expect(setupIsPending()).toBe(false)
    })

    it('tracks the pending → ready lifecycle provision() uses for crash recovery', () => {
      writeBranchState('conductor/my-feature', 'pending') // written right after branch create
      expect(setupIsPending()).toBe(true)
      expect(readBranchState()).toBe('conductor/my-feature')
      writeBranchState('conductor/my-feature', 'ready') // written after baseline + seed succeed
      expect(setupIsPending()).toBe(false)
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

    it('retries a rejected async operation the same way (used for the Drizzle execSql baseline)', async () => {
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
  })

  describe('buildPrismaBaselineSql', () => {
    it('returns null when there are no migrations', () => {
      expect(buildPrismaBaselineSql([])).toBeNull()
    })

    it('emits one _prisma_migrations row per migration with Prisma sha256 checksums', () => {
      const migrations = [
        { name: '0001_init', sql: 'CREATE TABLE "A" ();' },
        { name: '0002_more', sql: 'ALTER TABLE "A" ADD b int;' },
      ]
      const sql = buildPrismaBaselineSql(migrations)!
      expect(sql).toContain('INSERT INTO "_prisma_migrations"')
      for (const { name, sql: body } of migrations) {
        expect(sql).toContain(`'${name}'`)
        expect(sql).toContain(createHash('sha256').update(body).digest('hex'))
      }
    })

    it('is idempotent — only inserts migrations not already recorded', () => {
      const sql = buildPrismaBaselineSql([{ name: '0001_init', sql: 'x' }])!
      expect(sql).toMatch(/WHERE NOT EXISTS/i)
      expect(sql).toContain('e.migration_name = m.migration_name')
    })

    it('escapes single quotes in migration names (valid SQL literal)', () => {
      const sql = buildPrismaBaselineSql([{ name: "0001_o'brien", sql: 'x' }])!
      expect(sql).toContain("'0001_o''brien'")
    })
  })

  describe('buildDrizzleBaselineSql', () => {
    it('returns null when there are no migrations', () => {
      expect(buildDrizzleBaselineSql([])).toBeNull()
    })

    it('targets drizzle.__drizzle_migrations and ensures the table exists', () => {
      const sql = buildDrizzleBaselineSql([{ sql: 'CREATE TABLE "A" ();', when: 1700000000000 }])!
      expect(sql).toContain('CREATE SCHEMA IF NOT EXISTS "drizzle"')
      expect(sql).toContain('CREATE TABLE IF NOT EXISTS "drizzle"."__drizzle_migrations"')
      expect(sql).toContain('INSERT INTO "drizzle"."__drizzle_migrations" (hash, created_at)')
    })

    it('emits one row per migration: sha256 of the file contents + the journal `when`', () => {
      const migrations = [
        { sql: 'CREATE TABLE "A" ();', when: 1700000000000 },
        { sql: 'ALTER TABLE "A" ADD b int;', when: 1700000005000 },
      ]
      const sql = buildDrizzleBaselineSql(migrations)!
      for (const { sql: body, when } of migrations) {
        const hash = createHash('sha256').update(body).digest('hex')
        expect(sql).toContain(`('${hash}', ${when})`)
      }
    })

    it('is idempotent — only inserts migrations not already recorded', () => {
      const sql = buildDrizzleBaselineSql([{ sql: 'x', when: 1700000000000 }])!
      expect(sql).toMatch(/WHERE NOT EXISTS/i)
      expect(sql).toContain('e.hash = m.hash')
    })
  })
})
