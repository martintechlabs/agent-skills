# neondb-branch normal-child + state.json Implementation Plan

**Goal:** Stop per-workspace Neon branches from consuming root-branch slots, and replace the
name-in-a-textfile tracking with explicit `.neondb/state.json` lifecycle state.

**Spec:** `docs/superpowers/specs/2026-09-09-neondb-branch-normal-child-design.md`

**Architecture:** `scripts/neondb-branch.ts` keeps its shape (one copied-in CLI with
`provision`/`sync`/`teardown`, plus a new `adopt`) but grows two injectable seams so the
lifecycle is testable without a live Neon or a live Postgres: a `NeonClient` interface over the
Neon REST API, and a `SqlConnect` factory over the project's own Postgres driver. `main()` wires
the real implementations; tests wire a fake control plane and PGlite.

**Tech Stack:** TypeScript (`tsx` in the consuming project), Node 22 global `fetch` (no new
runtime dependency), `neonctl` retained only for parent connection-string resolution, Vitest +
`@electric-sql/pglite` in a throwaway scratch harness for this repo's own validation.

---

## Global Constraints

- This repo has no `package.json`. Validation goes through a throwaway harness outside the repo,
  driven by a new `tests/run.sh`. Never add `node_modules` here.
- No old-format compatibility path. `.neondb/branch` and `.neondb/branch-check` are detected and
  rejected by every command; only `adopt` interprets them.
- Names never identify a branch. Every lookup and every destructive call goes by `branchId`.
- `.neondb` is never removed recursively. Unrelated files in it survive teardown.
- `provision()` stays a full rebuild. No reuse-if-exists path.
- `metadata.version` bumps to `0.2.0` in the same change.

## File Structure

| Path | Change |
|---|---|
| `skills/devops/neondb-branch/scripts/neondb-branch.ts` | Rewrite: REST `NeonClient`, LSN capture, purge, `state.json`, lock, `adopt` |
| `skills/devops/neondb-branch/scripts/load-env.cjs` | `ready`-gated, override-assigning, no silent fallback |
| `skills/devops/neondb-branch/tests/neondb-branch.test.ts` | Rewrite around the new seams |
| `skills/devops/neondb-branch/tests/purge.test.ts` | New — PGlite-backed purge/rollback/unknown-table coverage |
| `skills/devops/neondb-branch/tests/run.sh` | New — bootstraps the scratch harness, runs `tsc` + Vitest |
| `skills/devops/neondb-branch/SKILL.md` | Rewrite of mechanism, safety, gotchas; privacy warning; migration steps; version bump |
| `skills/devops/neondb-branch/references/verify.md` | Rewrite for one branch, no `tmp/*` |
| `README.md` | Skill table row re-described |
| `AGENTS.md` | Add neondb-branch to the `tests/run.sh` list |

---

## Task 1 — Injectable seams and state module
- [ ] `NeonClient` interface + REST implementation (`findBranchByName`, `getBranchById`,
      `listBranchEndpoints`, `createBranch`, `deleteBranch`) with `NeonRequestError`
      carrying `status` and an `ambiguous` flag.
- [ ] `SqlConnect` / `SqlClient` interfaces; document wiring for `pg`, `postgres`,
      `@neondatabase/serverless`, including `connectionTimeoutMillis: 30_000`.
- [ ] `readState` (strict) / `writeState` (atomic) / `clearState`, `assertNoLegacyState`,
      `assertProjectMatches`.
- [ ] Lifecycle lock: `acquireLock` / `releaseLock`, dead-PID reclaim, `removeStateDirIfEmpty`.

## Task 2 — Purge
- [ ] `discoverTables` (base tables, extension-owned flagged via `pg_depend`).
- [ ] `planPurge(discovered, knownTables, knownSchemas, preserved)` — pure; returns
      `{ truncate[], preserved[], unknown[] }` and fails closed on unknown tables/schemas.
- [ ] `purgeApplicationRows` — one transaction, `TRUNCATE … RESTART IDENTITY CASCADE`,
      rollback on error; `verifyTablesEmpty` afterwards.

## Task 3 — Commands
- [ ] `provision`: delete recorded → `creating` → capture LSN → REST create → verify →
      `pending` → wait for connection → purge → verify empty → publish URLs → migrate → seed →
      `ready`; failure path deletes by id and retains state if that fails.
- [ ] `sync`: `ready` + URLs required, `getBranchById`, refresh name, never adopt by name.
- [ ] `teardown`: `deleting` → delete by id → confirm absent → strip URLs → clear state →
      unlock → rmdir-if-empty.
- [ ] `adopt`: legacy `.neondb/branch` → `state.json` with endpoint-host verification; sweeps
      `tmp/*`.

## Task 4 — Consumers and docs
- [ ] `load-env.cjs` rewrite.
- [ ] `SKILL.md` rewrite + `0.2.0`.
- [ ] `references/verify.md` rewrite.
- [ ] `README.md` row.

## Task 5 — Tests and validation
- [ ] `tests/run.sh` harness; `tsc --noEmit`; Vitest.
- [ ] All regression cases from the spec's Testing section green.
- [ ] `AGENTS.md` run.sh list updated.
