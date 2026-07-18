# plan-to-tickets — Design

**Date:** 2026-07-18
**Category:** `coding`
**Status:** Approved design, pending spec review

## Purpose

A skill that takes a superpowers spec + implementation plan (the `docs/superpowers/specs/...` +
`docs/superpowers/plans/...` pair produced by `brainstorming` and `writing-plans`) and turns it
into a GitHub backlog: one **epic issue** for the top-level spec/plan, and a set of **ticket
sub-issues** that independent workers (out of scope for this skill) can pick up. Each ticket is
tagged with a **complexity** (small/medium), a **suggested model tier** (an abstract capability
level, not a specific model), a **priority**, and its **dependencies** on other tickets, so
workers — human or agent — know what to build, how hard it is, roughly what capability tier fits
it, and what order to build it in.

The skill never dispatches or executes tickets itself. It stops once the backlog exists on
GitHub.

## Non-goals

- Does not execute, assign to, or monitor workers. Picking up and completing tickets is entirely
  out of scope.
- Does not support non-GitHub ticket trackers (Linear, Jira, plain files). GitHub Issues only.
- Never emits a "large"/"hard" complexity ticket. The skill splits oversized work until it fits
  medium-or-smaller; if a unit genuinely cannot be split further (already a single indivisible
  plan step), it is forced into `medium` with a flagged note in the ticket body rather than given
  a `large`/`hard` tag.
- Does not re-run TDD or review workflows on the tickets it creates — that's the concern of
  whatever skill/process the worker uses (e.g. `subagent-driven-development`) once they pick a
  ticket up.
- Not responsible for keeping GitHub issue state in sync with plan-file edits after creation
  (re-running the skill on an edited plan updates the epic/tickets it created, but does not
  diff/merge arbitrary manual edits made on GitHub in the meantime).

## Inputs

- A plan file path (`docs/superpowers/plans/YYYY-MM-DD-<feature>.md`, `### Task N` format from
  `writing-plans`). If not given, look for the most recently modified plan file and confirm with
  the user.
- The plan's paired spec file (`docs/superpowers/specs/YYYY-MM-DD-<feature>-design.md`). Located
  by matching `<feature>` slug; if no match is found, ask the user for the spec path rather than
  proceeding without one (no invented defaults).
- Target repo: current repo's `origin` remote by default (`gh repo view`), overridable.

## Files

```
skills/coding/plan-to-tickets/
├── SKILL.md                      # frontmatter + full procedure (decompose, preview, confirm, file)
├── references/
│   └── model-tiers.md            # editable complexity × task-nature → abstract model-tier table
├── scripts/
│   └── create-tickets.sh         # idempotent gh-CLI mechanics; consumes a JSON ticket-plan
└── tests/
    ├── fake-gh                   # records invocations, returns canned JSON (no network)
    └── run.sh                    # plain-bash test runner
```

Plus:
- A README.md row under the **Coding** table.
- A `skills.sh.json` grouping entry under the `coding` grouping.

## Decomposition algorithm (agent-side reasoning, not scripted)

Read the plan, extract every `### Task N` block (Files + Steps) in order. For each Task, compute
a raw signal:

- **File count** touched (Create + Modify + Test paths listed under `Files:`).
- **Step count** and whether steps are fully mechanical (code given verbatim, matches
  `writing-plans`' "no placeholders" bar) vs. requiring judgment (steps describe an outcome
  without full code, touch multiple existing subsystems, or require reading/understanding code
  not shown in the task).

Classify each raw Task as **tiny**, **right-sized**, or **oversized**, then:

1. **Merge** adjacent tiny Tasks that touch the same file/component and have no independent
   shippable value into one ticket. Never merge across unrelated components merely to reduce
   ticket count.
2. **Split** oversized Tasks along natural seams — the `Files:` boundary (e.g. backend vs.
   frontend, per created file) or step groups that are independently testable. Repeat splitting
   until every resulting unit fits the bound below.
3. **Classify final complexity** per resulting ticket:
   - **small** — 1-2 files, fully spec'd/mechanical, no cross-cutting judgment.
   - **medium** — 3+ files, or requires integration/judgment across existing code, but is still
     one coherent, single-sitting deliverable.
   - If a unit still doesn't fit `medium` after a split pass, split again — down to the
     granularity of a single plan Step if needed. If a single, already-indivisible Step still
     reads as exceeding `medium` (rare — e.g. a step whose own text bundles a large,
     un-decomposed change), stop splitting and force it into `medium`, adding a flagged note in
     the ticket body (e.g. "⚠️ exceeds typical medium scope; could not be split further without
     breaking a single plan step — consider revising the source plan"). `large`/`hard` is never a
     valid output tag; this forced case is the one exception path, and it must be visibly flagged,
     never silent.
4. **Classify task nature**: `text` (docs/copy/config-only files), `mechanical` (isolated
   code change, fully spec'd), or `judgment` (multi-file integration, design decisions not fully
   spelled out) — from file extensions and step content.
5. **Assign a model tier**: cross complexity × task-nature against `references/model-tiers.md`
   (see below) to get the `model-tier:<tier>` label. The skill never names a specific model or
   vendor — it emits an abstract capability tier; mapping a tier to an actual model is left
   entirely to whatever consumes the ticket (e.g. the worker's own dispatch config), so the
   ticket never goes stale as a team's model roster changes.
6. **Compute dependencies**: ticket B depends on ticket A when B's steps read or modify a file
   that A creates, or the plan's own ordering makes B build on A's output. Tickets with no
   file/content overlap and no ordering requirement are independent (parallel-safe) — no
   dependency edge between them.
7. **Compute priority**: `p1` for tickets that are on the critical path or block multiple other
   tickets, `p2` for normal work, `p3` for optional/polish/cleanup work called out as such in the
   plan or spec. This is a proposal, adjustable at the preview gate (step below).

## Preview / confirmation gate

Filing GitHub issues is a visible, shared-state action. Before creating anything, the skill
renders a table — ticket title, complexity, task nature, model tier, priority, dependencies — for the
whole backlog (epic + all tickets) and asks for explicit confirmation. Nothing is created until
the user approves. If the user requests changes (re-bucket a ticket, change a model tier, change
priority), apply them and re-render before proceeding.

## GitHub mechanics

**Epic issue:**
- Title: the spec's feature name.
- Body: goal + architecture summary (from the spec), links to the committed spec and plan files,
  a compact reference table of tickets (title, complexity, model tier, priority).
- Hidden marker comment: `<!-- plan-to-tickets: docs/superpowers/plans/<plan-file> -->` — used to
  detect a prior run of this skill against the same plan (idempotent: update the existing epic
  and its tickets instead of creating duplicates).
- Label: `epic`.

**Ticket sub-issues:**
- Body is self-contained per `writing-plans`' "assume zero context" bar: the concrete files and
  steps/code for that ticket's scope (reconstructed from the merged/split plan Tasks), not just a
  pointer to the plan. Includes a `Depends on: #N, #M` line when dependencies exist, and a `Part
  of #<epic>` line.
- Labels: `complexity:small` or `complexity:medium`, `priority:p1`/`p2`/`p3`,
  `model-tier:<tier>` (one of the four tiers from `references/model-tiers.md`).
- Parent/child relationship: GitHub's native sub-issues API
  (`gh api repos/{owner}/{repo}/issues/{epic}/sub_issues -f sub_issue_id=<ticket>`), giving a
  real progress bar and nested list on the epic. If the API is unsupported (older GHES, feature
  disabled), fall back to a checkbox list (`- [ ] #N <title>`) in the epic body instead — and
  report the fallback explicitly rather than silently proceeding as if native linking worked.
- Any missing label (`complexity:small`, `complexity:medium`, `priority:p1`, `priority:p2`,
  `priority:p3`, `model-tier:<tier>` per tier in use, `epic`) is created on first use.
- Dependency ordering guarantees ticket A (a dependency) is always created before ticket B (its
  dependent), so `Depends on:` can always reference a real, already-created issue number.

**Idempotency:** re-running the skill against the same plan file finds the existing epic (via the
marker comment) and updates it and its tickets in place rather than creating duplicates. This
mirrors `github-lockdown`'s upsert-by-marker approach.

## `references/model-tiers.md`

An editable markdown table, complexity × task-nature → **abstract model tier**. No specific model
or vendor name ever appears here or on a ticket — only a capability tier. Mapping a tier to an
actual model is a decision for whatever dispatches the ticket, made separately from this skill.

Four tiers cover the space, because text-only work, mechanical code, everyday integration, and
judgment-heavy work each demand a genuinely different capability level:

- **`lite`** — no code-reasoning required: docs, copy, config-only changes.
- **`efficient`** — cheap but code-capable: small, fully-specified, mechanical code changes.
- **`standard`** — everyday integration work: multi-file but well-understood, moderate judgment.
- **`flagship`** — the hardest judgment calls: architecture-adjacent decisions, ambiguous specs,
  cross-cutting design.

Default cross table (all `small`/`medium` × `text`/`mechanical`/`judgment` combinations; the two
marked *rare* are edge cases folded into the nearest neighboring tier rather than earning a
distinct fifth tier):

| complexity | task nature | model tier             |
|-----------|-------------|--------------------------|
| small     | text        | `lite`                   |
| small     | mechanical  | `efficient`              |
| small     | judgment    | `standard` *(rare)*      |
| medium    | text        | `efficient` *(rare)*     |
| medium    | mechanical  | `standard`               |
| medium    | judgment    | `flagship`                |

This table is editable — a project can rename tiers, collapse them, or add one back — but ships
with this 4-tier default since it's the smallest set that distinguishes every case this skill's
own complexity/nature axes actually produce.

## `scripts/create-tickets.sh`

Mechanical GitHub calls only — no decomposition logic. Takes a JSON ticket-plan (epic + tickets
with labels/body/dependencies, in creation order) produced by the agent's reasoning above.

**Preflight (no invented defaults — clear errors with remediation):**
- `gh auth status` succeeds.
- `jq` is installed.
- Caller can create issues on the target repo.

**Behavior:**
- `--dry-run`: print every planned `gh` call (label creation, issue creation, sub-issue linking)
  without executing.
- Real run: ensure labels exist → find-or-create epic (by marker comment) → for each ticket in
  dependency order, find-or-create the issue (by a similar marker in its body, keyed to
  epic+ticket-slug) → link as sub-issue of the epic (native API, falling back to a checkbox line
  on failure) → print created/updated issue numbers.
- Idempotent: safe to re-run against the same ticket-plan JSON.

## Tests (`tests/run.sh`)

Plain-bash runner (no `bats` dependency), matching `github-lockdown`'s harness. PATH-shims a fake
`gh` that records invocations and returns canned JSON (no network), asserting:

1. `--dry-run` prints the expected label/issue/sub-issue calls without executing anything.
2. First run creates the epic and every ticket issue with the right labels and body content
   (including `Depends on:` lines referencing real issue numbers from earlier in the same run).
3. Re-running against the same ticket-plan JSON finds the existing epic (via marker) and updates
   rather than duplicates.
4. Sub-issue linking calls `gh api .../sub_issues` with the correct epic/ticket ids.
5. When the sub-issues API call fails/is unsupported, the script falls back to a checkbox line in
   the epic body and reports the fallback (non-silent).
6. Missing `gh` auth or missing `jq` fails preflight with a non-zero exit and a remediation
   message.

## Output manifest

After a successful (non-dry-run) filing, write
`docs/superpowers/tickets/<plan-slug>.md` — epic issue number/link, each ticket's issue
number/link plus its complexity/model-tier/priority/dependencies — and commit it alongside the spec
and plan, for the same traceability those already get.

## Open decisions (proceeding with these unless vetoed)

- **Name:** `plan-to-tickets`.
- **Category:** `coding`.
- **Test harness:** plain-bash `tests/run.sh`, fake-`gh` (no `bats`, no network) — matching
  `github-lockdown`.
- **Model tier count:** 4 (`lite`, `efficient`, `standard`, `flagship`) — the smallest set that
  distinguishes every complexity × task-nature combination this skill produces. No specific model
  or vendor name ever appears on a ticket.
