# neondb-branch — normal-child provisioning + explicit lifecycle state — Design

**Date:** 2026-09-09
**Category:** `devops`
**Status:** Approved
**Supersedes parts of:** `docs/superpowers/specs/2026-07-28-neondb-branch-design.md`

## Problem

Two defects, one structural and one representational.

### 1. Schema-only branches consume root-branch slots

`provision()` creates the per-workspace branch with `neonctl branches create --schema-only
--parent <production>`. Neon's own documentation is explicit: *"Schema-only branches are root
branches, meaning they have no parent. As a root branch, each schema-only branch starts an
independent line of data in a Neon project."* Passing `--parent` does **not** make a schema-only
branch a child — the parent is only the schema donor.

Verified empirically against a live Neon project (`orange-forest-39329018`, Launch plan):

| Branch | `init_source` | `parent_id` | `parent_lsn` |
|---|---|---|---|
| `production` | `parent-data` | *(absent)* | *(absent)* |
| `workspace/toadfish-…` | `parent-schema` | *(absent)* | *(absent)* |
| `workspace/dab-…` | `parent-schema` | *(absent)* | *(absent)* |
| `vercel-dev` | `parent-data` | `br-sweet-resonance-arsioaz3` | `0/1BBADB0` |

Every workspace branch is a root branch. Root-branch allowances are 3 (Free), 5 (Launch), 25
(Scale) per project. Three concurrent workspaces on Launch is enough to hit
`ROOT_BRANCHES_LIMIT_EXCEEDED` and block all provisioning — including the disposable `tmp/*`
check branch, which is a *second* clone per run (a full-data one, so it is a normal child and
does not itself consume a root slot, but it doubles the API churn).

### 2. Tracking state is a name in a text file

`.neondb/branch` holds a branch **name** on line 1 and an undocumented `pending`/`ready` marker on
line 2, with a sibling `.neondb/branch-check` holding the check branch's name. Consequences:

- A branch is identified by a mutable display string. `sync()` renames the live Neon branch to
  follow a git-branch change or a workspace rename, and refuses only when the target name is
  already live. Names are not identity: a name freed by one workspace and reused by another is
  indistinguishable from "our branch, renamed".
- Line 2 is a bare word with no schema, and a file *without* it is silently read as `ready` —
  a legacy-compatibility path that makes an incomplete state look complete.
- There is no project binding, so a state file copied between checkouts pointed at different
  Neon projects is accepted.

## Solution

### One ordinary child of production

Replace the schema-only branch **and** the separate `tmp/*` migration-ledger clone with a single
normal, full-data child of the configured production branch.

- Capture the parent's current WAL LSN (`SELECT pg_current_wal_lsn()` against the parent,
  read-only, one statement) and create the child pinned at that snapshot.
- Create via the Neon REST API, not `neonctl branches create`: `--parent` accepts a name **or** an
  LSN as one value (verified against `neonctl@latest branches create --help`), so a named parent
  plus an explicit `parent_lsn` is not expressible through the CLI. `POST
  /projects/{id}/branches` with `{branch: {name, parent_id, parent_lsn}, endpoints:
  [{type: "read_write"}]}` is, and it returns the branch object (with its `br-…` id) plus
  `connection_uris[0].connection_uri` in one round trip.
- Verify the returned branch before any destructive SQL: id shape, exact name, `parent_id` equals
  the resolved production id, `parent_lsn` equals the captured LSN, and the branch is disposable
  (not `default`, not `primary`, not `protected`, not the parent itself).
- The child inherits production's migration ledger as ordinary row data, so the whole true-ledger
  mechanism — the `tmp/*` check branch, `readTrue*Ledger`, `build*LedgerBaselineSql` — is deleted.
  It existed only because a schema-only clone strips the ledger's rows.
- Purge application rows in one transaction, preserving the ledger and extension-owned tables.
  Verify emptiness before publishing connection URLs. Then apply migrations the checkout has and
  production does not.

The captured LSN doubles as an ownership check: `name + parent_id + parent_lsn` together must match
the creation request. A failed check requires manual recovery; it never authorizes deletion.

**Trade-off, accepted and documented:** a normal child initially contains production data, and
Neon's history window can retain that data in the branch's own snapshots after the purge. This is
a root-slot and correctness fix, **not** a privacy boundary. Schema-only branching remains the
only mechanism that never materializes production rows.

### `.neondb/state.json`

```json
{
  "branchId": "br-...",
  "branchName": "workspace/...",
  "projectId": "...",
  "status": "ready"
}
```

- `branchId` and `projectId` are identity. `branchName` is a display value, refreshed from Neon
  on `sync`, never used to find or delete anything.
- `status` ∈ `creating` | `pending` | `ready` | `deleting`. `branchId` is `null` **only** with
  `creating`, and non-null for every other status.
- Written atomically (temp file + rename, mode 0600). Parsed strictly: exactly the four keys,
  correct types, known status, and `projectId` equal to the configured `NEON_PROJECT_ID` — all
  checked **before** any Neon API call. No credentials in the file; `.neondb/` stays gitignored.
- Old `.neondb/branch` / `.neondb/branch-check` are **detected and rejected**, never interpreted
  and never converted — see "Scope" below.

### Lifecycle

| Command | Transitions |
|---|---|
| `provision` | delete recorded branch → `creating` (`branchId: null`) → create → verify → `pending` → purge → verify empty → migrate → seed → publish URLs → `ready` |
| `sync` | requires `ready` + managed URLs present; `getBranchById` (never by name); refreshes `branchName` |
| `teardown` | `deleting` → delete by id → confirm absent → strip URLs → remove state file → release lock → `rmdir .neondb` only if empty |

`provision`, `sync` and `teardown` serialize on one lifecycle lock (`.neondb/lock`, `wx` open,
PID recorded, reclaimed only when that PID is provably dead).

Failure rules:
- An **uncertain** creation response leaves `creating` in place and fails visibly. No blind POST
  retry, no adoption by name, no deletion by name. Only errors provably raised before the request
  reached Neon (DNS, connection refused) are retried.
- A failed cleanup retains recovery state and fails loudly. Teardown that cannot delete keeps
  `deleting` and the recorded id.
- A branch already gone (404) is success for teardown, not an error.

### Consumers

- `load-env.cjs` refuses to boot unless `state.json` reads `ready`, then assigns the managed DB
  vars from `.env.neondb` with **override** — no silent fallback to an ambient `DATABASE_URL`.
- Only the provisioning migrator reaches a `pending` branch, via the URI passed directly in its
  child-process environment; nothing is published to `.env.neondb` until purge is verified.
### Scope: fresh installs only

Confirmed 2026-09-09: this ships to repos that do not already have the skill installed, so no
conversion path is built. An `adopt` command that would have verified project, branch and endpoint
host before recording an id was designed and then cut rather than shipped unexercised.

The detection half stays, because the failure mode without it is silent: with `.neondb/branch`
ignored, provisioning would create a second branch alongside the old one and teardown would report
"nothing to tear down", leaking a live branch and the root slot this change exists to reclaim. Every
command therefore stops with manual-recovery instructions when either legacy file is present.

## Non-goals

- No backward-compatible reading of the old state format, and no conversion command. Detection plus
  a clear manual-recovery error is the whole of it.
- No rename-following. A git branch change or workspace rename never switches database ownership;
  `sync` logs the divergence and continues against the recorded id.
- `provision()` stays a deliberate full rebuild that discards workspace development data.
- No privacy claim about the workspace branch's contents.

## Testing

Regression coverage for: lifecycle transitions; a renamed branch and a reused name; project
mismatch (asserting the Neon client is never called); interrupted creation; failed cleanup
retaining `deleting`; empty-directory removal; preservation of unrelated files under `.neondb/`;
purge rollback; unknown tables and schemas; and slow connection acquisition.

Purge behavior is tested against **PGlite** (in-process Postgres) rather than a live database, so
the transaction, the ledger preservation, and the rollback are exercised for real. The Neon
control plane is a fake implementing the same `NeonClient` interface the production code uses,
with response shapes taken from the live API output recorded above.

## Ship-readiness corrections

The review found gaps in the implementation of the safety rules above. Harden them as follows:

- Treat interrupted HTTP response bodies as ambiguous requests, and treat a malformed successful
  branch lookup as an error, never proof of absence. A definitively rejected create clears its
  intent; an uncertain response keeps it.
- Re-read recorded branch identity and disposable flags before deletion. Record `deleting` and
  confirm absence before clearing state on every deletion path, including rebuild and setup failure.
  A creation response that fails ownership verification must be left for manual recovery; a returned
  id alone cannot override the failed name/parent/LSN check.
- Fetch the child's connection URI with the configured database and role. Infer these only from an
  unambiguous database listing; multiple databases require an explicit selection.
- Serialize stale-lock reclamation with an exclusive short-lived guard. An unreadable lock or a
  leftover guard requires manual inspection, rather than assuming its holder is dead.
- Use one multi-table `TRUNCATE ... RESTRICT`. Cross-table application foreign keys still work,
  while references from preserved tables fail and roll back instead of cascading into those tables.
- Reject enabled application `ON TRUNCATE` hooks on purge targets (including descendants) before
  truncating. Include materialized views in discovery so their stored production rows cannot pass
  unnoticed; they require explicit preservation or a project-specific purge design.

These corrections keep the fresh-install scope and ordinary-child design. No live Neon resources
are needed to reproduce them: REST response fixtures, lifecycle fakes, and PGlite cover the failures.
