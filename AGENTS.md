# AGENTS.md

## What this repo is

This is **not** an application — there's no server, no build, no database. It's a
collection of [Agent Skills](https://agentskills.io/) for Claude Code and other
skill-aware agents: each skill is a directory under `skills/<category>/<skill-name>/`
containing a `SKILL.md` (YAML frontmatter + Markdown instructions) plus optional
`scripts/`, `references/`, and `tests/`. Consumers install skills with
`npx skills add martintechlabs/agent-skills`. Several skills (`plan-to-tickets`,
`execute-tickets`, `epic-manager`) shell out to `gh` and `codex`/coding-agent CLIs and
mutate real GitHub state (issues, labels, PRs) in whatever repo they're pointed at —
treat those as live-system tooling, not sandboxed scripts.

## Operating mode

Every skill in this repo was built through the superpowers workflow: brainstorm → spec
→ plan → implement. `docs/superpowers/specs/YYYY-MM-DD-<skill>-design.md` and
`docs/superpowers/plans/YYYY-MM-DD-<skill>.md` exist in pairs for every skill here —
that's not incidental, it's how work happens in this repo. A new skill or a
non-trivial change to an existing one gets a spec + plan before implementation, same
as everywhere else superpowers is used.

Skills here get validated against **real repos** before being considered done, not
just unit-tested in isolation. `BACKLOG.md` exists specifically to hold non-blocking
findings surfaced during that real-repo validation — deliberately deferred rather than
scope-creeping the PR that found them. If you validate a skill live and find a
tangential issue, prefer adding it to `BACKLOG.md` over pulling it into your current
change.

## Autonomy policy

Safe to do without asking:
- Add, edit, or fix a skill's `SKILL.md`, `scripts/`, or `references/`.
- Run a skill's own test suite (`tests/run.sh` — fake `gh`/`codex`, no network).
- `bash -n` syntax-check any shell script before running it live.
- `--dry-run` invocations of any skill script — every skill that mutates GitHub state
  ships one; use it first, always.
- Read-only exploration of a target repo (e.g. `gh issue list`, `gh pr view`).

Needs explicit confirmation first:
- Any live invocation of `plan-to-tickets`, `execute-tickets`, or `epic-manager`
  against a real repo that files issues, opens/merges PRs, closes issues, or edits
  labels — dry-run it first, show the human what it would do, then proceed.
- Merging a PR in this repo (`gh pr merge`) — even one you authored yourself. Treat
  "let's ship this" as "push it and get it PR-ready," not "merge it," unless merging
  is named explicitly.
- Deleting branches, closing issues, or force-pushing on any repo other than a
  disposable local worktree you created for testing.
- Widening what an unattended coding-agent subprocess is allowed to run
  (`--dangerously-skip-permissions`, broad `--allowedTools` grants) — this changes the
  security posture of whatever's invoking it; confirm the scope with the human first.

## Decision rules

- Ambiguous or creative work (new skill design, a behavior change to an existing
  skill's control flow) gets a clarifying question or a brainstorm/spec pass before
  code — don't jump straight to implementation on a fuzzy ask.
- When a live validation run surfaces a real bug in a skill's script (not the thing
  you were testing), fix it at the root rather than working around it in the test —
  this repo's own tooling is fair game to fix, same as application code would be.
- When you find yourself repeatedly re-deriving the same workaround during a live
  test (an env var, a permission flag, a CLI quirk), that's a signal the skill's
  `SKILL.md` or a reference doc is missing it — document it, don't just remember it.

## Subagent policy

Skills here are largely independent of each other (different directories, no shared
runtime state) and mutation-heavy skills already isolate execution per ticket/worker
via git worktrees. That makes parallel dispatch a good fit:
- Auditing, reviewing, or testing multiple skills → one subagent per skill, dispatched
  in a single batch (see `CTO-PROMPT.md` for the pattern this repo already uses to run
  CTO-toolkit skills concurrently against a target repo).
- A `plan-to-tickets` → `execute-tickets` backlog is explicitly designed for
  concurrent workers (up to 10, named `alice`.."justin") — use that concurrency when
  actually executing a backlog, not sequential one-at-a-time runs.

Skip subagents for: editing a single `SKILL.md` section, a one-line script fix, or
tightly-coupled debugging of a live failing run (you need the full trace in your own
context, not summarized back from a subagent).

## Validation strategy

No repo-wide test command — each skill validates independently:

```bash
bash skills/<category>/<skill-name>/tests/run.sh
```

Present on at least `epic-manager`, `execute-tickets`, `plan-to-tickets`, and
`github-lockdown`. These are plain-bash suites against `fake-gh`/`fake-codex`/`fake-yq`
fixtures in each skill's `tests/` dir — no network calls, no real GitHub state. A test
result line looks like `ok   <description>`; grep for `not ok` to find failures (the
harness in some skills prints a stray `0 passed, 0 failed` line before the real
results run — that's a known quirk of the runner, not a signal of anything).

Before trusting a fixture-based test result for anything that touches `gh` output
shape: verify the fixture matches what real `gh` actually returns (field names,
casing) — a fixture drifting from reality is exactly how a real bug (case-sensitive
`state` comparison, real `gh` returns `"OPEN"`/`"CLOSED"` uppercase) can pass 41/41
tests while being broken in production. When in doubt, spot-check the real `gh`
command's JSON output shape, not just the fixture's.

For a skill whose whole job is mutating live GitHub state, the test suite is
necessary but not sufficient — a live `--dry-run` (or, with explicit confirmation, a
live run against a disposable sandbox repo) is what actually validates it end-to-end.

## Tooling

No package manager in the JS sense — nothing here is an npm package. `.tool-versions`
pins a Node version for skills whose *target* repos need it at runtime (e.g. testing
a Node app that `execute-tickets` built), not for this repo's own tooling. Everything
in this repo itself is bash (`skills/**/*.sh`) plus the occasional CLI dependency a
skill shells out to (`gh`, `jq`, `yq`, `codex`, `git`).

External CLI auth a live run needs, verified before you rely on it working:
- `gh auth status` must be green for anything touching GitHub.
- `codex` needs its own auth; if it's a ChatGPT-plan login rather than an API key, the
  default `gpt-5-codex` model in `execute-tickets`/`epic-manager`'s reviewer commands
  may not be available — check `~/.codex/models_cache.json` for what's actually
  supported under the current auth and pass `CODEX_MODEL=<supported-model>` rather
  than assuming the default works.
- Unattended coding-agent subprocesses (`claude -p ...` invoked by `execute-tickets`)
  need `--permission-mode acceptEdits` *and* an explicit `--allowedTools` grant for
  whatever Bash they're expected to run (git, the target repo's test runner) —
  `acceptEdits` alone does not cover Bash tool calls, and a headless agent with no one
  to approve a prompt will just stall silently.

## Environment variables

No `.env` files in this repo — it doesn't run a service. `CODEX_MODEL` (see above) is
the one environment variable worth knowing about; it's read by the vendored reviewer
commands in `execute-tickets` and `epic-manager` with `${CODEX_MODEL:-gpt-5-codex}`.

## Implementation guidelines

- New skill: `skills/<category>/<skill-name>/SKILL.md`, `<skill-name>` matching the
  frontmatter `name` exactly. Pick a category matching an existing
  `skills.sh.json` grouping, or add a new grouping if none fit — folder and grouping
  must agree (nothing enforces this automatically; see README's "Repository layout").
- Frontmatter: `name` and `description` required, `metadata.author` +
  `metadata.version` expected. **Bump `metadata.version` in the same change that ships
  a meaningful fix or feature to that skill — not as a follow-up.** Follow this repo's
  existing semver-ish convention (patch for small fixes, minor for new capabilities;
  `execute-tickets` is at 0.6.0, `plan-to-tickets` at 0.3.0 after iterating). If a
  version-carrying PR already merged without the bump (branch protection can force
  this if it's caught late), a small immediate follow-up PR is the fallback — not a
  reason to skip the bump.
- `description` is what triggers the skill — lead with what it does, then the
  concrete situations/phrasings that should activate it, and when to prefer a
  different skill instead if there's overlap.
- Supporting material a skill only sometimes needs (long tables, vendored prompts/
  schemas, example configs) goes in `references/`, loaded on demand — keep `SKILL.md`
  itself to the day-to-day procedure.
- Scripts that manage state via hidden markers (e.g. `<!-- plan-to-tickets:ticket:... -->`
  HTML comments in issue bodies) should keep that marker-parsing narrowly anchored —
  a loose regex matching human-readable prose elsewhere in the same body is a real bug
  class in this repo's history, not a hypothetical.
- Bookkeeping comments a skill posts to a GitHub thread (lock markers, dedup markers)
  should carry a human-readable line, not just a hidden HTML comment — a comment that
  renders as blank "No description provided" reads as broken even when it's working
  as designed.

## Review checklist

Before considering a skill change done:
- [ ] `metadata.version` bumped for the skill(s) changed.
- [ ] `tests/run.sh` passes (0 `not ok` lines) if the skill has one.
- [ ] New skill: added to `skills.sh.json`'s matching grouping *and* README's
      "Available skills" table.
- [ ] Any script change that touches `gh`/`codex` invocation shape re-verified with
      `--dry-run` before considering it live-ready.
- [ ] If validated live against a real/sandbox repo: temporary branches, worktrees,
      and test issues/PRs cleaned up (or explicitly left for the human to review).

## References

- `README.md` — full skill-authoring walkthrough ("Adding a new skill"), category
  list, repository layout. Don't duplicate it here; it's the source of truth for the
  mechanics.
- `skills.sh.json` — category groupings/ordering for the skills.sh listing page.
- `docs/superpowers/specs/` + `docs/superpowers/plans/` — design history per skill,
  one pair per skill, useful context before changing one you didn't build.
- `BACKLOG.md` — deliberately-deferred findings from real-repo validation.
- `CTO-PROMPT.md` — the reference pattern for running multiple skills as parallel
  subagents against a target repo.
