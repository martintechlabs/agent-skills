// Regression tests for scripts/neondb-branch.ts — lifecycle state, ownership, and the fail-closed
// paths. When you copy this into a project, adjust the import path to your layout.
//
// Nothing here talks to Neon or to a real Postgres: the control plane is a fake implementing the
// same NeonClient interface the production code uses, with response shapes taken from live Neon API
// output. The purge itself is exercised against real Postgres in purge.test.ts.
import { spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import {
  acquireLock,
  assertNoLegacyState,
  assertOwnedDisposableBranch,
  assertProjectMatches,
  AmbiguousCreateError,
  backoffMs,
  buildCountSql,
  buildTruncateSql,
  createNeonRestClient,
  DISCOVER_TABLES_SQL,
  FatalError,
  FIRST_CONNECTION_ATTEMPTS,
  NeonRequestError,
  parseState,
  planPurge,
  prismaKnownTables,
  PRISMA_TX_MAXWAIT_MS,
  provision,
  quoteIdent,
  readState,
  removeStateDirIfEmpty,
  resolveWorkspaceName,
  stripEnvVars,
  sync,
  teardown,
  upsertEnvVars,
  withRetry,
  workspaceBranchName,
  writeState,
  type Deps,
  type DiscoveredTable,
  type GitContext,
  type NeonBranch,
  type NeonClient,
  type SqlClient,
  type SqlConnect,
} from '../scripts/neondb-branch'

const PROJECT = 'orange-forest-39329018'
const PARENT_ID = 'br-sweet-resonance-arsioaz3'
const PARENT_LSN = '0/1BBADB0'

/** Shapes copied from live `GET /projects/{id}/branches` output. */
function parentBranch(): NeonBranch {
  return { id: PARENT_ID, project_id: PROJECT, name: 'production', primary: true, default: true, protected: true, current_state: 'ready', init_source: 'parent-data' }
}
function childBranch(overrides: Partial<NeonBranch> = {}): NeonBranch {
  return {
    id: 'br-dawn-river-arrz6rux',
    project_id: PROJECT,
    name: 'workspace/feature-x',
    parent_id: PARENT_ID,
    parent_lsn: PARENT_LSN,
    primary: false,
    default: false,
    protected: false,
    current_state: 'ready',
    init_source: 'parent-data',
    ...overrides,
  }
}

interface FakeNeon extends NeonClient {
  calls: string[]
  branches: Map<string, NeonBranch>
  failDeleteWith?: Error
  failCreateWith?: Error
}

function fakeNeon(options: { branches?: NeonBranch[]; created?: NeonBranch; connectionUri?: string } = {}): FakeNeon {
  const branches = new Map<string, NeonBranch>((options.branches ?? [parentBranch()]).map((b) => [b.id, b]))
  const client: FakeNeon = {
    calls: [],
    branches,
    async findBranchByName(projectId, name) {
      client.calls.push(`findBranchByName(${projectId},${name})`)
      return [...branches.values()].find((b) => b.name === name && b.project_id === projectId) ?? null
    },
    async getBranchById(projectId, branchId) {
      client.calls.push(`getBranchById(${projectId},${branchId})`)
      const found = branches.get(branchId)
      return found && found.project_id === projectId ? found : null
    },
    async createBranch(projectId, opts) {
      client.calls.push(`createBranch(${projectId},${opts.name},${opts.parentId},${opts.parentLsn})`)
      if (client.failCreateWith) throw client.failCreateWith
      const branch = options.created ?? childBranch({ name: opts.name, parent_id: opts.parentId, parent_lsn: opts.parentLsn })
      branches.set(branch.id, branch)
      return { branch, connectionUri: options.connectionUri ?? 'postgres://u:p@ep-child-123.us-east-2.aws.neon.tech/appdb' }
    },
    async deleteBranch(projectId, branchId) {
      client.calls.push(`deleteBranch(${projectId},${branchId})`)
      if (client.failDeleteWith) throw client.failDeleteWith
      return branches.delete(branchId) ? 'deleted' : 'absent'
    },
    async connectionUri(projectId, branchId) {
      client.calls.push(`connectionUri(${projectId},${branchId})`)
      return `postgres://u:p@ep-${branchId}.us-east-2.aws.neon.tech/appdb`
    },
  }
  return client
}

interface FakeSql {
  connect: SqlConnect
  statements: string[]
  connectAttempts: number
}

/** A scripted SQL session: enough to satisfy LSN capture, discovery, purge and the empty check. */
function fakeSql(options: { tables?: DiscoveredTable[]; failConnectTimes?: number; countsAfterPurge?: Record<string, number> } = {}): FakeSql {
  const state: FakeSql = { connect: null as unknown as SqlConnect, statements: [], connectAttempts: 0 }
  const tables = options.tables ?? [
    { schema: 'public', name: 'users', extensionOwned: false },
    { schema: 'public', name: '_prisma_migrations', extensionOwned: false },
  ]
  state.connect = async (uri: string) => {
    state.connectAttempts++
    if (options.failConnectTimes !== undefined && state.connectAttempts <= options.failConnectTimes) {
      throw new Error(`ECONNREFUSED connecting to ${uri}`)
    }
    const client: SqlClient = {
      async query<T>(sql: string): Promise<T[]> {
        state.statements.push(sql)
        if (sql.includes('pg_current_wal_lsn')) return [{ lsn: PARENT_LSN }] as unknown as T[]
        if (sql.trim() === DISCOVER_TABLES_SQL.trim()) {
          return tables.map((t) => ({ schema: t.schema, name: t.name, extension_owned: t.extensionOwned })) as unknown as T[]
        }
        if (sql.includes('count(*)')) {
          const counts = options.countsAfterPurge ?? {}
          return sql
            .split('UNION ALL')
            .map((part) => {
              const qualified = /'([^']+)' AS qualified/.exec(part)?.[1] ?? ''
              return { qualified, rows: counts[qualified] ?? 0 }
            }) as unknown as T[]
        }
        return [] as unknown as T[]
      },
    }
    return { client, end: async () => undefined }
  }
  return state
}

let sandbox: string
let neon: FakeNeon
let sql: FakeSql
let logs: string[]
let warnings: string[]

function makeDeps(overrides: Partial<Deps> = {}): Deps {
  return {
    neon,
    connect: sql.connect,
    knownTables: async () => ['public.users'],
    deployMigrations: () => undefined,
    seed: () => undefined,
    sleep: () => undefined, // never actually wait in tests
    log: (message) => logs.push(message),
    warn: (message) => warnings.push(message),
    ...overrides,
  }
}

beforeEach(() => {
  sandbox = mkdtempSync(join(tmpdir(), 'neondb-branch-test-'))
  vi.stubEnv('NEONDB_STATE_DIR', join(sandbox, '.neondb'))
  vi.stubEnv('NEONDB_BRANCH_ENV_FILE', join(sandbox, '.env.neondb'))
  vi.stubEnv('NEON_PROJECT_ID', PROJECT)
  vi.stubEnv('NEON_API_KEY', 'neon_api_key_test')
  vi.stubEnv('NEON_PARENT_BRANCH', 'production')
  vi.stubEnv('WORKSPACE_NAME', 'feature-x')
  vi.stubEnv('DATABASE_URL', '')
  neon = fakeNeon()
  sql = fakeSql()
  logs = []
  warnings = []
})

afterEach(() => {
  vi.unstubAllEnvs()
  rmSync(sandbox, { recursive: true, force: true })
})

const stateFile = () => join(sandbox, '.neondb', 'state.json')
const readStateFile = () => JSON.parse(readFileSync(stateFile(), 'utf8'))

describe('state file (.neondb/state.json)', () => {
  const valid = { branchId: 'br-abc', branchName: 'workspace/x', projectId: PROJECT, status: 'ready' as const }

  it('round-trips a valid state atomically, leaving no temp file behind', () => {
    writeState(valid)
    expect(readState()).toEqual(valid)
    expect(readdirSync(join(sandbox, '.neondb'))).toEqual(['state.json'])
  })

  it('rejects malformed JSON rather than guessing', () => {
    mkdirSync(join(sandbox, '.neondb'), { recursive: true })
    writeFileSync(stateFile(), '{not json')
    expect(() => readState()).toThrow(/not valid JSON/)
  })

  it.each(['branchId', 'branchName', 'projectId', 'status'])('rejects state missing "%s"', (key) => {
    const incomplete: Record<string, unknown> = { ...valid }
    delete incomplete[key]
    expect(() => parseState(JSON.stringify(incomplete))).toThrow(/incomplete: missing/)
  })

  it('rejects an unknown status', () => {
    expect(() => parseState(JSON.stringify({ ...valid, status: 'provisioned' }))).toThrow(/unknown status/)
  })

  it('rejects an unrecognized key — a foreign or drifted file is not interpreted loosely', () => {
    expect(() => parseState(JSON.stringify({ ...valid, databaseUrl: 'postgres://…' }))).toThrow(/unrecognized key/)
  })

  it('allows branchId null ONLY with status "creating"', () => {
    expect(parseState(JSON.stringify({ ...valid, branchId: null, status: 'creating' })).branchId).toBeNull()
    expect(() => parseState(JSON.stringify({ ...valid, branchId: null, status: 'ready' }))).toThrow(/"branchId" is not a Neon branch id/)
    expect(() => parseState(JSON.stringify({ ...valid, branchId: 'br-abc', status: 'creating' }))).toThrow(/creation intent is unresolved/)
  })

  it('rejects a branchId that is not a Neon branch id', () => {
    expect(() => parseState(JSON.stringify({ ...valid, branchId: 'workspace/x' }))).toThrow(/not a Neon branch id/)
  })

  it('carries no credentials', () => {
    writeState(valid)
    const raw = readFileSync(stateFile(), 'utf8')
    expect(raw).not.toMatch(/neon_api_key|password|postgres:\/\//i)
  })

  it('refuses a project mismatch BEFORE any Neon call', () => {
    expect(() => assertProjectMatches({ ...valid, projectId: 'some-other-project' }, PROJECT)).toThrow(/Refusing to contact Neon/)
  })
})

describe('legacy state detection (no compatibility path)', () => {
  it('refuses to run while the old .neondb/branch record is present', () => {
    mkdirSync(join(sandbox, '.neondb'), { recursive: true })
    writeFileSync(join(sandbox, '.neondb', 'branch'), 'workspace/feature-x\nready\n')
    expect(() => assertNoLegacyState()).toThrow(/is not proof of ownership/)
    // The error has to be actionable on its own: what to delete, and where the steps are.
    expect(() => readState()).toThrow(/delete the branch it names from the Neon console/)
    expect(() => readState()).toThrow(/rm -rf/)
    expect(() => readState()).toThrow(/SKILL\.md/)
  })

  it('refuses to run while a leaked temporary-branch record is present, so teardown cannot abandon it', () => {
    mkdirSync(join(sandbox, '.neondb'), { recursive: true })
    writeFileSync(join(sandbox, '.neondb', 'branch-check'), 'tmp/feature-x\n')
    expect(() => assertNoLegacyState()).toThrow(/leaked disposable clone/)
    expect(() => assertNoLegacyState()).toThrow(/rm -rf/)
  })

  it('teardown refuses rather than silently skipping a legacy record', async () => {
    mkdirSync(join(sandbox, '.neondb'), { recursive: true })
    writeFileSync(join(sandbox, '.neondb', 'branch'), 'workspace/feature-x\nready\n')
    await expect(teardown(makeDeps())).rejects.toThrow(/is not proof of ownership/)
    expect(neon.calls).toEqual([]) // and it never quietly reports "nothing to tear down"
  })
})

describe('lifecycle lock', () => {
  it('does not reclaim a lock whose PID has not been written yet', () => {
    mkdirSync(join(sandbox, '.neondb'), { recursive: true })
    writeFileSync(join(sandbox, '.neondb', 'lock'), '')
    expect(() => acquireLock('teardown')).toThrow(/cannot prove|Cannot prove/)
    expect(readFileSync(join(sandbox, '.neondb', 'lock'), 'utf8')).toBe('')
  })

  it('blocks a competing stale-lock reclaimer until the first has acquired ownership', () => {
    acquireLock('dead')
    let competitorError: unknown
    const release = acquireLock('first', () => {
      try { acquireLock('competitor', () => false) } catch (error) { competitorError = error }
      return false
    })
    expect(competitorError).toBeInstanceOf(FatalError)
    expect(JSON.parse(readFileSync(join(sandbox, '.neondb', 'lock'), 'utf8')).label).toBe('first')
    release()
  })
  it('serializes commands: a second holder is refused while the first is alive', () => {
    const release = acquireLock('provision')
    expect(() => acquireLock('teardown')).toThrow(/Another neondb-branch command \(provision/)
    release()
    acquireLock('teardown')()
  })

  it('reclaims a lock whose holder process is gone', () => {
    acquireLock('provision', () => true)
    const release = acquireLock('teardown', () => false) // the recorded pid is dead
    expect(typeof release).toBe('function')
    release()
  })
})

describe('removeStateDirIfEmpty', () => {
  it('removes the directory when it is empty', () => {
    mkdirSync(join(sandbox, '.neondb'), { recursive: true })
    expect(removeStateDirIfEmpty()).toBe(true)
    expect(existsSync(join(sandbox, '.neondb'))).toBe(false)
  })

  it('preserves the directory — and its contents — when anything else lives there', () => {
    mkdirSync(join(sandbox, '.neondb'), { recursive: true })
    writeFileSync(join(sandbox, '.neondb', 'notes.md'), 'keep me')
    expect(removeStateDirIfEmpty()).toBe(false)
    expect(readFileSync(join(sandbox, '.neondb', 'notes.md'), 'utf8')).toBe('keep me')
  })
})

describe('provision', () => {
  it('clears creation intent after a definitively rejected POST', async () => {
    neon.failCreateWith = new NeonRequestError('branch limit', 422, false)
    await expect(provision(makeDeps())).rejects.toThrow('branch limit')
    expect(readState()).toBeNull()
  })

  it('uses the selected child database instead of an arbitrary URI in the create response', async () => {
    neon = fakeNeon({ connectionUri: 'postgres://u:p@wrong-db-host/wrong' })
    const migrated: string[] = []
    await provision(makeDeps({ deployMigrations: (uri) => { migrated.push(uri) } }))
    expect(migrated).toEqual(['postgres://u:p@ep-br-dawn-river-arrz6rux.us-east-2.aws.neon.tech/appdb'])
  })

  it('refuses to delete its configured parent during a rebuild', async () => {
    const parent = childBranch({ id: PARENT_ID, name: 'stand-in-parent', parent_id: 'br-grandparent' })
    neon = fakeNeon({ branches: [parent] })
    vi.stubEnv('NEON_PARENT_BRANCH', PARENT_ID)
    writeState({ branchId: PARENT_ID, branchName: parent.name, projectId: PROJECT, status: 'ready' })
    await expect(provision(makeDeps())).rejects.toThrow(/Refusing to delete/)
    expect(neon.calls.some((call) => call.startsWith('deleteBranch'))).toBe(false)
  })

  it('keeps deleting state and does not create again while the old branch remains', async () => {
    neon = fakeNeon({ branches: [parentBranch(), childBranch()] })
    writeState({ branchId: childBranch().id, branchName: childBranch().name, projectId: PROJECT, status: 'ready' })
    neon.deleteBranch = async () => {
      expect(readStateFile().status).toBe('deleting')
      return 'deleted'
    }
    await expect(provision(makeDeps())).rejects.toThrow(/still present/)
    expect(readStateFile().status).toBe('deleting')
    expect(neon.calls.some((call) => call.startsWith('createBranch'))).toBe(false)
  })

  it('retains the branch id when cleanup was accepted but never finished', async () => {
    neon.deleteBranch = async () => 'deleted'
    await expect(provision(makeDeps({ seed: () => { throw new Error('seed failed') } }))).rejects.toThrow('seed failed')
    expect(readState()).toMatchObject({ branchId: childBranch().id, status: 'deleting' })
    expect(warnings.join('\n')).toMatch(/still present/)
  })
  it('walks creating → pending → ready, creating an ordinary child at the captured parent LSN', async () => {
    const transitions: string[] = []
    const deps = makeDeps({
      deployMigrations: () => {
        transitions.push(`migrate:${readStateFile().status}`)
      },
      seed: () => {
        transitions.push(`seed:${readStateFile().status}`)
      },
    })
    await provision(deps)

    expect(neon.calls).toContain(`createBranch(${PROJECT},workspace/feature-x,${PARENT_ID},${PARENT_LSN})`)
    // Migrations run only after the purge, and only while the branch is still `pending`.
    expect(transitions).toEqual(['migrate:pending', 'seed:pending'])
    expect(readStateFile()).toEqual({ branchId: 'br-dawn-river-arrz6rux', branchName: 'workspace/feature-x', projectId: PROJECT, status: 'ready' })
  })

  it('purges before publishing connection URLs, and truncates in a transaction', async () => {
    let envAtTruncate: boolean | null = null
    const watchingSql = fakeSql()
    const originalConnect = watchingSql.connect
    sql = {
      ...watchingSql,
      connect: async (uri) => {
        const session = await originalConnect(uri)
        return {
          ...session,
          client: {
            query: async <T>(statement: string, params?: unknown[]) => {
              if (statement.startsWith('TRUNCATE')) envAtTruncate = existsSync(join(sandbox, '.env.neondb'))
              return session.client.query<T>(statement, params)
            },
          },
        }
      },
    }
    await provision(makeDeps())

    const purge = sql.statements.filter((s) => s === 'BEGIN' || s.startsWith('TRUNCATE') || s === 'COMMIT')
    expect(purge).toEqual(['BEGIN', 'TRUNCATE TABLE "public"."users" RESTART IDENTITY RESTRICT', 'COMMIT'])
    expect(envAtTruncate).toBe(false) // no URL was publishable while production rows were still there
    expect(readFileSync(join(sandbox, '.env.neondb'), 'utf8')).toMatch(/DATABASE_URL='postgres:\/\//)
  })

  it('preserves the inherited migration ledger — the whole reason an ordinary child is used', async () => {
    await provision(makeDeps())
    const truncate = sql.statements.find((s) => s.startsWith('TRUNCATE')) ?? ''
    expect(truncate).not.toContain('_prisma_migrations')
    expect(logs.join('\n')).toMatch(/preserved 1 \(public\._prisma_migrations\)/)
  })

  it('fails closed on an unknown application table instead of publishing the database', async () => {
    sql = fakeSql({
      tables: [
        { schema: 'public', name: 'users', extensionOwned: false },
        { schema: 'public', name: 'invoices', extensionOwned: false }, // production is ahead of this checkout
        { schema: 'public', name: '_prisma_migrations', extensionOwned: false },
      ],
    })
    await expect(provision(makeDeps())).rejects.toThrow(/table\(s\) public\.invoices/)
    expect(existsSync(stateFile())).toBe(false) // cleaned up
    expect(neon.calls.filter((c) => c.startsWith('deleteBranch'))).toHaveLength(1)
  })

  it('refuses a mismatched parent_lsn without deleting a branch it cannot prove it owns', async () => {
    neon = fakeNeon({ created: childBranch({ parent_lsn: '0/DEADBEEF' }) })
    await expect(provision(makeDeps())).rejects.toThrow(/parent_lsn .* not the captured/)
    expect(neon.calls.some((call) => call.startsWith('deleteBranch'))).toBe(false)
    expect(readStateFile().status).toBe('creating')
  })

  it('leaves a non-disposable surprise response strictly alone', async () => {
    neon = fakeNeon({ created: childBranch({ name: 'production', protected: true }) })
    await expect(provision(makeDeps())).rejects.toThrow(/Refusing to use branch/)
    expect(neon.calls.some((c) => c.startsWith('deleteBranch'))).toBe(false)
    expect(readStateFile().status).toBe('creating') // a human resolves this one
  })

  it('refuses a returned branch that is a root branch (the schema-only bug this replaces)', () => {
    expect(() =>
      assertOwnedDisposableBranch(childBranch({ parent_id: undefined, parent_lsn: undefined, init_source: 'parent-schema' }), {
        projectId: PROJECT,
        name: 'workspace/feature-x',
        parentId: PARENT_ID,
      }),
    ).toThrow(/a root branch/)
  })

  it.each([{ default: true }, { primary: true }, { protected: true }])('refuses a branch flagged %o as non-disposable', (flag) => {
    expect(() => assertOwnedDisposableBranch(childBranch(flag), { projectId: PROJECT, name: 'workspace/feature-x', parentId: PARENT_ID, parentLsn: PARENT_LSN })).toThrow(
      /Refusing to use branch/,
    )
  })

  it('leaves creation intent unresolved on an ambiguous create — no blind retry, no adoption by name', async () => {
    neon.failCreateWith = new NeonRequestError('POST /branches → HTTP 502', 502, true)
    await expect(provision(makeDeps())).rejects.toThrow(AmbiguousCreateError)

    expect(neon.calls.filter((c) => c.startsWith('createBranch'))).toHaveLength(1) // exactly one POST
    expect(neon.calls.some((c) => c.startsWith('findBranchByName') && c.includes('workspace/feature-x'))).toBe(false)
    expect(neon.calls.some((c) => c.startsWith('deleteBranch'))).toBe(false)
    expect(readStateFile()).toEqual({ branchId: null, branchName: 'workspace/feature-x', projectId: PROJECT, status: 'creating' })
  })

  it('retries a create that provably never reached Neon', async () => {
    let attempts = 0
    const flaky = fakeNeon()
    const realCreate = flaky.createBranch.bind(flaky)
    flaky.createBranch = async (projectId, opts) => {
      attempts++
      if (attempts === 1) throw new NeonRequestError('POST /branches failed before a response was read (ECONNREFUSED)', null, false)
      return realCreate(projectId, opts)
    }
    neon = flaky
    await provision(makeDeps())
    expect(attempts).toBe(2)
    expect(readStateFile().status).toBe('ready')
  })

  it('refuses to start when a previous run left creation intent unresolved', async () => {
    writeState({ branchId: null, branchName: 'workspace/feature-x', projectId: PROJECT, status: 'creating' })
    await expect(provision(makeDeps())).rejects.toThrow(/UNRESOLVED branch creation/)
    expect(neon.calls).toEqual([]) // nothing is created, nothing is deleted
  })

  it('refuses a recorded project that is not the configured one, before contacting Neon', async () => {
    writeState({ branchId: 'br-elsewhere', branchName: 'workspace/feature-x', projectId: 'a-different-project', status: 'ready' })
    await expect(provision(makeDeps())).rejects.toThrow(/Refusing to contact Neon/)
    expect(neon.calls).toEqual([])
  })

  it('rebuilds by deleting the recorded ID, never the derived name', async () => {
    const stale = childBranch({ id: 'br-old-one', name: 'workspace/an-older-name' })
    neon = fakeNeon({ branches: [parentBranch(), stale] })
    writeState({ branchId: 'br-old-one', branchName: 'workspace/an-older-name', projectId: PROJECT, status: 'ready' })
    await provision(makeDeps())
    expect(neon.calls).toContain(`deleteBranch(${PROJECT},br-old-one)`)
    expect(neon.calls.some((c) => c.startsWith('findBranchByName') && c.includes('workspace/an-older-name'))).toBe(false)
  })

  it('tolerates a slow compute: the first connection is retried with growing backoff', async () => {
    sql = fakeSql({ failConnectTimes: 4 })
    const waits: number[] = []
    await provision(makeDeps({ sleep: (ms) => waits.push(ms) }))
    expect(readStateFile().status).toBe('ready')
    expect(waits.slice(0, 4)).toEqual([2000, 4000, 8000, 16000])
  })

  it('budgets minutes, not seconds, for a cold compute', () => {
    const budgetMs = Array.from({ length: FIRST_CONNECTION_ATTEMPTS - 1 }, (_, i) => backoffMs(i + 1)).reduce((a, b) => a + b, 0)
    expect(budgetMs).toBeGreaterThan(120_000)
    expect(PRISMA_TX_MAXWAIT_MS).toBe(30_000) // Prisma's 2s default loses this race every time
  })

  it('deletes the branch and clears state when setup fails after creation', async () => {
    await expect(
      provision(
        makeDeps({
          deployMigrations: () => {
            throw new Error('migrate deploy exploded')
          },
        }),
      ),
    ).rejects.toThrow('migrate deploy exploded')
    expect(neon.calls).toContain(`deleteBranch(${PROJECT},br-dawn-river-arrz6rux)`)
    expect(existsSync(stateFile())).toBe(false)
    // Publishing happens last, so a failure before it means no URL was ever exposed at all.
    expect(existsSync(join(sandbox, '.env.neondb'))).toBe(false)
  })

  it('withdraws the previous URL but keeps the Neon control vars when a re-provision fails', async () => {
    upsertEnvVars(join(sandbox, '.env.neondb'), { DATABASE_URL: 'postgres://u:p@previous-branch/appdb', NEON_PROJECT_ID: PROJECT })
    const stale = childBranch({ id: 'br-old-one', name: 'workspace/feature-x' })
    neon = fakeNeon({ branches: [parentBranch(), stale] })
    writeState({ branchId: 'br-old-one', branchName: 'workspace/feature-x', projectId: PROJECT, status: 'ready' })
    await expect(
      provision(
        makeDeps({
          deployMigrations: () => {
            throw new Error('migrate deploy exploded')
          },
        }),
      ),
    ).rejects.toThrow('migrate deploy exploded')

    const envFile = readFileSync(join(sandbox, '.env.neondb'), 'utf8')
    expect(envFile).not.toMatch(/DATABASE_URL/) // the old branch is gone; its URL must not linger
    expect(envFile).toMatch(/NEON_PROJECT_ID/) // the next attempt does not need these re-supplied
  })

  it('RETAINS recovery state and warns when that cleanup itself fails', async () => {
    neon.failDeleteWith = new NeonRequestError('DELETE → HTTP 500', 500, true)
    await expect(
      provision(
        makeDeps({
          deployMigrations: () => {
            throw new Error('migrate deploy exploded')
          },
        }),
      ),
    ).rejects.toThrow('migrate deploy exploded')

    expect(readStateFile()).toMatchObject({ branchId: 'br-dawn-river-arrz6rux', status: 'deleting' })
    expect(warnings.join('\n')).toMatch(/could not delete branch br-dawn-river-arrz6rux/)
  })
})

describe('sync', () => {
  function ready() {
    writeState({ branchId: 'br-dawn-river-arrz6rux', branchName: 'workspace/feature-x', projectId: PROJECT, status: 'ready' })
    neon = fakeNeon({ branches: [parentBranch(), childBranch()] })
    upsertEnvVars(join(sandbox, '.env.neondb'), { DATABASE_URL: 'postgres://u:p@ep-child-123.us-east-2.aws.neon.tech/appdb' })
  }

  it('verifies the recorded branch by ID and passes', async () => {
    ready()
    await sync(makeDeps())
    expect(neon.calls).toEqual([`getBranchById(${PROJECT},br-dawn-river-arrz6rux)`])
  })

  it.each(['creating', 'pending', 'deleting'] as const)('gates the app when state is "%s"', async (status) => {
    writeState({ branchId: status === 'creating' ? null : 'br-dawn-river-arrz6rux', branchName: 'workspace/feature-x', projectId: PROJECT, status })
    upsertEnvVars(join(sandbox, '.env.neondb'), { DATABASE_URL: 'postgres://u:p@ep-child-123.example/appdb' })
    await expect(sync(makeDeps())).rejects.toThrow(new RegExp(`state "${status}", not "ready"`))
  })

  it('gates when the workspace was never provisioned', async () => {
    await expect(sync(makeDeps())).rejects.toThrow(/not provisioned/)
  })

  it('gates when the managed database URL is missing, even with an ambient one exported', async () => {
    writeState({ branchId: 'br-dawn-river-arrz6rux', branchName: 'workspace/feature-x', projectId: PROJECT, status: 'ready' })
    vi.stubEnv('DATABASE_URL', 'postgres://u:p@shared-production-host/appdb') // the trap
    await expect(sync(makeDeps())).rejects.toThrow(/An ambient DATABASE_URL does not count/)
  })

  it('refreshes a branch renamed on Neon, keeping the same ID', async () => {
    ready()
    neon.branches.set('br-dawn-river-arrz6rux', childBranch({ name: 'workspace/renamed-in-console' }))
    await sync(makeDeps())
    expect(readStateFile()).toEqual({ branchId: 'br-dawn-river-arrz6rux', branchName: 'workspace/renamed-in-console', projectId: PROJECT, status: 'ready' })
  })

  it('never adopts another branch that reused this workspace name', async () => {
    ready()
    // Our branch was renamed away; a DIFFERENT branch now carries the name our identity derives.
    neon.branches.set('br-dawn-river-arrz6rux', childBranch({ name: 'workspace/renamed-in-console' }))
    neon.branches.set('br-someone-else', childBranch({ id: 'br-someone-else', name: 'workspace/feature-x' }))
    await sync(makeDeps())
    expect(readStateFile().branchId).toBe('br-dawn-river-arrz6rux')
    expect(neon.calls.some((c) => c.startsWith('findBranchByName'))).toBe(false)
    expect(logs.join('\n')).toMatch(/never switches database ownership/)
  })

  it('gates when the recorded branch is gone, rather than picking a replacement', async () => {
    ready()
    neon.branches.delete('br-dawn-river-arrz6rux')
    await expect(sync(makeDeps())).rejects.toThrow(/no longer exists in Neon/)
  })

  it('refuses a project mismatch without contacting Neon', async () => {
    writeState({ branchId: 'br-dawn-river-arrz6rux', branchName: 'workspace/feature-x', projectId: 'other-project', status: 'ready' })
    upsertEnvVars(join(sandbox, '.env.neondb'), { DATABASE_URL: 'postgres://u:p@ep-child-123.example/appdb' })
    await expect(sync(makeDeps())).rejects.toThrow(/Refusing to contact Neon/)
    expect(neon.calls).toEqual([])
  })
})

describe('teardown', () => {
  it.each([{ default: true }, { primary: true }, { protected: true }, { parent_id: null }])('refuses to delete a recorded branch that is no longer disposable: %o', async (flags) => {
    neon.branches.set(childBranch().id, childBranch(flags))
    await expect(teardown(makeDeps())).rejects.toThrow(/Refusing to delete/)
    expect(neon.calls.some((call) => call.startsWith('deleteBranch'))).toBe(false)
    expect(readState()).not.toBeNull()
  })
  beforeEach(() => {
    writeState({ branchId: 'br-dawn-river-arrz6rux', branchName: 'workspace/feature-x', projectId: PROJECT, status: 'ready' })
    neon = fakeNeon({ branches: [parentBranch(), childBranch()] })
    upsertEnvVars(join(sandbox, '.env.neondb'), { DATABASE_URL: 'postgres://u:p@h/db', NEON_PROJECT_ID: PROJECT })
  })

  it('records deleting, deletes by ID, confirms absence, then clears state and URLs', async () => {
    await teardown(makeDeps())
    expect(neon.calls).toEqual([`getBranchById(${PROJECT},br-dawn-river-arrz6rux)`, `deleteBranch(${PROJECT},br-dawn-river-arrz6rux)`, `getBranchById(${PROJECT},br-dawn-river-arrz6rux)`])
    expect(existsSync(stateFile())).toBe(false)
    expect(readFileSync(join(sandbox, '.env.neondb'), 'utf8')).not.toMatch(/DATABASE_URL/)
    expect(existsSync(join(sandbox, '.neondb'))).toBe(false) // empty, so removed
  })

  it('treats an already-deleted branch as success', async () => {
    neon.branches.delete('br-dawn-river-arrz6rux')
    await teardown(makeDeps())
    expect(logs.join('\n')).toMatch(/was already gone/)
    expect(existsSync(stateFile())).toBe(false)
  })

  it('waits out a delayed deletion instead of trusting the response', async () => {
    let reads = 0
    const slow = neon.getBranchById.bind(neon)
    neon.getBranchById = async (projectId, branchId) => {
      reads++
      return reads < 3 ? childBranch({ current_state: 'deleting' }) : slow(projectId, branchId)
    }
    await teardown(makeDeps())
    expect(reads).toBe(3)
    expect(existsSync(stateFile())).toBe(false)
  })

  it('retains "deleting" and fails visibly when the delete fails', async () => {
    neon.failDeleteWith = new NeonRequestError('DELETE → HTTP 500', 500, true)
    await expect(teardown(makeDeps())).rejects.toThrow(/HTTP 500/)
    expect(readStateFile()).toEqual({ branchId: 'br-dawn-river-arrz6rux', branchName: 'workspace/feature-x', projectId: PROJECT, status: 'deleting' })
    expect(readFileSync(join(sandbox, '.env.neondb'), 'utf8')).toMatch(/DATABASE_URL/) // still recoverable
  })

  it('preserves unrelated files in .neondb and never removes the directory recursively', async () => {
    writeFileSync(join(sandbox, '.neondb', 'notes.md'), 'keep me')
    await teardown(makeDeps())
    expect(readFileSync(join(sandbox, '.neondb', 'notes.md'), 'utf8')).toBe('keep me')
    expect(existsSync(stateFile())).toBe(false)
  })

  it('refuses to guess when creation intent was never resolved', async () => {
    writeState({ branchId: null, branchName: 'workspace/feature-x', projectId: PROJECT, status: 'creating' })
    await expect(teardown(makeDeps())).rejects.toThrow(/UNRESOLVED branch creation/)
    expect(neon.calls).toEqual([])
  })
})

describe('planPurge (fail-closed classification)', () => {
  const ledger: DiscoveredTable = { schema: 'public', name: '_prisma_migrations', extensionOwned: false }

  it('truncates known application tables and preserves the ledger', () => {
    const plan = planPurge([ledger, { schema: 'public', name: 'users', extensionOwned: false }], ['public.users'])
    expect(plan).toEqual({ truncate: ['public.users'], preserved: ['public._prisma_migrations'] })
  })

  it('preserves extension-owned tables (PostGIS reference data) without listing them as known', () => {
    const plan = planPurge([ledger, { schema: 'public', name: 'spatial_ref_sys', extensionOwned: true }], [])
    expect(plan.preserved).toContain('public.spatial_ref_sys')
    expect(plan.truncate).toEqual([])
  })

  it('fails closed on a table this checkout does not know about', () => {
    expect(() => planPurge([ledger, { schema: 'public', name: 'invoices', extensionOwned: false }], ['public.users'])).toThrow(/table\(s\) public\.invoices/)
  })

  it('fails closed on a schema outside APP_SCHEMAS', () => {
    expect(() => planPurge([ledger, { schema: 'billing', name: 'ledger_entries', extensionOwned: false }], ['public.users'])).toThrow(/schema\(s\) billing/)
  })

  it('accepts known tables that are absent — production being behind this checkout is normal', () => {
    const plan = planPurge([ledger], ['public.users', 'public.invoices'])
    expect(plan.truncate).toEqual([])
  })

  it('honours an explicitly preserved table', () => {
    const plan = planPurge([ledger, { schema: 'public', name: 'countries', extensionOwned: false }], [], { preserved: ['public.countries'] })
    expect(plan.preserved).toContain('public.countries')
  })
})

describe('SQL construction', () => {
  it('quotes identifiers, doubling embedded quotes', () => {
    expect(quoteIdent('users')).toBe('"users"')
    expect(quoteIdent('we"ird')).toBe('"we""ird"')
  })

  it('builds a single multi-table TRUNCATE so foreign-key order cannot matter', () => {
    expect(buildTruncateSql(['public.users', 'public.orders'])).toBe('TRUNCATE TABLE "public"."users", "public"."orders" RESTART IDENTITY RESTRICT')
  })

  it('builds one round-trip emptiness check', () => {
    expect(buildCountSql(['public.users'])).toBe('SELECT \'public.users\' AS qualified, count(*)::bigint AS rows FROM "public"."users"')
  })
})

describe('prismaKnownTables', () => {
  it('honours @@map and includes implicit many-to-many join tables', () => {
    const tables = prismaKnownTables({
      models: [
        { name: 'User', dbName: 'users', fields: [{ kind: 'object', relationName: 'PostToUser', isList: true }] },
        { name: 'Post', dbName: null, fields: [{ kind: 'object', relationName: 'PostToUser', isList: true }] },
      ],
    })
    expect(tables.sort()).toEqual(['public.Post', 'public._PostToUser', 'public.users'])
  })

  it('does not invent a join table for a one-to-many relation', () => {
    const tables = prismaKnownTables({
      models: [
        { name: 'User', fields: [{ kind: 'object', relationName: 'PostToUser', isList: true }] },
        { name: 'Post', fields: [{ kind: 'object', relationName: 'PostToUser', isList: false }] },
      ],
    })
    expect(tables).not.toContain('public._PostToUser')
  })
})

describe('withRetry', () => {
  it('retries a transient failure with growing backoff, then succeeds', async () => {
    const waits: number[] = []
    let calls = 0
    const result = await withRetry(
      'flaky',
      () => {
        calls++
        if (calls < 3) throw new Error('transient')
        return 'ok'
      },
      { sleep: (ms) => waits.push(ms), log: () => undefined },
    )
    expect(result).toBe('ok')
    expect(waits).toEqual([2000, 4000])
  })

  it('never retries a FatalError', async () => {
    let calls = 0
    await expect(
      withRetry(
        'fatal',
        () => {
          calls++
          throw new FatalError('misconfigured')
        },
        { sleep: () => undefined, log: () => undefined },
      ),
    ).rejects.toThrow('misconfigured')
    expect(calls).toBe(1)
  })

  it('never retries an ambiguous control-plane failure unless the caller says it is idempotent', async () => {
    let mutatingCalls = 0
    await expect(
      withRetry(
        'mutating',
        () => {
          mutatingCalls++
          throw new NeonRequestError('HTTP 503', 503, true)
        },
        { sleep: () => undefined, log: () => undefined },
      ),
    ).rejects.toThrow('HTTP 503')
    expect(mutatingCalls).toBe(1)

    let idempotentCalls = 0
    await expect(
      withRetry(
        'idempotent',
        () => {
          idempotentCalls++
          throw new NeonRequestError('HTTP 503', 503, true)
        },
        { attempts: 3, sleep: () => undefined, log: () => undefined, retryAmbiguous: true },
      ),
    ).rejects.toThrow('HTTP 503')
    expect(idempotentCalls).toBe(3)
  })
})

describe('Neon REST boundary', () => {
  it('never retries POST after headers arrive but reading the response body fails', async () => {
    let posts = 0
    const client = createNeonRestClient('test', async () => {
      posts++
      return { text: async () => { throw new Error('socket reset') }, status: 201, ok: true } as unknown as Response
    })
    await expect(withRetry('create', () => client.createBranch(PROJECT, { name: 'workspace/test', parentId: PARENT_ID, parentLsn: PARENT_LSN }), {
      attempts: 3, sleep: () => undefined, log: () => undefined,
    })).rejects.toMatchObject({ ambiguous: true })
    expect(posts).toBe(1)
  })

  it.each(['{}', 'null', '{bad', '{"branch":{"id":"br-other"}}'])('does not interpret malformed HTTP 200 lookup as absence: %s', async (body) => {
    const client = createNeonRestClient('test', async () => new Response(body, { status: 200 }))
    await expect(client.getBranchById(PROJECT, 'br-requested')).rejects.toThrow(/Unexpected Neon/)
  })

  it('uses only HTTP 404 as proof a branch is absent', async () => {
    const client = createNeonRestClient('test', async () => new Response('{"message":"not found"}', { status: 404 }))
    await expect(client.getBranchById(PROJECT, 'br-requested')).resolves.toBeNull()
  })

  it('requires database selection when the branch has multiple databases', async () => {
    vi.stubEnv('NEON_DATABASE_NAME', '')
    vi.stubEnv('NEON_ROLE_NAME', '')
    const client = createNeonRestClient('test', async (url) => new Response(JSON.stringify(String(url).includes('/databases')
      ? { databases: [{ name: 'first', owner_name: 'first_owner' }, { name: 'app', owner_name: 'app_owner' }] }
      : { uri: 'postgres://first_owner:p@child/first' })))
    await expect(client.connectionUri(PROJECT, 'br-child')).rejects.toThrow(/NEON_DATABASE_NAME/)
  })

  it('derives the role from the selected database rather than the first database', async () => {
    vi.stubEnv('NEON_DATABASE_NAME', 'app')
    vi.stubEnv('NEON_ROLE_NAME', '')
    let requestedRole: string | null = null
    const client = createNeonRestClient('test', async (url) => {
      if (String(url).includes('/databases')) return new Response(JSON.stringify({ databases: [{ name: 'first', owner_name: 'first_owner' }, { name: 'app', owner_name: 'app_owner' }] }))
      requestedRole = new URL(String(url)).searchParams.get('role_name')
      return new Response(JSON.stringify({ uri: 'postgres://app_owner:p@child/app' }))
    })
    await client.connectionUri(PROJECT, 'br-child')
    expect(requestedRole).toBe('app_owner')
  })
})

describe('workspace identity (unchanged naming convention)', () => {
  const worktree: GitContext = { isSecondaryWorktree: true, branch: 'martintechlabs/feature-x' }
  const singleClone: GitContext = { isSecondaryWorktree: false, branch: 'martintechlabs/feature-x' }

  it('prefers CONDUCTOR_WORKSPACE_NAME over every other source', () => {
    expect(resolveWorkspaceName({ CONDUCTOR_WORKSPACE_NAME: 'conductor-ws', ORCA_WORKSPACE_NAME: 'orca-ws', WORKSPACE_NAME: 'generic' }, '/tmp/dir', worktree)).toBe('conductor-ws')
  })

  it('falls back to the checkout basename for a secondary worktree, then the git branch', () => {
    expect(resolveWorkspaceName({}, '/tmp/my-worktree', worktree)).toBe('my-worktree')
    expect(resolveWorkspaceName({}, '/tmp/repo', singleClone)).toBe('martintechlabs/feature-x')
  })

  it('keeps the workspace/ prefix, slugification and hash-truncation of the previous design', () => {
    expect(workspaceBranchName('martintechlabs/feature-x')).toBe('workspace/martintechlabs-feature-x')
    const long = workspaceBranchName('a'.repeat(80))
    expect(long.startsWith('workspace/')).toBe(true)
    expect(long.slice('workspace/'.length).length).toBeLessThanOrEqual(48)
    expect(long).not.toMatch(/-$/)
  })
})

describe('.env.neondb upsert/strip', () => {
  const file = () => join(sandbox, '.env.neondb')

  it('updates a key in place, preserving unrelated lines and comments', () => {
    writeFileSync(file(), '# comment\nOTHER=1\nDATABASE_URL=old\n')
    upsertEnvVars(file(), { DATABASE_URL: 'postgres://new' })
    expect(readFileSync(file(), 'utf8')).toBe("# comment\nOTHER=1\nDATABASE_URL='postgres://new'\n")
  })

  it('strips only the managed keys, deleting the file when nothing is left', () => {
    writeFileSync(file(), "DATABASE_URL='x'\nOTHER=1\n")
    stripEnvVars(file(), ['DATABASE_URL'])
    expect(readFileSync(file(), 'utf8')).toBe('OTHER=1\n')
    stripEnvVars(file(), ['OTHER'])
    expect(existsSync(file())).toBe(false)
  })
})

describe('load-env.cjs (the startup guard)', () => {
  /** Run the preload hook exactly as the dev/build/test scripts do, and report what the child saw. */
  function boot(env: Record<string, string> = {}): { status: number | null; stdout: string; stderr: string } {
    const result = spawnSync(process.execPath, ['--require', './scripts/load-env.cjs', '-e', 'process.stdout.write(String(process.env.DATABASE_URL))'], {
      cwd: sandbox,
      encoding: 'utf8',
      env: { PATH: process.env.PATH ?? '', ...env },
    })
    return { status: result.status, stdout: result.stdout, stderr: result.stderr }
  }

  beforeEach(() => {
    mkdirSync(join(sandbox, 'scripts'), { recursive: true })
    writeFileSync(join(sandbox, 'scripts', 'load-env.cjs'), readFileSync(new URL('../scripts/load-env.cjs', import.meta.url), 'utf8'))
  })

  it('refuses to start an unprovisioned workspace', () => {
    const { status, stderr } = boot()
    expect(status).toBe(1)
    expect(stderr).toMatch(/has no database/)
  })

  it.each(['creating', 'pending', 'deleting'] as const)('refuses to start against a "%s" branch', (status) => {
    writeState({ branchId: status === 'creating' ? null : 'br-x', branchName: 'workspace/feature-x', projectId: PROJECT, status })
    upsertEnvVars(join(sandbox, '.env.neondb'), { DATABASE_URL: 'postgres://u:p@workspace-host/appdb' })
    const result = boot()
    expect(result.status).toBe(1)
    expect(result.stderr).toMatch(new RegExp(`state "${status}", not "ready"`))
  })

  it('overrides an ambient DATABASE_URL — the shared database never wins', () => {
    writeState({ branchId: 'br-x', branchName: 'workspace/feature-x', projectId: PROJECT, status: 'ready' })
    upsertEnvVars(join(sandbox, '.env.neondb'), { DATABASE_URL: 'postgres://u:p@workspace-host/appdb' })
    const { status, stdout } = boot({ DATABASE_URL: 'postgres://u:p@SHARED-production-host/appdb' })
    expect(status).toBe(0)
    expect(stdout).toBe('postgres://u:p@workspace-host/appdb')
  })

  it('reads the URL literally, so a $ in a generated password survives', () => {
    writeState({ branchId: 'br-x', branchName: 'workspace/feature-x', projectId: PROJECT, status: 'ready' })
    upsertEnvVars(join(sandbox, '.env.neondb'), { DATABASE_URL: 'postgres://u:pa$$w0rd@workspace-host/appdb' })
    expect(boot({ HOME: sandbox }).stdout).toBe('postgres://u:pa$$w0rd@workspace-host/appdb')
  })

  it('refuses when the state is ready but the managed URL is absent', () => {
    writeState({ branchId: 'br-x', branchName: 'workspace/feature-x', projectId: PROJECT, status: 'ready' })
    upsertEnvVars(join(sandbox, '.env.neondb'), { NEON_PROJECT_ID: PROJECT })
    const { status, stderr } = boot({ DATABASE_URL: 'postgres://u:p@SHARED-production-host/appdb' })
    expect(status).toBe(1)
    expect(stderr).toMatch(/does not define DATABASE_URL/)
  })
})
