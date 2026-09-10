# Verifying against real Neon

Read this when you want end-to-end confidence beyond `tsc` and the bundled tests. It exercises the
two things that only a live Neon project can prove: that the workspace branch really is an **ordinary
child** (a `parent_id` and a `parent_lsn`, no root-branch slot consumed), and that the **purge**
leaves production's migration ledger intact while emptying every application table.

Everything below runs against a **throwaway stand-in parent**, never real production. `<pm>` is
`pnpm exec` / `npx` / `yarn`.

```bash
PROJECT=<neon-project-id>
export NEON_API_KEY=<your-key>
API=https://console.neon.tech/api/v2
neon() { curl -sS -H "Authorization: Bearer $NEON_API_KEY" -H 'Content-Type: application/json' "$@"; }
```

## 1. Confirm the bug you are fixing (optional, but convincing)

Any branch created with `--schema-only` has no parent. On a project that still has one:

```bash
neon "$API/projects/$PROJECT/branches" | jq -r '.branches[] | [.name, .init_source, (.parent_id // "ROOT"), (.parent_lsn // "-")] | @tsv'
```

A `parent-schema` row with `ROOT` in the parent column is a branch consuming a root slot. Root
allowances are 3 (Free), 5 (Launch), 25 (Scale) — that is how `ROOT_BRANCHES_LIMIT_EXCEEDED` happens.

## 2. Build a stand-in parent that is deliberately behind

The interesting case is production missing a migration this checkout has, so the purge and the
post-purge `migrate deploy` both have real work. Create a throwaway parent, apply all but the newest
migration, and put some rows in it so the purge has something to remove.

```bash
PARENT_ID=$(neon "$API/projects/$PROJECT/branches" \
  -d '{"branch":{"name":"workspace/verify-parent"},"endpoints":[{"type":"read_write"}]}' | jq -r '.branch.id')
PARENT_CS=$(neon "$API/projects/$PROJECT/branches" | jq -r --arg id "$PARENT_ID" '.branches[]|select(.id==$id)|.id' >/dev/null; \
  neon "$API/projects/$PROJECT/connection_uri?branch_id=$PARENT_ID&database_name=<db>&role_name=<role>" | jq -r '.uri')

# Apply all but the newest migration to the stand-in parent, then give it data:
DATABASE_URL="$PARENT_CS" <pm> prisma migrate deploy
psql "$PARENT_CS" -c "INSERT INTO users (email) VALUES ('stand-in-prod@example.com')"
```

Point provisioning at it: `NEON_PARENT_BRANCH=workspace/verify-parent` (a `br-…` id works too).

## 3. Provision, and check every claim

```bash
NEON_PROJECT_ID=$PROJECT NEON_PARENT_BRANCH=workspace/verify-parent WORKSPACE_NAME=verify \
  <pm> tsx scripts/neondb-branch.ts provision
```

Then assert, in order:

```bash
cat .neondb/state.json
# want: {"branchId":"br-…","branchName":"workspace/verify","projectId":"…","status":"ready"}
# and NO credentials anywhere in that file.

cat "$(git rev-parse --absolute-git-dir)/neondb-workspace.json"
# want: matching branch/project ids, creation parent/LSN, and databaseTarget with NO credentials.

BR=$(jq -r .branchId .neondb/state.json)
neon "$API/projects/$PROJECT/branches/$BR" | jq '.branch | {parent_id, parent_lsn, init_source, protected, default}'
# want: parent_id == the stand-in parent's id, parent_lsn a real "0/…" value,
#       init_source "parent-data". A null parent_id here means the root-slot bug is back.

CS=$(grep '^DATABASE_URL=' .env.neondb | cut -d= -f2- | tr -d "'")
psql "$CS" -c "SELECT count(*) FROM _prisma_migrations"   # ledger INHERITED, not rebuilt
psql "$CS" -c "SELECT count(*) FROM users"                # 0 (or just the seed's fixtures)
DATABASE_URL="$CS" <pm> prisma migrate status             # "Database schema is up to date!"
```

The migration the stand-in parent never ran should have been applied by provisioning, and the ledger
count should now equal the project's full migration count. For Drizzle, read
`drizzle.__drizzle_migrations` instead and use `drizzle-kit migrate` for the "nothing left to run"
check.

### Check the fail-closed path

Add a table the checkout does not know about, then re-provision:

```bash
psql "$PARENT_CS" -c "CREATE TABLE surprise_table (id serial PRIMARY KEY)"
<pm> tsx scripts/neondb-branch.ts provision
# want: it FAILS with "table(s) public.surprise_table", deletes the branch it just created,
#       and leaves no .neondb/state.json behind.
psql "$PARENT_CS" -c "DROP TABLE surprise_table"
```

### Check that a rename does not move the database

```bash
neon -X PATCH "$API/projects/$PROJECT/branches/$BR" -d '{"branch":{"name":"workspace/renamed-by-hand"}}'
<pm> tsx scripts/neondb-branch.ts sync
jq -r '.branchId, .branchName' .neondb/state.json
# want: the SAME branchId, with branchName refreshed to "workspace/renamed-by-hand".
```

Then, still with `WORKSPACE_NAME=verify`, confirm `sync` logs that identity and ownership have
diverged and keeps the recorded branch rather than creating or adopting anything.

### Check copied-file guards

In a separate disposable Git worktree, copy only the ready workspace's `.neondb/state.json` and
`.env.neondb`. Both `sync` and `teardown` must refuse the missing/foreign ownership receipt before
contacting Neon; the startup preload must refuse too. Do not copy private Git metadata. Remove the
copied files after the check. The original workspace must still sync successfully.

## 4. Tear down and check the cleanup

```bash
echo "note" > .neondb/keep-me.txt
<pm> tsx scripts/neondb-branch.ts teardown

neon "$API/projects/$PROJECT/branches/$BR" | jq -r '.message // "gone"'   # want: an error/404
ls .neondb                                                                # want: keep-me.txt only
grep DATABASE_URL .env.neondb || echo "DATABASE_URL withdrawn"
test ! -e "$(git rev-parse --absolute-git-dir)/neondb-workspace.json"
rm .neondb/keep-me.txt && rmdir .neondb
```

Re-run `teardown` once more: it should report there is nothing to tear down rather than failing.

## 5. Clean up the stand-in parent

```bash
neon -X DELETE "$API/projects/$PROJECT/branches/$PARENT_ID"
```

## What "good" looks like

```
state.json:  status=ready, branchId=br-…, no credentials
branch:      parent_id=<stand-in parent>, parent_lsn=0/…, init_source=parent-data   ← not a root branch
ledger:      inherited from the parent, then caught up by migrate deploy
app tables:  empty (or seeded fixtures only) — no stand-in-prod rows
unknown table: provisioning FAILS CLOSED and cleans up after itself
rename:      same branchId, refreshed branchName, no adoption
teardown:    branch gone, DATABASE_URL withdrawn, unrelated files in .neondb preserved
```

If the branch comes back with a null `parent_id`, provisioning fell back to schema-only branching and
the root-slot bug is back. If `migrate status` is not up to date, the ledger was not inherited —
check that the branch really is `init_source: parent-data` and that the purge preserved
`_prisma_migrations`.
