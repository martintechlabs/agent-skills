# neondb-branch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `skills/devops/conductor-neon-db` in place with `skills/devops/neondb-branch` — the same Neon+Prisma/Drizzle per-workspace branching mechanic, but installable in any git repo (no orchestration tool required at the script layer), with first-class shipped config for both Conductor and Orca, workspace-stable identity resolution, an upsert-based `.env.neondb`, and pure decision functions for testability.

**Architecture:** One TypeScript CLI script (`scripts/neondb-branch.ts`, copied verbatim into a consuming project) with three commands (`provision`/`sync`/`teardown`), driven entirely by plain `package.json` scripts. Identity resolves through a precedence chain (`CONDUCTOR_WORKSPACE_NAME` → `ORCA_WORKSPACE_NAME` → `WORKSPACE_NAME` → worktree-directory basename → git branch) via a pure `resolveWorkspaceName()`. `sync()`'s branching (hard gate / noop / reconcile / rename / collision) and `teardown()`'s (delete / already-gone) are each driven by a small pure decision function (`planSync` / `planTeardown`) so the tricky cases are unit-tested without mocking `neonctl`. The true-ledger baseline (disposable `tmp/*` check branch, full-rebuild `provision()`, safety guards) carries over from `conductor-neon-db` unchanged.

**Tech Stack:** TypeScript (`tsx` at runtime in a consuming project), Vitest for this repo's own development/validation (via a throwaway scratch harness — this repo has no Node toolchain of its own), `neonctl`, `dotenv`.

**Spec:** `docs/superpowers/specs/2026-07-28-neondb-branch-design.md`

---

## Global Constraints

- `provision()` stays a full, deterministic rebuild every run. No reuse-if-exists path, ever.
- The true-ledger baseline (disposable `tmp/*` check branch, read the parent's real applied-migration rows, never trust local migration files) is unchanged in mechanics throughout.
- `ORM` (`'prisma'|'drizzle'`), `PM_EXEC`, `DB_ENV_VARS`, `SEED_SCRIPT`, `DRIZZLE_MIGRATIONS_SCHEMA`/`DRIZZLE_MIGRATIONS_TABLE` porting knobs all carry over unchanged.
- `resolveWorkspaceName` never reads from `.env.neondb` or any file — identity only ever comes from `process.env` or git/cwd state passed in explicitly. That file can be copied across workspaces; a stored identity would collide two of them.
- Every destructive Neon operation (delete, rename) keeps going through `assertDisposableChildBranch`/`assertDisposableCheckBranch` — never relaxed.
- This repo (`agent-skills`) has no `package.json`/Node toolchain of its own (see `AGENTS.md`) — `scripts/neondb-branch.ts` and `tests/neondb-branch.test.ts` are validated via a **throwaway scratch harness** outside the repo (Task 1, Step 1), never by adding `node_modules`/`package.json` to this repo.
- `conductor-neon-db` is replaced in place — no dual-maintenance path, no separate skill kept alongside.

## File Structure

| Path | Responsibility |
|---|---|
| `skills/devops/neondb-branch/SKILL.md` | Full rewrite: identity precedence, dual-orchestrator setup, `.env.neondb` upsert semantics, hard-gate/soft-rename rules, safety model |
| `skills/devops/neondb-branch/scripts/neondb-branch.ts` | The whole mechanic: identity resolution, true-ledger baseline, provision/sync/teardown, safety guards |
| `skills/devops/neondb-branch/scripts/load-env.cjs` | `NODE_OPTIONS`-require hook that loads `.env.neondb` into the dev server process |
| `skills/devops/neondb-branch/tests/neondb-branch.test.ts` | Unit tests for every pure/exported helper |
| `skills/devops/neondb-branch/references/verify.md` | Live end-to-end verification walkthrough against real Neon |
| `skills/devops/neondb-branch/references/conductor-settings.toml.example` | Exact Conductor config template |
| `skills/devops/neondb-branch/references/orca.yaml.example` | Exact Orca config template |
| `skills.sh.json` | `DevOps` grouping: `conductor-neon-db` → `neondb-branch` |
| `README.md` | Skill table row renamed + re-described |

`skills/devops/conductor-neon-db/` is deleted once the above is in place (Task 9).

---

## Task 1: Scratch test harness + mechanical port (rename, no behavior change)

**Files:**
- Create: `skills/devops/neondb-branch/scripts/neondb-branch.ts` (copied + renamed from `conductor-db.ts`)
- Create: `skills/devops/neondb-branch/tests/neondb-branch.test.ts` (copied + renamed from `conductor-db.test.ts`)
- Reference only (not modified yet): `skills/devops/conductor-neon-db/*` (left in place until Task 9)

**Interfaces:**
- Consumes: nothing (first task)
- Produces: a compiling, fully-passing baseline under the new name/paths, with legacy-migration-only code removed, ready for Tasks 2–6 to layer new behavior on top

- [ ] **Step 1: Set up the scratch Vitest harness (outside this repo)**

This repo has no `package.json`. Create a one-time throwaway harness in the scratchpad directory to run the TypeScript tests during development — never commit any of this to the repo.

```bash
SCRATCH=/private/tmp/claude-501/-Users-smartin-orca-workspaces-agent-skills-mojarra/232ff6de-43d9-4d59-af36-586513a2785c/scratchpad/neondb-branch-dev
mkdir -p "$SCRATCH/work/scripts" "$SCRATCH/work/tests"
cd "$SCRATCH"
cat > package.json <<'EOF'
{
  "name": "neondb-branch-dev-harness",
  "private": true,
  "devDependencies": {
    "vitest": "^2.1.9",
    "typescript": "^5.6.3",
    "dotenv": "^17.2.2",
    "@types/node": "^20.14.0"
  }
}
EOF
cat > vitest.config.ts <<'EOF'
import { defineConfig } from 'vitest/config'
export default defineConfig({ test: { globals: true } })
EOF
npm install --silent
```

Expected: installs cleanly, no errors.

- [ ] **Step 2: Create the new skill directory and copy the source files**

```bash
mkdir -p /Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/neondb-branch/scripts
mkdir -p /Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/neondb-branch/tests
mkdir -p /Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/neondb-branch/references
cp /Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/conductor-neon-db/scripts/conductor-db.ts \
   /Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/neondb-branch/scripts/neondb-branch.ts
cp /Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/conductor-neon-db/tests/conductor-db.test.ts \
   /Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/neondb-branch/tests/neondb-branch.test.ts
```

- [ ] **Step 3: Mechanical renames in both copied files**

```bash
SKILL=/Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/neondb-branch
sed -i '' \
  -e "s/conductor-db/neondb-branch/g" \
  -e "s/'conductor\/'/'workspace\/'/g" \
  -e "s/\.conductor\/db-branch/.neondb\/branch/g" \
  -e "s/CONDUCTOR_DB_STATE_FILE/NEONDB_BRANCH_STATE_FILE/g" \
  "$SKILL/scripts/neondb-branch.ts"
sed -i '' \
  -e "s/conductor-db/neondb-branch/g" \
  -e "s/'conductor\//'workspace\//g" \
  -e "s/conductor\/my-feature/workspace\/my-feature/g" \
  -e "s/conductor\/x/workspace\/x/g" \
  -e "s/CONDUCTOR_DB_STATE_FILE/NEONDB_BRANCH_STATE_FILE/g" \
  -e "s#\.\./scripts/conductor-db#../scripts/neondb-branch#" \
  "$SKILL/tests/neondb-branch.test.ts"
```

- [ ] **Step 4: Remove legacy-migration-only code (no upgrade path needed for a brand-new skill)**

In `scripts/neondb-branch.ts`, delete the `legacyWorkspaceBranchName()` function entirely (its docstring + body — it existed only to support upgrading from a pre-hash-suffix version of `conductor-db.ts`, which has no bearing on a new skill).

In `tests/neondb-branch.test.ts`, delete the whole `describe('legacyWorkspaceBranchName (pre-hash-suffix fallback)', ...)` block (2 tests).

You will see `legacyWorkspaceBranchName` still referenced inside `teardown()`'s candidate-list logic (`derived`/`legacy` variables) — leave those call sites as compile errors for now; Task 6 rewrites `teardown()` entirely and will remove them. For this task only, temporarily change the `legacy` variable's assignment to `null` so the file still compiles:

Find:
```ts
  let derived: string | null = null
  let legacy: string | null = null
  try {
    derived = workspaceBranchName()
    legacy = legacyWorkspaceBranchName()
  } catch {
```

Replace with:
```ts
  let derived: string | null = null
  const legacy: string | null = null
  try {
    derived = workspaceBranchName()
  } catch {
```

- [ ] **Step 5: Fix the direct-execution guard regex and header comment intro**

In `scripts/neondb-branch.ts`, confirm the bottom-of-file guard now reads (from the earlier sed):

```ts
if (process.argv[1] && /neondb-branch\.[cm]?[jt]s$/.test(process.argv[1])) {
  void main()
}
```

Replace the entire top-of-file header comment block (everything before `import { execFileSync, spawnSync } from 'node:child_process'`) with:

```ts
// scripts/neondb-branch.ts
//
// Per-workspace ISOLATED Neon database branch — for any git repo, with no orchestration tool
// required at this layer. Each workspace gets its own SCHEMA-ONLY Neon branch off the parent
// (production) branch: full schema + extensions (e.g. PostGIS's spatial_ref_sys data), ZERO
// production rows, created instantly (Neon copies no data).
//
// provision() is a full, deterministic rebuild — EVERY run, not just the first, deletes whatever
// branch is currently recorded for this workspace (if any) and creates a fresh one. Any data
// written into the workspace branch through normal app usage is discarded on every re-run — the
// branch is disposable by design; there is no "reuse an existing branch" path.
//
// A schema-only branch starts with an EMPTY migrations table (even if the parent's isn't), which
// would otherwise make the migrator either re-run every migration against tables that already
// exist (if the parent has real schema) and fail, or silently believe a falsely assumed history is
// real. So before deploying migrations, provision() learns the parent's TRUE applied-migration set:
// it clones the parent again — this time WITH data, into a second, equally disposable `tmp/*`
// branch — reads that clone's real migration-ledger rows (row data is the only source of truth for
// "what really ran"; a schema-only clone strips it, even for this table), deletes the clone, and
// seeds the workspace branch's ledger with exactly those rows. The ORM's migrate-deploy then
// applies whatever's genuinely still missing — correct whether the parent has every migration, none
// of them, or is only partway caught up.
//
// Workspace identity resolves through a precedence chain (see resolveWorkspaceName()):
// CONDUCTOR_WORKSPACE_NAME > ORCA_WORKSPACE_NAME > WORKSPACE_NAME > worktree-directory basename >
// current git branch. `sync()` hard-gates unsafe states (never provisioned, setup interrupted, the
// recorded branch is gone) and, once past those, best-effort RENAMES the live Neon branch when the
// resolved identity has moved on from what's recorded (e.g. a Conductor/Orca workspace rename) —
// but refuses (hard gate) if the target name is already a DIFFERENT live branch, since that's two
// workspaces colliding, not a rename.
//
//   provision → `tsx scripts/neondb-branch.ts provision`
//   sync      → `tsx scripts/neondb-branch.ts sync` (chained in front of the dev server command)
//   teardown  → `tsx scripts/neondb-branch.ts teardown`
//
// Requires (set in .env.neondb, your shell, or your orchestrator's env config — see SKILL.md):
//   NEON_API_KEY       – Neon API key (read by neonctl); required by provision AND teardown
//   NEON_PROJECT_ID    – Neon project to branch within; required by provision AND teardown
//   NEON_PARENT_BRANCH – REQUIRED by provision (no default); branch to clone, e.g. "production".
//                        teardown/sync only use it for the production-safety guard, if set.
//   (seed credentials) – whatever your seed needs; provision-only — see seedWorkspace() below
//
// provision() mirrors NEON_API_KEY/NEON_PROJECT_ID/NEON_PARENT_BRANCH into .env.neondb (alongside
// DATABASE_URL) so sync/teardown are self-sufficient regardless of how they're invoked (a bare
// terminal, Conductor archive, Orca archive) — see the .env.neondb upsert helpers below.
//
// Assumes Neon (Postgres) with migrations managed by EITHER Prisma OR Drizzle (set ORM below),
// with `neonctl` and `tsx` available as project-local binaries. BOTH ORMs need the project's own
// Postgres driver wired into execSql() — reading the parent's true migration ledger back needs a
// real query result, which neither `prisma db execute` nor `drizzle-kit` gives you. Adjust the
// PORTING KNOBS just below for your project.
//
// SAFETY: every destructive op (branch delete/rename) is guarded to only ever run against a
// disposable `workspace/*` workspace branch or a disposable `tmp/*` check branch — never the
// parent/production branch. provision() never opens a connection to the parent directly, only to
// the disposable check branch cloned from it.
```

- [ ] **Step 6: Generalize `requireEnv()`'s error message (no longer Conductor-specific)**

Find:
```ts
function requireEnv(name: string): string {
  const value = process.env[name]
  if (!value) {
    throw new Error(
      `${name} is required for Conductor's per-workspace Neon branch. ` +
        `Add it as a Conductor environment variable (Local tab for local, Cloud tab for cloud).`,
    )
  }
  return value
}
```

Replace with:
```ts
function requireEnv(name: string): string {
  const value = process.env[name]
  if (!value) {
    throw new Error(
      `${name} is required for the per-workspace Neon branch. Set it in .env.neondb, your shell ` +
        `environment, or your orchestrator's environment config (e.g. Conductor's Environment tabs).`,
    )
  }
  return value
}
```

- [ ] **Step 7: Run the baseline test suite — expect 43/43 passing (45 minus the 2 removed legacy tests)**

```bash
SCRATCH=/private/tmp/claude-501/-Users-smartin-orca-workspaces-agent-skills-mojarra/232ff6de-43d9-4d59-af36-586513a2785c/scratchpad/neondb-branch-dev
SKILL=/Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/neondb-branch
rm -rf "$SCRATCH/work"
mkdir -p "$SCRATCH/work/scripts" "$SCRATCH/work/tests"
cp "$SKILL/scripts/neondb-branch.ts" "$SCRATCH/work/scripts/"
cp "$SKILL/tests/neondb-branch.test.ts" "$SCRATCH/work/tests/"
cd "$SCRATCH" && npx vitest run work/tests/neondb-branch.test.ts
```

Expected: `Test Files  1 passed (1)`, `Tests  43 passed (43)`. If it doesn't compile, fix whatever the sed steps missed (check for any remaining literal `conductor` strings with `grep -in conductor "$SKILL/scripts/neondb-branch.ts" "$SKILL/tests/neondb-branch.test.ts"` — only the Conductor-config-tab reference inside the new header/requireEnv text you just wrote, and any Conductor-specific identity-source mentions that are correct to keep, should remain).

- [ ] **Step 8: Commit**

```bash
cd /Users/smartin/orca/workspaces/agent-skills/mojarra
git add skills/devops/neondb-branch/scripts/neondb-branch.ts skills/devops/neondb-branch/tests/neondb-branch.test.ts
git commit -m "$(cat <<'EOF'
neondb-branch: mechanical port from conductor-neon-db

Renamed script/test/prefixes/state paths with no behavior change yet;
dropped the legacy pre-hash-suffix migration path (no upgrade history to
preserve for a brand-new skill). Baseline for the identity/env-file/sync
rework that follows.
EOF
)"
```

---

## Task 2: `resolveWorkspaceName` — the identity precedence chain

**Files:**
- Modify: `skills/devops/neondb-branch/scripts/neondb-branch.ts`
- Modify: `skills/devops/neondb-branch/tests/neondb-branch.test.ts`

**Interfaces:**
- Consumes: Task 1's baseline
- Produces: `export interface GitContext { isSecondaryWorktree: boolean; branch: string | null }`, `export function resolveWorkspaceName(env: NodeJS.ProcessEnv, cwd: string, git: GitContext): string`, `export function workspaceBranchName(raw: string): string`, `export function checkBranchName(raw: string): string`, `currentWorkspaceBranchName(): string` (internal glue used by provision/sync/teardown)

- [ ] **Step 1: Write the failing tests**

Add near the top of `tests/neondb-branch.test.ts`, replacing the import list to add the new names (keep all existing imports, add these):

```ts
import {
  // ...existing imports...
  resolveWorkspaceName,
  type GitContext,
} from '../scripts/neondb-branch'
```

Replace the entire `describe('workspaceBranchName', ...)` block with:

```ts
describe('resolveWorkspaceName (workspace identity precedence)', () => {
  const worktree: GitContext = { isSecondaryWorktree: true, branch: 'martintechlabs/feature-x' }
  const singleClone: GitContext = { isSecondaryWorktree: false, branch: 'martintechlabs/feature-x' }
  const noIdentity: GitContext = { isSecondaryWorktree: false, branch: null }

  it('prefers CONDUCTOR_WORKSPACE_NAME over every other source', () => {
    const env = { CONDUCTOR_WORKSPACE_NAME: 'conductor-ws', ORCA_WORKSPACE_NAME: 'orca-ws', WORKSPACE_NAME: 'general-ws' }
    expect(resolveWorkspaceName(env, '/work/trees/mojarra', worktree)).toBe('conductor-ws')
  })

  it('prefers ORCA_WORKSPACE_NAME over WORKSPACE_NAME and checkout signals', () => {
    const env = { ORCA_WORKSPACE_NAME: 'orca-ws', WORKSPACE_NAME: 'general-ws' }
    expect(resolveWorkspaceName(env, '/work/trees/mojarra', worktree)).toBe('orca-ws')
  })

  it('falls back to WORKSPACE_NAME when no tool-specific var is set', () => {
    expect(resolveWorkspaceName({ WORKSPACE_NAME: 'general-ws' }, '/work/trees/mojarra', worktree)).toBe('general-ws')
  })

  it('falls back to the checkout directory basename for a secondary git worktree with no env vars', () => {
    expect(resolveWorkspaceName({}, '/Users/dev/workspaces/mojarra', worktree)).toBe('mojarra')
  })

  it('falls back to the current git branch for a plain single-clone checkout with no env vars', () => {
    expect(resolveWorkspaceName({}, '/Users/dev/myrepo', singleClone)).toBe('martintechlabs/feature-x')
  })

  it('throws a clear error when nothing resolves (no env vars, not a worktree, detached HEAD)', () => {
    expect(() => resolveWorkspaceName({}, '/Users/dev/myrepo', noIdentity)).toThrow(/Could not determine workspace identity/)
  })
})

describe('workspaceBranchName / checkBranchName (given an already-resolved raw identity)', () => {
  it('slugifies a short identity into a clean workspace/ branch (no hash suffix)', () => {
    expect(workspaceBranchName('My Cool Feature!')).toBe('workspace/my-cool-feature')
  })

  it('collapses separator runs and trims leading/trailing separators', () => {
    expect(workspaceBranchName('  Feature / 123 -- test  ')).toBe('workspace/feature-123-test')
  })

  it('truncates an over-long identity and appends a hash suffix, never ending in a separator', () => {
    const raw = 'a'.repeat(100)
    const name = workspaceBranchName(raw)
    expect(name).toMatch(/^workspace\/a{39}-[0-9a-f]{8}$/)
    expect(name).not.toMatch(/-$/)
    expect(name.length).toBeLessThanOrEqual('workspace/'.length + 48)
  })

  it('re-trims a separator left dangling by truncation before the hash (no "--")', () => {
    const raw = 'a'.repeat(38) + ' ' + 'b'.repeat(20)
    const name = workspaceBranchName(raw)
    expect(name).toMatch(/^workspace\/a{38}-[0-9a-f]{8}$/)
    expect(name).not.toContain('--')
  })

  it('gives distinct branches to distinct long identities sharing a truncated prefix (no collision)', () => {
    const prefix = 'shared-prefix-that-is-definitely-longer-than-forty-eight-characters-'
    expect(workspaceBranchName(`${prefix}alpha`)).not.toBe(workspaceBranchName(`${prefix}beta`))
  })

  it('throws when the identity has no usable characters', () => {
    expect(() => workspaceBranchName('@@@')).toThrow(/Could not derive a branch name/)
  })

  it('checkBranchName shares workspaceBranchName\'s slug but under the tmp/ prefix', () => {
    expect(checkBranchName('My Cool Feature!')).toBe('tmp/my-cool-feature')
    expect(checkBranchName('My Cool Feature!')).not.toBe(workspaceBranchName('My Cool Feature!'))
  })

  it('truncates and hashes independently of workspaceBranchName, never colliding across the two prefixes', () => {
    const raw = 'a'.repeat(100)
    expect(checkBranchName(raw)).toMatch(/^tmp\/a{39}-[0-9a-f]{8}$/)
    expect(checkBranchName(raw).slice('tmp/'.length)).toBe(workspaceBranchName(raw).slice('workspace/'.length))
  })
})
```

Delete the old `describe('checkBranchName ...', ...)` block (its cases are now folded into the block above) and delete the old test `'throws a clear error when the workspace name is missing — without telling the user...'` (that behavior moved to `resolveWorkspaceName`, already covered above).

- [ ] **Step 2: Run tests — expect FAIL (new exports don't exist yet)**

```bash
SCRATCH=/private/tmp/claude-501/-Users-smartin-orca-workspaces-agent-skills-mojarra/232ff6de-43d9-4d59-af36-586513a2785c/scratchpad/neondb-branch-dev
SKILL=/Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/neondb-branch
rm -rf "$SCRATCH/work" && mkdir -p "$SCRATCH/work/scripts" "$SCRATCH/work/tests"
cp "$SKILL/scripts/neondb-branch.ts" "$SCRATCH/work/scripts/"
cp "$SKILL/tests/neondb-branch.test.ts" "$SCRATCH/work/tests/"
cd "$SCRATCH" && npx vitest run work/tests/neondb-branch.test.ts 2>&1 | tail -40
```

Expected: FAIL — `resolveWorkspaceName` is not exported / `workspaceBranchName` still expects zero args.

- [ ] **Step 3: Implement `resolveWorkspaceName`, `GitContext`, and rework `workspaceBranchName`/`checkBranchName`**

Add `basename` to the existing `node:path` import:

```ts
import { dirname, basename } from 'node:path'
```

Find the existing `workspaceSlug()` function and the `branchNameWithPrefix()` function:

```ts
/** The raw slug for the current workspace, before any length handling. */
function workspaceSlug(): string {
  const raw = process.env.CONDUCTOR_WORKSPACE_NAME
  if (!raw) {
    // Deliberately NOT requireEnv: Conductor injects this variable itself. Telling the user to
    // add it to the env tabs would pin every workspace to ONE shared slug (and one branch).
    throw new Error(
      'CONDUCTOR_WORKSPACE_NAME is not set — this script must run inside a Conductor workspace ' +
        '(Conductor injects it automatically). Do NOT add it to the Conductor env tabs.',
    )
  }
  const slug = raw
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
  if (!slug) {
    throw new Error(`Could not derive a branch name from CONDUCTOR_WORKSPACE_NAME="${raw}".`)
  }
  return slug
}

/**
 * Shared by workspaceBranchName() and checkBranchName() — same slug/truncation/collision-hash
 * logic under a different disposable-branch prefix.
 */
function branchNameWithPrefix(prefix: string): string {
  const raw = process.env.CONDUCTOR_WORKSPACE_NAME ?? ''
  let slug = workspaceSlug()
  if (slug.length > MAX_SLUG) {
    // Truncate, but keep distinct workspaces distinct: append a short hash of the FULL name so
    // two long names that share a prefix don't collide onto the same branch (which would break
    // isolation and let one workspace's teardown delete another's branch). Re-trim any separator
    // the cut left dangling so the name never ends in "-".
    const suffix = createHash('sha256').update(raw).digest('hex').slice(0, 8)
    slug = `${slug.slice(0, MAX_SLUG - suffix.length - 1).replace(/-+$/, '')}-${suffix}`
  }
  return `${prefix}${slug}`
}

/** Stable, Neon-safe branch name derived from the workspace name. */
export function workspaceBranchName(): string {
  return branchNameWithPrefix(BRANCH_PREFIX)
}

/**
 * The disposable branch used once per provision() run to learn the parent's true
 * applied-migration state (see seedTrueBaseline). Same derivation as workspaceBranchName(),
 * under CHECK_BRANCH_PREFIX — deterministic, not random, so a leftover from a killed run is found
 * by name and replaced rather than accumulating orphans.
 */
export function checkBranchName(): string {
  return branchNameWithPrefix(CHECK_BRANCH_PREFIX)
}
```

Replace that whole block with:

```ts
/**
 * What identifies "this workspace" — before slugify, before any Neon prefix. See
 * resolveWorkspaceName() for the precedence chain; this is only the pure slug/truncation logic
 * shared by workspaceBranchName() and checkBranchName().
 */
function slugify(raw: string): string {
  const slug = raw
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
  if (!slug) {
    throw new Error(`Could not derive a branch name from workspace identity "${raw}".`)
  }
  return slug
}

/**
 * Shared by workspaceBranchName() and checkBranchName() — same slug/truncation/collision-hash
 * logic under a different disposable-branch prefix, given an already-resolved raw identity.
 */
function branchNameWithPrefix(prefix: string, raw: string): string {
  let slug = slugify(raw)
  if (slug.length > MAX_SLUG) {
    // Truncate, but keep distinct workspaces distinct: append a short hash of the FULL name so
    // two long names that share a prefix don't collide onto the same branch (which would break
    // isolation and let one workspace's teardown delete another's branch). Re-trim any separator
    // the cut left dangling so the name never ends in "-".
    const suffix = createHash('sha256').update(raw).digest('hex').slice(0, 8)
    slug = `${slug.slice(0, MAX_SLUG - suffix.length - 1).replace(/-+$/, '')}-${suffix}`
  }
  return `${prefix}${slug}`
}

/** Stable, Neon-safe branch name derived from an already-resolved raw workspace identity. */
export function workspaceBranchName(raw: string): string {
  return branchNameWithPrefix(BRANCH_PREFIX, raw)
}

/**
 * The disposable branch used once per provision() run to learn the parent's true
 * applied-migration state (see seedTrueBaseline). Same derivation as workspaceBranchName(),
 * under CHECK_BRANCH_PREFIX — deterministic, not random, so a leftover from a killed run is found
 * by name and replaced rather than accumulating orphans.
 */
export function checkBranchName(raw: string): string {
  return branchNameWithPrefix(CHECK_BRANCH_PREFIX, raw)
}

/** What resolveWorkspaceName() needs to know about the current checkout, gathered by the caller. */
export interface GitContext {
  /** true when this checkout is a linked git worktree (not the main/primary checkout) */
  isSecondaryWorktree: boolean
  /** current branch name, or null when HEAD is detached or this isn't a git repository */
  branch: string | null
}

/**
 * Workspace identity, before slugify. First match wins:
 *   1. CONDUCTOR_WORKSPACE_NAME — Conductor injects this per workspace.
 *   2. ORCA_WORKSPACE_NAME — Orca's own identity, when the project/tool sets it.
 *   3. WORKSPACE_NAME — general ambient override for custom tools, tests, or a project that
 *      exports one name for every tool. Only read from process env — NEVER from .env.neondb,
 *      which can be copied across workspaces and would collide them onto the same Neon branch.
 *   4. basename(cwd) for a secondary git worktree with none of the above set — each worktree is
 *      its own directory, so this is stable across a `git checkout` inside it.
 *   5. The current git branch, for a plain single-clone checkout with none of the above set —
 *      here "the workspace" genuinely IS the branch, so switching branches IS switching identity.
 * Throws when nothing resolves (detached HEAD / not a git repo, and no env var set) — there is no
 * derivable identity in that case.
 */
export function resolveWorkspaceName(env: NodeJS.ProcessEnv, cwd: string, git: GitContext): string {
  const fromEnv = env.CONDUCTOR_WORKSPACE_NAME || env.ORCA_WORKSPACE_NAME || env.WORKSPACE_NAME
  if (fromEnv) return fromEnv
  if (git.isSecondaryWorktree) return basename(cwd)
  if (git.branch) return git.branch
  throw new Error(
    'Could not determine workspace identity: no CONDUCTOR_WORKSPACE_NAME / ORCA_WORKSPACE_NAME / ' +
      'WORKSPACE_NAME is set, this checkout is not a secondary git worktree, and there is no usable ' +
      'git branch (detached HEAD, or not a git repository). Check out a named branch, or set ' +
      'WORKSPACE_NAME explicitly.',
  )
}

/** Impure glue for resolveWorkspaceName()'s `git` parameter — not itself unit-tested; exercised via references/verify.md. */
function currentGitContext(cwd: string): GitContext {
  let gitDir: string
  try {
    gitDir = execFileSync('git', ['rev-parse', '--git-dir'], { cwd, encoding: 'utf8' }).trim()
  } catch {
    return { isSecondaryWorktree: false, branch: null }
  }
  const isSecondaryWorktree = /[\\/]worktrees[\\/]/.test(gitDir)
  let branch: string | null = null
  try {
    const ref = execFileSync('git', ['rev-parse', '--abbrev-ref', 'HEAD'], { cwd, encoding: 'utf8' }).trim()
    branch = ref === 'HEAD' ? null : ref // literal 'HEAD' means detached
  } catch {
    branch = null
  }
  return { isSecondaryWorktree, branch }
}

/** The workspace's Neon branch name, resolved from the live process/cwd/git state. */
function currentWorkspaceBranchName(): string {
  return workspaceBranchName(resolveWorkspaceName(process.env, process.cwd(), currentGitContext(process.cwd())))
}
```

- [ ] **Step 4: Update call sites**

`provision()` needs the resolved `raw` identity itself (to pass through to `seedTrueBaseline()`),
not just the derived branch name, so it gets a direct edit rather than the `currentWorkspaceBranchName()`
shortcut. In `provision()`, find:

```ts
  const branchName = workspaceBranchName()
```

Replace with:

```ts
  const raw = resolveWorkspaceName(process.env, process.cwd(), currentGitContext(process.cwd()))
  const branchName = workspaceBranchName(raw)
```

In `seedTrueBaseline()`, find its signature and internal `checkBranchName()` call:

```ts
async function seedTrueBaseline(projectId: string, parent: string, uri: string): Promise<void> {
```

Replace with:

```ts
async function seedTrueBaseline(projectId: string, parent: string, uri: string, raw: string): Promise<void> {
```

Find inside that function:

```ts
  const checkName = checkBranchName()
```

Replace with:

```ts
  const checkName = checkBranchName(raw)
```

Find its call site inside `provision()`:

```ts
    await seedTrueBaseline(projectId, parent, uri)
```

Replace with:

```ts
    await seedTrueBaseline(projectId, parent, uri, raw)
```

In `sync()` and `teardown()`, every remaining bare `workspaceBranchName()` call (no args) becomes
`currentWorkspaceBranchName()` for now — these two functions get fully rewritten in Tasks 5–6, so
this is purely "keep it compiling," not a redesign yet.

- [ ] **Step 5: Run tests — expect PASS**

```bash
SCRATCH=/private/tmp/claude-501/-Users-smartin-orca-workspaces-agent-skills-mojarra/232ff6de-43d9-4d59-af36-586513a2785c/scratchpad/neondb-branch-dev
SKILL=/Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/neondb-branch
rm -rf "$SCRATCH/work" && mkdir -p "$SCRATCH/work/scripts" "$SCRATCH/work/tests"
cp "$SKILL/scripts/neondb-branch.ts" "$SCRATCH/work/scripts/"
cp "$SKILL/tests/neondb-branch.test.ts" "$SCRATCH/work/tests/"
cd "$SCRATCH" && npx vitest run work/tests/neondb-branch.test.ts
```

Expected: all tests pass (count will have grown from 43 by the new `resolveWorkspaceName`/reworked `workspaceBranchName`/`checkBranchName` cases, minus the ones you deleted in Step 1).

- [ ] **Step 6: Commit**

```bash
cd /Users/smartin/orca/workspaces/agent-skills/mojarra
git add skills/devops/neondb-branch/scripts/neondb-branch.ts skills/devops/neondb-branch/tests/neondb-branch.test.ts
git commit -m "$(cat <<'EOF'
neondb-branch: resolveWorkspaceName precedence chain

Identity resolves CONDUCTOR_WORKSPACE_NAME > ORCA_WORKSPACE_NAME >
WORKSPACE_NAME > worktree basename > git branch, replacing the
Conductor-only env var read. workspaceBranchName/checkBranchName now take
an explicit resolved identity instead of reading env directly.
EOF
)"
```

---

## Task 3: `.env.neondb` upsert/strip helpers

**Files:**
- Modify: `skills/devops/neondb-branch/scripts/neondb-branch.ts`
- Modify: `skills/devops/neondb-branch/tests/neondb-branch.test.ts`

**Interfaces:**
- Consumes: Task 2's `currentWorkspaceBranchName()` / identity plumbing
- Produces: `export function upsertEnvVars(path: string, vars: Record<string, string>): void`, `export function stripEnvVars(path: string, keys: string[]): void`; removes `writeEnvFile`, `buildEnvFileContents`, `provisionedEnvTraceExists`, `removeGeneratedEnvFiles`

- [ ] **Step 1: Write the failing tests**

Replace the existing `describe('buildEnvFileContents ...', ...)` block with:

```ts
describe('upsertEnvVars / stripEnvVars (.env.neondb is upserted in place, never truncated)', () => {
  let envFile: string

  beforeEach(() => {
    envFile = join(sandbox, `.env.neondb.${Math.random().toString(36).slice(2)}`)
  })

  afterEach(() => {
    rmSync(envFile, { force: true })
  })

  it('creates the file with the given vars when none existed', () => {
    upsertEnvVars(envFile, { DATABASE_URL: 'postgres://a', NEON_API_KEY: 'k' })
    const content = readFileSync(envFile, 'utf8')
    expect(content).toContain("DATABASE_URL='postgres://a'")
    expect(content).toContain("NEON_API_KEY='k'")
  })

  it('updates an existing key in place, preserving unrelated lines', () => {
    writeFileSync(envFile, "# a comment\nDATABASE_URL='old'\nOTHER_VAR='keep-me'\n")
    upsertEnvVars(envFile, { DATABASE_URL: 'postgres://new' })
    const content = readFileSync(envFile, 'utf8')
    expect(content).toContain('# a comment')
    expect(content).toContain("DATABASE_URL='postgres://new'")
    expect(content).not.toContain('old')
    expect(content).toContain("OTHER_VAR='keep-me'")
  })

  it('appends a var that is not present yet, preserving everything else', () => {
    writeFileSync(envFile, "OTHER_VAR='keep-me'\n")
    upsertEnvVars(envFile, { DATABASE_URL: 'postgres://a' })
    const content = readFileSync(envFile, 'utf8')
    expect(content).toContain("OTHER_VAR='keep-me'")
    expect(content).toContain("DATABASE_URL='postgres://a'")
  })

  it('upserts multiple keys in one call (DATABASE_URL plus the three Neon control vars)', () => {
    upsertEnvVars(envFile, {
      DATABASE_URL: 'postgres://a',
      NEON_API_KEY: 'k',
      NEON_PROJECT_ID: 'p',
      NEON_PARENT_BRANCH: 'production',
    })
    const content = readFileSync(envFile, 'utf8')
    for (const line of ["DATABASE_URL='postgres://a'", "NEON_API_KEY='k'", "NEON_PROJECT_ID='p'", "NEON_PARENT_BRANCH='production'"]) {
      expect(content).toContain(line)
    }
  })

  it('stripEnvVars removes just the given keys, preserving the rest', () => {
    writeFileSync(envFile, "DATABASE_URL='postgres://a'\nNEON_API_KEY='k'\n")
    stripEnvVars(envFile, ['DATABASE_URL'])
    const content = readFileSync(envFile, 'utf8')
    expect(content).not.toContain('DATABASE_URL')
    expect(content).toContain("NEON_API_KEY='k'")
  })

  it('stripEnvVars deletes the file entirely when nothing is left', () => {
    writeFileSync(envFile, "DATABASE_URL='postgres://a'\n")
    stripEnvVars(envFile, ['DATABASE_URL'])
    expect(existsSync(envFile)).toBe(false)
  })

  it('stripEnvVars is a no-op when the file does not exist', () => {
    expect(() => stripEnvVars(envFile, ['DATABASE_URL'])).not.toThrow()
    expect(existsSync(envFile)).toBe(false)
  })
})
```

Add `existsSync` to the `node:fs` import at the top of the test file if not already present:

```ts
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
```

Add the new function names to the import from `'../scripts/neondb-branch'`:

```ts
  stripEnvVars,
  upsertEnvVars,
```

- [ ] **Step 2: Run tests — expect FAIL**

```bash
SCRATCH=/private/tmp/claude-501/-Users-smartin-orca-workspaces-agent-skills-mojarra/232ff6de-43d9-4d59-af36-586513a2785c/scratchpad/neondb-branch-dev
SKILL=/Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/neondb-branch
rm -rf "$SCRATCH/work" && mkdir -p "$SCRATCH/work/scripts" "$SCRATCH/work/tests"
cp "$SKILL/scripts/neondb-branch.ts" "$SCRATCH/work/scripts/"
cp "$SKILL/tests/neondb-branch.test.ts" "$SCRATCH/work/tests/"
cd "$SCRATCH" && npx vitest run work/tests/neondb-branch.test.ts 2>&1 | tail -30
```

Expected: FAIL — `upsertEnvVars`/`stripEnvVars` not exported.

- [ ] **Step 3: Implement `upsertEnvVars`/`stripEnvVars`, remove the old full-rewrite helpers**

Find and delete these four functions entirely: `provisionedEnvTraceExists()`, `removeGeneratedEnvFiles()`, `buildEnvFileContents()`, and `writeEnvFile()`.

In their place, add:

```ts
function readEnvFileRaw(path: string): string {
  try {
    return readFileSync(path, 'utf8')
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return ''
    throw error
  }
}

/** Non-empty lines of `content`, trailing newline stripped, with any line whose key is in `keys` removed. */
function withoutKeys(content: string, keys: string[]): string[] {
  const trimmed = content.replace(/\n+$/, '')
  if (trimmed === '') return []
  const keySet = new Set(keys)
  return trimmed.split('\n').filter((line) => {
    const eq = line.indexOf('=')
    return eq === -1 ? true : !keySet.has(line.slice(0, eq))
  })
}

/**
 * Upsert every NAME=value pair in `vars` into `path`, preserving every other line (unrelated vars,
 * comments, blank lines) untouched. Creates the file if it doesn't exist yet. Single-quoted values:
 * dotenv's expand step would otherwise rewrite a literal `$` inside a connection string.
 */
export function upsertEnvVars(path: string, vars: Record<string, string>): void {
  const kept = withoutKeys(readEnvFileRaw(path), Object.keys(vars))
  const appended = Object.entries(vars).map(([name, value]) => `${name}='${value}'`)
  writeFileSync(path, `${[...kept, ...appended].join('\n')}\n`, { mode: 0o600 })
}

/**
 * Remove every line whose key is in `keys` from `path`, preserving everything else. Deletes the
 * file entirely if that leaves nothing behind; no-ops if the file doesn't exist.
 */
export function stripEnvVars(path: string, keys: string[]): void {
  const raw = readEnvFileRaw(path)
  if (!raw.trim()) return
  const kept = withoutKeys(raw, keys)
  if (kept.length === 0) rmSync(path, { force: true })
  else writeFileSync(path, `${kept.join('\n')}\n`, { mode: 0o600 })
}
```

- [ ] **Step 4: Wire `upsertEnvVars`/`stripEnvVars` into `provision()`**

Find in `provision()`:

```ts
    const uri = await withRetry('fetch connection string', () => getConnectionString(projectId, branchName))
    writeEnvFile({
      ...Object.fromEntries(DB_ENV_VARS.map((name) => [name, uri])),
      NEON_API_KEY: apiKey,
      NEON_PROJECT_ID: projectId,
      NEON_PARENT_BRANCH: parent,
    })
    console.log(`[conductor-db] wrote ${DB_ENV_VARS.join(', ')} and Neon credentials for ${branchName} → ${ENV_FILE}`)
```

Replace with:

```ts
    const uri = await withRetry('fetch connection string', () => getConnectionString(projectId, branchName))
    upsertEnvVars(ENV_FILE, {
      ...Object.fromEntries(DB_ENV_VARS.map((name) => [name, uri])),
      NEON_API_KEY: apiKey,
      NEON_PROJECT_ID: projectId,
      NEON_PARENT_BRANCH: parent,
    })
    console.log(`[neondb-branch] wrote ${DB_ENV_VARS.join(', ')} and Neon credentials for ${branchName} → ${ENV_FILE}`)
```

Find `provision()`'s failure-cleanup block:

```ts
  } catch (error) {
    console.error('[conductor-db] setup failed — deleting the branch so the next attempt starts clean.')
    try {
      await deleteBranch(projectId, branchName)
      // Env file first, state record last — a crash between the two leaves the record
      // (harmless, self-corrects on the next provision), rather than an env file with no
      // record, which would slip past sync's gates and boot the app against a dead endpoint.
      rmSync(ENV_FILE, { force: true })
      rmSync(stateFilePath(), { force: true })
    } catch {
      console.error(
        `[conductor-db] WARNING: could not delete branch ${branchName}; ` +
          `keeping ${stateFilePath()} so the next provision/teardown can find it.`,
      )
    }
    throw error
  }
```

Replace with:

```ts
  } catch (error) {
    console.error('[neondb-branch] setup failed — deleting the branch so the next attempt starts clean.')
    try {
      await deleteBranch(projectId, branchName)
      // Strip only the branch-specific DB vars (they'd point at a dead endpoint) — leave
      // NEON_API_KEY/NEON_PROJECT_ID/NEON_PARENT_BRANCH in .env.neondb so the next provision
      // attempt doesn't need them re-supplied. State record last: a crash between the two leaves
      // the record (harmless, self-corrects on the next provision), rather than a DB var with no
      // record, which would slip past sync's gates and boot the app against a dead endpoint.
      stripEnvVars(ENV_FILE, DB_ENV_VARS)
      rmSync(stateFilePath(), { force: true })
    } catch {
      console.error(
        `[neondb-branch] WARNING: could not delete branch ${branchName}; ` +
          `keeping ${stateFilePath()} so the next provision/teardown can find it.`,
      )
    }
    throw error
  }
```

- [ ] **Step 5: Fix `teardown()`'s now-broken references to the removed helpers (temporary — Task 6 rewrites `teardown()` fully)**

Find every remaining call to `provisionedEnvTraceExists()` inside `teardown()` and temporarily replace each with `false` (a placeholder that keeps the file compiling; Task 6 replaces this whole function). Find every call to `removeGeneratedEnvFiles()` and replace with `stripEnvVars(ENV_FILE, DB_ENV_VARS)`.

- [ ] **Step 6: Run tests — expect PASS**

```bash
SCRATCH=/private/tmp/claude-501/-Users-smartin-orca-workspaces-agent-skills-mojarra/232ff6de-43d9-4d59-af36-586513a2785c/scratchpad/neondb-branch-dev
SKILL=/Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/neondb-branch
rm -rf "$SCRATCH/work" && mkdir -p "$SCRATCH/work/scripts" "$SCRATCH/work/tests"
cp "$SKILL/scripts/neondb-branch.ts" "$SCRATCH/work/scripts/"
cp "$SKILL/tests/neondb-branch.test.ts" "$SCRATCH/work/tests/"
cd "$SCRATCH" && npx vitest run work/tests/neondb-branch.test.ts
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
cd /Users/smartin/orca/workspaces/agent-skills/mojarra
git add skills/devops/neondb-branch/scripts/neondb-branch.ts skills/devops/neondb-branch/tests/neondb-branch.test.ts
git commit -m "$(cat <<'EOF'
neondb-branch: upsert .env.neondb instead of full rewrite

provision() upserts DATABASE_URL (+ DB_ENV_VARS) and the three Neon
control vars in place, preserving any other content in the file.
Failure cleanup strips only the branch-specific vars, keeping the Neon
control vars for the next attempt. Removes the old full-rewrite/
trace-detection helpers.
EOF
)"
```

---

## Task 4: Programmatic `.env.neondb` load in `main()` + `load-env.cjs`

**Files:**
- Modify: `skills/devops/neondb-branch/scripts/neondb-branch.ts`
- Modify: `skills/devops/neondb-branch/tests/neondb-branch.test.ts`
- Create: `skills/devops/neondb-branch/scripts/load-env.cjs`

**Interfaces:**
- Consumes: `ENV_FILE` constant (unchanged from Task 1)
- Produces: `main()` loads `.env.neondb` via `dotenv` before dispatching; `load-env.cjs` is a standalone require-hook the dev server uses

- [ ] **Step 1: Write the failing test for `main()`'s env loading**

Add near the end of the test file, before the final closing of the outer `describe`:

```ts
describe('main() loads .env.neondb before dispatching (never overriding an already-set var)', () => {
  let envFile: string

  beforeEach(() => {
    envFile = join(sandbox, '.env.neondb')
    process.env.NEONDB_BRANCH_ENV_FILE = envFile
  })

  afterEach(() => {
    delete process.env.NEONDB_BRANCH_ENV_FILE
    delete process.env.NEON_PROJECT_ID
    rmSync(envFile, { force: true })
  })

  it('populates process.env from the file when the var is not already set', () => {
    writeFileSync(envFile, "NEON_PROJECT_ID='from-file'\n")
    loadEnvFile()
    expect(process.env.NEON_PROJECT_ID).toBe('from-file')
  })

  it('never overrides a var already present in process.env', () => {
    process.env.NEON_PROJECT_ID = 'from-shell'
    writeFileSync(envFile, "NEON_PROJECT_ID='from-file'\n")
    loadEnvFile()
    expect(process.env.NEON_PROJECT_ID).toBe('from-shell')
  })

  it('is a no-op when the file does not exist', () => {
    expect(() => loadEnvFile()).not.toThrow()
  })
})
```

Add `loadEnvFile` to the import from `'../scripts/neondb-branch'`.

- [ ] **Step 2: Run tests — expect FAIL**

```bash
SCRATCH=/private/tmp/claude-501/-Users-smartin-orca-workspaces-agent-skills-mojarra/232ff6de-43d9-4d59-af36-586513a2785c/scratchpad/neondb-branch-dev
SKILL=/Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/neondb-branch
rm -rf "$SCRATCH/work" && mkdir -p "$SCRATCH/work/scripts" "$SCRATCH/work/tests"
cp "$SKILL/scripts/neondb-branch.ts" "$SCRATCH/work/scripts/"
cp "$SKILL/tests/neondb-branch.test.ts" "$SCRATCH/work/tests/"
cd "$SCRATCH" && npx vitest run work/tests/neondb-branch.test.ts 2>&1 | tail -30
```

Expected: FAIL — `loadEnvFile` not exported.

- [ ] **Step 3: Add the `dotenv` import and a testable env-loading function**

Add near the top of `scripts/neondb-branch.ts`, alongside the other imports:

```ts
import { config as dotenvConfig } from 'dotenv'
```

Add this function near `stateFilePath()` (same "resolved at call time so tests can override it" pattern):

```ts
/** Where main() loads .env.neondb from. Test-only override via NEONDB_BRANCH_ENV_FILE — never set this in a real workspace. */
function envFilePath(): string {
  return process.env.NEONDB_BRANCH_ENV_FILE ?? ENV_FILE
}

/**
 * Load .env.neondb into process.env, never overriding an already-set var. Exported (and factored
 * out of main()) so tests can exercise the loading behavior directly without invoking the CLI
 * dispatch.
 */
export function loadEnvFile(): void {
  dotenvConfig({ path: envFilePath() })
}
```

- [ ] **Step 4: Call it from `main()`**

Find:

```ts
async function main(): Promise<void> {
  const mode = process.argv[2]
```

Replace with:

```ts
async function main(): Promise<void> {
  loadEnvFile() // .env.neondb, never overriding an already-set var
  const mode = process.argv[2]
```

- [ ] **Step 5: Create `scripts/load-env.cjs`**

```js
// scripts/load-env.cjs
//
// Preloaded via NODE_OPTIONS='--require ./scripts/load-env.cjs' (see the dev/build/start scripts
// in your package.json) so the dev server picks up DATABASE_URL from .env.neondb — the
// per-workspace Neon branch file scripts/neondb-branch.ts writes.
//
// SAFETY: this silently falls back to whatever the dev server's own .env loading provides when
// .env.neondb doesn't exist. That's only safe because `sync`'s hard gates run BEFORE this in the
// same `&&` chain (see the "dev" script) — never remove one without the other, or an unprovisioned
// workspace boots straight against the ambient/shared DATABASE_URL with no warning.
try {
  process.loadEnvFile('.env.neondb')
} catch (error) {
  if (error.code !== 'ENOENT') throw error
}
```

- [ ] **Step 6: Run tests — expect PASS**

```bash
SCRATCH=/private/tmp/claude-501/-Users-smartin-orca-workspaces-agent-skills-mojarra/232ff6de-43d9-4d59-af36-586513a2785c/scratchpad/neondb-branch-dev
SKILL=/Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/neondb-branch
rm -rf "$SCRATCH/work" && mkdir -p "$SCRATCH/work/scripts" "$SCRATCH/work/tests"
cp "$SKILL/scripts/neondb-branch.ts" "$SCRATCH/work/scripts/"
cp "$SKILL/tests/neondb-branch.test.ts" "$SCRATCH/work/tests/"
cd "$SCRATCH" && npm install --silent && npx vitest run work/tests/neondb-branch.test.ts
```

Expected: all tests pass.

- [ ] **Step 7: Manually verify `load-env.cjs` in isolation**

```bash
SCRATCH=/private/tmp/claude-501/-Users-smartin-orca-workspaces-agent-skills-mojarra/232ff6de-43d9-4d59-af36-586513a2785c/scratchpad/neondb-branch-dev
mkdir -p "$SCRATCH/loadenv-check" && cd "$SCRATCH/loadenv-check"
cp /Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/neondb-branch/scripts/load-env.cjs .
echo "DATABASE_URL='postgres://from-file'" > .env.neondb
node -e "require('./load-env.cjs'); console.log(process.env.DATABASE_URL)"
rm .env.neondb
node -e "require('./load-env.cjs'); console.log('no file, no throw:', process.env.DATABASE_URL)"
```

Expected: first command prints `postgres://from-file`; second prints `no file, no throw: undefined` (no exception).

- [ ] **Step 8: Commit**

```bash
cd /Users/smartin/orca/workspaces/agent-skills/mojarra
git add skills/devops/neondb-branch/scripts/neondb-branch.ts skills/devops/neondb-branch/scripts/load-env.cjs skills/devops/neondb-branch/tests/neondb-branch.test.ts
git commit -m "$(cat <<'EOF'
neondb-branch: load .env.neondb programmatically, add load-env.cjs

main() loads .env.neondb itself via dotenv before dispatching, so no
package.json script needs a dotenv-cli shell prefix. load-env.cjs is the
NODE_OPTIONS require-hook the dev server uses instead — only safe because
sync's hard gates always run first in the same && chain.
EOF
)"
```

---

## Task 5: `planSync` + rewritten `sync()`

**Files:**
- Modify: `skills/devops/neondb-branch/scripts/neondb-branch.ts`
- Modify: `skills/devops/neondb-branch/tests/neondb-branch.test.ts`

**Interfaces:**
- Consumes: `currentWorkspaceBranchName`/`resolveWorkspaceName` (Task 2), `readBranchStateFull` (renamed from the existing private `readStateFile`), `renameBranch`/`assertDisposableChildBranch`/`requireEnv` (unchanged, Task 1)
- Produces: `export type SyncAction = ...`, `export function planSync(...): SyncAction`, rewritten `sync()`

- [ ] **Step 1: Export the existing private state reader under a name tests can use**

Find:

```ts
/** Single reader for the state file; the exported helpers below are thin views over it. */
function readStateFile(): { branch: string; phase: 'pending' | 'ready' } | null {
```

Replace with:

```ts
/** Single reader for the state file; the exported helpers below are thin views over it. */
export function readBranchStateFull(): { branch: string; phase: 'pending' | 'ready' } | null {
```

Every existing internal call to `readStateFile()` (inside `readBranchState()` and `setupIsPending()`) now calls `readBranchStateFull()` — update both.

- [ ] **Step 2: Write the failing tests for `planSync`**

Add a new `describe` block (place it near the existing `withRetry` tests):

```ts
describe('planSync (sync() decision logic)', () => {
  const readyState = { branch: 'workspace/feature-x', phase: 'ready' as const }
  const pendingState = { branch: 'workspace/feature-x', phase: 'pending' as const }

  it('gates as unprovisioned when there is no state at all', () => {
    expect(planSync(null, 'workspace/feature-x', false, false)).toEqual({ type: 'gate', reason: { type: 'unprovisioned' } })
  })

  it('gates as pending when setup never finished', () => {
    expect(planSync(pendingState, 'workspace/feature-x', true, true)).toEqual({ type: 'gate', reason: { type: 'pending' } })
  })

  it('noops when the recorded branch matches current and still exists', () => {
    expect(planSync(readyState, 'workspace/feature-x', true, true)).toEqual({ type: 'noop' })
  })

  it('gates as a dead branch when recorded matches current but the branch is gone', () => {
    expect(planSync(readyState, 'workspace/feature-x', false, false)).toEqual({
      type: 'gate',
      reason: { type: 'deadBranch', recorded: 'workspace/feature-x' },
    })
  })

  it('renames when recorded differs from current and only the recorded branch exists (the normal case)', () => {
    expect(planSync(readyState, 'workspace/main', true, false)).toEqual({
      type: 'rename',
      from: 'workspace/feature-x',
      to: 'workspace/main',
    })
  })

  it('reconciles instead of renaming when a prior sync already renamed on Neon but crashed before recording it locally', () => {
    expect(planSync(readyState, 'workspace/main', false, true)).toEqual({ type: 'reconcile', to: 'workspace/main' })
  })

  it('gates as a dead branch when recorded differs from current and NEITHER exists', () => {
    expect(planSync(readyState, 'workspace/main', false, false)).toEqual({
      type: 'gate',
      reason: { type: 'deadBranch', recorded: 'workspace/feature-x' },
    })
  })

  it('flags a collision when recorded differs from current and BOTH already exist as live branches', () => {
    expect(planSync(readyState, 'workspace/main', true, true)).toEqual({
      type: 'collision',
      from: 'workspace/feature-x',
      to: 'workspace/main',
    })
  })
})
```

Add `planSync` to the import list from `'../scripts/neondb-branch'`.

- [ ] **Step 3: Run tests — expect FAIL**

```bash
SCRATCH=/private/tmp/claude-501/-Users-smartin-orca-workspaces-agent-skills-mojarra/232ff6de-43d9-4d59-af36-586513a2785c/scratchpad/neondb-branch-dev
SKILL=/Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/neondb-branch
rm -rf "$SCRATCH/work" && mkdir -p "$SCRATCH/work/scripts" "$SCRATCH/work/tests"
cp "$SKILL/scripts/neondb-branch.ts" "$SCRATCH/work/scripts/"
cp "$SKILL/tests/neondb-branch.test.ts" "$SCRATCH/work/tests/"
cd "$SCRATCH" && npx vitest run work/tests/neondb-branch.test.ts 2>&1 | tail -30
```

Expected: FAIL — `planSync` not exported.

- [ ] **Step 4: Implement `planSync` and the exact `SyncAction` type**

Add above the existing `sync()` function:

```ts
export type SyncGateReason =
  | { type: 'unprovisioned' }
  | { type: 'pending' }
  | { type: 'deadBranch'; recorded: string }

export type SyncAction =
  | { type: 'gate'; reason: SyncGateReason }
  | { type: 'noop' }
  | { type: 'reconcile'; to: string }
  | { type: 'rename'; from: string; to: string }
  | { type: 'collision'; from: string; to: string }

/**
 * Pure decision function for sync(). Hard gates (unprovisioned / pending / dead recorded branch)
 * always win. Only once past those does a recorded-vs-current mismatch get evaluated: normal
 * rename, a reconcile-only self-heal (a prior sync already renamed on Neon but crashed before
 * persisting locally), or — when the target name is already a DIFFERENT live branch — a hard
 * collision gate instead of a rename that would silently fail and leave a stale DATABASE_URL.
 */
export function planSync(
  state: { branch: string; phase: 'pending' | 'ready' } | null,
  current: string,
  recordedExists: boolean,
  currentExists: boolean,
): SyncAction {
  if (!state) return { type: 'gate', reason: { type: 'unprovisioned' } }
  if (state.phase === 'pending') return { type: 'gate', reason: { type: 'pending' } }
  if (state.branch === current) {
    return recordedExists ? { type: 'noop' } : { type: 'gate', reason: { type: 'deadBranch', recorded: state.branch } }
  }
  if (!recordedExists && currentExists) return { type: 'reconcile', to: current }
  if (!recordedExists && !currentExists) return { type: 'gate', reason: { type: 'deadBranch', recorded: state.branch } }
  if (currentExists) return { type: 'collision', from: state.branch, to: current }
  return { type: 'rename', from: state.branch, to: current }
}
```

- [ ] **Step 5: Rewrite `sync()`**

Delete the entire existing `sync()` function and `renameCatchUp()` function. Replace with:

```ts
function throwForGate(reason: SyncGateReason): never {
  if (reason.type === 'unprovisioned') {
    throw new Error('Workspace not provisioned — run `db:provision` (or `worktree:setup`) before starting the dev server.')
  }
  if (reason.type === 'pending') {
    throw new Error('Workspace database setup did not finish (state is "pending") — re-run `db:provision` to recover it.')
  }
  throw new Error(`Recorded branch "${reason.recorded}" no longer exists in Neon — re-run \`db:provision\` to recreate it.`)
}

function collisionMessage(action: Extract<SyncAction, { type: 'collision' }>): string {
  return (
    `Refusing to start: this workspace's identity resolves to "${action.to}", which already exists ` +
    `as its own live Neon branch, while "${action.from}" (a different, still-live branch) is ` +
    `recorded here. These are two previously-provisioned workspaces colliding — renaming would ` +
    `silently fail and leave a stale DATABASE_URL. Re-run \`db:provision\` to rebuild "${action.to}" ` +
    `for this checkout (discards its current data), or check back out whatever matches "${action.from}".`
  )
}

/**
 * Runs before every dev-server start (chained in front of it — see the "dev" package.json script).
 * Hard gates throw (blocking the dev server, deliberately); a rename/reconcile is best-effort and
 * never blocks the dev server on its own failure. See planSync() for the full decision table.
 */
async function sync(): Promise<void> {
  const raw = resolveWorkspaceName(process.env, process.cwd(), currentGitContext(process.cwd()))
  const current = workspaceBranchName(raw)
  const state = readBranchStateFull()

  if (!state || state.phase === 'pending') {
    const action = planSync(state, current, false, false)
    if (action.type === 'gate') throwForGate(action.reason)
    return
  }

  const projectId = requireEnv('NEON_PROJECT_ID')
  requireEnv('NEON_API_KEY')
  const recordedExists = await withRetry('check recorded branch', () => branchExists(projectId, state.branch), 3)
  const currentExists =
    state.branch === current ? recordedExists : await withRetry('check current branch', () => branchExists(projectId, current), 3)
  const action = planSync(state, current, recordedExists, currentExists)

  switch (action.type) {
    case 'noop':
      return
    case 'gate':
      throwForGate(action.reason)
      return
    case 'collision':
      throw new Error(collisionMessage(action))
    case 'reconcile':
      writeBranchState(action.to)
      console.log(`[neondb-branch] recorded branch was already renamed on Neon — reconciled local state to "${action.to}".`)
      return
    case 'rename': {
      try {
        const parent = process.env.NEON_PARENT_BRANCH ?? ''
        assertDisposableChildBranch(action.from, parent)
        assertDisposableChildBranch(action.to, parent)
        await renameBranch(projectId, action.from, action.to)
        writeBranchState(action.to)
        console.log(`✅ [neondb-branch] renamed ${action.from} → ${action.to} to match the current workspace.`)
      } catch (error) {
        console.warn(`[neondb-branch] WARNING: branch rename failed: ${error instanceof Error ? error.message : error}`)
      }
      return
    }
  }
}
```

- [ ] **Step 6: Run tests — expect PASS**

```bash
SCRATCH=/private/tmp/claude-501/-Users-smartin-orca-workspaces-agent-skills-mojarra/232ff6de-43d9-4d59-af36-586513a2785c/scratchpad/neondb-branch-dev
SKILL=/Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/neondb-branch
rm -rf "$SCRATCH/work" && mkdir -p "$SCRATCH/work/scripts" "$SCRATCH/work/tests"
cp "$SKILL/scripts/neondb-branch.ts" "$SCRATCH/work/scripts/"
cp "$SKILL/tests/neondb-branch.test.ts" "$SCRATCH/work/tests/"
cd "$SCRATCH" && npx vitest run work/tests/neondb-branch.test.ts
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
cd /Users/smartin/orca/workspaces/agent-skills/mojarra
git add skills/devops/neondb-branch/scripts/neondb-branch.ts skills/devops/neondb-branch/tests/neondb-branch.test.ts
git commit -m "$(cat <<'EOF'
neondb-branch: planSync + rewritten sync() — hard gates + guarded rename

sync() now hard-gates unprovisioned/pending/dead-branch states before
ever considering a rename, and refuses (hard gate) when the target name
is already a different live branch instead of attempting a rename that
would silently fail. planSync encodes the full decision table for
independent unit testing.
EOF
)"
```

---

## Task 6: `planTeardown` + rewritten `teardown()`

**Files:**
- Modify: `skills/devops/neondb-branch/scripts/neondb-branch.ts`
- Modify: `skills/devops/neondb-branch/tests/neondb-branch.test.ts`

**Interfaces:**
- Consumes: `resolveWorkspaceName`/`currentGitContext` (Task 2), `stripEnvVars` (Task 3), `readBranchStateFull`/`readCheckBranchState`/`clearCheckBranchState` (Task 1/5)
- Produces: `export type TeardownAction = ...`, `export function planTeardown(branchExists: boolean): TeardownAction`, rewritten `teardown()`

- [ ] **Step 1: Write the failing tests for `planTeardown`**

Add a new `describe` block near `planSync`'s tests:

```ts
describe('planTeardown (teardown() decision logic)', () => {
  it('deletes when the branch still exists on Neon (the normal case)', () => {
    expect(planTeardown(true)).toEqual({ type: 'delete' })
  })

  it('treats it as already torn down when the branch is gone — avoids retrying a delete that would 404 forever', () => {
    expect(planTeardown(false)).toEqual({ type: 'alreadyGone' })
  })
})
```

Add `planTeardown` to the import list.

- [ ] **Step 2: Run tests — expect FAIL**

```bash
SCRATCH=/private/tmp/claude-501/-Users-smartin-orca-workspaces-agent-skills-mojarra/232ff6de-43d9-4d59-af36-586513a2785c/scratchpad/neondb-branch-dev
SKILL=/Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/neondb-branch
rm -rf "$SCRATCH/work" && mkdir -p "$SCRATCH/work/scripts" "$SCRATCH/work/tests"
cp "$SKILL/scripts/neondb-branch.ts" "$SCRATCH/work/scripts/"
cp "$SKILL/tests/neondb-branch.test.ts" "$SCRATCH/work/tests/"
cd "$SCRATCH" && npx vitest run work/tests/neondb-branch.test.ts 2>&1 | tail -20
```

Expected: FAIL — `planTeardown` not exported.

- [ ] **Step 3: Implement `planTeardown` and rewrite `teardown()`**

Add above `teardown()`:

```ts
export type TeardownAction = { type: 'delete' } | { type: 'alreadyGone' }

/**
 * Pure decision function for teardown(): whether the target branch still exists on Neon. Mirrors
 * planSync()'s extraction for the same class of decision — self-heal (skip a delete that would
 * 404 forever) is directly testable without mocking neonctl.
 */
export function planTeardown(branchExists: boolean): TeardownAction {
  return branchExists ? { type: 'delete' } : { type: 'alreadyGone' }
}
```

Delete the entire existing `teardown()` function. Replace with:

```ts
async function teardown(): Promise<void> {
  const raw = resolveWorkspaceName(process.env, process.cwd(), currentGitContext(process.cwd()))
  const derived = workspaceBranchName(raw)
  const state = readBranchStateFull()
  const target = state?.branch ?? derived

  if (!process.env.NEON_PROJECT_ID || !process.env.NEON_API_KEY) {
    if (!state && !readCheckBranchState()) {
      console.warn('[neondb-branch] NEON_PROJECT_ID / NEON_API_KEY not set and nothing recorded — nothing to clean.')
      return
    }
    throw new Error(
      'NEON_PROJECT_ID / NEON_API_KEY are required to delete this workspace\'s Neon branch (a record ' +
        'exists). Set them (e.g. in .env.neondb) and re-run teardown, or the branch will leak.',
    )
  }
  const projectId = requireEnv('NEON_PROJECT_ID')
  const parent = process.env.NEON_PARENT_BRANCH ?? ''

  // Sweep a leaked tmp/* check branch first (a provision killed between creating it and its own
  // cleanup) — independent of which workspace branch we target below.
  try {
    const checkName = readCheckBranchState() ?? checkBranchName(raw)
    assertDisposableCheckBranch(checkName, parent)
    if (await withRetry('check for leaked check branch', () => branchExists(projectId, checkName), 3)) {
      console.log(`[neon] deleting leaked check branch ${checkName}…`)
      await deleteBranch(projectId, checkName, { inherit: true })
    }
    clearCheckBranchState()
  } catch (error) {
    console.warn(`[neondb-branch] WARNING: could not check for/delete a leaked check branch: ${error instanceof Error ? error.message : error}`)
  }

  assertDisposableChildBranch(target, parent)
  const exists = await withRetry('check branch exists', () => branchExists(projectId, target), 3)
  const action = planTeardown(exists)
  if (action.type === 'alreadyGone') {
    console.log(`[neondb-branch] branch ${target} not found in project ${projectId} — treating as already torn down.`)
  } else {
    console.log(`[neon] deleting branch ${target}…`)
    await deleteBranch(projectId, target, { inherit: true })
  }
  stripEnvVars(ENV_FILE, DB_ENV_VARS)
  rmSync(stateFilePath(), { force: true })
  console.log('✅ [neondb-branch] workspace database torn down.')
}
```

- [ ] **Step 4: Remove now-dead code this rewrite orphans**

`legacyWorkspaceBranchName` references inside the old `teardown()` are gone now that the whole function was replaced — confirm with:

```bash
grep -n "legacyWorkspaceBranchName\|provisionedEnvTraceExists\|removeGeneratedEnvFiles" \
  /Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/neondb-branch/scripts/neondb-branch.ts
```

Expected: no matches. If any remain, delete them — they were only kept as compile-time placeholders in Tasks 1/3.

- [ ] **Step 5: Run tests — expect PASS**

```bash
SCRATCH=/private/tmp/claude-501/-Users-smartin-orca-workspaces-agent-skills-mojarra/232ff6de-43d9-4d59-af36-586513a2785c/scratchpad/neondb-branch-dev
SKILL=/Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/neondb-branch
rm -rf "$SCRATCH/work" && mkdir -p "$SCRATCH/work/scripts" "$SCRATCH/work/tests"
cp "$SKILL/scripts/neondb-branch.ts" "$SCRATCH/work/scripts/"
cp "$SKILL/tests/neondb-branch.test.ts" "$SCRATCH/work/tests/"
cd "$SCRATCH" && npx vitest run work/tests/neondb-branch.test.ts
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/smartin/orca/workspaces/agent-skills/mojarra
git add skills/devops/neondb-branch/scripts/neondb-branch.ts skills/devops/neondb-branch/tests/neondb-branch.test.ts
git commit -m "$(cat <<'EOF'
neondb-branch: planTeardown + rewritten teardown()

Drops the recorded/derived/legacy-name candidate list (no longer needed
now that identity resolution doesn't have a legacy migration path) in
favor of resolved-identity + recorded-state, with the same leaked
tmp/* check-branch sweep and already-gone self-heal as before.
EOF
)"
```

---

## Task 7: `SKILL.md` full rewrite

**Files:**
- Create: `skills/devops/neondb-branch/SKILL.md`

**Interfaces:**
- Consumes: behavior from Tasks 1–6
- Produces: operator-facing documentation only, no code

- [ ] **Step 1: Write `SKILL.md`**

```markdown
---
name: neondb-branch
description: >-
  Set up fully isolated per-workspace Neon databases for any git repo: each workspace gets its
  own instant schema-only Neon branch off production (full schema, zero production data),
  baselined against production's TRUE applied-migration state — not assumed from local files —
  via a disposable full-data check branch (Prisma or Drizzle), with test fixtures seeded. No
  orchestration tool required — plain package.json scripts drive provision/sync/teardown, with
  workspace identity resolved from Conductor, Orca, a general WORKSPACE_NAME, or (for a plain
  single-clone checkout) the current git branch. Ships ready-to-use Conductor and Orca config
  templates too. provision() fully rebuilds the branch on every run. Manual-only — run in a
  Neon + Prisma or Neon + Drizzle project to add the setup.
disable-model-invocation: true
metadata:
  author: martintechlabs
  version: "0.1.0"
---

# Per-workspace isolated Neon databases (Prisma or Drizzle, any git repo)

## What this sets up

Every workspace — a Conductor workspace, an Orca worktree, or a plain git checkout on its own
branch — gets its **own** database, so parallel agents never read or write the same rows.
`provision()` is a **full, deterministic rebuild — every run, not just the first**: it deletes
whatever branch is currently recorded for the workspace (if any) and creates a fresh one. Any
data written into the workspace branch through normal app usage is discarded on every re-run —
the branch is disposable by design; there is no "reuse an existing branch, keep its data" path.

Each `provision()` run:

1. Creates an **instant schema-only Neon branch** off the parent (production) branch — full
   schema and extensions (e.g. PostGIS reference data), **zero production rows**. Neon copies no
   data, so this is fast and cheap.
2. **Baselines the ORM's migration history against production's TRUE applied-migration state** —
   by cloning production a *second* time, this time **with data**, into a disposable `tmp/*`
   check branch, reading that clone's real ledger rows, seeding the workspace branch's (empty)
   ledger with exactly those rows, then deleting the check branch. The ORM's migrate-deploy then
   applies whatever's genuinely still missing.
3. **Seeds** test fixtures.
4. Upserts `DATABASE_URL` (and any other `DB_ENV_VARS`) plus `NEON_API_KEY`/`NEON_PROJECT_ID`/
   `NEON_PARENT_BRANCH` into `.env.neondb` (its own file — your real `.env` is never touched),
   preserving anything else already in that file. This keeps `.env.neondb` self-sufficient for
   later `sync`/`teardown` calls regardless of how they're invoked.
5. Records the branch name in `.neondb/branch` (gitignored) so teardown deletes the **same**
   branch even after an identity change (e.g. a Conductor workspace rename).

## Workspace identity

There is no single required environment variable. Identity resolves through a precedence chain,
first match wins:

| Order | Source | When it applies |
|---|---|---|
| 1 | `CONDUCTOR_WORKSPACE_NAME` | Conductor injects this automatically |
| 2 | `ORCA_WORKSPACE_NAME` | Set by Orca or the project, when present |
| 3 | `WORKSPACE_NAME` | General ambient override for custom tools, tests, or a project that wants one name for every tool |
| 4 | Checkout directory basename | A secondary git worktree with none of the above set — stable across a `git checkout` inside it |
| 5 | Current git branch | A plain single-clone checkout with none of the above set — here "the workspace" genuinely *is* the branch |

`WORKSPACE_NAME` is **never** read from `.env.neondb` — that file can be copied or reused across
workspaces, which would collide two of them onto the same Neon branch. Set it in your shell,
CI config, or orchestrator env instead.

### Renaming: deliberate vs. incidental

A git branch changes on every `git checkout`, not just a deliberate rename. Treating every branch
change as "follow the rename" would mean checking out `main` to peek at something and running
`pnpm dev` silently renaming your feature branch's live Neon branch. So renaming is split:

- **`provision()`** is the deliberate path: it always deletes whatever's recorded and creates
  fresh under the current identity. Re-running it after `git branch -m old new` (or a Conductor
  workspace rename) is how you move this workspace's Neon branch to follow the change —
  discarding whatever data was in the old branch.
- **`sync()`** (chained in front of the dev server) is a passive verifier. It hard-gates unsafe
  states (never provisioned, setup interrupted, the recorded branch is gone) and, once past
  those, **best-effort renames** the live Neon branch when identity has moved on — unless the
  target name is already a *different* live branch, in which case it hard-gates instead (two
  previously-provisioned workspaces colliding, not a rename).

## When this applies

- The project's database is on **Neon** (branching is a Neon feature).
- Migrations are managed by **Prisma** or **Drizzle** (set the `ORM` knob in the script).
- `neonctl`, `tsx`, and `dotenv` are available as project-local dev dependencies, plus a Node
  package manager (pnpm/npm/yarn). **Both ORMs** need the project's existing Postgres driver
  (`@neondatabase/serverless` / `postgres` / `pg`) wired into the script's `execSql()` knob —
  reading production's true migration ledger back needs a real query result.

If the stack is different (not Neon, or not Prisma/Drizzle), the exact mechanics here don't
transfer — adapt the script's knobs, or tell the user this skill assumes Neon + Prisma/Drizzle
and stop.

## Why schema-only + baseline (the one non-obvious part)

A schema-only Neon branch gives you the schema and extensions but an **empty migrations table**
(the migration history is table *data*, which schema-only doesn't copy). If you leave it empty,
the migrator thinks nothing is applied, tries to recreate every table, and fails because the
tables already exist.

The naive fix — baseline by reconstructing the ledger from the **repo's own migration files**,
marking every committed migration applied — has a real bug: it assumes production has actually
run every migration committed on this code branch, and never checks. If it hasn't, that migration
gets falsely marked applied without ever running on the workspace branch, and the app breaks the
moment it touches whatever that migration created — silently, since the migrator now believes
it's "up to date".

So provisioning learns production's **true** applied-migration set instead of assuming it:

1. Clone production a *second* time — this time **with data** — into a disposable `tmp/*` check
   branch. Row data is the only source of truth for "what really ran"; a schema-only clone strips
   it, even for the migrations table itself.
2. Read that clone's real migration-ledger rows.
3. Delete the check branch — production itself is never connected to directly, only this
   disposable clone of it.
4. Seed the workspace branch's (empty) ledger with **exactly those rows**, verbatim — not
   recomputed from local files.
5. Run the ORM's migrate-deploy, which now applies whatever's genuinely still missing.

The two ORMs differ only in the ledger table and the row shape — both read from the check branch
and write into the workspace branch, never from local files:

- **Prisma** — `_prisma_migrations`. Only rows Prisma itself considers genuinely applied
  (`finished_at` set, `rolled_back_at` null) count. The captured `checksum` and `migration_name`
  are inserted verbatim.
- **Drizzle** — `drizzle.__drizzle_migrations`. Each captured row is `hash` + `created_at`,
  inserted verbatim. drizzle-kit decides what to run by the **latest `created_at`**, so this must
  be the value production's own ledger recorded.

## Setup

### 1. Preflight

Confirm the project is Neon + Prisma **or** Neon + Drizzle, and find the package manager
(lockfile: `pnpm-lock.yaml` → pnpm, `package-lock.json` → npm, `yarn.lock` → yarn). Ensure
`neonctl`, `tsx`, and `dotenv` are dev dependencies (`<pm> add -D neonctl tsx dotenv` if missing).
Note which Postgres driver the project already uses — you'll wire it into `execSql()` in step 2.
Identify the Neon project's **production branch name** (`neonctl branches list --project-id <id>`
— the one marked default/primary).

### 2. Add the provisioning script

Copy `scripts/neondb-branch.ts` and `scripts/load-env.cjs` (both bundled with this skill) into
the project's `scripts/`. Adjust the **PORTING KNOBS** block at the top of `neondb-branch.ts`:

- `ORM` — `'prisma'` or `'drizzle'`.
- `PM_EXEC` — your package manager's exec form (`['pnpm','exec']` / `['npx']` / `['yarn']`).
- `SEED_SCRIPT` and the `seedWorkspace()` body — adapt to the project's seed.
- **Wire `execSql()`** to the project's Postgres driver and remove its throw.
- **Drizzle only:** `DRIZZLE_MIGRATIONS_SCHEMA`/`DRIZZLE_MIGRATIONS_TABLE` only if customized.
- `DB_ENV_VARS` — every env var that must point at the workspace branch (defaults to just
  `DATABASE_URL`; add `DIRECT_URL`/`shadowDatabaseUrl` if your schema references them).

Copy `tests/neondb-branch.test.ts` into the project's test directory (adjust the import path to
your layout) — it locks the safety-critical bits: the identity precedence chain, the
`workspace/*`/`tmp/*`-only deletion guard, the `.env.neondb` upsert/strip behavior, and both
ORMs' idempotent true-ledger baseline row format.

### 3. Wire up `package.json`

```jsonc
{
  "scripts": {
    "db:provision": "tsx scripts/neondb-branch.ts provision",
    "db:sync": "tsx scripts/neondb-branch.ts sync",
    "db:teardown": "tsx scripts/neondb-branch.ts teardown",

    "worktree:setup": "<pm install> && <orm generate, if prisma> && tsx scripts/neondb-branch.ts provision",
    "worktree:sync": "tsx scripts/neondb-branch.ts sync",
    "worktree:archive": "tsx scripts/neondb-branch.ts teardown",

    "dev": "tsx scripts/neondb-branch.ts sync && NODE_OPTIONS='--require ./scripts/load-env.cjs' <your original dev command>"
  }
}
```

`db:*` is the plain-install surface. `worktree:*` is the same three commands under a shared
vocabulary both Conductor and Orca call — see step 4. Plain-clone users can ignore `worktree:*`
entirely. **`dev`'s `sync &&` prefix is not optional** — `load-env.cjs`'s fallback to your dev
server's own `.env` loading is only safe because `sync` hard-gates first; never ship a `dev`
script that skips it.

Add the same `NODE_OPTIONS='--require ./scripts/load-env.cjs'` prefix to `build`/`start`/seed
scripts if you want provisioned-workspace parity there too. For Prisma's CLI (`migrate`/
`db execute`/`studio`) outside `dev`, add to `prisma.config.ts`:

```ts
import { config as loadEnv } from 'dotenv'
loadEnv({ path: '.env.neondb' })
loadEnv()
```

(Drizzle has no equivalent config-loading hook — source `.env.neondb` explicitly for any ad hoc
`drizzle-kit` invocation outside `dev`.)

### 4. Orchestrator config (optional — both shipped, use what applies)

**Conductor** — copy `references/conductor-settings.toml.example` to
`.conductor/settings.toml`:

```toml
"$schema" = "https://conductor.build/schemas/settings.repo.schema.json"

[scripts]
setup = "corepack enable pnpm && pnpm worktree:setup"
archive = "pnpm worktree:archive"
run = "pnpm worktree:sync && pnpm dev --port $CONDUCTOR_PORT"
run_mode = "concurrent"
```

`run_mode = "concurrent"` is safe because each workspace has its own Neon branch and
`$CONDUCTOR_PORT`. **Never put `DATABASE_URL` in Conductor's Environment tabs** — it would
override the per-workspace branch. Put `NEON_API_KEY`/`NEON_PROJECT_ID`/`NEON_PARENT_BRANCH` in
**both** Local and Cloud tabs (or in `.env.neondb` directly) — `provision()` mirrors them into
`.env.neondb` regardless, so `archive` is self-sufficient even if Conductor's archive process is
ever missing env vars.

**Orca** — copy `references/orca.yaml.example` to `orca.yaml`:

```yaml
scripts:
  setup: |
    corepack enable pnpm && pnpm worktree:setup
  archive: |
    pnpm worktree:archive
```

Orca has no `run` hook — `sync`'s hard gate lives entirely in the `dev` script from step 3, which
is why that `sync &&` prefix is universal rather than orchestrator-specific.

Track `.conductor/settings.toml` in git (needed for cloud workspaces to read it) but gitignore
everything else generated: `.neondb/`, `.env.neondb` (already covered by `.env*` in most
`.gitignore`s — verify with `git check-ignore .env.neondb`).

### 5. Wire up seeding (adapt to the project)

`seedWorkspace()` runs the project's seed against the new branch as the last setup step. Most
seeds have (or should have) a guard that refuses non-local databases; authorize it for **this
branch only** (never production). If there's no seed, delete `seedWorkspace()` and its call.

### 6. Verify

- `<pm> exec tsc --noEmit` (and run the bundled test if you copied it).
- **Protect the production branch in Neon** (console → branch → Protect, or
  `neonctl branches set-protection`).
- For end-to-end confidence against real Neon, follow `references/verify.md`.

## Safety model

- **Name guard**: every destructive op (delete and rename) refuses to run unless the target
  starts with `workspace/` (workspace branch) or `tmp/` (disposable check branch) and isn't the
  parent.
- **Child-only targeting, never the parent directly**: every SQL connection targets either the
  workspace branch or the disposable check branch — `provision()` never opens a connection to the
  parent, only clones it.
- **No slug collisions**: over-long identities are truncated with a content hash appended, under
  each prefix independently.
- **Self-destruct on failure**: if anything after branch creation fails, the just-created
  workspace branch is deleted, and its state record plus branch-specific `.env.neondb` vars are
  cleaned up (Neon control vars are kept, so the next attempt doesn't need them re-supplied).
- **Every `provision()` run is a full, deterministic rebuild** — no "reuse a ready branch and keep
  its data" path exists.
- **True-ledger baseline, not a local-file assumption** — see "Why schema-only + baseline" above.
- **Guarded rename, never a silent collision**: `sync()` refuses to rename onto a name that's
  already a different live branch — see "Renaming: deliberate vs. incidental" above.
- Plus the Neon-side **branch protection** on production (step 6).

## Gotchas

- **`.env.neondb`'s DATABASE_URL is managed by this script** — hand-edit the other vars freely,
  but don't hand-edit `DATABASE_URL`; the next `provision()` overwrites it anyway.
- **`provision()` discards workspace data on every re-run** — any row written through normal app
  usage (not just seed fixtures) is gone the next time setup runs. If you need data to persist
  across a re-provision, put it in the seed script, not in ad hoc rows.
- **A plain single-clone checkout ties identity to the git branch** — switching branches without
  running `db:provision` for the new one will hit `sync`'s hard gate (unprovisioned) rather than
  silently reusing or renaming the previous branch's database.
- **Cold computes are expected** — a branch whose compute has never been connected to can take a
  while to boot; provisioning retries with exponential backoff around every Neon API step.
- **Seeding is opt-in** — if the seed credential isn't set, provisioning logs a warning and the
  workspace comes up empty rather than failing setup.
- **A `tmp/*` branch appears briefly during every provision** — it's the disposable check branch
  used to read the true migration ledger; seeing one linger past a run means it leaked (an
  interrupted provision), and the next `provision()`/`teardown()` sweeps it up automatically.
- **`execSql` is required for both ORMs** — reading the true migration ledger back needs a real
  query result, which neither `prisma db execute` nor `drizzle-kit` gives you.
```

- [ ] **Step 2: Commit**

```bash
cd /Users/smartin/orca/workspaces/agent-skills/mojarra
git add skills/devops/neondb-branch/SKILL.md
git commit -m "$(cat <<'EOF'
neondb-branch: write SKILL.md

Full setup guide: identity precedence chain, deliberate-vs-incidental
rename rules, package.json scripts, both orchestrator config templates,
.env.neondb upsert semantics, safety model, gotchas.
EOF
)"
```

---

## Task 8: `references/verify.md` + orchestrator config examples

**Files:**
- Create: `skills/devops/neondb-branch/references/verify.md` (adapted from `conductor-neon-db`'s)
- Create: `skills/devops/neondb-branch/references/conductor-settings.toml.example`
- Create: `skills/devops/neondb-branch/references/orca.yaml.example`

**Interfaces:**
- Consumes: behavior from Tasks 1–6 (branch prefixes, script name)
- Produces: reference docs only

- [ ] **Step 1: Copy and rename `verify.md`**

```bash
cp /Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/conductor-neon-db/references/verify.md \
   /Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/neondb-branch/references/verify.md
sed -i '' \
  -e "s/conductor\/verify-parent/workspace\/verify-parent/g" \
  -e "s/conductor\/verify/workspace\/verify/g" \
  -e "s/scripts\/conductor-db\.ts/scripts\/neondb-branch.ts/g" \
  /Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/neondb-branch/references/verify.md
```

Manually confirm no remaining `conductor` references:

```bash
grep -in "conductor" /Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/neondb-branch/references/verify.md
```

If the only remaining hits are inside `BR=conductor/verify` style variable *values* already caught above, you're done. Otherwise fix the remaining ones by hand (the walkthrough's actual schema-only → true-baseline → migrate-deploy → seed flow doesn't change — only branch names/script filename do).

- [ ] **Step 2: Create `references/conductor-settings.toml.example`**

```toml
"$schema" = "https://conductor.build/schemas/settings.repo.schema.json"

# setup/archive/run all delegate to the shared worktree:* package.json scripts (see SKILL.md
# step 3). Secrets (NEON_API_KEY / NEON_PROJECT_ID / NEON_PARENT_BRANCH) live in Conductor's
# Environment tabs (Local + Cloud) and/or .env.neondb — never committed here. Do NOT set
# DATABASE_URL here or in the Environment tabs; provision() owns it per workspace.

[scripts]
setup = "corepack enable pnpm && pnpm worktree:setup"
archive = "pnpm worktree:archive"
run = "pnpm worktree:sync && pnpm dev --port $CONDUCTOR_PORT"
run_mode = "concurrent"
```

- [ ] **Step 3: Create `references/orca.yaml.example`**

```yaml
# Mirrors Conductor's setup/archive — both delegate to the shared worktree:* package.json
# scripts (see SKILL.md step 3). NEON_API_KEY / NEON_PROJECT_ID / NEON_PARENT_BRANCH come from
# .env.neondb (and/or the ambient environment) — not from this file. Orca has no run hook: the
# sync hard gate is chained inside package.json's "dev" script instead.
scripts:
  setup: |
    corepack enable pnpm && pnpm worktree:setup
  archive: |
    pnpm worktree:archive
```

- [ ] **Step 4: Commit**

```bash
cd /Users/smartin/orca/workspaces/agent-skills/mojarra
git add skills/devops/neondb-branch/references/verify.md \
  skills/devops/neondb-branch/references/conductor-settings.toml.example \
  skills/devops/neondb-branch/references/orca.yaml.example
git commit -m "$(cat <<'EOF'
neondb-branch: verify.md + shipped Conductor/Orca config templates

verify.md walkthrough mechanics unchanged (schema-only + true-baseline
flow); only branch prefixes and the script filename are updated.
EOF
)"
```

---

## Task 9: `skills.sh.json` + `README.md` + remove old skill directory

**Files:**
- Modify: `skills.sh.json`
- Modify: `README.md`
- Delete: `skills/devops/conductor-neon-db/`

**Interfaces:**
- Consumes: nothing further
- Produces: repo-wide listing consistency

- [ ] **Step 1: Update `skills.sh.json`**

Find the `DevOps` grouping's `skills` array:

```json
      "skills": [
        "conductor-neon-db",
        "github-lockdown"
      ]
```

Replace with:

```json
      "skills": [
        "neondb-branch",
        "github-lockdown"
      ]
```

- [ ] **Step 2: Update `README.md`**

Find:

```markdown
| [`conductor-neon-db`](skills/devops/conductor-neon-db/SKILL.md) | Sets up fully isolated per-workspace databases for Conductor — each workspace gets its own instant schema-only Neon branch (full schema, zero production data) with the ORM's migration history baselined (Prisma or Drizzle) and fixtures seeded, plus the `.conductor/settings.toml` that wires setup/run/archive. |
```

Replace with:

```markdown
| [`neondb-branch`](skills/devops/neondb-branch/SKILL.md) | Sets up fully isolated per-workspace Neon databases for any git repo — each workspace gets its own instant schema-only Neon branch (full schema, zero production data) with the ORM's migration history baselined against production's true applied-migration state (Prisma or Drizzle) and fixtures seeded. Identity resolves from Conductor, Orca, a general `WORKSPACE_NAME`, or the current git branch; ships ready-to-use Conductor and Orca config templates. |
```

- [ ] **Step 3: Remove the old skill directory**

```bash
git rm -r /Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/conductor-neon-db
```

- [ ] **Step 4: Verify no remaining references to the old skill name anywhere in the repo**

```bash
cd /Users/smartin/orca/workspaces/agent-skills/mojarra
grep -rln "conductor-neon-db\|conductor-db\.ts\|conductor-db\.test\.ts" . --include="*.md" --include="*.json" --include="*.ts" 2>/dev/null
```

Expected: no output (aside from this plan/spec doc under `docs/superpowers/`, which is historical record and intentionally keeps the old name for context — do not edit those).

- [ ] **Step 5: Commit**

```bash
cd /Users/smartin/orca/workspaces/agent-skills/mojarra
git add skills.sh.json README.md
git commit -m "$(cat <<'EOF'
neondb-branch: replace conductor-neon-db in skills.sh.json and README

conductor-neon-db is removed; neondb-branch takes its place in the
DevOps grouping and the skill table.
EOF
)"
```

---

## Task 10: Final validation pass

**Files:** none (verification only)

**Interfaces:**
- Consumes: everything from Tasks 1–9
- Produces: confidence the skill is complete and internally consistent

- [ ] **Step 1: Full test suite one more time**

```bash
SCRATCH=/private/tmp/claude-501/-Users-smartin-orca-workspaces-agent-skills-mojarra/232ff6de-43d9-4d59-af36-586513a2785c/scratchpad/neondb-branch-dev
SKILL=/Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/neondb-branch
rm -rf "$SCRATCH/work" && mkdir -p "$SCRATCH/work/scripts" "$SCRATCH/work/tests"
cp "$SKILL/scripts/neondb-branch.ts" "$SCRATCH/work/scripts/"
cp "$SKILL/tests/neondb-branch.test.ts" "$SCRATCH/work/tests/"
cd "$SCRATCH" && npx vitest run work/tests/neondb-branch.test.ts
```

Expected: 0 failures.

- [ ] **Step 2: Type-check with `tsc --noEmit`**

```bash
SCRATCH=/private/tmp/claude-501/-Users-smartin-orca-workspaces-agent-skills-mojarra/232ff6de-43d9-4d59-af36-586513a2785c/scratchpad/neondb-branch-dev
cd "$SCRATCH" && npx tsc --noEmit --strict --target es2020 --module commonjs --esModuleInterop \
  --skipLibCheck work/scripts/neondb-branch.ts
```

Expected: no errors. (`--skipLibCheck` avoids noise from the scratch harness's own dependency
type defs; this is not the real project's `tsconfig.json`, just enough to catch real type errors
in the script itself.)

- [ ] **Step 3: Confirm the safety-critical guard is exercised for every prefix**

```bash
grep -n "BRANCH_PREFIX\s*=\|CHECK_BRANCH_PREFIX\s*=" \
  /Users/smartin/orca/workspaces/agent-skills/mojarra/skills/devops/neondb-branch/scripts/neondb-branch.ts
```

Expected: `BRANCH_PREFIX = 'workspace/'` and `CHECK_BRANCH_PREFIX = 'tmp/'`.

- [ ] **Step 4: Review checklist (from AGENTS.md)**

- [ ] `metadata.version` present (`"0.1.0"`, new skill) — confirm in `SKILL.md` frontmatter.
- [ ] `tests/neondb-branch.test.ts` passes (0 failures) — confirmed Step 1.
- [ ] Added to `skills.sh.json`'s `DevOps` grouping and `README.md`'s table — confirmed Task 9.
- [ ] `--dry-run` re-verification: N/A — this skill has no `--dry-run` mode (it's a copy-into-project script, not a live-mutation CLI against a shared repo like `execute-tickets`/`epic-manager`).
- [ ] Live validation: this task's script changes are validated via `references/verify.md`
      against a real Neon project as a follow-up, outside this repo (this repo has no live Neon
      project of its own to test against) — note this to the user rather than claiming it here.

- [ ] **Step 5: Clean up the scratch harness**

```bash
rm -rf /private/tmp/claude-501/-Users-smartin-orca-workspaces-agent-skills-mojarra/232ff6de-43d9-4d59-af36-586513a2785c/scratchpad/neondb-branch-dev
```

- [ ] **Step 6: Final status check**

```bash
cd /Users/smartin/orca/workspaces/agent-skills/mojarra
git status --short
git log --oneline -10
```

Expected: clean working tree, 9 commits (Tasks 1–9) since the spec commit.

---

## Spec coverage checklist (self-review)

| Spec requirement | Task |
|---|---|
| True-ledger baseline / disposable `tmp/*` check branch unchanged | 1 (carried over), verified throughout |
| Full-rebuild `provision()`, no reuse-if-exists | 1 (carried over) |
| No local-migration-file baseline | 1 (carried over — never introduced) |
| `workspace/<slug>` + `tmp/<slug>` prefixes | 1 |
| `.neondb/branch` + `.neondb/branch-check` state paths | 1 |
| Drop `CONDUCTOR_IS_LOCAL`/`$CONDUCTOR_PORT` local/cloud fork | 1 (never carried over) |
| `resolveWorkspaceName` precedence chain (5 tiers) | 2 |
| `workspaceBranchName`/`checkBranchName` take resolved identity, not env directly | 2 |
| `.env.neondb` upsert (not full rewrite); strip-not-delete on teardown/failure | 3 |
| Programmatic dotenv load in `main()`; no `dotenv -e` shell prefix needed | 4 |
| `load-env.cjs` require-hook, ENOENT-safe | 4 |
| `sync()` hard gates: unprovisioned / pending / dead recorded branch | 5 |
| `sync()` best-effort rename on mismatch (not auto-rebuild) | 5 |
| Collision guard: hard-gate instead of a rename that would silently fail | 5 |
| `planSync` pure decision function, fully unit-tested | 5 |
| `planTeardown` pure decision function + already-gone self-heal | 6 |
| `provision()`/`teardown()` porting knobs (`ORM`/`PM_EXEC`/`DB_ENV_VARS`) unchanged | 1 (carried over), 3, 6 |
| `SKILL.md` rewrite: identity, rename semantics, dual-orchestrator setup | 7 |
| Shipped Conductor + Orca config templates | 8 |
| `verify.md` updated (mechanics unchanged) | 8 |
| `skills.sh.json` / `README.md` renamed | 9 |
| `conductor-neon-db` removed, no dual-maintenance | 9 |
| `metadata.version` present (new skill, per repo convention) | 7 |

## Placeholder / consistency scan

- No TBD steps; every step has concrete file paths, complete code, or exact shell commands.
- Names consistent across tasks: `resolveWorkspaceName`, `GitContext`, `currentGitContext`,
  `currentWorkspaceBranchName`, `workspaceBranchName`, `checkBranchName`, `upsertEnvVars`,
  `stripEnvVars`, `readBranchStateFull`, `planSync`, `SyncAction`, `SyncGateReason`,
  `planTeardown`, `TeardownAction` — each defined once (Task 2/3/5/6) and referenced identically
  in every later task and in `SKILL.md`.
- `ENV_FILE`, `BRANCH_PREFIX`, `CHECK_BRANCH_PREFIX`, `MAX_SLUG`, `ORM`, `PM_EXEC`, `DB_ENV_VARS`,
  `SEED_SCRIPT` porting knobs are never renamed — only `BRANCH_PREFIX`'s *value* changes
  (`'conductor/'` → `'workspace/'`), confirmed identical in Task 1 and Task 10 Step 3.
- Every task's "run tests" step uses the identical scratch-harness copy-then-run pattern
  established in Task 1 Step 1 — no task invents a different validation mechanism.
