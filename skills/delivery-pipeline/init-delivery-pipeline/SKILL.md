---
name: init-delivery-pipeline
description: >-
  Interactively scaffold .execute-tickets/agents.yml and .execute-tickets/checklist.yml
  for a repo that has plan-to-tickets, execute-tickets, and epic-manager installed —
  detecting the repo's actual language, package manager, and test/lint/build commands
  so the drafted config is tailored to this project, not a generic template. Preflights
  gh/codex/claude auth, shows both drafts for confirmation before writing, and prints the
  exact ready-to-paste execute-tickets worker loop and epic-manager --once commands for
  a given plan and repo. Use when deploying the delivery pipeline to a new repo for the
  first time, or when asked to set up/scaffold the ticket-pipeline config. Not for
  tweaking a single existing tier's command — use execute-tickets' own init-agents.sh
  --force for that.
metadata:
  author: stephen-martin
  version: "0.1.0"
---

# Set up the delivery pipeline for a new repo

A one-time, interactive setup companion for `plan-to-tickets` + `execute-tickets` +
`epic-manager`. Detects this repo's language/tooling, drafts a tailored
`.execute-tickets/agents.yml` and `.execute-tickets/checklist.yml`, and — once you confirm
and it writes them — prints the exact commands to paste into cron or Warp to run the
`execute-tickets` worker pool and the `epic-manager` singleton loop.

This skill never runs headless or on cron. It never touches GitHub. It doesn't replace
`execute-tickets/scripts/init-agents.sh` — that stays for re-scaffolding just `agents.yml`
later.

## When this applies

Use when: a repo has (or is about to have) `plan-to-tickets`, `execute-tickets`, and
`epic-manager` installed and needs `.execute-tickets/agents.yml` +
`.execute-tickets/checklist.yml` set up for the first time; the user asks to "set up the
delivery pipeline," "deploy execute-tickets/epic-manager to this repo," or "scaffold the
ticket pipeline config."

Not for: a repo that already has both files and just wants one tier's command tweaked —
use `execute-tickets/scripts/init-agents.sh --force` instead. Not for repos that will run
only a subset of the three pipeline skills — this skill assumes all three.

## Dependencies

Reads (never writes) two files that must exist in sibling skill directories:

- `execute-tickets/references/agents.example.yml`
- `epic-manager/references/checklist-schema.json`

If either can't be found, stop immediately and name which skill is missing and the
install command to fix it (e.g. `npx skills add martintechlabs/agent-skills --skill
execute-tickets,epic-manager`). Never fall back to a hardcoded copy — that would drift
from the real templates.

## Procedure

### 1. Preflight tooling

- `gh auth status` — **hard stop** if not authenticated.
- `codex` on `PATH` and authenticated — warn, don't block.
- `claude` on `PATH` — warn, don't block.
- Whether `superpowers` is enabled for the current account (check `enabledPlugins` in
  `~/.claude/settings.json` if readable; skip silently if not) — informational only. This
  is an account-level setting, not a project one — workers may run under a different
  account than this session.

### 2. Detect project facts

Read, in order of precedence, whichever exist: `package.json`, `pyproject.toml`,
`Cargo.toml`, `go.mod`, `Makefile`, `.github/workflows/*.yml`. Determine:

- Language + package manager.
- Real test/lint/build commands — prefer what's already wired into CI
  (`.github/workflows/*.yml`) over guessing; fall back to package-manager convention
  (`npm test`, `pytest -q`, `cargo test`, `go test ./...`) if no CI config exists.
- Whether the project looks like a long-running server (a start/serve script, listens on
  a port) — relevant for a boot-and-respond checklist item.

Check whether `.execute-tickets/agents.yml` and/or `.execute-tickets/checklist.yml`
already exist. Never silently overwrite — see step 5.

### 3. Draft `agents.yml`

Start from `execute-tickets/references/agents.example.yml`'s four tiers
(lite/efficient/standard/flagship, `claude -p` with per-tier `--model`). Tailor
`--allowedTools` to what step 2 found — e.g. `Bash(git *) Bash(npm *)` for Node,
`Bash(git *) Bash(pytest *)` for Python. Keep the underlying CLI and prompt bodies as the
vendored default.

### 4. Draft `checklist.yml`

Propose `run:` items directly from the test/lint/build commands found in step 2. Where
the project looks like a server, propose a boot-and-respond check. Propose one or two
`judge:` items only where grounded in something specific about this repo (e.g. "no TODO
left in shipped code" scoped to the actual source directories found) — not a generic
unscoped template.

### 5. Show drafts, confirm, write

Present both drafted files in full. If either target file already exists, say so and ask
before overwriting. Only write after confirmation.

### 6. Print the ready-to-paste commands

Ask for (or infer via `gh repo view`) `--repo`, the plan slug (`--plan`), and how many
`execute-tickets` workers to include (1–10). Render via:

```bash
skills/delivery-pipeline/init-delivery-pipeline/scripts/print-commands.sh \
  --plan <plan-slug> --repo <owner/repo> --workers <N>
```

This prints the exact `execute-tickets` worker loop and the `epic-manager --once`
command — kept as a separate deterministic script rather than free-form output so the
flag syntax can't drift or get hallucinated. Point at
`execute-tickets/references/warp-setup.md` and `epic-manager/references/warp-setup.md`
for wiring either into Warp specifically.

## Flags (`scripts/print-commands.sh`)

| Flag | Effect |
|--|--|
| `--plan <slug>` | Plan slug (required). |
| `--repo <owner/repo>` | Target repo (required). |
| `--workers <N>` | Number of `execute-tickets` workers to include, 1–10 (default: 10). |
| `--help` | Show help. |

## What this skill deliberately does not do

- **Create GitHub labels.** Each of the three pipeline skills already self-heals its own
  required labels on first real run.
- **Run headless or on cron.** Always interactive, once, by a human in a live session.
- **Guarantee the drafted config is correct.** It's a grounded starting point, shown for
  confirmation before anything is written — not a substitute for review.
- **Change the flag surface or behavior of `plan-to-tickets`, `execute-tickets`, or
  `epic-manager`.** Purely additive.
