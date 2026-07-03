# GitHub rulesets: how this skill applies the lockdown

This skill enforces branch protection through **repository rulesets** (not classic
branch protection), plus the repo-level `delete_branch_on_merge` setting.

## What gets created

A ruleset named `github-lockdown` on the repo, `enforcement: active`, targeting the
default branch via the `~DEFAULT_BRANCH` ref selector (or `refs/heads/<branch>` when
`--branch` is passed). Default rules: `pull_request` with
`required_approving_review_count: 0`, `non_fast_forward` (block force-push), and
`deletion` (block branch deletion). By default **no bypass actors** — the rules apply
to everyone, including admins. `--admin-bypass` adds the built-in admin repo role
(RepositoryRole id 5) as an `always` bypass actor.

## Required permissions

You must have the **admin** role on the repo (the script checks `viewerPermission`).
`gh` must be authenticated (`gh auth login`) with a token that can manage rulesets.
`jq` must be installed.

## Idempotency

The script looks up an existing ruleset **by name** (`github-lockdown`). If found it
`PUT`s an update to that id; otherwise it `POST`s a new one. Re-running never creates
duplicates, and it never touches rulesets it did not create.

## Inspecting and undoing

- List rulesets: `gh api repos/<owner>/<repo>/rulesets`
- View one: `gh api repos/<owner>/<repo>/rulesets/<id>`
- Remove the lockdown: `gh api -X DELETE repos/<owner>/<repo>/rulesets/<id>`
- Turn off auto-delete: `gh api -X PATCH repos/<owner>/<repo> -F delete_branch_on_merge=false`

## Notes

- Rulesets are available on **public and private** repos, including free plans — this is
  why the skill uses them instead of classic branch protection.
- `--dry-run` prints the exact JSON body (stdout) and the planned actions (stderr) without
  changing anything.
- Status checks are matched by their **context** string (the check name that appears on the
  commit status); pass them comma-separated via `--status-checks`.
