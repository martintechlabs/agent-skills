# init-delivery-pipeline — Design

**Date:** 2026-07-22
**Category:** `delivery-pipeline`
**Status:** Approved design, pending spec review

## Purpose

A new, fourth skill in the `delivery-pipeline` category that turns "I just installed
`plan-to-tickets` + `execute-tickets` + `epic-manager` in a new repo, now what" into a short
interactive session. It inspects the target repo, drafts a `.execute-tickets/agents.yml` and
`.execute-tickets/checklist.yml` tailored to that repo's actual language/tooling, writes them
after confirmation, and prints the two ready-to-paste commands (`execute-tickets`'s worker
for-loop and `epic-manager`'s singleton `--once` command) for whatever plan/repo the user gives
it.

Today, setting this up means hand-assembling both config files from a generic template and a raw
JSON schema (verified against a real deployment: `test_arena`'s `checklist.yml` was written by
hand against `epic-manager/references/checklist-schema.json`, with no scaffold to start from),
plus separately reading two ~70%-duplicated `warp-setup.md` docs to figure out the actual cron
commands. `init-delivery-pipeline` collapses that into one guided pass.

This does **not** replace or restructure `plan-to-tickets`, `execute-tickets`, or `epic-manager`
— those three stay exactly as they are. `init-delivery-pipeline` is purely additive: an
installation companion, not a fourth pipeline stage.

## Non-goals

- **Not a headless/cron skill.** Always run interactively, once, by a human sitting in a live
  Claude Code session with `Read`/`Grep`/`Bash` access to the target repo. No subprocess call to
  `codex exec` or a headless `claude -p` — the invoking session does the detection and drafting
  itself, the same way `plan-to-tickets` drafts ticket bodies itself rather than shelling out.
- **No GitHub mutation.** Does not create labels. `plan-to-tickets`, `execute-tickets`, and
  `epic-manager` each already idempotently self-heal their own required labels
  (`ensure_labels()` / `ensure_lock_labels()`) on their own first real run — duplicating that
  here would just be a second place for the label set to drift out of sync.
- **Does not replace `init-agents.sh`.** That script stays, for anyone who wants to re-scaffold
  just `agents.yml` later without re-running the whole setup flow.
- **Does not change the flag surface, behavior, or config format** of any of the other three
  skills' scripts. It reads their reference templates/schemas as grounding material; it does not
  modify them.
- **Does not re-plan, execute, or ship tickets.** Purely a setup step that runs once, before any
  of the other three skills' loops start.
- **Does not guarantee the drafted config is correct.** It's a starting point grounded in real
  detected facts about the repo, shown to the human for confirmation before anything is written
  — not a substitute for the human reviewing it.

## When this applies

Use when: a repo has (or is about to have) `plan-to-tickets`, `execute-tickets`, and
`epic-manager` installed and needs `.execute-tickets/agents.yml` +
`.execute-tickets/checklist.yml` set up for the first time; the user asks to "set up the delivery
pipeline," "deploy execute-tickets/epic-manager to this repo," or "scaffold the ticket
pipeline config" for a repo that doesn't have one yet. Not for repos that already have both
files and just want one tier's command tweaked — point at `init-agents.sh --force` instead.

## Dependencies on sibling skills

`init-delivery-pipeline` reads (never writes) two files that live in sibling skill directories:

- `execute-tickets/references/agents.example.yml` — the four Claude-default model-tier command
  templates, used as the base for the drafted `agents.yml`.
- `epic-manager/references/checklist-schema.json` — the JSON Schema the drafted `checklist.yml`
  must satisfy.

This assumes `execute-tickets` and `epic-manager` are installed as siblings under a common skills
root. Verified against the real `npx skills add` layout (flat: `<root>/plan-to-tickets/`,
`<root>/execute-tickets/`, etc., regardless of this source repo's own `skills/<category>/`
structure) — a safe assumption given this skill only makes sense once at least those two are
already installed. If either reference file can't be found, the procedure stops immediately with
a clear message naming which skill is missing and the install command to fix it — no silent
fallback to a hardcoded copy that could drift from the real templates.

## Procedure

### 1. Preflight tooling

Before touching any files, check and report:

- `gh auth status` — **hard stop** if not authenticated (every downstream skill needs it, and
  repo detection itself may want `gh repo view`).
- `codex` on `PATH` and authenticated — **warn, don't block** (only blocks the checklist gate's
  `judge:` items and the per-ticket/final review, not setup itself).
- `claude` (or whatever CLI the drafted `agents.yml` will target) on `PATH` — **warn, don't
  block**.
- Whether `superpowers` is enabled for the current account (`enabledPlugins` in
  `~/.claude/settings.json` if readable, else skip the check silently) — **informational only**.
  This is an account-level setting, not a project one (confirmed empirically: it lives in
  `~/.claude/settings.json`, not anything committed to a target repo), so a "not detected" result
  is a note, not a failure — the user may run workers under a different account than this
  session.

Each check prints pass/fail/skip; only the `gh auth` failure halts the procedure.

### 2. Detect project facts

Read, in order of precedence, whichever of these exist: `package.json`, `pyproject.toml`,
`Cargo.toml`, `go.mod`, `Makefile`, `.github/workflows/*.yml`. Extract:

- Language + package manager (npm/pnpm/yarn, pip/poetry, cargo, go modules).
- Real test/lint/build commands — prefer whatever's already wired into CI
  (`.github/workflows/*.yml`) over guessing, since that's the project's own source of truth for
  "this is how we verify this repo." Fall back to package-manager convention (`npm test`, `pytest
  -q`, `cargo test`, `go test ./...`) if no CI config exists.
- Whether the project looks like a long-running server (has a start/serve script, listens on a
  port) — relevant for judge/run checklist items in the style of `test_arena`'s real
  `checklist.yml`, which included a "server boots and responds" check.

Also check whether `.execute-tickets/agents.yml` and/or `.execute-tickets/checklist.yml` already
exist. Existing files are never silently overwritten — see step 5.

### 3. Draft `agents.yml`

Start from `execute-tickets/references/agents.example.yml`'s four tiers (lite/efficient/standard/
flagship, `claude -p` with per-tier `--model`). Tailor `--allowedTools` to what step 2 found —
e.g. `Bash(git *) Bash(npm *)` for a Node project, `Bash(git *) Bash(pytest *)` for Python —
matching the shape already hand-written for `test_arena`. Keep the underlying CLI (`claude -p`)
and prompt bodies as the vendored default; this is about scoping tool access to the repo's real
tooling, not picking a different coding agent.

### 4. Draft `checklist.yml`

Propose `run:` items directly from the test/lint/build commands found in step 2 — e.g. `name: Test
suite passes, type: run, command: "npm test"`. Where the project looks like a server (step 2),
propose a boot-and-respond check in the style of `test_arena`'s real one. Propose one or two
`judge:` items only where they're grounded in something specific about the repo (e.g. "no TODO
left in shipped code" scoped to the actual source directories found, not a generic unscoped
grep) — reasoning about what's actually worth gating this specific repo on, not filling a
template quota.

### 5. Show drafts, confirm, write

Present both drafted files in full. If either target file already exists, say so explicitly and
ask before overwriting (never silently clobber). Only write after the human confirms — this is
the safety mechanism in place of a `--dry-run` flag, since the whole procedure already is the
preview.

### 6. Print the ready-to-paste commands

Ask for (or infer via `gh repo view`) the target `--repo`, the plan slug (`--plan`), and how many
`execute-tickets` workers to include (1–10, from the fixed `alice`..`justin` name list). Render,
via `scripts/print-commands.sh` (see below — kept as a separate deterministic script rather than
free-form agent output, so the exact flag syntax can't drift or get hallucinated):

- The `execute-tickets` worker for-loop (`for W in alice bob ...; do execute-tickets.sh --worker
  "$W" --plan <slug> ... & done; wait`), sized to the requested worker count.
- The `epic-manager` singleton command (`epic-manager.sh --plan <slug> --repo <owner/repo>
  --once`).

Print both plus a one-line pointer to `execute-tickets/references/warp-setup.md` and
`epic-manager/references/warp-setup.md` for wiring either into Warp specifically, rather than
duplicating that content a third time.

## Files

```
skills/delivery-pipeline/init-delivery-pipeline/
├── SKILL.md                    # frontmatter + full procedure above
├── scripts/
│   └── print-commands.sh       # pure templating: given --plan/--repo/--workers N, print the
│                                # two ready-to-paste commands. No gh/codex calls — this is the
│                                # only piece of this skill that's mechanically testable.
└── tests/
    ├── run.sh
    └── lib.sh
```

No `references/` directory — this skill reads other skills' reference files (see Dependencies
above) rather than shipping its own templates, to avoid a second copy that can drift from the
real ones.

## Flags (`scripts/print-commands.sh`)

| Flag | Effect |
|--|--|
| `--plan <slug>` | Plan slug (required). |
| `--repo <owner/repo>` | Target repo (required). |
| `--workers <N>` | Number of `execute-tickets` workers to include, 1–10 (default: 10). Names taken in order from the fixed `alice`..`justin` list, matching `execute-tickets.sh`'s own cap. |
| `--help` | Show help. |

## Tests

`print-commands.sh` is the only fixture-testable surface (no `gh`/`codex` calls to fake — pure
string templating):

1. `--workers 1` still emits the `for W in alice; do ...; done; wait` loop form, not a bare
   single-line command — one code path for all worker counts, no special case at `N=1`.
2. `--workers 10` emits all ten names in the fixed order, capped — `--workers 11` (or any value
   above 10) errors rather than silently clamping or inventing an 11th name.
3. Missing `--plan` or `--repo` errors with a clear message; neither has a default (no invented
   defaults for values that must be correct or the printed commands are wrong).
4. The `epic-manager.sh --once` line is always emitted exactly once regardless of `--workers`.
5. Output is byte-for-byte diffed against a fixed expected string per case — this is the one part
   of the skill where "looks right" isn't good enough, since a wrong flag name here would be
   silently copy-pasted into a real cron job.

The detection (step 2) and drafting (steps 3–4) are agent judgment, not fixture-testable — same
category as `plan-to-tickets`'s own ticket-body drafting, which also has no automated test beyond
`create-tickets.sh`'s mechanical filing step.

## Open questions deferred to implementation

- **Exact CI-config parsing depth.** Step 2 reads `.github/workflows/*.yml` for existing
  test/lint commands where present. How much YAML-structure parsing that needs (vs. just
  `grep`-ing for `run:` lines under a job) is an implementation detail — start with the simpler
  `grep` approach, only add real YAML parsing if it proves too lossy in practice.
- **`--allowedTools` beyond the package manager.** Step 3 scopes tool access to the detected
  package manager's own command (`npm`, `pytest`, `cargo`, `go`). Whether to also detect and add
  common adjacent tools (e.g. `docker`, `make`) is left to implementation judgment per project,
  not a fixed rule.
