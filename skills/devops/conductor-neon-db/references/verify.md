# Verifying against real Neon

Read this when you want end-to-end confidence that provisioning works on the project's actual
Neon project — beyond `tsc`/unit tests. It exercises the **true-ledger baseline**: a throwaway
`conductor/verify` workspace branch (schema-only) plus a throwaway `tmp/verify` check branch
(full data), confirms the check branch's real migration ledger gets copied verbatim into the
workspace branch, confirms migrate-deploy applies whatever's still missing, and deletes both.
Production is never touched: every database op targets one of the two throwaway branches, and
both branch names carry the prefix (`conductor/` or `tmp/`) the safety guard requires.

The walkthrough below is written for **Prisma**; a **Drizzle** variant follows at the end, with
the per-step deltas (different migrations table, no `prisma db execute`, `drizzle-kit migrate`
as the "nothing to apply" check).

Assumes `neonctl` is authenticated (`neonctl auth`) and you know the Neon `PROJECT_ID` and the
production/parent branch name. `<pm>` below is `pnpm exec` / `npx` / `yarn`.

## 1. A snapshot helper (shows the state of a branch)

Write this to `/tmp/snapshot.sql`. It reports PostGIS presence, `spatial_ref_sys` count, both
migration tables' counts (`public._prisma_migrations` and `drizzle.__drizzle_migrations` —
whichever exists; the other shows `-99`), and every public table's row count — surfaced via a
deliberate `RAISE EXCEPTION` because `prisma db execute` doesn't return query results.

```sql
DO $$
DECLARE has_postgis boolean; srs bigint := -1; srs_schema text; mig bigint := -1; dmig bigint := -1;
        t text; n bigint; counts text := '';
BEGIN
  SELECT EXISTS(SELECT 1 FROM pg_extension WHERE extname='postgis') INTO has_postgis;
  SELECT schemaname INTO srs_schema FROM pg_tables WHERE tablename='spatial_ref_sys' LIMIT 1;
  IF srs_schema IS NOT NULL THEN EXECUTE format('SELECT count(*) FROM %I.spatial_ref_sys', srs_schema) INTO srs; END IF;
  BEGIN SELECT count(*) INTO mig FROM public._prisma_migrations; EXCEPTION WHEN undefined_table THEN mig := -99; END;
  BEGIN SELECT count(*) INTO dmig FROM drizzle.__drizzle_migrations; EXCEPTION WHEN undefined_table THEN dmig := -99; END;
  FOR t IN SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename
  LOOP EXECUTE format('SELECT count(*) FROM public.%I', t) INTO n; counts := counts||t||'='||n||' '; END LOOP;
  RAISE EXCEPTION 'SNAP postgis=% srs[%]=% _prisma_migrations=% __drizzle_migrations=% | %',
    has_postgis, coalesce(srs_schema,'-'), srs, mig, dmig, counts;
END $$;
```

## 2. Set up a *deliberately behind* parent, so the true-baseline fix actually has something to fix

The bug this mechanism fixes only shows up when production hasn't run every migration committed
on this code branch — verifying against a parent that's already fully caught up would pass even
with the old, buggy file-derived baseline. Pick (or create) a **throwaway** Neon branch to stand
in as `PARENT` — never point this verification at real production — and leave at least one
migration file committed locally that this stand-in parent has never run:

```bash
PROJECT=<neon-project-id>; PARENT=conductor/verify-parent
<pm> neonctl branches delete "$PARENT" --project-id "$PROJECT" </dev/null >/dev/null 2>&1  # clear leftover
<pm> neonctl branches create --project-id "$PROJECT" --name "$PARENT" --parent production --output json </dev/null >/dev/null && echo "created $PARENT"
PCS=$(<pm> neonctl connection-string "$PARENT" --project-id "$PROJECT" </dev/null)
# Apply all but the LATEST migration to $PARENT, e.g.:
DATABASE_URL="$PCS" <pm> prisma migrate deploy   # or: apply all but the newest migration by hand
```

`$PARENT` now plays the role `NEON_PARENT_BRANCH` normally does — it's what the check branch and
the workspace branch both clone from below.

## 3. Run the flow

```bash
BR=conductor/verify; CHECK=tmp/verify
trap '<pm> neonctl branches delete "$BR" --project-id "$PROJECT" </dev/null >/dev/null 2>&1; \
      <pm> neonctl branches delete "$CHECK" --project-id "$PROJECT" </dev/null >/dev/null 2>&1; \
      echo "cleaned up $BR and $CHECK"' EXIT
<pm> neonctl branches delete "$BR" --project-id "$PROJECT" </dev/null >/dev/null 2>&1     # clear leftovers
<pm> neonctl branches delete "$CHECK" --project-id "$PROJECT" </dev/null >/dev/null 2>&1

# 1) instant schema-only workspace branch off the (deliberately behind) parent
<pm> neonctl branches create --project-id "$PROJECT" --name "$BR" --parent "$PARENT" --schema-only --output json </dev/null >/dev/null && echo created
CS=$(<pm> neonctl connection-string "$BR" --project-id "$PROJECT" </dev/null)

# 2) full-data check branch off the SAME parent — this is what teaches provisioning the parent's
#    TRUE applied-migration set, instead of assuming the local migration files match it
<pm> neonctl branches create --project-id "$PROJECT" --name "$CHECK" --parent "$PARENT" --output json </dev/null >/dev/null && echo "check branch created"
CHECK_CS=$(<pm> neonctl connection-string "$CHECK" --project-id "$PROJECT" </dev/null)

# wake both cold computes (first connection may fail; the next command then succeeds)
echo "SELECT 1;" | <pm> prisma db execute --url "$CS" --stdin >/dev/null 2>&1
echo "SELECT 1;" | <pm> prisma db execute --url "$CS" --stdin >/dev/null 2>&1 && echo "workspace compute awake"
echo "SELECT 1;" | <pm> prisma db execute --url "$CHECK_CS" --stdin >/dev/null 2>&1
echo "SELECT 1;" | <pm> prisma db execute --url "$CHECK_CS" --stdin >/dev/null 2>&1 && echo "check compute awake"

# 3) snapshot the WORKSPACE branch before baseline: expect postgis=t, spatial_ref_sys populated,
#    _prisma_migrations=0, app tables=0
<pm> prisma db execute --url "$CS" --file /tmp/snapshot.sql 2>&1 | grep -oiE 'SNAP .*'

# 4) snapshot the CHECK branch: this is the parent's TRUE state — _prisma_migrations should show
#    fewer rows than the project's full migration count (that's the point of step 2 above)
<pm> prisma db execute --url "$CHECK_CS" --file /tmp/snapshot.sql 2>&1 | grep -oiE 'SNAP .*'

# 5) baseline the WORKSPACE branch from the CHECK branch's true ledger, then confirm migrate
#    status is clean and the missing migration(s) actually ran
<pm> prisma db execute --url "$CS" --file /tmp/true-baseline.sql >/dev/null 2>&1
DATABASE_URL="$CS" <pm> prisma migrate deploy   # should apply exactly the migration(s) $PARENT never ran
DATABASE_URL="$CS" <pm> prisma migrate status   # want: "Database schema is up to date!"

# 6) delete the check branch NOW — provisioning does this immediately after reading the ledger,
#    never keeping a connection to it open longer than necessary
<pm> neonctl branches delete "$CHECK" --project-id "$PROJECT" </dev/null >/dev/null 2>&1 && echo "check branch deleted"

# 7) seed (authorized for this branch only), then snapshot AFTER: _prisma_migrations matches the
#    project's FULL migration count now (migrate deploy caught it up), app tables have fixtures
DATABASE_URL="$CS" E2E_EXPECTED_DATABASE_URL="$CS" <seed-creds> <pm> tsx prisma/seed.ts
<pm> prisma db execute --url "$CS" --file /tmp/snapshot.sql 2>&1 | grep -oiE 'SNAP .*'
```

To produce `/tmp/true-baseline.sql`, run a tiny script that:
1. Queries the check branch for its real ledger: `SELECT checksum, migration_name FROM "_prisma_migrations" WHERE finished_at IS NOT NULL AND rolled_back_at IS NULL ORDER BY started_at`.
2. Passes the rows to `buildPrismaLedgerBaselineSql` (imported from `scripts/conductor-db.ts`) and writes the result.

This exercises the exact read/build code the real provisioning uses — the only difference is
driving it by hand instead of through `provision()`.

## What "good" looks like

```
workspace before: postgis=t  spatial_ref_sys=<N>  _prisma_migrations=0   app tables all 0
check (true state): _prisma_migrations=<N-1>   (fewer than the project's full migration count)
deploy:  applies exactly the migration(s) the check branch didn't have
status:  Database schema is up to date!
after:   postgis=t  spatial_ref_sys=<N>  _prisma_migrations=<full migration count>  app tables seeded
```

If `migrate status` is **not** "up to date" after baselining, the checksums don't match what
Prisma itself wrote to the check branch's ledger — check that the baseline SQL used the rows
read back from the check branch verbatim, not values recomputed from local `migration.sql` files
(that's precisely the bug this mechanism replaces).

## Drizzle variant

Same two-branch lifecycle (steps 1–2 identical: a throwaway schema-only `conductor/verify`
workspace branch **and** a throwaway full-data `tmp/verify` check branch, both off a
deliberately-behind `$PARENT`). Deltas:

1. **Migrations table.** Watch `__drizzle_migrations=` in the snapshot, not `_prisma_migrations=`
   (it lives in the `drizzle` schema). On the check branch this should show fewer rows than the
   project's full migration count; on the workspace branch, `0` before baseline.
2. **Reading the true ledger and executing the baseline.** Drizzle has no `prisma db execute`,
   so both the check branch's `SELECT hash, created_at FROM "drizzle"."__drizzle_migrations"`
   read and the workspace branch's baseline INSERT go through the project's Postgres driver —
   the same `execSql` you wired in the script — or, for a throwaway manual check where `psql` is
   handy, `psql "$CHECK_CS" -c '...'` to read and `psql "$CS" -f /tmp/true-baseline.sql` to
   write. Produce `/tmp/true-baseline.sql` by feeding the check branch's rows straight into
   `buildDrizzleLedgerBaselineSql` (imported from `scripts/conductor-db.ts`) — exercising the
   exact code the real provisioning uses.
3. **The "nothing pending" check.** Instead of `prisma migrate status`, run
   `DATABASE_URL="$CS" <pm> drizzle-kit migrate` after baselining — it should apply exactly the
   migration(s) `$PARENT` never ran and then report nothing left to do. If it instead tries to
   re-apply migrations the check branch's ledger DID have (and fails because those tables already
   exist), the baseline rows are missing or their `created_at` doesn't match what the check
   branch's ledger actually recorded — drizzle-kit decides what to run by the latest
   `created_at`, so it must come from the observed rows, not a value re-derived locally.

```
workspace before: postgis=t  spatial_ref_sys=<N>  __drizzle_migrations=0                app tables all 0
check (true state): __drizzle_migrations=<N-1>  (fewer than the project's full migration count)
migrate: applies exactly the migration(s) the check branch didn't have, then nothing left to run
after:   postgis=t  spatial_ref_sys=<N>  __drizzle_migrations=<full migration count>  app tables seeded
```
