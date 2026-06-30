// Unit tests for the safety-critical pure helpers in scripts/conductor-db.ts.
// When you copy this into a project, adjust the import path to your layout
// (e.g. `../../scripts/conductor-db` from `__tests__/scripts/`). Runs under Jest or Vitest.
import { createHash } from 'node:crypto'
import {
  assertDisposableChildBranch,
  buildDrizzleBaselineSql,
  buildPrismaBaselineSql,
  workspaceBranchName,
} from '../scripts/conductor-db'

describe('conductor-db helpers', () => {
  const ORIGINAL_ENV = process.env

  beforeEach(() => {
    process.env = { ...ORIGINAL_ENV }
  })

  afterAll(() => {
    process.env = ORIGINAL_ENV
  })

  describe('workspaceBranchName', () => {
    it('slugifies the workspace name into a conductor/ branch', () => {
      process.env.CONDUCTOR_WORKSPACE_NAME = 'My Cool Feature!'
      expect(workspaceBranchName()).toBe('conductor/my-cool-feature')
    })

    it('collapses separator runs and trims leading/trailing separators', () => {
      process.env.CONDUCTOR_WORKSPACE_NAME = '  Feature / 123 -- test  '
      expect(workspaceBranchName()).toBe('conductor/feature-123-test')
    })

    it('caps the slug at 48 characters', () => {
      process.env.CONDUCTOR_WORKSPACE_NAME = 'a'.repeat(100)
      expect(workspaceBranchName()).toBe(`conductor/${'a'.repeat(48)}`)
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
  })
})
