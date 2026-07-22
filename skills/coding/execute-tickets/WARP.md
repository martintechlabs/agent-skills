# Running execute-tickets on Warp's scheduled-agent platform

Project rules for Warp agents working in this directory (see
[Warp's Rules docs](https://docs.warp.dev/agent-platform/capabilities/rules/) —
Warp reads `WARP.md`/`AGENTS.md` from the repo root and the current directory).
If you're asked to wire `execute-tickets.sh` up to run on a schedule in Warp,
read this first.

## The one thing that matters: use `--once`, not the daemon loop

Warp's [scheduled agents](https://docs.warp.dev/platform/triggers/scheduled-agents/)
run a fixed prompt on a cron schedule, and each firing gets a **fresh, isolated
session** — the container is torn down after the run and the next firing
starts clean (see [Environments](https://docs.warp.dev/platform/environments/)).
There is no persistent process between firings.

That rules out the `while true` / 10-concurrent-worker daemon mode this skill's
`SKILL.md` describes for a long-running terminal or CI job. It does not rule
out running this skill on Warp — `--once` exists specifically for this:

> `--once` runs a single pick + full ticket loop and exits — useful for cron.

Each Warp firing should invoke:

```bash
skills/coding/execute-tickets/scripts/execute-tickets.sh \
  --worker <name> --plan <plan-slug> --agent-cmd '<your command>' --once
```

Ticket state (lock labels, `needs-human`, closed issues) lives on GitHub, not
in the container, so it survives fine across ephemeral runs. This also means
the "fetch the epic branch fresh per ticket" fix already in this script is a
non-issue here: Warp clones the repo fresh on every firing anyway.

## Emulating the 10 concurrent workers

The lock-label claiming (`lock:alice`..`lock:justin`) was built for
independent, uncoordinated processes — that's exactly what separate
scheduled agents are. Create up to 10 scheduled agents (one per `--worker`
name), each with its own cron entry, each running the `--once` invocation
above with its own `--worker <name>`. Don't create a single schedule and
try to fan it out to several concurrent runs some other way — the name is
what makes claiming safe.

## Environment requirements

Configure a Warp [Environment](https://docs.warp.dev/platform/environments/)
for this and point the scheduled agents at it:

- **Base image must be glibc-based** (Debian/Ubuntu or similar) — Warp
  environments do not support Alpine/musl images.
- Install `git`, `gh`, `jq`, and whatever coding-agent CLI your `--agent-cmd`
  invokes (plus `codex`, or your own `--reviewer-cmd`, for the review step).
- Provide GitHub credentials via Warp **Agent Secrets** (not baked into the
  image), so `gh auth status` passes in the script's `preflight()` step.
- The environment's checkout must land on the **epic branch**
  (`source_branch` from the plan's manifest), not the repo's default branch —
  `load_manifest` reads `docs/superpowers/tickets/<plan-slug>.md` from
  whatever's checked out locally, and that file only exists on the epic
  branch. If the environment's default checkout step doesn't take a branch
  parameter, add `git checkout <epic-branch>` to the environment's startup
  commands.

## What this file does not (yet) cover

This is guidance derived from Warp's public docs, not a config that's been
run against a live Warp account from this repo. Before trusting it in
production, do one `--dry-run --once` invocation inside the actual configured
environment to confirm `gh`/`jq`/`codex` resolve and `gh auth status` is
green, before wiring up the real cron schedule.
