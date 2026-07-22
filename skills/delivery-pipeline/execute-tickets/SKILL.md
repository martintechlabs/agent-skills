---
name: execute-tickets
description: >-
  Pick up a plan-to-tickets backlog on GitHub, drive each ready ticket through a
  coding agent + codex code review + CI verification loop, then merge the PR back
  to the plan's epic branch. Runs as up to 10 concurrent worker processes per
  repo; each worker claims tickets via a per-slot lock label, sub-branches from
  the epic branch, invokes per-tier commands from `.execute-tickets/agents.yml`
  (or optional `--agent-cmd` override), runs `codex exec` against the PR with a
  vendored review schema + prompt, blocks merge on codex priority 0-1 findings
  and red CI checks, and feeds blocking findings back to the agent for up to N
  iterations. Use when the user has a filed plan-to-tickets backlog and wants
  tickets executed end-to-end (agent -> review -> merge), when they ask to
  run/dispatch/execute a ticket backlog, or when they want the codex review loop
  wired to a ticket queue. Never coordinates across plans or repos, never merges
  the epic itself, and hard-caps at 10 workers per repo.
metadata:
  author: stephen-martin
  version: "0.6.0"
---

# Execute a plan-to-tickets backlog end-to-end

Pick up the epic + ticket sub-issues filed by `plan-to-tickets` and drive each
ready ticket all the way to a merged PR on the plan's epic branch. The bundled
`scripts/execute-tickets.sh` does the mechanical work: claim a ticket, sub-branch
from the epic branch, invoke a coding agent (from `.execute-tickets/agents.yml`
by model tier, or a process-wide `--agent-cmd` override), open a PR, wait for
CI, run codex code review, feed blocking findings back to the agent, and merge
once the review is clean and CI is green.

Designed to run as up to **10 concurrent worker processes per repo**, each
with a distinct `--worker` name (`alice`, `bob`, `carol`, `dave`, `eve`,
`frank`, `gordon`, `hank`, `isaac`, `justin`) that becomes its lock label
(`lock:<name>`). The 10-slot cap is a hard limit — beyond that the label
mutex stops being a useful mental model.

This skill never merges the epic PR itself, never retries a `needs-human`
ticket automatically, and never coordinates across plans or repos.

## When this applies

- `plan-to-tickets` has already filed an epic + tickets on GitHub for a plan,
  and the manifest `docs/superpowers/tickets/<plan-slug>.md` is committed to the
  repo (its YAML front matter carries `source_branch`, `spec_file`, `plan_file`).
- The target is a **GitHub** repo, `gh`, `git`, `jq`, and `codex` are on PATH,
  and `gh auth status` is green. When not passing `--agent-cmd`, **`yq`**
  (mikefarah v4) is also required to load `.execute-tickets/agents.yml`.
- Branch protection on the epic branch permits `gh pr merge` (or auto-merge is
  enabled). If the epic branch is protected against direct merges by the user
  running the executor, ticket merges will fail and land on `needs-human`.
- Prefer repo-local `.execute-tickets/agents.yml` (scaffold with
  `scripts/init-agents.sh`) mapping each model tier to a shell command.
  Pass `--agent-cmd` only to override that file for the whole worker process.

If no plan slug is named, use the most recently modified manifest under
`docs/superpowers/tickets/` and confirm it with the user before proceeding. If
no manifest exists, stop and point at `plan-to-tickets` — do not try to
reconstruct backlog metadata from issue bodies.

## Branch topology

`plan-to-tickets` puts the spec + plan on `source_branch` (the epic branch).
Each ticket sub-branches from `origin/<source_branch>` and its PR targets the
epic branch. Nothing merges to `main` until the epic itself is merged by a
human — the executor stops at the epic boundary.

```
main
 └─ source_branch (epic)  <- holds spec + plan, target for ticket PRs
     ├─ ticket/142-add-parser        (PR merged back to epic)
     ├─ ticket/143-wire-cli
     └─ ticket/144-doc-updates
```

Because tickets merge into `source_branch` as they finish, workers re-fetch
`origin/<source_branch>` at worktree creation time so later tickets start from
sibling tickets' merged code. If two ticket branches touch the same lines,
`gh pr merge` will refuse — that ticket lands on `needs-human` with the merge
error, which is a real signal that the plan's decomposition was too coarse.

## The per-ticket loop

For each ticket picked up:

1. **Claim** — add `lock:<name>` label, verify no other `lock:*` label is present.
   If a race is detected, release and pick another.
2. **Worktree** — `git worktree add --detach <path> origin/<source_branch>`,
   then `git switch -c ticket/<n>-<slug>`. Worktree path includes the worker ID
   so all 10 workers never collide on disk.
3. **Agent, iteration 1** — resolve the agent command (`--agent-cmd` override, or
   the ticket's `model-tier` entry in `agents.yml`) and invoke it with all
   substitution tokens. Agent commits on the ticket branch. If it forgot to
   push, executor pushes.
4. **Open PR** — `gh pr create --base <source_branch> --head <branch> \
   --body "Ticket: #<n>"`. Not `Closes #<n>`: GitHub only honors closing
   keywords when the PR targets the repo's *default* branch, and this PR
   targets the epic branch, so the keyword would silently do nothing — see
   step 8.
5. **Wait for CI** — `gh pr checks --watch`, bounded by `--ci-timeout` per
   iteration (default 1800s).
6. **Codex review** — compose a prompt (vendored `references/codex-review-prompt.md`
   + ticket body + spec path + plan path + PR diff), run `codex exec
   --output-schema references/codex-review-schema.json --sandbox read-only -o
   review.json - < prompt.md`.
7. **Decide.** Blocking = any of:
   - `overall_correctness == "patch is incorrect"`
   - Any finding with `priority <= --block-priority-max` **and**
     `confidence_score >= --min-confidence`
   - Any CI check whose conclusion is not `SUCCESS`/`NEUTRAL`/`SKIPPED`
     (checks still in `PENDING`/`IN_PROGRESS`/`QUEUED` are treated as
     not-yet-final and won't block on their own)
8. **Green path** — post P2/P3 (and low-confidence) findings as informational
   PR comments, then `gh pr merge <method> --delete-branch --auto` (falling
   back to synchronous merge if auto-merge isn't enabled). Once merged,
   explicitly `gh issue close <n>` — the PR's "Closes #n" keyword never fires
   against a non-default base branch, so the executor closes the ticket issue
   itself; this is what lets dependents unblock (see "ready" below). Release
   the lock.
9. **Red path** — assemble a feedback bundle (blocking findings + failing check
   names + verdict explanation) into a file, re-invoke the same resolved agent
   command with `{review_feedback}` pointing at that file and `{iteration}`
   incremented. Agent pushes new commits. Loop back to step 5.
10. **Iteration cap** — if the loop hits `--max-iterations` (default 5), remove
    the lock, add `needs-human`, comment the last feedback bundle on the
    issue, move on to the next ticket.

## Severity model

Codex's structured review output uses an integer `priority` field, **0..3, lower
is more severe**:

| priority | meaning | blocks merge? |
|:--:|--|:--:|
| 0 | severe (correctness, security, data loss) | yes |
| 1 | major (design, error handling, performance) | yes |
| 2 | minor (readability, non-critical refactors) | no — posted as PR comment |
| 3 | nit (naming, formatting, wording) | no — posted as PR comment |

Findings below `--min-confidence` (default `0.5`) are treated as informational
regardless of priority — codex flagging itself as unsure is a signal not to
loop the agent on it. `overall_correctness == "patch is incorrect"` always
blocks even if no individual finding does; the reviewer sometimes emits a
verdict without an accompanying finding at the required severity.

The vendored review schema and prompt live at:

- `references/codex-review-schema.json` — the structured-output schema.
- `references/codex-review-prompt.md` — the reviewer system prompt, including
  the priority scale defined above.

Override both with `--review-schema <path>` and `--review-prompt <path>` when a
repo needs different standards (stricter thresholds, project-specific rules,
etc.). Do not edit the vendored files in place unless you're changing the
default for every project using this skill.

## Reviewer command

Default (`--reviewer-cmd` unset):

```
codex exec --model "${CODEX_MODEL:-gpt-5-codex}" \
  --output-schema {review_schema} \
  -o {review_output} \
  --sandbox read-only \
  - < {review_prompt_composed}
```

`{review_prompt_composed}` is the vendored prompt with the ticket body, spec
path, plan path, and PR diff appended — the executor builds it fresh per
iteration. `--sandbox read-only` is non-negotiable: the reviewer must not
write to the tree. Override the reviewer command with `--reviewer-cmd` only
when you need a different codex model, an org-hosted proxy, or a bespoke
reviewer entirely. Available tokens: `{review_schema}` `{review_prompt_composed}`
`{review_output}` `{pr_number}` `{branch}` `{worktree}` `{head_sha}`.

## Agent commands

Day-to-day routing lives in the **target repo** at
`.execute-tickets/agents.yml` (sibling to any `.execute-tickets/checklist.yml`
owned elsewhere — this skill never edits checklist files). Keys are model
tiers from `plan-to-tickets`; values are full shell commands:

| Key | Intent |
|--|--|
| `lite` | Docs/copy/config-only |
| `efficient` | Small, fully-spec'd mechanical code |
| `standard` | Everyday multi-file integration |
| `flagship` | Hardest judgment / architecture-adjacent |

**Selection:**

| Situation | Command used |
|--|--|
| `--agent-cmd` passed | That command for **every** ticket this process runs |
| No `--agent-cmd` | Ticket's `model-tier` entry from `agents.yml` |

When the flag is omitted, preflight requires the file to exist, `yq` on PATH,
and all four keys non-empty. Partial files fail before any ticket is claimed.
Missing or invalid `model-tier` on a ticket → `needs-human` (no silent fallback).

### Scaffold with Claude defaults

```bash
skills/delivery-pipeline/execute-tickets/scripts/init-agents.sh
# optional: --repo-root <path>  --force  --dry-run
```

Copies `references/agents.example.yml` to `.execute-tickets/agents.yml`. Refuses
to overwrite without `--force`. Edit model flags for your org before launching
workers. See `plan-to-tickets`'s `references/model-tiers.md` for the tier
vocabulary.

### Tokens

Each command (YAML or `--agent-cmd`) is run from inside the ticket worktree.
Tokens (each shell-quoted independently, safe to interpolate anywhere):

| token | value |
|--|--|
| `{issue_number}` | e.g. `142` |
| `{issue_title}` | ticket title |
| `{issue_body}` | path to a temp file with the ticket body |
| `{spec_file}` | repo-relative path to spec |
| `{plan_file}` | repo-relative path to plan |
| `{model_tier}` | `lite` \| `efficient` \| `standard` \| `flagship` |
| `{complexity}` | `small` \| `medium` |
| `{priority}` | `p1` \| `p2` \| `p3` |
| `{worktree}` | absolute path to the ticket worktree |
| `{branch}` | new branch name (`ticket/<n>-<slug>`) |
| `{review_feedback}` | path to feedback bundle on retries; empty string on iteration 1 |
| `{iteration}` | `1` on first pass, `2..N` on review retries |

Rules the agent must follow:

- Commit on `{branch}`. Push is optional (executor pushes if missing).
- **Never open a PR.** The executor opens it after verifying the first push.
- On iterations `>=2`, read `{review_feedback}` and address only the blocking
  findings + failing checks listed there. Do not re-open unrelated design
  questions mid-review-loop.

Ticket-level model routing is primarily `agents.yml` (tier → command). Use
`--agent-cmd` only as a process-wide override for debugging or one-off runs.

## Procedure

### 1. Confirm the backlog is ready to execute

Read the manifest for the target plan. Confirm the epic and every ticket
sub-issue still exist on GitHub (re-running `plan-to-tickets` in `--dry-run`
on the same plan is the cheapest way — it lists what it would create/update
without touching anything). Do not proceed if the manifest references a plan
or spec file that is not committed on `source_branch`: the agent and the
reviewer both need to read them.

### 2. Configure agent commands

If `.execute-tickets/agents.yml` is missing:

```bash
skills/delivery-pipeline/execute-tickets/scripts/init-agents.sh
```

Edit the four tier commands (Claude defaults ship in the template; replace with
pi/codex/etc. as needed). Each command must:

- Run from inside the ticket worktree (executor `cd`s there before invoking).
- Read the ticket body from `{issue_body}` (a path — not inline text).
- Consume `{spec_file}` and `{plan_file}` as repo-relative paths.
- Handle `{review_feedback}` when `{iteration}` is `>=2`.
- Commit onto `{branch}` and not open a PR.

For a one-off process that ignores YAML, pass `--agent-cmd` instead.

### 3. Dry-run one worker first

```bash
skills/delivery-pipeline/execute-tickets/scripts/execute-tickets.sh \
  --worker alice --plan <plan-slug> \
  --dry-run --once
```

Prints the ticket the executor would pick, agent **source**
(`agents.yml#<tier>` or `--agent-cmd`), worktree path, branch name, and the
fully-rendered agent + reviewer commands. Nothing is claimed, no worktree is
created, no agent or codex call is made. Fix wrong tokens or manifests before
going live.

### 4. Launch up to 10 workers

```bash
for W in alice bob carol dave eve frank gordon hank isaac justin; do
  skills/delivery-pipeline/execute-tickets/scripts/execute-tickets.sh \
    --worker "$W" --plan <plan-slug> \
    > "logs/executor-${W}.log" 2>&1 &
done
wait
```

(Only launch as many of the 10 names as you actually want running — the
list is a cap, not a requirement to always use all 10.)

Each worker loops: pick highest-priority ready ticket → claim → run the per-ticket
loop above → release the lock (on merge) or set `needs-human` (on failure). If
no ticket is ready (all locked, all blocked by open dependencies, or backlog
empty), the worker sleeps `--poll` seconds (default 30) and tries again.
`--once` runs a single pick + full ticket loop and exits — useful for cron.
See `references/warp-setup.md` for running the 10-worker pattern as separate
Warp scheduled agents instead of a long-running daemon.

A ticket is "ready" when: (a) its body carries this plan's ticket marker, (b)
it has no `lock:*` label, (c) it has no `needs-human` label, (d) it has no
assignees, and (e) every issue referenced in its `Depends on: #NNN` line is
closed. The executor explicitly closes a ticket's issue on merge (step 8 of
the per-ticket loop), which unblocks dependents on the next poll — no
scheduler needed.

Do not run more than 10 workers against the same repo without extending the
`WORKER_NAMES` list in the script. The script hard-caps `--worker` at these
10 names by design.

### 5. Handle `needs-human` tickets

Any failure — agent exits non-zero, no commits pushed, `gh pr create` fails,
reviewer command fails, review loop exhausted, merge fails after a clean
review — causes the executor to remove its lock, add a `needs-human` label,
comment the failure reason (and the last feedback bundle, if there is one)
on the ticket, and move on.

Triage:

```bash
gh issue list --repo <owner/repo> --label needs-human --state open
```

Common outcomes: fix the agent command and remove `needs-human` to re-queue;
edit the ticket body to clarify scope; increase `--max-iterations` if the
review loop was just close to converging; drop the ticket and re-run
`plan-to-tickets` after revising the plan. The executor never silently
retries — silent retries hide real problems.

### 6. Stop conditions

The executor stops when: the user kills the worker processes, `--once` was
passed and a cycle completed, or (in long-running mode) the backlog is fully
drained *and* the user kills the workers. There is no "done" state the script
can detect on its own — more ready tickets can appear at any time (a
`needs-human` label removed, a dependency PR merged, `plan-to-tickets` re-run
with an updated plan).

**Merging the epic PR is out of scope.** Whatever process merges the epic
branch into `main` — human review, CI auto-merge, `gh pr merge --auto` on a
schedule — is a separate decision, made by whoever trusts the collected
ticket output.

## Flags (`scripts/execute-tickets.sh`)

| Flag | Effect |
|--|--|
| `--worker <name>` | Worker identity, case-insensitive (required). One of: alice, bob, carol, dave, eve, frank, gordon, hank, isaac, justin. Becomes lock label `lock:<name>`. |
| `--plan <slug>` | Plan slug: basename of `docs/superpowers/tickets/<slug>.md` (required). |
| `--agent-cmd <cmd>` | Optional process-wide agent command (overrides `agents.yml`). Required only if no valid `.execute-tickets/agents.yml` is present. |
| `--repo <owner/repo>` | Target repo (default: current repo via `gh repo view`). |
| `--reviewer-cmd <cmd>` | Codex review command (default: `codex exec ... --sandbox read-only`). |
| `--review-schema <path>` | Override review output schema (default: vendored). |
| `--review-prompt <path>` | Override reviewer system prompt (default: vendored). |
| `--block-priority-max <N>` | Findings with `priority <= N` block merge. Default: `1` (P0+P1 block). |
| `--min-confidence <F>` | Findings below this confidence never block. Default: `0.5`. |
| `--max-iterations <N>` | Max agent+review cycles before `needs-human`. Default: `5`. |
| `--merge-method <flag>` | One of `--squash`, `--rebase`, `--merge`. Default: `--squash`. |
| `--ci-timeout <seconds>` | Per-iteration wait for PR checks to settle. Default: `1800`. |
| `--poll <seconds>` | Sleep between empty polls in loop mode. Default: `30`. |
| `--once` | Pick + run at most one ticket, then exit. |
| `--dry-run` | Print the selected ticket + composed commands; do not claim/worktree/agent/review/merge. |
| `--help` | Show help. |

## What this skill deliberately does not do

- **Merge the epic PR** (or anything to `main`). Stops at the epic branch.
- **Retry `needs-human` tickets.** All failures require human triage.
- **Invent model IDs for you over time.** `init-agents.sh` ships a Claude
  snapshot; projects own edits to `agents.yml`.
- **Coordinate across plans or repos.** One invocation, one plan, one repo.
- **Scale past 10 workers per repo.** The 10-name lock label set is the cap.
- **Auto-merge PRs before codex says the patch is correct.** `overall_correctness`
  is a hard gate, even without matching high-priority findings.
