# Setting up execute-tickets on Warp's cloud-agent platform

A step-by-step guide to wiring `execute-tickets.sh` into Warp using the `oz`
CLI (Warp's cloud-agent platform). Commands below are drawn from
[Warp's Oz CLI docs](https://docs.warp.dev/reference/cli/) — verify against
`oz --help` / `oz <command> --help` if any flag has changed since.

## The one thing that matters: use `--once`, not the daemon loop

Warp's [scheduled agents](https://docs.warp.dev/agent-platform/cloud-agents/triggers/scheduled-agents/)
run a fixed prompt on a cron schedule, and each firing gets a **fresh,
isolated session** — the container is torn down after the run and the next
firing starts clean (see [Environments](https://docs.warp.dev/agent-platform/cloud-agents/environments/)).
There is no persistent process between firings.

That rules out the `while true` / 10-concurrent-worker daemon mode this
skill's `SKILL.md` describes for a long-running terminal or CI job. It does
not rule out running this skill on Warp — `--once` exists specifically for
this:

> `--once` runs a single pick + full ticket loop and exits — useful for cron.

Ticket state (lock labels, `needs-human`, closed issues) lives on GitHub, not
in the container, so it survives fine across ephemeral runs. This also means
the "fetch the epic branch fresh per ticket" behavior already in this script
is a non-issue here: Warp clones the repo fresh on every firing anyway.

## 1. Install and authenticate the `oz` CLI

If you have the Warp desktop app, `oz` is already available. Otherwise
install it per Warp's CLI docs, then authenticate:

```bash
oz login
```

(For CI/headless setup instead of an interactive login, use an API key —
see [API keys for the Oz CLI](https://docs.warp.dev/reference/cli/api-keys/).)

## 2. Create the Environment

An Environment is the Docker image + cloned repo(s) + setup commands every
scheduled firing starts from. Create one per plan you're actively executing
(the epic branch checkout below is plan-specific):

```bash
oz environment create \
  --name "execute-tickets-<plan-slug>" \
  --docker-image debian:bookworm-slim \
  --repo <owner/repo> \
  --setup-command "apt-get update && apt-get install -y git jq curl" \
  --setup-command "curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg && echo 'deb [signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main' > /etc/apt/sources.list.d/github-cli.list && apt-get update && apt-get install -y gh" \
  --setup-command "git checkout <epic-branch>" \
  --description "execute-tickets workers for <plan-slug>"
```

Notes:

- **The base image must be glibc-based** (Debian/Ubuntu or similar) — Warp
  environments do not support Alpine/musl images.
- Install whatever your `--agent-cmd` and `--reviewer-cmd` actually invoke
  too (a coding-agent CLI, `codex`, etc.) — add more `--setup-command` flags
  per tool, following each tool's own install instructions. The commands
  above only cover `git`, `jq`, and `gh`.
- The `git checkout <epic-branch>` setup command is required:
  `load_manifest` reads `docs/superpowers/tickets/<plan-slug>.md` from
  whatever's checked out locally, and that file only exists on the epic
  branch (`source_branch` from the plan's manifest), not the repo's default
  branch.
- `--repo`, and `--setup-command` are each repeatable — pass one per repo /
  per command, in the order you want them to run.
- To change any of this later: `oz environment update <ENV_ID> --repo ...` /
  `--docker-image ...` / `--setup-command ...` (same flags, targeting an
  existing environment by ID).

## 3. Provide GitHub credentials as a secret

Don't bake a token into the image. Create it as a team secret instead:

```bash
oz secret create --team GH_TOKEN
```

(prompts for the value interactively; use `--value-file <path>` to supply it
from a file instead). Scheduled/cron agents run with no user context, so
they only receive **team-level** secrets — `--team` above is what makes this
secret visible to them.

`gh` natively honors a `GH_TOKEN` environment variable for authentication
without needing an explicit `gh auth login` step, so naming the secret
`GH_TOKEN` is enough to make `gh auth status` pass in the script's
`preflight()`.

## 4. Create one scheduled agent per worker name

The lock-label claiming (`lock:alice`..`lock:justin`) was built for
independent, uncoordinated processes — that's exactly what separate
scheduled agents are. Create up to 10 (one per `--worker` name), each on its
own cron entry, each running the `--once` invocation with its own name:

```bash
ENV_ID="<environment-id-from-step-2>"

for W in alice bob carol dave eve frank gordon hank isaac justin; do
  oz schedule create \
    --name "execute-tickets-$W" \
    --cron "*/10 * * * *" \
    --environment "$ENV_ID" \
    --prompt "Run this exact command and report its exit code and output: skills/coding/execute-tickets/scripts/execute-tickets.sh --worker $W --plan <plan-slug> --agent-cmd '<your command>' --once"
done
```

Only create as many of the 10 names as you actually want running — this is
a cap, not a requirement to always use all 10. Don't create a single
schedule and try to fan it out to several concurrent runs some other way —
the name is what makes claiming safe.

The `--prompt` is instructions to a cloud **agent** (an LLM), not a literal
shell invocation — Warp's cloud agent decides how to execute it. Phrasing it
as "run this exact command" (rather than a looser description) is what keeps
the agent from improvising. `oz schedule create` also accepts a `--skill`
flag ("use skill as base prompt", format `repo:skill_name` or
`org/repo:skill_name`) that might let you reference this skill directly
instead of spelling out the command — that wasn't verified against this
specific repo/skill while writing this doc, so treat the `--prompt` form
above as the confirmed path and only try `--skill` if you're willing to
verify it yourself first.

Useful lifecycle commands once schedules exist:

```bash
oz schedule list                        # all schedules: id, cron, pause state, last/next run
oz schedule get <SCHEDULE_ID>            # detail on one
oz schedule pause <SCHEDULE_ID>          # disable without deleting
oz schedule unpause <SCHEDULE_ID>
oz schedule update <SCHEDULE_ID> --cron "0 * * * *"   # change any create-time flag
oz schedule delete <SCHEDULE_ID>
```

## What this file does not (yet) cover

This is guidance derived from Warp's public docs, not a config that's been
run against a live Warp account from this repo. Before trusting it in
production:

1. Run one `oz environment create` + one `oz schedule create` for a single
   worker name.
2. Check `oz schedule get <SCHEDULE_ID>` after its first firing to confirm
   the agent actually ran `--dry-run --once` successfully (swap `--dry-run`
   into the `--prompt` command for this first check) — that `gh`/`jq`/your
   agent CLI resolve, and `gh auth status` is green — before wiring up the
   real, non-dry-run schedule and the remaining worker names.
