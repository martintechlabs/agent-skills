// Purge tests against REAL Postgres, in-process, via PGlite — no server, no network, no Neon.
// The purge is the one part of provisioning whose correctness is a property of Postgres itself
// (transaction semantics, TRUNCATE … CASCADE, catalog introspection), so faking it would test
// nothing. When you copy this into a project, adjust the import path to your layout.
import { PGlite } from '@electric-sql/pglite'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  discoverTables,
  planPurge,
  purgeApplicationRows,
  verifyTablesEmpty,
  type SqlClient,
} from '../scripts/neondb-branch'

let db: PGlite
let client: SqlClient

/** The same adapter shape a project wires into the script's `connect()` knob. */
function adapt(instance: PGlite): SqlClient {
  return { query: async <T>(sql: string, params?: unknown[]) => (await instance.query<T>(sql, params as never[])).rows }
}

async function rowCount(table: string): Promise<number> {
  const rows = await client.query<{ n: number | string }>(`SELECT count(*)::bigint AS n FROM ${table}`)
  return Number(rows[0].n)
}

beforeEach(async () => {
  db = new PGlite()
  client = adapt(db)
  // A branch as it looks immediately after cloning production: application rows AND the inherited
  // migration ledger, which is precisely what an ordinary child gives us and a schema-only branch
  // does not.
  await db.exec(`
    CREATE TABLE public.users (id serial PRIMARY KEY, email text NOT NULL);
    CREATE TABLE public.orders (id serial PRIMARY KEY, user_id integer NOT NULL REFERENCES public.users(id));
    CREATE TABLE public._prisma_migrations (
      id text PRIMARY KEY, checksum text NOT NULL, finished_at timestamptz,
      migration_name text NOT NULL, logs text, rolled_back_at timestamptz,
      started_at timestamptz NOT NULL DEFAULT now(), applied_steps_count integer NOT NULL DEFAULT 0
    );
    INSERT INTO public.users (email) VALUES ('prod-user-1@example.com'), ('prod-user-2@example.com');
    INSERT INTO public.orders (user_id) VALUES (1), (1), (2);
    INSERT INTO public._prisma_migrations (id, checksum, finished_at, migration_name, applied_steps_count)
      VALUES ('a', 'aa', now(), '20260101000000_init', 1), ('b', 'bb', now(), '20260201000000_orders', 1);
    CREATE VIEW public.active_users AS SELECT * FROM public.users;
  `)
})

afterEach(async () => {
  await db.close()
})

const KNOWN = ['public.users', 'public.orders']

describe('discoverTables', () => {
  it('finds base tables only — views are not tables and must not be classified', async () => {
    const found = await discoverTables(client)
    expect(found.map((t) => `${t.schema}.${t.name}`).sort()).toEqual(['public._prisma_migrations', 'public.orders', 'public.users'])
  })

  it('ignores partitions, whose parent is truncated for them', async () => {
    await db.exec(`
      CREATE TABLE public.events (id serial, at date NOT NULL) PARTITION BY RANGE (at);
      CREATE TABLE public.events_2026 PARTITION OF public.events FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
    `)
    const names = (await discoverTables(client)).map((t) => t.name)
    expect(names).toContain('events')
    expect(names).not.toContain('events_2026')
  })

  it('flags extension-owned tables so the purge never empties reference data', async () => {
    await db.exec(`
      CREATE EXTENSION IF NOT EXISTS plpgsql;
      CREATE TABLE public.spatial_ref_sys (srid integer PRIMARY KEY, srtext text);
      INSERT INTO pg_depend (classid, objid, objsubid, refclassid, refobjid, refobjsubid, deptype)
        VALUES ('pg_class'::regclass, 'public.spatial_ref_sys'::regclass, 0,
                'pg_extension'::regclass, (SELECT oid FROM pg_extension WHERE extname = 'plpgsql'), 0, 'e');
    `)
    const found = await discoverTables(client)
    expect(found.find((t) => t.name === 'spatial_ref_sys')?.extensionOwned).toBe(true)
    expect(found.find((t) => t.name === 'users')?.extensionOwned).toBe(false)

    const plan = planPurge(found, KNOWN)
    expect(plan.preserved).toContain('public.spatial_ref_sys')
    expect(plan.truncate).toEqual(['public.orders', 'public.users'])
  })
})

describe('purgeApplicationRows', () => {
  it('empties every application table while leaving the inherited migration ledger intact', async () => {
    const plan = planPurge(await discoverTables(client), KNOWN)
    await purgeApplicationRows(client, plan)

    expect(await rowCount('public.users')).toBe(0)
    expect(await rowCount('public.orders')).toBe(0)
    expect(await rowCount('public._prisma_migrations')).toBe(2)
    await expect(verifyTablesEmpty(client, plan.truncate)).resolves.toBeUndefined()
  })

  it('empties tables in any foreign-key direction — a single CASCADE truncate cannot deadlock on order', async () => {
    // users is referenced BY orders; truncating it alone would fail without the combined statement.
    const plan = planPurge(await discoverTables(client), KNOWN)
    expect(plan.truncate).toEqual(['public.orders', 'public.users'])
    await expect(purgeApplicationRows(client, plan)).resolves.toBeUndefined()
  })

  it('restarts identity sequences, so a fresh workspace starts from 1', async () => {
    await purgeApplicationRows(client, planPurge(await discoverTables(client), KNOWN))
    await client.query("INSERT INTO public.users (email) VALUES ('first@example.com')")
    const rows = await client.query<{ id: number }>('SELECT id FROM public.users')
    expect(rows[0].id).toBe(1)
  })

  it('rolls the whole purge back when the transaction cannot commit — never half-purged', async () => {
    const statements: string[] = []
    const failingAtCommit: SqlClient = {
      query: async <T>(sql: string, params?: unknown[]) => {
        statements.push(sql)
        if (sql === 'COMMIT') throw new Error('connection reset before commit')
        return client.query<T>(sql, params)
      },
    }
    const plan = planPurge(await discoverTables(client), KNOWN)
    await expect(purgeApplicationRows(failingAtCommit, plan)).rejects.toThrow('connection reset before commit')

    expect(statements).toEqual(['BEGIN', 'TRUNCATE TABLE "public"."orders", "public"."users" RESTART IDENTITY CASCADE', 'COMMIT', 'ROLLBACK'])
    // The rows survive, which is the proof the TRUNCATE really was inside a transaction.
    expect(await rowCount('public.users')).toBe(2)
    expect(await rowCount('public.orders')).toBe(3)
  })

  it('rolls back when one table in the plan does not exist, leaving the others untouched', async () => {
    await expect(purgeApplicationRows(client, { truncate: ['public.users', 'public.does_not_exist'], preserved: [] })).rejects.toThrow()
    expect(await rowCount('public.users')).toBe(2)
  })

  it('is a no-op when there is nothing to purge', async () => {
    await expect(purgeApplicationRows(client, { truncate: [], preserved: ['public._prisma_migrations'] })).resolves.toBeUndefined()
    expect(await rowCount('public._prisma_migrations')).toBe(2)
  })
})

describe('verifyTablesEmpty (the gate before any URL is published)', () => {
  it('refuses to pass a table that still holds rows', async () => {
    await expect(verifyTablesEmpty(client, ['public.users'])).rejects.toThrow(/public\.users=2/)
  })

  it('passes once the purge has run', async () => {
    await purgeApplicationRows(client, planPurge(await discoverTables(client), KNOWN))
    await expect(verifyTablesEmpty(client, ['public.users', 'public.orders'])).resolves.toBeUndefined()
  })
})

describe('fail-closed classification against a real catalog', () => {
  it('refuses when production carries a table this checkout has never heard of', async () => {
    await db.exec('CREATE TABLE public.invoices (id serial PRIMARY KEY, total numeric NOT NULL)')
    const found = await discoverTables(client)
    expect(() => planPurge(found, KNOWN)).toThrow(/table\(s\) public\.invoices/)
  })

  it('refuses when production carries a whole schema this checkout has never heard of', async () => {
    await db.exec('CREATE SCHEMA billing; CREATE TABLE billing.entries (id serial PRIMARY KEY)')
    const found = await discoverTables(client)
    expect(() => planPurge(found, KNOWN)).toThrow(/schema\(s\) billing/)
  })

  it('accepts production being BEHIND this checkout — a known table that does not exist yet', async () => {
    const plan = planPurge(await discoverTables(client), [...KNOWN, 'public.not_migrated_yet'])
    expect(plan.truncate).toEqual(['public.orders', 'public.users'])
  })

  it('survives an identifier that needs quoting', async () => {
    await db.exec('CREATE TABLE public."odd ""name" (id serial PRIMARY KEY)')
    await db.exec('INSERT INTO public."odd ""name" DEFAULT VALUES')
    const plan = planPurge(await discoverTables(client), [...KNOWN, 'public.odd "name'])
    await purgeApplicationRows(client, plan)
    expect(await rowCount('public."odd ""name"')).toBe(0)
  })
})

describe('slow connection acquisition', () => {
  it('an adapter that takes seconds to hand back a session still works end to end', async () => {
    const slow: SqlClient = {
      query: async <T>(sql: string, params?: unknown[]) => {
        await new Promise((resolve) => setTimeout(resolve, 25))
        return client.query<T>(sql, params)
      },
    }
    const plan = planPurge(await discoverTables(slow), KNOWN)
    await purgeApplicationRows(slow, plan)
    await expect(verifyTablesEmpty(slow, plan.truncate)).resolves.toBeUndefined()
  })
})
