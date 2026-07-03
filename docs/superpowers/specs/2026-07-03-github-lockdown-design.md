# github-lockdown — Design

**Date:** 2026-07-03
**Category:** `devops`
**Status:** Approved design, pending spec review

## Purpose

A manual-only skill that locks down a GitHub repository: protects the default
branch, requires a pull request for any change, defaults to **0 required
approvers**, blocks force-pushes and branch deletion, and turns on
**auto-delete branches on merge**. It runs a short interview so the user can
tune the strictness, with a dead-simple "just use the defaults" path.

The skill applies protection through **GitHub repository rulesets** (the modern
mechanism, available on free private + public repos), plus the repo-level
`delete_branch_on_merge` setting. It enforces for **everyone including admins**
(no bypass actors) by default.

## Non-goals

- No classic branch-protection support (rulesets only).
- Never deletes branches, rewrites history, or removes rulesets the skill did
  not create. It only *adds* protection.
- Not model-invocable — changing repo governance is high-stakes, so it runs
  only when the user asks for it by name.

## Files

```
skills/devops/github-lockdown/
├── SKILL.md                 # frontmatter (disable-model-invocation: true) + interview/procedure
├── scripts/lockdown.sh      # bash + gh + jq; secure defaults baked in, knobs as flags
├── tests/run.sh             # plain-bash test runner; PATH-shims a fake `gh`, asserts payloads (no network)
└── references/rulesets.md   # the ruleset model, permissions, troubleshooting
```

Plus:
- A README.md row under the **DevOps** table.
- A `skills.sh.json` grouping entry under the `devops` grouping.

## The default lockdown (zero-config path)

`./lockdown.sh` with no flags, against the current repo's **default branch**,
creates/updates a ruleset named `github-lockdown` with:

- `enforcement: active`, **no bypass actors** (enforced for everyone, incl. admins).
- Target: the default branch via the `~DEFAULT_BRANCH` ref selector (correct for
  `main` or `master`).
- Rules:
  - `pull_request` with `required_approving_review_count: 0` (the "no approvers" default).
  - `non_fast_forward` (block force-pushes).
  - `deletion` (block branch deletion).
- Repo setting: `delete_branch_on_merge: true` (auto-delete merged branches).

All other knobs (status checks, signed commits, linear history, code-owner
review, conversation resolution, dismiss-stale-approvals) are **off** by default.

## Short interview

SKILL.md opens with: *"Apply the standard lockdown, or customize?"*

- **Defaults path:** user accepts → print a one-line summary → confirm → apply.
- **Customize path:** ask a short interview:
  1. Required approvers? (default **0**)
  2. Require status checks to pass? Which check names? (default **none**)
  3. Extras (multi-select, all **off** by default): require conversation
     resolution · linear history · signed commits · code-owner review · dismiss
     stale approvals on push.

Admin bypass is **off** by default and exposed only as a `--admin-bypass` flag —
it is not asked in the interview.

After collecting answers, the SKILL runs the script with `--dry-run` to show the
exact planned changes, confirms, then applies for real.

## Script behavior (`scripts/lockdown.sh`)

**Preflight (no invented defaults — clear errors with remediation):**
- `gh auth status` succeeds.
- `jq` is installed.
- Caller has **admin** on the repo (`gh repo view --json viewerPermission` ==
  `ADMIN`). Otherwise fail with remediation.

**Idempotent upsert by name:**
- `GET /repos/{owner}/{repo}/rulesets`, find one named `github-lockdown` via `jq`.
- Found → `PUT /repos/{owner}/{repo}/rulesets/{id}` (update).
- Not found → `POST /repos/{owner}/{repo}/rulesets` (create).
- Re-running never duplicates.

**Flags:**
`--repo <owner/repo>` (default: current repo via `gh repo view`),
`--branch <name>` (default: repo default branch),
`--approvals N` (default 0),
`--admin-bypass` (default off),
`--require-conversation-resolution`,
`--linear-history`,
`--signed-commits`,
`--require-code-owner-review`,
`--dismiss-stale-approvals`,
`--status-checks "ci,build"` (comma-separated check contexts),
`--no-auto-delete` (skip flipping `delete_branch_on_merge`),
`--dry-run` (print JSON + planned actions, apply nothing),
`--ruleset-name <name>` (default `github-lockdown`).

**Apply order:** upsert ruleset, then PATCH repo `delete_branch_on_merge`
(unless `--no-auto-delete`).

**Verify:** re-GET the ruleset and the repo setting; print a human-readable
confirmation of what is now enforced.

**Safety:** only ever adds protection. Never deletes branches, history, or
rulesets it did not create. Idempotent by name.

## Tests (`tests/run.sh`)

Plain-bash runner (no `bats` dependency). It PATH-shims a fake `gh` that records
invocations and returns canned JSON, then asserts:

1. Default run emits the expected `POST` ruleset payload (0 approvals, PR +
   `non_fast_forward` + `deletion`, no bypass actors, `~DEFAULT_BRANCH` target).
2. When a ruleset named `github-lockdown` already exists, the script routes to
   `PUT /rulesets/{id}` with the correct id (idempotent upsert).
3. Each flag flips the right rule field (e.g. `--approvals 2`,
   `--signed-commits`, `--linear-history`, `--status-checks`, `--admin-bypass`).
4. A `PATCH` to `/repos/{o}/{r}` sets `delete_branch_on_merge: true`, and
   `--no-auto-delete` suppresses it.
5. Non-admin preflight (`viewerPermission != ADMIN`) fails with a non-zero exit
   and a remediation message.

No network access; runs anywhere with bash + jq.

## references/rulesets.md

Explains: the ruleset data model and the exact JSON shape; required token
permissions (repo admin / `admin:repo_hook`-equivalent via `gh`); how the skill
coexists with pre-existing rulesets (updates only its own by name); how to
inspect (`gh api .../rulesets`) and how to remove the lockdown if needed;
free-plan availability notes; and common failure modes.

## Open decisions (proceeding with these unless vetoed)

- **Name:** `github-lockdown`.
- **Test harness:** plain-bash `tests/run.sh` (no `bats` dependency).
