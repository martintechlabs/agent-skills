# Verifying against real Neon

Read this when you want end-to-end confidence that provisioning works on the project's actual
Neon project — beyond `tsc`/unit tests. It provisions a **throwaway** `conductor/verify` branch,
confirms the schema-only → baseline → (seed) flow, and deletes it. Production is never touched:
every database op uses the throwaway branch's connection string, and the branch name carries the
`conductor/` prefix the safety guard requires.

Assumes `neonctl` is authenticated (`neonctl auth`) and you know the Neon `PROJECT_ID` and the
production/parent branch name.

## 1. A snapshot helper (shows the state of a branch)

Write this to `/tmp/snapshot.sql`. It reports PostGIS presence, `spatial_ref_sys` count,
`_prisma_migrations` count, and every public table's row count — surfaced via a deliberate
`RAISE EXCEPTION` because `prisma db execute` doesn't return query results.

```sql
DO $$
DECLARE has_postgis boolean; srs bigint := -1; srs_schema text; mig bigint := -1;
        t text; n bigint; counts text := '';
BEGIN
  SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname='postgis') INTO has_postgis;
  SELECT schemaname INTO srs_schema FROM pg_tables WHERE tablename='spatial_ref_sys' LIMIT 1;
  IF srs_schema IS NOT NULL THEN EXECUTE format('SELECT count(*) FROM %I.spatial_ref_sys', srs_schema) INTO srs; END IF;
  BEGIN SELECT count(*) INTO mig FROM public._prisma_migrations; EXCEPTION WHEN undefined_table THEN mig := -99; END;
  FOR t IN SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename
  LOOP EXECUTE format('SELECT count(*) FROM public.%I', t) INTO n; counts := counts||t||'='||n||' '; END LOOP;
  RAISE EXCEPTION 'SNAP postgis=% srs[%]=% _prisma_migrations=% | %', has_postgis, coalesce(srs_schema,'-'), srs, mig, counts;
END $$;
```

## 2. Run the flow

Set `PROJECT`, `PARENT` (e.g. `production`), and the package-manager exec prefix to match the
project. `<pm>` below is `pnpm exec` / `npx` / `yarn`.

```bash
PROJECT=<neon-project-id>; PARENT=production; BR=conductor/verify
trap '<pm> neonctl branches delete "$BR" --project-id "$PROJECT" </dev/null >/dev/null 2>&1; echo "cleaned up $BR"' EXIT
<pm> neonctl branches delete "$BR" --project-id "$PROJECT" </dev/null >/dev/null 2>&1  # clear leftover

# 1) instant schema-only branch off production
<pm> neonctl branches create --project-id "$PROJECT" --name "$BR" --parent "$PARENT" --schema-only --output json </dev/null >/dev/null && echo created
CS=$(<pm> neonctl connection-string "$BR" --project-id "$PROJECT" </dev/null)

# wake the cold compute (first connection may fail; the next command then succeeds)
echo "SELECT 1;" | <pm> prisma db execute --url "$CS" --stdin >/dev/null 2>&1
echo "SELECT 1;" | <pm> prisma db execute --url "$CS" --stdin >/dev/null 2>&1 && echo "compute awake"

# 2) snapshot BEFORE baseline: expect postgis=t, spatial_ref_sys populated, _prisma_migrations=0, app tables=0
<pm> prisma db execute --url "$CS" --file /tmp/snapshot.sql 2>&1 | grep -oiE 'SNAP .*'

# 3) baseline using the project's OWN buildBaselineSql, then confirm migrate status is clean
#    (generate the INSERT however you like; the script's baselineMigrations does exactly this)
<pm> prisma db execute --url "$CS" --file /tmp/baseline.sql >/dev/null 2>&1
DATABASE_URL="$CS" <pm> prisma migrate status   # want: "Database schema is up to date!"

# 4) seed (authorized for this branch only), then snapshot AFTER: _prisma_migrations matches the
#    migration count, app tables now have fixtures
DATABASE_URL="$CS" E2E_EXPECTED_DATABASE_URL="$CS" <seed-creds> <pm> tsx prisma/seed.ts
<pm> prisma db execute --url "$CS" --file /tmp/snapshot.sql 2>&1 | grep -oiE 'SNAP .*'
```

To produce `/tmp/baseline.sql` from the project's own logic, run a tiny script that imports
`buildBaselineSql` from `scripts/conductor-db.ts`, feeds it the migrations read from
`prisma/migrations/*/migration.sql`, and writes the result — that exercises the exact checksum
code the real provisioning uses.

## What "good" looks like

```
before:  postgis=t  spatial_ref_sys=<N>  _prisma_migrations=0   app tables all 0
status:  Database schema is up to date!
after:   postgis=t  spatial_ref_sys=<N>  _prisma_migrations=<migration count>  app tables seeded
```

If `migrate status` is **not** "up to date" after baselining, the checksums don't match Prisma's
— check that migrations are read as the raw `migration.sql` bytes/text, unchanged.
