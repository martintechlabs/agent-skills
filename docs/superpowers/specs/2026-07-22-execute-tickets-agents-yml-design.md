# execute-tickets agents.yml routing — Design

**Date:** 2026-07-22
**Category:** `coding`
**Status:** Approved

## Purpose

Today `execute-tickets.sh` requires a single `--agent-cmd` for every ticket. Ticket
labels already carry an abstract `model-tier:*` (`lite` / `efficient` / `standard` /
`flagship`) so dispatchers *could* route by capability, but the executor never did —
tier was only a substitution token inside one global command.

This design adds **repo-local agent routing config**: a YAML file that maps each
model tier to a full shell command (any coding CLI — Claude Code, Codex, Pi, Warp,
etc.). Day-to-day runs drop `--agent-cmd` and pick the command for the ticket's tier.
A separate init script scaffolds that file with Claude-oriented defaults so users are
not starting from a blank page.

## Non-goals

- Does not put reviewer configuration in YAML. Review stays `--reviewer-cmd` /
  default `codex exec` (unchanged).
- Does not key routing on `complexity:small|medium`. Complexity stays a label for
  humans and `{complexity}` substitution only; routing keys are model tiers only.
- Does not merge with or edit `.execute-tickets/checklist.yml` (owned by a separate
  concern / agent). This design only coexists under the same directory.
- Does not invent structured per-CLI fields (`agent:`, `model:`, `args:`). Each tier
  value is an opaque shell command string. Teaching the executor every CLI's flag
  surface is out of scope.
- Does not auto-update model IDs when vendors rename models. The example template is
  a snapshot; projects own their edits.
- Does not change claim/lock, worktree, PR, CI, or codex review loop mechanics beyond
  **which command string** is invoked for the coding agent.

## Config location and ownership

| Path | Owner | Purpose |
|------|--------|---------|
| `<repo-root>/.execute-tickets/checklist.yml` | Separate agent / concern | Checklist (out of scope here) |
| `<repo-root>/.execute-tickets/agents.yml` | This feature | Per-tier agent commands |
| `skills/coding/execute-tickets/references/agents.example.yml` | Skill | Vendored Claude-default template used by init |

**Repo root** is `git rev-parse --show-toplevel` from the process working directory
when the executor starts (same root used for the plan manifest today). Config is
read from the **target application repo**, not from the agent-skills install path.

## Schema

`agents.yml` is a flat map of exactly four keys to non-empty string values:

```yaml
# .execute-tickets/agents.yml
# Each value is a shell command run from the ticket worktree.
# Tokens (same as --agent-cmd today; each shell-quoted by the executor):
#   {issue_number} {issue_title} {issue_body}
#   {spec_file} {plan_file}
#   {model_tier} {complexity} {priority}
#   {worktree} {branch}
#   {review_feedback} {iteration}
lite: >
  <shell command for docs/copy/config-only work>
efficient: >
  <shell command for small mechanical code>
standard: >
  <shell command for everyday multi-file integration>
flagship: >
  <shell command for hardest judgment / architecture-adjacent work>
```

Rules:

- Keys must be exactly `lite`, `efficient`, `standard`, `flagship` (the
  `plan-to-tickets` model-tier vocabulary). No extra keys required; unknown extra
  keys are ignored (forward-compatible), not fatal.
- Values must be non-empty strings after YAML parse (block scalars `>` / `|` and
  plain scalars are all fine).
- Token rules for the agent are unchanged: commit on `{branch}`; must not open a PR;
  on `{iteration} >= 2` address only `{review_feedback}`.

## Selection and override

| Situation | Agent command used |
|-----------|-------------------|
| `--agent-cmd` passed | That command for **every** ticket this process runs (global override) |
| No `--agent-cmd` | Command for the ticket's `model-tier` label from `agents.yml` |

`--agent-cmd` remains supported for one-off debugging and for environments that
prefer not to commit routing config. When the flag is set, **`agents.yml` is not
required**.

When the flag is **not** set:

1. Require `<repo-root>/.execute-tickets/agents.yml` to exist.
2. Require `yq` on PATH (hard dependency for this path, same class as `jq`).
3. At **preflight / load time**, require all four keys present with non-empty string
   values. Missing file, unreadable YAML, or any missing/empty tier → hard error
   **before** claiming any ticket. Message must name the path and which keys failed.
4. Per ticket: read `model-tier` from issue labels (existing `label_value` helper).
   If the label is missing or not one of the four tiers → `needs-human` for that
   ticket (do not guess `standard` or fall back silently).

## `scripts/init-agents.sh` (independent)

A **separate** script under `skills/coding/execute-tickets/scripts/init-agents.sh`.
It is **not** a flag on `execute-tickets.sh` and is never called by the executor.

### Responsibility

Scaffold `.execute-tickets/agents.yml` from the skill's vendored Claude-default
template.

### Flags

| Flag | Effect |
|------|--------|
| (none) | Write template to `<repo-root>/.execute-tickets/agents.yml` |
| `--repo-root <path>` | Override repo root (default: `git rev-parse --show-toplevel` or cwd) |
| `--force` | Overwrite an existing `agents.yml` |
| `--dry-run` | Print the would-be file contents to stdout; write nothing |
| `--help` | Usage |

### Behavior

1. Resolve output path: `<root>/.execute-tickets/agents.yml`.
2. Create `.execute-tickets/` if missing. **Never** create, read, or modify
   `checklist.yml`.
3. If `agents.yml` exists and `--force` is not set → exit non-zero with a clear
   message (point at `--force` / `--dry-run`).
4. Copy/render from `references/agents.example.yml` (Claude-oriented defaults for
   all four tiers). Implementation may `cp` the example file as-is so the example
   and the init output stay one source of truth.
5. On success, print the written path and a one-line reminder to edit model flags
   for the org before launching workers.

### Claude defaults (template content)

The example file holds real Claude Code CLI invocations with tier-differentiated
model selection. Exact flags and model identifiers are pinned at implementation
time against current Claude Code CLI docs (not invented here as speculative
strings). Intent of the four defaults:

| Tier | Intent |
|------|--------|
| `lite` | Cheapest/fastest Claude suitable for docs/copy/config |
| `efficient` | Mid-cheap Claude for fully-spec'd small code changes |
| `standard` | Default strong Claude for multi-file integration |
| `flagship` | Strongest Claude for ambiguous / architecture-adjacent work |

Each template command must use the shared `{token}` set and the same agent
commit/no-PR contract documented for `--agent-cmd`.

## Changes to `execute-tickets.sh`

1. **`--agent-cmd` becomes optional** when `agents.yml` can supply commands.
   Argument parsing: missing both flag and a loadable four-tier config → die in
   preflight with remediation (`run init-agents.sh` or pass `--agent-cmd`).
2. **Preflight**
   - Always: existing `gh` / `git` / `jq` / auth checks.
   - If no `--agent-cmd`: require `yq`; load and validate all four tiers; stash
     commands in shell variables or a small assoc map for the process lifetime.
   - If `--agent-cmd` set: skip YAML load (optional: warn if file exists and is
     unused — not required).
3. **`invoke_agent` / dry-run**
   - Resolve `AGENT_CMD_EFFECTIVE` = flag value **or** tier lookup.
   - Dry-run output must show the fully rendered command **and** the source
     (`--agent-cmd` vs `agents.yml#<tier>`).
4. **Audit comments** on the GitHub issue: include agent source and tier (e.g.
   `Agent: agents.yml#flagship · model_tier=flagship · PR #N`) so humans can see
   routing without reading worker logs.
5. **`SKILL.md` / `WARP.md` (or `references/` Warp docs)**: first-time setup points
   at `init-agents.sh`; launch examples show workers **without** `--agent-cmd`
   once config exists; document override behavior.

## Dependencies

| Tool | When required |
|------|----------------|
| `yq` | Loading `agents.yml` (no `--agent-cmd`) |
| `gh`, `git`, `jq` | Unchanged |
| `codex` | Unchanged (reviewer path) |
| Claude Code CLI (`claude`) | Only for the **default template** commands; projects may replace every line with pi/codex/etc. |

No YAML parser reimplementation in pure bash. No second format (JSON twin).

## Tests

Extend `skills/coding/execute-tickets/tests/` (fake-gh harness style):

1. **Preflight fails** without `--agent-cmd` when `agents.yml` is missing.
2. **Preflight fails** when any of the four keys is missing or empty.
3. **Green path** with fixture `agents.yml`: ticket labeled `model-tier:efficient`
   invokes the efficient command (assert via fake agent log / command capture).
4. **`--agent-cmd` override** wins even when `agents.yml` is present (assert the
   flag command ran, not the YAML tier command).
5. **Missing/invalid `model-tier` label** on an otherwise ready ticket →
   `needs-human` (or equivalent flag path), no agent invoke with a guessed tier.
6. **`init-agents.sh`**: writes file under a temp root; second run without
   `--force` fails; `--force` overwrites; `--dry-run` writes nothing.

## Files and components

| Path | Change |
|------|--------|
| `skills/coding/execute-tickets/scripts/execute-tickets.sh` | Optional `--agent-cmd`; load/validate/select from `agents.yml` |
| `skills/coding/execute-tickets/scripts/init-agents.sh` | **New** independent scaffolder |
| `skills/coding/execute-tickets/references/agents.example.yml` | **New** Claude-default template (source of truth for init) |
| `skills/coding/execute-tickets/SKILL.md` | Document config, init, override, `yq` |
| Warp / references docs as applicable | Point at init + config path |
| `skills/coding/execute-tickets/tests/*` | Fixtures + cases above |

## Success criteria

- A repo can run workers with only `--worker` + `--plan` after `init-agents.sh` and
  optional edit of model flags.
- All four tiers must be configured up front when using YAML mode; partial files
  never silently partial-route.
- One-off `--agent-cmd` still works without any YAML.
- Checklist file and agent routing file never couple.
- Existing claim → worktree → agent → PR → CI → codex review → merge loop behavior
  is otherwise unchanged.
