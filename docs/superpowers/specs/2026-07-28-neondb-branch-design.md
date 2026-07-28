# neondb-branch (generalizing conductor-neon-db) — Design

**Date:** 2026-07-28
**Category:** `devops`
**Status:** Approved

## Purpose

`conductor-neon-db` gives every Conductor workspace its own isolated Neon database
branch — schema-only clone off production, baselined against production's *true*
applied-migration state (never assumed from local files), fixtures seeded — but it is
wired entirely to Conductor: `CONDUCTOR_WORKSPACE_NAME` for identity,
`.conductor/settings.toml` for the setup/run/archive lifecycle, `CONDUCTOR_IS_LOCAL`
for the local/cloud split.

This design replaces it **in place** with `neondb-branch`: the same Neon+Prisma/Drizzle
mechanic, installable in any git repo with no orchestration tool assumed. Workspace
identity comes from the current git branch. Lifecycle triggers become plain
`package.json` scripts the developer runs (or a worktree-management tool calls)
directly, instead of Conductor-specific hooks.

A reference implementation at a sibling project (`mobata`, internal — not part of this
repo) was reviewed during design. It is an **earlier fork** of this script's history
(pre-dates the true-ledger baseline fix and the four safety-hardening review passes
already shipped in `conductor-neon-db`), generalized sideways to also support a second
orchestration tool (Orca) rather than removed from needing one at all. Several of its
mechanics are call-outs below as things to explicitly **not** carry over; a few
testability/robustness patterns are worth adopting regardless.

## Non-goals

- Does not change the Neon+Prisma/Drizzle mechanics: schema-only branch, disposable
  `tmp/*` check branch, true-ledger read/baseline, `migrate deploy`, seeding. All of
  this is Conductor-independent already and stays exactly as it is.
- Does not support a "reuse an existing branch, keep its data across re-runs" mode.
  `provision()` stays a full, deterministic rebuild every run, matching
  `conductor-neon-db`'s existing (already-fixed) behavior. `mobata`'s reuse-if-exists
  model is a regression of the bug the true-ledger baseline replaced and is explicitly
  rejected here.
- Does not read migration state from local migration files as a baseline source.
  `mobata`'s `buildBaselineSql(readMigrations())` (parent trusted to have run every
  committed migration) is the exact drift bug `conductor-neon-db`'s check-branch
  mechanism exists to prevent. Not adopted.
- Does not keep any Conductor-specific concept: `CONDUCTOR_WORKSPACE_NAME`,
  `CONDUCTOR_IS_LOCAL`, `$CONDUCTOR_PORT`, `.conductor/settings.toml`. A project still
  using Conductor can wire its `run`/`setup`/`archive` scripts to call the plain
  `package.json` scripts this design defines (that composition is the project's
  choice, not something this skill documents or special-cases).
- Does not auto-rename the live Neon branch when the git branch changes. Renaming is
  a deliberate action (re-running `db:provision`), never a side effect of starting the
  dev server — see "Workspace identity and renaming" below for why.
- Does not keep `conductor-neon-db` as a separate skill. It is replaced in place;
  there is no dual-maintenance path.
- Does not add a `WORKSPACE_NAME` override env var or a directory-basename fallback.
  Git branch name is the sole identity source (see "Decisions ruled out" below).

## Decisions ruled out (and why)

Two structural alternatives were considered and rejected during design:

1. **Directory basename as identity** (`mobata`'s actual approach — derives from
   `basename(cwd)`, falling back from `CONDUCTOR_WORKSPACE_NAME`). This is correct
   only when every workspace lives in its own directory (worktree-per-branch tooling)
   and silently wrong for a plain single-clone repo where branches are switched in
   place — every branch would collide onto the same Neon branch. Rejected in favor of
   git branch name, which works for both worktree-based and plain single-clone usage.
2. **Explicit `WORKSPACE_NAME` env var with a fallback chain.** Adds a second identity
   source to document and reason about (which one won, in which precedence) for a
   generalization step whose whole point is removing environment-variable plumbing.
   Rejected; git branch name alone is the identity source.

## Workspace identity and renaming

Identity is the current git branch (`git rev-parse --abbrev-ref HEAD`), slugified with
the same rules `conductor-neon-db` already uses (lowercase, non-alnum runs collapsed to
`-`, trimmed, truncated with a content hash suffix past `MAX_SLUG`). Detached HEAD or
"not inside a git repository" throws a clear, actionable error — there is no derivable
identity in either case.

A git branch changes on **every checkout**, not just a deliberate rename — unlike
`CONDUCTOR_WORKSPACE_NAME`, which only changed when a human renamed the workspace in
Conductor's UI. Treating every branch change as "the workspace was renamed, follow it"
would mean:

- Checking out `main` momentarily to look something up, then running `pnpm dev`,
  silently renames the live Neon branch to `workspace/main`.
- Checking back out the original feature branch renames it back.
- Provisioning while accidentally on the wrong branch would delete a *different*
  branch's real, in-progress Neon branch.

To avoid this, renaming is split into two different behaviors depending on whether the
action is deliberate or incidental:

- **`provision()`** keeps `conductor-neon-db`'s existing full-rebuild behavior
  unchanged: it derives the branch name from whatever branch is currently checked out,
  deletes whatever branch is currently recorded in the state file (if it still exists),
  and creates a fresh one under the current name — already logging clearly which
  branch it's replacing. Re-running `db:provision` after `git branch -m old new` is how
  you deliberately move this workspace's Neon branch to follow a rename.
- **`sync()`** (chained in front of the dev server — see "Lifecycle" below) becomes a
  **pure verifier, never a mutator**. If the branch recorded in the state file doesn't
  match the branch derived from the current checkout, `sync()` throws — it never
  renames anything. Error message: which branch is recorded, which branch you're
  currently on, and the two ways to resolve it (check back out the recorded branch, or
  re-run `db:provision` if you meant to move this workspace to the new branch).

This also restores two hard gates `conductor-neon-db` has today that a naive port could
drop: `sync()` still refuses to start (non-zero exit) when the state file shows setup
never finished (`pending` phase — see below), and still refuses to start when the
recorded branch no longer exists in Neon at all.

## Branch prefixes and state files

| Old (Conductor) | New |
|---|---|
| `conductor/<slug>` (workspace branch) | `workspace/<slug>` |
| `tmp/<slug>` (disposable check branch) | `tmp/<slug>` (unchanged) |
| `.conductor/db-branch` | `.neondb/branch` |
| `.conductor/db-branch-check` | `.neondb/branch-check` |

`.neondb/` is gitignored in full — there is no shared config file inside it (unlike
`.conductor/`, which had to carve out an exception for the committed
`settings.toml`). State file format, atomic write-then-rename, and the
`pending`/`ready` phase marker are otherwise unchanged from `conductor-neon-db`.

## Lifecycle — no orchestration tool assumed

There are no `setup`/`run`/`archive` hooks to wire into. Instead, three
`package.json` scripts:

```jsonc
{
  "scripts": {
    "db:provision": "tsx scripts/neondb-branch.ts provision",
    "dev": "tsx scripts/neondb-branch.ts sync && NODE_OPTIONS='--require ./scripts/load-env.cjs' <original dev command>",
    "db:teardown": "tsx scripts/neondb-branch.ts teardown"
  }
}
```

- `db:provision` — manual, run once per branch (or again to deliberately rebuild /
  follow a rename — see above).
- `dev` — the project's existing dev script, prefixed with `sync` (hard gate) and the
  `NODE_OPTIONS` require-hook (see next section). Nothing else about the dev command
  changes.
- `db:teardown` — manual, run before deleting/abandoning the branch (worktree removal,
  branch deletion, or simply "done with this feature").

A project using a worktree-management tool (Conductor, Orca, a custom script, etc.) is
free to call these same three `pnpm`/`npm` scripts from its own lifecycle hooks — that
composition is the project's business, not something this skill documents, since the
whole point is not assuming any particular tool exists.

## `.env.neondb` handling

`provision()` **upserts** into `.env.neondb` rather than truncating and rewriting it:

- Every `DB_ENV_VARS` entry (`DATABASE_URL` by default; project can add `DIRECT_URL` /
  `shadowDatabaseUrl` etc., same knob as today) — always updated to the fresh branch's
  connection string.
- `NEON_API_KEY`, `NEON_PROJECT_ID`, `NEON_PARENT_BRANCH` — mirrored in from ambient
  environment (wherever the developer already has them — shell profile, `.env`,
  direnv) on every `provision()` run, same as `conductor-neon-db` does today. This
  keeps `.env.neondb` self-sufficient for later `sync`/`teardown` invocations even
  from a shell that never had them exported.

`main()` loads `.env.neondb` itself, programmatically, via the `dotenv` package
(`config({ path: ENV_FILE })`, never overriding an already-set var) before dispatching
to `provision`/`sync`/`teardown` — the same approach `mobata` uses. This is why none of
the three `package.json` scripts above need a `dotenv -e ... --` shell prefix: the
script is self-sufficient regardless of how it's invoked. `dotenv` becomes a new
dev-dependency the setup instructions add alongside `neonctl`/`tsx`.

Upsert semantics: read the file if present, replace the first matching `KEY=` line for
each var or append if absent, leave every other line (unrelated vars, comments, blank
lines) untouched. No header comment, no "generated by this script" marker — the state
file (`.neondb/branch`) is the sole source of truth for "was this workspace ever
provisioned," so there's no need to fingerprint the env file's origin.

`teardown()` strips only the `DB_ENV_VARS` keys afterward (they'd point at a
now-deleted branch's dead endpoint) and leaves `NEON_API_KEY`/`NEON_PROJECT_ID`/
`NEON_PARENT_BRANCH` in place, so a later `db:provision` on this same checkout doesn't
need them re-supplied. If stripping the `DB_ENV_VARS` keys leaves the file with no
other content, the file is deleted entirely; otherwise the remaining lines (including
the three Neon control vars) are kept.

## Loading `.env.neondb` into the dev server

Adopted from `mobata` rather than the `dotenv -e ... -o --` prefix originally
considered: a small bundled `scripts/load-env.cjs` (~10 lines), loaded via
`NODE_OPTIONS='--require ./scripts/load-env.cjs'` in the `dev` script (and `build`/
`start`/seed scripts, if the project wants provisioned-workspace parity there too):

```js
try {
  process.loadEnvFile('.env.neondb')
} catch (error) {
  if (error.code !== 'ENOENT') throw error
}
```

This avoids an extra `dotenv-cli` dev dependency and avoids rewriting the project's own
`dev` command into a long chained one-liner — only a `NODE_OPTIONS` prefix and the
`sync &&` gate are added. **This is safe only because `sync()`'s hard gates run first
in the same `&&` chain**: `load-env.cjs`'s ENOENT-swallowing fallback means an
unprovisioned workspace would otherwise boot the dev server straight against whatever
ambient `DATABASE_URL` is lying around (e.g. `.env.local`) with no warning at all. The
hard gate is what makes that fallback safe instead of a silent shared-database
collision — the two are adopted together, not independently.

Prisma's CLI needs the same file loaded for `migrate`/`db execute`/`studio` outside the
`dev` script; document a `prisma.config.ts` snippet (mirroring `mobata`'s) that loads
`.env.neondb` first, falling back to plain `.env`:

```ts
import { config as loadEnv } from 'dotenv'
loadEnv({ path: '.env.neondb' })
loadEnv()
```

(Drizzle has no equivalent config-loading hook to extend; document that Drizzle
projects should source `.env.neondb` explicitly for any ad hoc `drizzle-kit` CLI
invocation outside `dev`.)

## Adopted testability/robustness patterns (from `mobata`)

Independent of the mechanics rejected above, two patterns are worth carrying into the
rewrite:

- **Pure decision functions** for `sync`/`teardown` branching logic (`planSync`-style,
  `planTeardown`-style) — given local state plus live Neon-existence booleans, return
  what action to take, unit-tested without mocking `neonctl`. `conductor-neon-db`
  today inlines this logic; extracting it improves testability with no behavior
  change.
- **Teardown self-heal**: if the target branch is already gone (a previous teardown
  died between delete and state cleanup, or a manual delete), treat it as
  already-torn-down and clean up local state, rather than retrying a delete that would
  404 forever. `conductor-neon-db` already has an equivalent for this specific case;
  keep it, expressed as a small pure `planTeardown()` helper for testability parity
  with `sync`.

## Files and components

| Path | Change |
|---|---|
| `skills/devops/neondb-branch/SKILL.md` | New (replaces `skills/devops/conductor-neon-db/SKILL.md`) — full rewrite: new frontmatter name/description, `metadata: {author: martintechlabs, version: "0.1.0"}`, drop all Conductor sections, document the three `package.json` scripts, `.env.neondb` upsert semantics, `load-env.cjs`, git-branch identity + deliberate-vs-automatic renaming |
| `skills/devops/neondb-branch/scripts/neondb-branch.ts` | Renamed + reworked from `conductor-db.ts`: git-branch identity, `sync()` hard-gate-not-rename, `.env.neondb` upsert (not full rewrite), `planSync`/`planTeardown` pure helpers |
| `skills/devops/neondb-branch/scripts/load-env.cjs` | New, bundled — the `NODE_OPTIONS` require-hook |
| `skills/devops/neondb-branch/tests/neondb-branch.test.ts` | Renamed + extended from `conductor-db.test.ts`: new branch-mismatch-hard-gate cases, upsert/strip env-file cases, `planSync`/`planTeardown` unit tests |
| `skills/devops/neondb-branch/references/verify.md` | Updated for new prefixes/paths/lifecycle (mechanics of the verify walkthrough itself — schema-only + true-baseline flow — are unchanged) |
| `skills.sh.json` | `conductor-neon-db` → `neondb-branch` in the `DevOps` grouping |
| `README.md` | Skill table row renamed + description updated |
| `skills/devops/conductor-neon-db/` | Removed (replaced in place, not kept alongside) |

## Success criteria

- A fresh git repo (no Conductor, no Orca, no worktree tooling of any kind) can adopt
  this skill and get an isolated per-branch Neon database using only `git` +
  `package.json` scripts.
- Switching branches and running `pnpm dev` on an unprovisioned or different branch
  fails loudly with a clear remediation, never silently boots against the wrong
  database.
- `provision()` remains a full, deterministic rebuild every run; no data-preserving
  reuse path exists.
- The true-ledger baseline (disposable `tmp/*` check branch, never trusting local
  migration files) is intact and unchanged in mechanics.
- `ORM` (Prisma/Drizzle), `PM_EXEC`, and `DB_ENV_VARS` porting knobs all still exist
  and work as they do in `conductor-neon-db` today.
- `tsc --noEmit` clean; `tests/neondb-branch.test.ts` passes with 0 failures,
  including new coverage for the branch-mismatch hard gate and the upsert/strip
  env-file behavior.
- `conductor-neon-db` no longer exists as a separate skill; all references
  (`skills.sh.json`, `README.md`) point at `neondb-branch`.
