// Unit tests for the safety-critical pure helpers in scripts/conductor-db.ts.
// When you copy this into a project, adjust the import path to your layout
// (e.g. `../../scripts/conductor-db` from `__tests__/scripts/`). Runs under Jest or Vitest.
import { createHash } from 'node:crypto'
import { mkdtempSync, rmSync } from 'node:fs'
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
  legacyWorkspaceBranchName,
  readBranchState,
  readCheckBranchState,
  setupIsPending,
  withRetry,
  workspaceBranchName,
  writeBranchState,
  writeCheckBranchState,
} from '../scripts/conductor-db'

describe('conductor-db helpers', () => {
  const ORIGINAL_ENV = process.env
  let sandbox: string

  // Point the state-file helpers at a throwaway directory (via the script's test-only
  // CONDUCTOR_DB_STATE_FILE override) so the tests can never touch — or destroy, if the run is
  // interrupted — the REAL .conductor/db-branch of the workspace they happen to run inside.
  // (No process.chdir(): it is unsupported in worker threads, e.g. Vitest's threads pool.)
  beforeAll(() => {
    sandbox = mkdtempSync(join(tmpdir(), 'conductor-db-test-'))
    ORIGINAL_ENV.CONDUCTOR_DB_STATE_FILE = join(sandbox, '.conductor', 'db-branch')
  })

  beforeEach(() => {
    process.env = { ...ORIGINAL_ENV }
  })

  afterAll(() => {
    delete ORIGINAL_ENV.CONDUCTOR_DB_STATE_FILE
    process.env = ORIGINAL_ENV
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

    it('throws a clear error when the workspace name is missing — without telling the user to set the Conductor-injected variable themselves', () => {
      delete process.env.CONDUCTOR_WORKSPACE_NAME
      expect(() => workspaceBranchName()).toThrow(/CONDUCTOR_WORKSPACE_NAME is not set/)
      expect(() => workspaceBranchName()).toThrow(/Do NOT add it to the Conductor env tabs/)
    })

    it('throws when the name has no usable characters', () => {
      process.env.CONDUCTOR_WORKSPACE_NAME = '@@@'
      expect(() => workspaceBranchName()).toThrow(/Could not derive a branch name/)
    })
  })

  describe('checkBranchName (disposable per-run branch used to learn the true migration ledger)', () => {
    it('shares workspaceBranchName\'s slug but under the tmp/ prefix', () => {
      process.env.CONDUCTOR_WORKSPACE_NAME = 'My Cool Feature!'
      expect(checkBranchName()).toBe('tmp/my-cool-feature')
      expect(checkBranchName()).not.toBe(workspaceBranchName())
    })

    it('truncates and hashes independently of workspaceBranchName, never colliding across the two prefixes', () => {
      process.env.CONDUCTOR_WORKSPACE_NAME = 'a'.repeat(100)
      expect(checkBranchName()).toMatch(/^tmp\/a{39}-[0-9a-f]{8}$/)
      expect(checkBranchName().slice('tmp/'.length)).toBe(workspaceBranchName().slice('conductor/'.length))
    })
  })

  describe('legacyWorkspaceBranchName (pre-hash-suffix fallback)', () => {
    it('is null for short names — old and new derivations agree', () => {
      process.env.CONDUCTOR_WORKSPACE_NAME = 'My Cool Feature!'
      expect(legacyWorkspaceBranchName()).toBeNull()
    })

    it('returns the old flat 48-char truncation for long names, so pre-upgrade branches stay findable', () => {
      process.env.CONDUCTOR_WORKSPACE_NAME = 'a'.repeat(100)
      expect(legacyWorkspaceBranchName()).toBe(`conductor/${'a'.repeat(48)}`)
      expect(legacyWorkspaceBranchName()).not.toBe(workspaceBranchName())
    })
  })

  describe('assertDisposableChildBranch (production-safety guard)', () => {
    it('allows a conductor/ workspace branch', () => {
      expect(() => assertDisposableChildBranch('conductor/my-feature', 'production')).not.toThrow()
    })

    it('allows a tmp/ check branch', () => {
      expect(() => assertDisposableChildBranch('tmp/my-feature', 'production')).not.toThrow()
    })

    it('refuses a branch that is neither conductor/ nor tmp/ prefixed (e.g. production)', () => {
      expect(() => assertDisposableChildBranch('production', 'production')).toThrow(/workspace branch/)
      expect(() => assertDisposableChildBranch('development', 'production')).toThrow(/workspace branch/)
    })

    it('refuses operating on the parent branch even if it were conductor/ prefixed', () => {
      expect(() => assertDisposableChildBranch('conductor/x', 'conductor/x')).toThrow(/parent branch/)
    })
  })

  describe('assertDisposableCheckBranch (stricter: tmp/ only, not conductor/)', () => {
    it('allows a tmp/ check branch', () => {
      expect(() => assertDisposableCheckBranch('tmp/my-feature', 'production')).not.toThrow()
    })

    it('refuses a conductor/ workspace branch even though assertDisposableChildBranch would allow it', () => {
      expect(() => assertDisposableCheckBranch('conductor/my-feature', 'production')).toThrow(/check branch/)
    })

    it('refuses operating on the parent branch', () => {
      expect(() => assertDisposableCheckBranch('tmp/x', 'tmp/x')).toThrow(/parent branch/)
    })
  })

  describe('readBranchState / writeBranchState / setupIsPending (rename- and crash-safety)', () => {
    // The suite-level sandbox (above) means there is no real state file to protect here; each
    // test starts from whatever the previous one wrote, so clean up after each.
    afterEach(() => {
      rmSync(process.env.CONDUCTOR_DB_STATE_FILE!, { force: true })
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
      writeBranchState('conductor/my-feature', 'ready') // written after baseline + deploy + seed succeed
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
      writeBranchState('conductor/my-feature')
      writeCheckBranchState('tmp/my-feature')
      expect(readCheckBranchState()).toBe('tmp/my-feature')
      expect(readBranchState()).toBe('conductor/my-feature') // unaffected by the check-branch record
    })

    it('clears cleanly, leaving the workspace-branch record untouched', () => {
      writeBranchState('conductor/my-feature')
      writeCheckBranchState('tmp/my-feature')
      clearCheckBranchState()
      expect(readCheckBranchState()).toBeNull()
      expect(readBranchState()).toBe('conductor/my-feature')
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
})
