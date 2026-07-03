---
name: github-lockdown
description: >-
  Lock down a GitHub repository: protect the default branch behind a required pull
  request (0 approvers by default), block force-pushes and branch deletion, and enable
  auto-delete of merged branches. Uses GitHub repository rulesets via the gh CLI, enforced
  for everyone including admins by default. Manual-only — invoke by name when you want to
  secure a repo ("lock down this repo", "protect main", "require PRs").
disable-model-invocation: true
metadata:
  author: martintechlabs
  version: "0.1.0"
---

# Lock down a GitHub repository

Protect a repo's default branch with a GitHub **repository ruleset** and turn on
auto-delete of merged branches. The bundled `scripts/lockdown.sh` does the work through
the `gh` CLI; it is **idempotent** (upserts one ruleset named `github-lockdown`). It never
deletes branches or history, and never touches any ruleset other than its own
`github-lockdown` ruleset, which it creates or updates in place.

## When this applies

- The target is a **GitHub** repo and you have (or can get) the **admin** role on it.
- `gh` is installed and authenticated (`gh auth login`) and `jq` is installed.

If the user is not an admin, stop and tell them an admin must run this — do not invent a
workaround.

## Defaults (the fast path)

The standard lockdown, applied with no flags:

- Protect the **default branch** (correct whether it's `main` or `master`).
- **Require a pull request**, with **0 required approvers**.
- **Block force-pushes** and **block branch deletion**.
- **Auto-delete** branches on merge.
- **No bypass** — enforced for everyone, including admins.

## Procedure

1. **Ask: defaults or customize?** Say exactly what the defaults are (above) and ask:
   *"Apply the standard lockdown, or customize it?"*
   - If they accept the defaults, go straight to step 3 with no other questions.

2. **If customizing, run this short interview** (offer the default in brackets; skip any
   the user doesn't care about):
   - Required approvers? [0]
   - Require status checks to pass? If so, which check names (comma-separated)? [none]
   - Any extras? (any of: require conversation resolution · require linear history ·
     require signed commits · require code-owner review · dismiss stale approvals on push)
     [none]
   - Should repo admins be allowed to bypass? [no]

3. **Resolve the target repo.** Default to the current repo. If ambiguous, ask for
   `owner/repo`.

4. **Dry-run and confirm.** Run the script with `--dry-run` and the chosen flags, show the
   user the planned changes, and get explicit confirmation before applying:

   ```bash
   skills/devops/github-lockdown/scripts/lockdown.sh --dry-run --repo <owner/repo> [flags]
   ```

5. **Apply.** Re-run without `--dry-run`. Report the verification summary the script prints.

## Flags

| Flag | Effect |
|------|--------|
| `--repo <owner/repo>` | Target repo (default: current repo) |
| `--branch <name>` | Protect a specific branch (default: the default branch) |
| `--approvals N` | Required approving reviews (default: 0) |
| `--admin-bypass` | Let repo admins bypass (default: off) |
| `--require-conversation-resolution` | Require review threads resolved before merge |
| `--linear-history` | Require linear history |
| `--signed-commits` | Require signed commits |
| `--require-code-owner-review` | Require a CODEOWNERS review |
| `--dismiss-stale-approvals` | Dismiss stale approvals on push |
| `--status-checks "ci,build"` | Require these status check contexts to pass |
| `--no-auto-delete` | Leave `delete_branch_on_merge` unchanged |
| `--ruleset-name <name>` | Name of the managed ruleset (default: github-lockdown) |
| `--dry-run` | Print planned changes; apply nothing |

See `references/rulesets.md` for the ruleset model, required permissions, and how to undo
the lockdown.
