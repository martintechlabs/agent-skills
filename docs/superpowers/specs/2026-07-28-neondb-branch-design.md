# neondb-branch (generalizing conductor-neon-db) — Design

**Date:** 2026-07-28
**Category:** `devops`
**Status:** Approved (amended 2026-08-01 — dual Orca + Conductor seamless support)

## Purpose

`conductor-neon-db` gives every Conductor workspace its own isolated Neon database
branch — schema-only clone off production, baselined against production's *true*
applied-migration state (never assumed from local files), fixtures seeded — but it is
wired entirely to Conductor: `CONDUCTOR_WORKSPACE_NAME` for identity,
`.conductor/settings.toml` for the setup/run/archive lifecycle, `CONDUCTOR_IS_LOCAL`
for the local/cloud split.

This design replaces it **in place** with `neondb-branch`: the same Neon+Prisma/Drizzle
mechanic, installable in any git repo. The script itself assumes **no** orchestration
tool. Workspace identity is **workspace-stable** under Conductor and Orca (and git-branch
based only for plain single-clone checkouts). Lifecycle is plain `package.json` scripts;
Conductor and Orca are first-class consumers of those same scripts via thin config
templates the skill ships and documents.

The Neon mechanics stay those already hardened in `conductor-neon-db` (true-ledger
baseline, full-rebuild provision, safety guards). What changes is packaging and
identity: dual-orchestrator wiring (`worktree:*` scripts + `.conductor/settings.toml` +
`orca.yaml`), workspace-stable name resolution, `.env.neondb` upsert, programmatic
dotenv load, `load-env.cjs`, and pure `planSync` / `planTeardown` helpers for
testability. Reuse-if-exists provision and baselining from local migration files remain
explicitly out of scope — both are regressions of bugs the true-ledger work fixed.

## Non-goals

- Does not change the Neon+Prisma/Drizzle mechanics: schema-only branch, disposable
  `tmp/*` check branch, true-ledger read/baseline, `migrate deploy`, seeding. All of
  this is orchestrator-independent already and stays exactly as it is.
- Does not support a "reuse an existing branch, keep its data across re-runs" mode.
  `provision()` stays a full, deterministic rebuild every run, matching
  `conductor-neon-db`'s existing (already-fixed) behavior. A reuse-if-exists path would
  reintroduce the partial-state / baseline-drift class of bugs true-ledger replaced and
  is explicitly rejected here.
- Does not read migration state from local migration files as a baseline source.
  Reconstructing the ledger from committed migrations (parent trusted to have run every
  one) is the exact drift bug `conductor-neon-db`'s check-branch mechanism exists to
  prevent. Not adopted.
- Does not fork script behavior on `CONDUCTOR_IS_LOCAL` (or any Orca equivalent). Local
  and cloud workspaces run the same code path; secrets come from env / `.env.neondb`,
  not from tool-specific branching.
- Does not auto-rebuild (delete+recreate) the Neon branch as a side effect of starting
  the dev server. A deliberate identity move that *discards data* is always
  `db:provision` / `worktree:setup` — see "Workspace identity and renaming".
- Does not keep `conductor-neon-db` as a separate skill. It is replaced in place;
  there is no dual-maintenance path.
- Does not require Conductor *or* Orca. A plain git clone with only `package.json`
  scripts is a supported install path. Orchestrator configs are optional, documented
  add-ons that call the same scripts.

## Dual-orchestrator requirement (first-class)

**Seamless with both Conductor and Orca is a hard requirement**, not an afterthought
left to each project. Concretely:

1. One script (`scripts/neondb-branch.ts`) with three commands: `provision`, `sync`,
   `teardown`.
2. One shared `package.json` surface both tools call — thin `worktree:*` aliases over
   `db:*` (see "Lifecycle" below). Neither orchestrator needs to know about Neon,
   neonctl, or state-file paths.
3. Skill ships and documents **both** config templates:
   - `.conductor/settings.toml` — `setup` / `run` / `archive` → `worktree:*`
   - `orca.yaml` — `scripts.setup` / `scripts.archive` → `worktree:*` (Orca has no
     `run` hook; the hard gate lives in `package.json`'s `dev` script instead)
4. Identity resolution prefers each tool's own env var, then a general
   `WORKSPACE_NAME`, then checkout-derived fallbacks: `CONDUCTOR_WORKSPACE_NAME` →
   `ORCA_WORKSPACE_NAME` → `WORKSPACE_NAME` → secondary-worktree basename → git
   branch. Conductor already injects its var. Orca 1.4.x does **not** currently
   export `ORCA_WORKSPACE_NAME`, so the basename fallback is what makes Orca work
   today; when Orca (or the project) sets `ORCA_WORKSPACE_NAME` /
   `WORKSPACE_NAME`, those win over basename.

The skill is still "no orchestration tool assumed" at the **script** layer. It is
**not** "composition is the project's private business" at the **skill/docs** layer —
dual wiring is part of what the skill teaches and installs.

## Decisions ruled out (and why)

1. **Git branch as the sole identity source** (earlier draft of this design). Rejected
   for dual-orchestrator use: Conductor identity is the stable workspace name (city
   codename), not the git branch; Orca worktree display/path codenames (`mojarra`)
   differ from the feature branch (`martintechlabs/…`). A brief `git checkout main`
   inside a live workspace would either hard-fail `dev` or, on re-provision, wipe that
   workspace's Neon branch. Workspace-stable identity fixes this; git branch remains
   only the plain-single-clone fallback (see below).
2. **Basename alone as identity** (no further fallback). Correct for
   worktree-per-workspace tools (each worktree is its own directory) but silently wrong
   for a plain single-clone repo where branches are switched in place — every branch
   would collide onto one Neon branch. Rejected as the *only* source; retained as the
   secondary-worktree fallback.
3. **An explicit hand-set `WORKSPACE_NAME` in `.env.neondb`.** That file can be
   copied/reused across workspaces and would collide two of them onto the same Neon
   branch. Identity is always resolved at runtime from orchestrator env, ambient
   process env, or the checkout — never stored as a fixed value in the env file.
   Ambient `WORKSPACE_NAME` is the **general** env slot (after tool-specific vars),
   not something provision writes into `.env.neondb`.
4. **`sync()` hard-failing on every recorded-vs-current identity mismatch with no
   rename path.** Correct if identity were git branch (checkout ≠ rename). Wrong when
   identity is workspace-stable: Conductor renames the workspace in the UI with no
   rename event, and the existing skill's best-effort Neon rename on `run` is the
   right UX (data preserved, name catches up). Restored: soft rename on mismatch when
   the recorded branch still exists; hard gates only for unsafe states (see below).

## Workspace identity and renaming

### Resolution order

`resolveWorkspaceName(env, cwd, gitContext)` returns the raw identity string (before
slugify), first match wins:

1. **`env.CONDUCTOR_WORKSPACE_NAME`** — Conductor injects this per workspace. Wins
   over any general `WORKSPACE_NAME` so a copied shell env cannot override the
   tool's own identity.
2. **`env.ORCA_WORKSPACE_NAME`** — Orca's own identity when present. Same precedence
   rationale as Conductor.
3. **`env.WORKSPACE_NAME`** — the **general** ambient env var for plain installs,
   custom orchestrators, tests, or a project that exports one name for every tool.
   Only if already set in the process environment. **Never** read from
   `.env.neondb` (that file can be copied across workspaces and would collide them).
4. **Secondary git worktree → `basename(cwd)`** — when none of the three env vars
   are set. Detected when `.git` is a file, or `git rev-parse --git-dir` contains
   `/worktrees/`. Makes **Orca work today** without `ORCA_WORKSPACE_NAME` (worktree
   dirs like `…/workspaces/agent-skills/mojarra`) and covers a Conductor workspace
   if its env var is ever missing.
5. **Plain main-worktree / single clone → current git branch**
   (`git rev-parse --abbrev-ref HEAD`). Detached HEAD or "not a git repository"
   throws a clear, actionable error — no derivable identity.

Slugify rules stay as in `conductor-neon-db` (lowercase, non-alnum runs collapsed to
`-`, trimmed, truncated with a content hash suffix past `MAX_SLUG`). Neon branch name
is `workspace/<slug>` (see prefixes below).

This function is pure and unit-tested with injected `env` / `cwd` / git-context so the
precedence chain cannot silently regress. Tests must lock **tool-specific before
general**: `CONDUCTOR_WORKSPACE_NAME` / `ORCA_WORKSPACE_NAME` beat `WORKSPACE_NAME`
when both are set.

### Why this order

| Environment | What wins | Stable across `git checkout`? |
|---|---|---|
| Conductor workspace | `CONDUCTOR_WORKSPACE_NAME` | Yes |
| Orca with `ORCA_WORKSPACE_NAME` set | `ORCA_WORKSPACE_NAME` | Yes |
| Custom / plain with `WORKSPACE_NAME` set | `WORKSPACE_NAME` | Yes (caller-controlled) |
| Orca worktree, no env (current 1.4.x) | `basename(cwd)` (e.g. `mojarra`) | Yes |
| Plain single clone, no env | git branch | No — by design: branch *is* the workspace |

### Rename / mismatch behavior

Identity sources that change only on deliberate workspace rename (Conductor UI rename,
Orca worktree directory/codename change, or a caller changing `WORKSPACE_NAME` /
`ORCA_WORKSPACE_NAME`) are rare and intentional. Git-branch identity changes on every
checkout — but that path only applies to plain single-clone with no env vars set,
where "the workspace" *is* the branch.

Split by action:

- **`provision()`** — full rebuild, unchanged from `conductor-neon-db`: derive current
  identity → delete whatever is recorded in the state file (if it still exists) →
  create fresh under the current name. Logs clearly which Neon branch it is replacing.
  This is the deliberate "move me / rebuild me" path (data discarded).
- **`sync()`** — **hard gates first** (non-zero exit, block the dev server):
  1. No state file / missing `.env.neondb` → unprovisioned; tell user to run
     `db:provision` or `worktree:setup`.
  2. State phase is `pending` → interrupted provision; same remediation.
  3. Recorded Neon branch no longer exists in the project → dead endpoint; re-provision.
  - **Then**, if recorded name ≠ name derived from current identity:
    - Prefer **best-effort rename** of the live Neon branch (real rename, not
      delete+recreate — data and connection endpoint stay valid) and update the state
      file, matching today's `conductor-neon-db` rename catch-up (including the
      "recorded gone but current already exists → reconcile local state only"
      self-heal via `planSync`).
    - Rename failures are **warnings, exit 0** — cosmetic name drift must never block
      the dev server. Isolation is preserved because teardown always trusts the state
      file, not a re-derived name.
  - Under plain-single-clone (git-branch identity), a checkout to a different branch
    that was never provisioned hits hard gate (1) or (3) for that identity's name —
    it does **not** silently rename the previous branch's Neon DB onto `main`. If the
    previous branch's Neon name is still what the state file records and the user is
    now on a different git branch, derived identity differs: `sync` attempts rename
    to the new branch slug. That is acceptable for plain-clone (one checkout, one
    active identity) and is why provision-on-the-right-branch remains the rule for
    multi-branch isolation there. Document this clearly in the skill.
  - **Guard the rename target**: before attempting the rename, check whether the
    derived target name already exists in Neon as a *different* live branch (i.e. a
    branch this same state file did not just record). If so, this is not a rename —
    it's two distinct previously-provisioned identities colliding (e.g. checking out a
    branch that already has its own real `workspace/<slug>` from an earlier session).
    Treat this as a hard gate (refuse to start, name both branches, tell the user to
    re-run `db:provision` for the current identity) rather than attempting a rename
    that would fail anyway and fall through to booting against the stale
    `DATABASE_URL` left in `.env.neondb`.

`planSync` / `planTeardown` pure helpers encode the above for unit-testing without
mocking `neonctl`.

## Branch prefixes and state files

| Old (Conductor) | New |
|---|---|
| `conductor/<slug>` (workspace branch) | `workspace/<slug>` |
| `tmp/<slug>` (disposable check branch) | `tmp/<slug>` (unchanged) |
| `.conductor/db-branch` | `.neondb/branch` |
| `.conductor/db-branch-check` | `.neondb/branch-check` |

`.neondb/` is gitignored in full — there is no shared config file inside it (unlike
`.conductor/`, which still needs a carve-out for the committed `settings.toml` when
Conductor is used). State file format, atomic write-then-rename, and the
`pending`/`ready` phase marker are otherwise unchanged from `conductor-neon-db`.

## Lifecycle — shared `package.json` surface

Core scripts every install gets:

```jsonc
{
  "scripts": {
    "db:provision": "tsx scripts/neondb-branch.ts provision",
    "db:sync": "tsx scripts/neondb-branch.ts sync",
    "db:teardown": "tsx scripts/neondb-branch.ts teardown",

    // Thin aliases both orchestrators call — install deps / generate client as needed
    "worktree:setup": "<pm install> && <orm generate if prisma> && tsx scripts/neondb-branch.ts provision",
    "worktree:sync": "tsx scripts/neondb-branch.ts sync",
    "worktree:archive": "tsx scripts/neondb-branch.ts teardown",

    // Hard gate + env load; Orca has no run hook, so this is the universal entry
    "dev": "tsx scripts/neondb-branch.ts sync && NODE_OPTIONS='--require ./scripts/load-env.cjs' <original dev command>"
  }
}
```

- `db:provision` / `worktree:setup` — run once per workspace (or again to deliberately
  rebuild / follow an identity change that should discard data).
- `db:sync` / `worktree:sync` / leading `sync` in `dev` — hard gates + optional
  best-effort rename (see above).
- `db:teardown` / `worktree:archive` — run before abandoning the workspace (worktree
  removal, Conductor archive, Orca worktree rm, or "done with this feature").

Plain-clone users can ignore `worktree:*` and call `db:*` only. Orchestrator installs
use `worktree:*` so both tools share one vocabulary.

### Conductor — `.conductor/settings.toml` (skill ships this template)

```toml
"$schema" = "https://conductor.build/schemas/settings.repo.schema.json"

# setup/archive/run all delegate to the shared worktree:* package.json scripts.
# Secrets (NEON_*) live in Conductor Environment tabs (Local + Cloud) and/or
# .env.neondb — never committed here. Do NOT set DATABASE_URL here or in env tabs.

[scripts]
setup = "corepack enable pnpm && pnpm worktree:setup"
archive = "pnpm worktree:archive"
run = "pnpm worktree:sync && pnpm dev --port $CONDUCTOR_PORT"
run_mode = "concurrent"
```

Notes the skill must document (carried forward from `conductor-neon-db`):

- `run_mode = "concurrent"` is safe because each workspace has its own Neon branch and
  `$CONDUCTOR_PORT`.
- **Do not put `DATABASE_URL` in Conductor Environment tabs** — it overrides the
  per-workspace branch.
- `NEON_API_KEY` / `NEON_PROJECT_ID` / `NEON_PARENT_BRANCH` in **both** Local and Cloud
  tabs. `provision()` still mirrors them into `.env.neondb`; `main()` loads that file
  before `teardown`, so archive is self-sufficient even when Conductor's archive
  process is missing env vars (observed production bug — keep the fallback).
- Gitignore carve-out: track `settings.toml`, ignore `.conductor/db-branch*` if any
  legacy paths remain; prefer `.neondb/` fully ignored for new state.
- `file_include_globs` is top-level only (not inside `[scripts]`).

### Orca — `orca.yaml` (skill ships this template)

```yaml
# Mirrors Conductor's setup/archive. Both tools call the same worktree:* scripts.
# NEON_* come from .env.neondb (and/or the ambient environment) — not from this file.
# Orca has no run hook: sync is chained inside package.json "dev".
scripts:
  setup: |
    corepack enable pnpm && pnpm worktree:setup
  archive: |
    pnpm worktree:archive
```

Notes the skill must document:

- Orca worktree create/setup should run `worktree:setup` (via this recipe or the
  project's equivalent environment recipe hooks).
- Orca worktree remove/archive should run `worktree:archive` so Neon branches do not
  leak.
- Because there is no Orca `run` equivalent, **never** ship a `dev` script that skips
  `sync` — that hard gate is what makes `load-env.cjs`'s ENOENT fallback safe.
- Identity: `ORCA_WORKSPACE_NAME` if set, else `WORKSPACE_NAME` if set, else worktree
  directory basename (current Orca 1.4.x has neither env var — basename is what
  works today).

### Custom / other tools

Any tool that can run shell on workspace create / start / destroy can call
`worktree:setup` / rely on `dev`'s sync / `worktree:archive`. No further integration
surface exists or is planned.

## `.env.neondb` handling

`provision()` **upserts** into `.env.neondb` rather than truncating and rewriting it:

- Every `DB_ENV_VARS` entry (`DATABASE_URL` by default; project can add `DIRECT_URL` /
  `shadowDatabaseUrl` etc., same knob as today) — always updated to the fresh branch's
  connection string.
- `NEON_API_KEY`, `NEON_PROJECT_ID`, `NEON_PARENT_BRANCH` — mirrored in from ambient
  environment (wherever the developer already has them — shell profile, `.env`,
  direnv, Conductor Environment tabs) on every `provision()` run, same as
  `conductor-neon-db` does today. This keeps `.env.neondb` self-sufficient for later
  `sync`/`teardown` invocations even from a shell that never had them exported
  (including Conductor archive).

`main()` loads `.env.neondb` itself, programmatically, via the `dotenv` package
(`config({ path: ENV_FILE })`, never overriding an already-set var) before dispatching
to `provision`/`sync`/`teardown`. This is why none of the package.json scripts need a
`dotenv -e ... --` shell prefix: the script is self-sufficient regardless of how it's
invoked (Conductor archive, Orca archive, bare terminal). `dotenv` becomes a new
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

Prefer a small bundled `scripts/load-env.cjs` (~10 lines) over a `dotenv -e ... -o --`
shell prefix, loaded via `NODE_OPTIONS='--require ./scripts/load-env.cjs'` in the
`dev` script (and `build`/`start`/seed scripts, if the project wants
provisioned-workspace parity there too):

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
collision — the two are adopted together, not independently. This matters equally for
Conductor `run` (which chains `worktree:sync` before `dev`) and for Orca (which only
has `dev`).

Prisma's CLI needs the same file loaded for `migrate`/`db execute`/`studio` outside the
`dev` script; document a `prisma.config.ts` snippet that loads `.env.neondb` first,
falling back to plain `.env`:

```ts
import { config as loadEnv } from 'dotenv'
loadEnv({ path: '.env.neondb' })
loadEnv()
```

(Drizzle has no equivalent config-loading hook to extend; document that Drizzle
projects should source `.env.neondb` explicitly for any ad hoc `drizzle-kit` CLI
invocation outside `dev`.)

## Testability / robustness patterns

- **Pure decision functions** for `sync`/`teardown` (`planSync`, `planTeardown`) —
  given local state plus live Neon-existence booleans, return what action to take,
  unit-tested without mocking `neonctl`. Includes rename / reconcile / noop for sync
  and delete / alreadyGone for teardown.
- **Pure `resolveWorkspaceName`** with injected env/cwd/git-context — locks the
  dual-orchestrator precedence chain.
- **Teardown self-heal**: if the target branch is already gone, treat as
  already-torn-down and clean up local state (idempotent archive under both tools).

## Files and components

| Path | Change |
|---|---|
| `skills/devops/neondb-branch/SKILL.md` | New (replaces `skills/devops/conductor-neon-db/SKILL.md`) — full rewrite: frontmatter name/description, `metadata: {author: martintechlabs, version: "0.1.0"}`, hybrid identity, `db:*` + `worktree:*` scripts, **both** Conductor and Orca config templates, `.env.neondb` upsert, `load-env.cjs`, rename-vs-hard-gate semantics |
| `skills/devops/neondb-branch/scripts/neondb-branch.ts` | Renamed + reworked from `conductor-db.ts`: `resolveWorkspaceName` chain, `workspace/` prefix, `.neondb/*` state paths, `.env.neondb` upsert, `planSync`/`planTeardown` pure helpers, best-effort rename + hard gates |
| `skills/devops/neondb-branch/scripts/load-env.cjs` | New, bundled — the `NODE_OPTIONS` require-hook |
| `skills/devops/neondb-branch/tests/neondb-branch.test.ts` | Renamed + extended: identity precedence cases (`CONDUCTOR_WORKSPACE_NAME` > `ORCA_WORKSPACE_NAME` > `WORKSPACE_NAME` > worktree basename > git branch), hard-gate cases, best-effort rename/reconcile cases, upsert/strip env-file cases, `planSync`/`planTeardown` |
| `skills/devops/neondb-branch/references/verify.md` | Updated for new prefixes/paths/lifecycle; still schema-only + true-baseline flow |
| `skills/devops/neondb-branch/references/conductor-settings.toml.example` | Optional: exact Conductor template (or inline in SKILL.md — either is fine if not duplicated poorly) |
| `skills/devops/neondb-branch/references/orca.yaml.example` | Optional: exact Orca template (same rule) |
| `skills.sh.json` | `conductor-neon-db` → `neondb-branch` in the `DevOps` grouping |
| `README.md` | Skill table row renamed + description updated (mention Neon branch-per-workspace for Conductor, Orca, or plain git) |
| `skills/devops/conductor-neon-db/` | Removed (replaced in place, not kept alongside) |

## Success criteria

- A fresh git repo (no Conductor, no Orca) can adopt this skill and get an isolated
  per-branch Neon database using only `git` + `package.json` `db:*` scripts.
- A Conductor project that applies the shipped `.conductor/settings.toml` template
  gets setup → isolated DB, run → sync hard gates + best-effort rename, archive →
  teardown, with `run_mode = concurrent`, without any script changes beyond the shared
  `worktree:*` surface.
- An Orca project that applies the shipped `orca.yaml` template gets setup/archive
  parity via the same `worktree:*` scripts; `pnpm dev` enforces sync (Orca has no run
  hook). Identity resolves via `ORCA_WORKSPACE_NAME` or `WORKSPACE_NAME` when set,
  otherwise basename of the worktree directory.
- Checking out another git branch **inside** a Conductor or Orca workspace does **not**
  change Neon identity and does **not** block `dev` solely because of that checkout.
- Renaming a Conductor workspace (or changing the derived workspace name under Orca)
  best-effort renames the Neon branch on next sync; data is preserved. Failures warn
  and still allow the dev server to start.
- Unprovisioned / `pending` / deleted-Neon-branch states still hard-fail `sync` with
  clear remediation — never silently boot against ambient `DATABASE_URL`.
- `provision()` remains a full, deterministic rebuild every run; no data-preserving
  reuse path exists.
- The true-ledger baseline (disposable `tmp/*` check branch, never trusting local
  migration files) is intact and unchanged in mechanics.
- `ORM` (Prisma/Drizzle), `PM_EXEC`, and `DB_ENV_VARS` porting knobs all still exist
  and work as they do in `conductor-neon-db` today.
- `tsc --noEmit` clean; `tests/neondb-branch.test.ts` passes with 0 failures,
  including identity-precedence, hard-gate, rename/reconcile, and upsert/strip
  coverage.
- `conductor-neon-db` no longer exists as a separate skill; all references
  (`skills.sh.json`, `README.md`) point at `neondb-branch`.
