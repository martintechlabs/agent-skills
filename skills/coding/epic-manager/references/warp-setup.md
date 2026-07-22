# Setting up epic-manager on Warp's cloud-agent platform

A step-by-step guide to wiring `epic-manager.sh` into Warp using the `oz` CLI
(Warp's cloud-agent platform). Commands below are drawn from
[Warp's Oz CLI docs](https://docs.warp.dev/reference/cli/) — verify against
`oz --help` / `oz <command> --help` if any flag has changed since.

## The one thing that matters: singleton, `--once`, slow cadence

Warp's [scheduled agents](https://docs.warp.dev/agent-platform/cloud-agents/triggers/scheduled-agents/)
run a fixed prompt on a cron schedule, and each firing gets a **fresh,
isolated session** — the container is torn down after the run and the next
firing starts clean. There is no persistent process between firings.

That's fine for `epic-manager`: use `--once` per firing, exactly as for
`execute-tickets`. The manager is a **singleton** (one process per plan, per
repo), so unlike the executor — which runs up to 10 parallel workers, one per
scheduled agent — the manager needs **exactly one scheduled agent per plan**.
The `lock:manager` label makes overlapping firings safe (the loser exits
cleanly), but there's no benefit to scheduling more than one manager per plan.

**Cadence:** every 5 minutes is plenty. Plan-level state changes slowly
(tickets take minutes-to-hours to merge; the manager has no ticket work of
its own to do). The default `--poll 300` is for loop mode; under Warp's
cron-`--once` model, the cron schedule *is* the poll.

Ticket + epic state (`lock:*` labels, `needs-human`, closed issues, PRs)
lives on GitHub, not in the container, so it survives fine across ephemeral
runs.

## 1. Install and authenticate the `oz` CLI

If you have the Warp desktop app, `oz` is already available. Otherwise install
it per Warp's CLI docs, then authenticate:

```bash
oz login
```

(For CI/headless setup instead of an interactive login, use an API key — see
[API keys for the Oz CLI](https://docs.warp.dev/reference/cli/api-keys/).)

## 2. Create the Environment

An Environment is the Docker image + cloned repo(s) + setup commands every
scheduled firing starts from. Create one per plan you're actively managing:

```bash
oz environment create \
  --name "epic-manager-<plan-slug>" \
  --docker-image debian:bookworm-slim \
  --repo <owner/repo> \
  --setup-command "apt-get update && apt-get install -y git jq curl yq" \
  --setup-command "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg && echo 'deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main' > /etc/apt/sources.list.d/github-cli.list && apt-get update && apt-get install -y gh" \
  --setup-command "git checkout <epic-branch>" \
  --description "epic-manager for <plan-slug>"
```

Notes:

- **The base image must be glibc-based** (Debian/Ubuntu or similar) — Warp
  environments do not support Alpine/musl images.
- **`yq` is required** for checklist parsing. Install it via `go install`
  or download the single binary; ensure it's on PATH at the version the
  manager expects (yq v4+).
- **`codex`** must also be on PATH. Install per OpenAI's codex CLI docs.

## 3. Provide GitHub auth and Codex auth via Agent Secrets

The manager needs `gh auth status` green and codex authenticated. Store both
as Agent Secrets in Warp (see [Agent Secrets](https://docs.warp.dev/agent-platform/cloud-agents/secrets/))
and reference them in the scheduled agent's environment:

- `GH_TOKEN` — a GitHub PAT with `repo` scope (or the fine-grained equivalent:
  issues, pull requests, labels, and contents on the target repo).
- `CODEX_API_KEY` (or whatever your codex CLI reads) — for the codex reviewer.

## 4. Create the scheduled agent

One scheduled agent per plan, firing every 5 minutes:

```bash
oz scheduled-agent create \
  --name "epic-manager-<plan-slug>" \
  --environment "epic-manager-<plan-slug>" \
  --schedule "*/5 * * * *" \
  --prompt "Run the epic manager for <plan-slug>: bash skills/coding/epic-manager/scripts/epic-manager.sh --plan <plan-slug> --repo <owner/repo> --once"
```

The `--once` is non-negotiable: each firing runs one reconcile + act cycle and
exits. The next firing's fresh container picks up where it left off via
GitHub state. If a firing is still running when the next cron tick fires, the
new firing can't acquire `lock:manager` and exits cleanly — no double-run.

## 5. Run it alongside `execute-tickets` workers

A repo running both: executors on one scheduled-agent set (up to 10 workers,
each its own scheduled agent firing `--worker <name> --once` on a fast cron,
e.g. every minute), and **one** epic-manager scheduled agent firing `--once`
on a slower cron (every 5 minutes). They coordinate through GitHub state
only — the manager observes `lock:<name>` labels to report progress; the
executors never touch `lock:manager` or the epic PR.

## 6. Human commands

The manager reads commands from comments on the **epic issue**. To approve a
merge, file a rework, or abandon, comment on the epic issue in GitHub (not
the PR, not the Warp terminal):

- `ship it` / `#shipit` / 🚀 / `lgtm` / `merge it`
- `rework [#N]: <description>`
- `abandon`

The next manager firing (within 5 minutes) parses the comment and acts. You'll
see the result as a manager response comment on the same issue.
