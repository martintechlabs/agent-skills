# epic-manager — Design

**Date:** 2026-07-22
**Category:** `coding`
**Status:** Approved design, pending spec review

## Purpose

A singleton skill that supervises a `plan-to-tickets` epic end-to-end: tracks
executor progress, gates the epic→`main` PR behind a per-project checklist,
runs a final integration review, and obeys human commands posted as comments
on the epic issue (`ship it`, `rework:`, `abandon`).

`execute-tickets` stops at the epic branch boundary — it merges ticket PRs
into `epic/<slug>` and never creates a reviewable PR into `main`. That leaves
a gap: there is no component that (a) detects when the backlog is drained,
(b) decides the epic is ready for a human to review, (c) opens the final
epic→`main` PR, or (d) acts on the human's review decision. Today that gap
is filled by a human watching the epic branch and hand-merging it — which
defeats the purpose of an automated executor and produces no audit trail.

`epic-manager` fills the gap at the right level of abstraction. The executor
is a ticket-level worker that structurally cannot observe plan-level state
(a worker sees one ticket, never the whole plan). The manager exists at the
plan level, where "all tickets closed," "checklist satisfied," and "human
approved" are real, detectable states. It is a separate process with a
separate cadence (slow, plan-granular) and a separate lock namespace
(`lock:manager`), communicating with executors through GitHub state only —
labels, issue/PR state, comments. No IPC, no shared filesystem.

## Non-goals

- **Re-planning.** When the decomposition itself is wrong, the manager
  cannot fix it. It surfaces the problem (`needs-human`) and points at
  `plan-to-tickets`. Re-planning is a human + plan-to-tickets action.
- **Assigning tickets to workers.** Executors self-serve via `lock:*` labels.
  The manager observes who has what, it does not dispatch.
- **Auto-merging without human approval.** The epic PR is never merged until
  a human posts a `ship it` command. The manager is the mechanism by which
  the human's approval becomes a merge, not a substitute for that approval.
- **Touching individual tickets.** The manager reads ticket state for
  progress reporting and (for `rework:`) files new tickets, but it never
  edits, closes, or labels an existing ticket issue. Ticket lifecycle is
  the executor's job.
- **Coordinating across plans or repos.** One invocation, one plan, one
  repo. Same scope boundary as `execute-tickets`.

## The human↔manager interface: comments are intent, labels are state

Labels are machine-internal state the manager uses to avoid re-doing work
(`lock:manager`, `needs-human`, `checklist-failed`). Comments are the
human's natural-language interface: the manager posts its actions and
observations as comments, the human speaks in comments, the manager parses
comments for commands. The whole human↔manager conversation lives in one
readable thread on the epic issue, top to bottom.

A command is a comment whose **first line** is a recognized trigger phrase
(case-insensitive, several aliases per intent). Free-form discussion in
other comments is ignored.

## The loop

```
1. Acquire lock:manager on the epic issue (singleton). Can't → exit.
2. Reconcile plan state from GitHub:
   - open tickets carrying this plan's marker, grouped:
       in-progress (any lock:* label)  needs-human  ready  closed
   - if any ready OR in-progress → post a progress comment + release + exit
     (executors are still working; the manager has nothing to do)
3. Backlog drained (no ready, no in-progress; only closed + maybe needs-human):
   a. Hybrid checklist gate (see below). Any fail → no PR, post actionable
      failures on the epic issue, set needs-human, release, exit.
   b. Open epic→main PR, idempotent (check for an existing open one first).
      Body = ticket roster + checklist summary + reviewer model used.
      Closes #<epic> (works because the PR targets main, the default branch).
   c. Run final integration review (codex, advisory, holistic). Post findings
      as a comment on the epic issue + a summary on the PR. Blocking findings
      → loud comment, but PR stays open — the human merges, not the manager.
4. Parse human commands from epic issue comments since last manager visit
   (see command surface below).
5. Release lock:manager.
```

Run as `--once` per cron firing (the WARP.md pattern) or in a slow loop
(`--poll`, default 300s — slower than the executor's 30s because plan-level
state changes less frequently and the manager has no ticket work of its own
to do).

## Singleton coordination

`lock:manager` on the epic issue, acquired at start, released at end. A
firing that cannot acquire it exits cleanly (the previous firing is still
running). This is the same label-lock pattern `execute-tickets` uses for
ticket claims, just at the plan level with a dedicated label that lives
outside the executor's `lock:<name>` namespace.

If a manager firing crashes without releasing the lock (process killed,
host died), the lock is stale. Recovery: a subsequent firing detects the
lock, checks the age of the lock-acquisition comment, and after a
configurable staleness threshold (default 1h) force-claims it (removes the
old label, adds its own, posts a "recovered stale lock" note). The
manager never runs two instances against the same epic.

## Hybrid checklist gate

Per-repo checklist at `.execute-tickets/checklist.yml`. No file → skip the
gate entirely (backwards-compatible; repos without one go straight to the
epic PR). The manager ships the mechanism, not the rules — every repo has
different "is this kosher" criteria.

```yaml
pre_pr_checks:
  - name: CHANGELOG updated
    type: run
    command: "git diff --name-only origin/main...HEAD | grep -q CHANGELOG.md"
  - name: No TODO in shipped code
    type: run
    command: "! grep -rn 'TODO' src/"
  - name: Public API has documentation
    type: judge
    instruction: "Every new or modified public function has docstring documentation."
  - name: Error messages are actionable
    type: judge
    instruction: "Error messages guide the user toward a fix, not just describe the failure."
```

**Evaluation:**

- `run:` — execute in a worktree checked out at the epic branch tip. Exit 0
  = pass. Deterministic, fast, cheap. Output captured for the failure
  comment if non-zero.
- `judge:` — compose a prompt (epic diff + the instruction), run
  `codex exec --output-schema` with a new judgment schema
  (`{passed: bool, reasoning: str, confidence: number}`), get pass/fail +
  reasoning. Reuses the executor's `codex exec --sandbox read-only` pattern
  but with a simpler schema — this is a yes/no judgment, not a findings list.
- `name:` is required and used in the failure comment; `command:` /
  `instruction:` is required per type.

**Failure behavior:** any item fails → epic PR does **not** open. The
failure comment on the epic issue is **actionable**: for each failed item,
name, type, the command or instruction, the failure output (for `run:`) or
codex's reasoning + confidence (for `judge:`), and a one-line "what to do"
suggestion where obvious. The epic issue gets `needs-human` **and**
`checklist-failed` (so `gh issue list --label checklist-failed` distinguishes
"checklist failed" from other `needs-human` reasons without reading comments).
The user fixes the issues, removes both labels, and the next manager firing
re-runs the gate from scratch.

A malformed checklist file (bad YAML, unknown type, missing field) is
treated as a hard failure: no PR, `needs-human`, and the failure comment
names the parse error with the file path and line. The manager never
silently skips a checklist it can't understand.

## Final integration review

Distinct from per-ticket review, not a duplicate. Per-ticket review is
scoped to the ticket (the reviewer prompt explicitly says "don't flag
out-of-scope things"), so integration concerns are *out of scope by design*.
The final review's whole job is the integration view: do these N tickets
collectively implement the spec? Gaps between tickets, conflicts,
cross-cutting bugs no per-ticket review could catch.

- Runs after the epic PR opens, against the full epic…main diff.
- Uses a **different prompt and schema** than per-ticket review — the rubric
  is holistic ("does this implement the spec end-to-end?"), not scoped to a
  ticket.
- **Advisory to the human.** Findings post as a comment on the epic issue
  and a summary on the PR. Blocking findings (priority 0/1, same threshold
  as the executor) get a loud `review-blocked` comment (a clearly-marked
  comment, not a label — the label set stays minimal), but the PR stays
  open — the human decides whether to `ship it`, `rework:`, or `abandon`.
- The manager never prevents merge based on the final review. It surfaces
  findings; the human acts on them.

**Size caveat:** the cumulative epic diff could be large. v1 starts with one
codex call on the full diff. If context limits become a problem in
practice, chunk by directory and merge findings — deferred until we see it
fail, not built speculatively.

## Command surface

Human commands are comments on the epic issue, first line = trigger:

| Human comment (first line) | Manager action |
|--|--|
| `ship it` / `#shipit` / 🚀 / `lgtm` / `merge it` | Guard: no open rework-filed tickets, no in-progress `lock:*` on any ticket. Re-verify CI green on the epic PR. Merge `--squash --delete-branch --auto`. Post confirmation with merge SHA. |
| `rework [#N]: <description>` | Codex picks metadata (priority/complexity/model-tier) from the description + epic context. File a new ticket issue with the plan marker, "Refines #N" if `#N` referenced, the codex-chosen labels, and a "Filed by manager from rework request" note. Post a filing comment with codex's reasoning + retune hints. Reset any prior `ship it` approval (see below). |
| `abandon` | Close the epic PR. Close the epic issue as "not planned." Post a final summary comment. |
| *(other comments)* | Ignored — free-form discussion. |

### `rework:` details

"Rework" is never "redo ticket #42." By the time a ticket is merged into
the epic it is done; rework means **file a new ticket** that refines or
supersedes prior work. `rework #42: change the button to blue` files a new
ticket whose body says "Refines #42" for executor context, but #42 stays
closed and is never touched.

The new ticket's metadata is chosen by **codex**, not static defaults. The
manager invokes `codex exec --output-schema` with a small schema
(`{priority, complexity, model_tier, reasoning}`) against the rework
description + epic context, and applies the returned labels. The filing
comment includes codex's reasoning and **retune hints**: "Filed #N as
priority:p1, complexity:medium, model-tier:standard. If this touches
security or large refactors, consider `model-tier:flagship` /
`complexity:large`; edit the issue labels to retune before an executor
picks it up." The human can adjust labels on the issue directly before an
executor claims it (`pick_candidate` only takes unassigned, un-locked,
non-`needs-human` issues).

The epic PR stays open across reworks — it is a living review surface that
accumulates the full history of what the epic became. The new ticket
merges into the epic branch, the PR diff auto-updates, and the manager
posts "diff changed since last review, re-review required."

### Approval-reset invariant

Any merge into the epic branch **after** a `ship it` invalidates that
approval. The manager detects the new merge (comparing the epic branch SHA
recorded at `ship it` time to the current tip), posts "diff updated since
`ship it`, please re-review," and will not merge until a fresh `ship it`
appears. This is what makes keeping the PR open across reworks safe: the
human's approval always refers to a specific diff state, and any change
forces re-confirmation.

The manager guards `ship it` against in-flight work: if there are open
rework-filed tickets or any ticket carrying a `lock:*` label, `ship it` is
held with a comment ("waiting on #N, #M to finish") rather than executed.

## Audit pattern

All manager actions post as comments on the **epic issue** — same
durable-trail principle as the executor's ticket comments. A human opening
the epic issue sees, top to bottom: every progress check, every checklist
result, the epic PR opening, the final review findings, their own commands,
and the manager's responses. No logs needed; the issue *is* the audit
trail.

Progress comments are named-worker aware: "alice merged #42 (1 iteration);
bob in progress on #43" rather than "worker 1 / worker 2." The manager
observes `lock:*` labels generically (it does not care whether the executor
uses names or numbers), but reads the names for human-readable reporting.

## Files and components

- `skills/coding/epic-manager/SKILL.md` — the skill description, when-it-
  applies, loop overview, flag reference, command surface.
- `skills/coding/epic-manager/scripts/epic-manager.sh` — the singleton loop,
  state reconciliation, checklist gate, epic PR creation, final review,
  command parser, audit comments.
- `skills/coding/epic-manager/references/checklist-schema.json` — JSON
  schema for the `.execute-tickets/checklist.yml` validation (the YAML is
  parsed by the script; this schema documents the contract and is used by
  any future validator).
- `skills/coding/epic-manager/references/final-review-prompt.md` — the
  holistic integration-review system prompt (distinct from the executor's
  per-ticket `codex-review-prompt.md`).
- `skills/coding/epic-manager/references/final-review-schema.json` — the
  integration-review output schema (findings + overall_correctness, same
  shape as the per-ticket schema but with the holistic prompt).
- `skills/coding/epic-manager/references/metadata-guess-schema.json` — the
  `{priority, complexity, model_tier, reasoning}` schema for codex's rework
  metadata guess.
- `skills/coding/epic-manager/references/metadata-guess-prompt.md` — the
  prompt for the metadata guess.
- `skills/coding/epic-manager/WARP.md` — cron wiring for `--once` per
  firing (mirrors the executor's WARP.md).
- `README.md` and `skills.sh.json` — list the new skill.

## Flags (`scripts/epic-manager.sh`)

| Flag | Effect |
|--|--|
| `--plan <slug>` | Plan slug (required). Same as `execute-tickets`. |
| `--repo <owner/repo>` | Target repo (default: current repo via `gh repo view`). |
| `--checklist <path>` | Override checklist file (default: `.execute-tickets/checklist.yml` at repo root). |
| `--reviewer-cmd <cmd>` | Final-review codex command (default: `codex exec --sandbox read-only ...`). |
| `--final-review-schema <path>` | Override final-review schema (default: vendored). |
| `--final-review-prompt <path>` | Override final-review prompt (default: vendored). |
| `--block-priority-max <N>` | Findings at or below this priority are flagged as blocking in the review comment. Default: 1. |
| `--poll <seconds>` | Sleep between cycles in loop mode. Default: 300. |
| `--stale-lock-threshold <seconds>` | Force-claim `lock:manager` after this staleness. Default: 3600. |
| `--once` | Run one cycle, then exit (cron mode). |
| `--dry-run` | Print the reconciled state + intended actions; do not claim/comment/open-PR/review/merge. |
| `--quiet` | Reduce stderr logging. Epic-issue audit comments always post. |
| `--help` | Show help. |

## Relationship to `execute-tickets`

The manager is a **peer**, not a replacement. Both run on cron; they
coordinate through GitHub state:

- Executors claim tickets via `lock:<name>`, merge ticket PRs into the epic
  branch, post ticket audit comments, set `needs-human` on tickets that
  fail.
- The manager claims the epic via `lock:manager`, observes executor state,
  gates the epic PR, runs the final review, and acts on human commands.
- Neither knows the other exists. Both read the same issue/PR/label state.
- The manager never touches `lock:<name>` labels or ticket issues (except
  filing new tickets for `rework:`). Executors never touch `lock:manager`
  or the epic PR.

A repo running both: executors on one cron cadence (fast, `--once` per
firing), the manager on another (slow, `--once` per firing). WARP.md covers
the wiring for each.

## Tests

The shell test suite (`tests/run.sh` + `tests/fake-gh` + `tests/fake-codex`,
mirroring the executor's test layout) will prove:

1. **Singleton lock.** Two concurrent firings: one acquires `lock:manager`,
   the other exits cleanly without mutating state. A stale lock past
   `--stale-lock-threshold` is force-claimed with a recovery comment.
2. **Reconciliation.** With ready or in-progress tickets, the manager posts
   progress and exits without opening a PR. With a drained backlog, it
   proceeds to the checklist gate.
3. **Checklist gate — `run:` pass/fail.** A passing `run:` item lets the
   PR open; a failing one blocks the PR and posts an actionable failure
   comment (command + output + suggestion) + `needs-human`.
4. **Checklist gate — `judge:` pass/fail.** A `judge:` item that codex
   returns `{passed: true}` lets the PR open; `{passed: false}` blocks
   with codex's reasoning in the comment.
5. **Malformed checklist.** Bad YAML / unknown type / missing field → no
   PR, `needs-human`, failure comment names the parse error + file:line.
6. **No checklist file.** Repo without `.execute-tickets/checklist.yml` →
   gate skipped, PR opens directly (backwards-compatible).
7. **Epic PR idempotency.** A second cycle with an already-open epic PR
   does not create a duplicate.
8. **Final review.** After PR open, codex is invoked with the holistic
   prompt + epic diff; findings post on the epic issue + PR summary.
   Blocking findings produce a loud comment but do not close the PR.
9. **`ship it` happy path.** Human `ship it` → guard passes (no open
   rework, no in-progress) → CI re-verified green → PR merged `--squash
   --delete-branch --auto` → confirmation comment with SHA.
10. **`ship it` guards.** `ship it` with an open rework ticket → held with
    a "waiting on #N" comment, no merge. `ship it` with an in-progress
    `lock:*` ticket → same.
11. **Approval reset.** A `ship it` recorded, then a new merge into the
    epic branch (simulating a rework ticket landing) → manager posts
    "diff changed, re-review required" and will not merge on the stale
    `ship it`.
12. **`rework:` filing.** Human `rework: change the button to blue` →
    codex invoked for metadata → new ticket filed with plan marker + codex-
    chosen labels → filing comment includes reasoning + retune hints →
    prior `ship it` reset.
13. **`rework #N:` reference.** `rework #42: ...` → new ticket body
    contains "Refines #42"; #42 stays closed and untouched.
14. **`abandon`.** Human `abandon` → epic PR closed, epic issue closed
    "not planned," final summary comment posted.
15. **Command parsing robustness.** `Ship It`, `#SHIPIT`, 🚀 alone,
    `lgtm`, `merge it` all recognized. Free-form comments ignored. A
    `ship it` buried on line 3 of a comment is ignored (only first line
    is a command).
16. **Named-worker awareness.** Progress comments report `lock:alice` /
    `lock:bob` as "alice" / "bob", not as slot numbers.

## Open questions deferred to implementation

- **Chunked final review.** If the epic diff exceeds codex's context
  window, chunk by directory and merge findings. Deferred until observed
  in practice — v1 ships one call on the full diff.
- **Checklist file discovery.** v1 reads `.execute-tickets/checklist.yml`
  at the repo root only. Per-plan overrides (`.execute-tickets/<slug>-checklist.yml`)
  are a future expansion if needed.

## Non-goals revisited

- No re-planning, ticket assignment, auto-merge-without-approval,
  per-ticket lifecycle, or cross-plan/repo coordination (see Non-goals).
- No executor-side epic-PR hack shipped as a stopgap. The manager is the
  sole owner of epic PR creation; `execute-tickets` continues to stop at
  the epic branch boundary unchanged.
- No new escalation label. The manager reuses `needs-human` (same label,
  same meaning, plan-level observer) and differentiates via comment body.
