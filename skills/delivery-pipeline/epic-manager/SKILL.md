---
name: epic-manager
description: >-
  Supervise a plan-to-tickets epic end-to-end: track executor progress, gate the
  epic->main PR behind a per-project hybrid checklist (run: shell + judge: codex),
  run a final integration review, and obey human commands (ship it / rework: /
  abandon) posted as comments on the epic issue. Singleton (lock:manager), runs
  on cron or in a slow loop. Peer to execute-tickets; communicates through
  GitHub state only. Use when execute-tickets has merged ticket PRs into the
  epic branch and you want the epic shepherded to a reviewable PR on main with
  a final review and human merge approval. Omit --plan for repo-wide mode,
  processing one open epic per cycle, stalest-first -- ideal for a single
  long-running manager process covering the whole repo. Never re-plans,
  assigns tickets, auto-merges without human approval, or touches individual
  ticket issues (except filing new ones for rework:).
metadata:
  author: stephen-martin
  version: "0.3.0"
---

# Supervise a plan-to-tickets epic end-to-end

Pick up where `execute-tickets` stops. The executor merges ticket PRs into the
epic branch (`source_branch`) and never creates a reviewable PR into `main`.
`epic-manager` fills that gap: it watches the plan's tickets, and when the
backlog drains it opens the epic→`main` PR, runs a final integration review,
and waits for a human to say `ship it` (or `rework:` / `abandon`) in a comment
on the epic issue.

Designed to run as a **singleton** — one manager process per plan, per repo.
The `lock:manager` label on the epic issue is the mutex; a firing that can't
acquire it exits cleanly. This is a separate lock namespace from the
executor's `lock:<name>` roster (`alice`..`justin`), so managers and executors
never collide.

The manager never merges the epic PR without an explicit human `ship it`. It
is the mechanism by which a human's approval becomes a merge, not a substitute
for that approval.

## When this applies

- `plan-to-tickets` has filed an epic + tickets on GitHub, and
  `execute-tickets` is (or has been) driving them through to merge into the
  epic branch.
- The target is a **GitHub** repo, `gh`, `git`, `jq`, `yq`, and `codex` are on
  PATH, and `gh auth status` is green.
- The epic issue exists and carries the marker
  `<!-- plan-to-tickets:epic:<plan_file> -->` (the manager finds it by this
  marker — it does not assume the epic is any specific issue number).
- You want the collected ticket work shepherded to a reviewable PR on `main`
  with a final review and a human merge gate, rather than hand-merging the
  epic branch yourself.

If no epic issue with the marker exists, the manager stops and points at
`plan-to-tickets` — it does not try to reconstruct the epic from ticket state.

**Repo-wide mode.** Omit `--plan` entirely to have the manager discover every
open epic and process one per cycle, stalest-first (ranked by each epic's own
comment history — no new state, nothing to configure). A discovered epic whose
manifest can't be resolved is skipped with a logged warning; the manager tries
the next-stalest epic instead of dying. This is the mode a long-running manager
process should use (e.g. deployed continuously via systemd, one instance for
the whole repo) so new epics get supervised as soon as `plan-to-tickets` files
them — no per-plan process to start. Use `--plan` to dedicate an invocation to
one specific epic instead.

## The human↔manager interface

**Comments are intent, labels are state.** The manager posts its actions and
observations as comments on the epic issue; the human speaks in comments; the
manager parses comments for commands. The whole conversation lives in one
readable thread on the epic issue, top to bottom — the issue *is* the audit
trail.

Labels stay machine-internal: `lock:manager` (singleton mutex),
`needs-human` (same label the executor uses, but the manager sets it on the
**epic issue** for plan-level escalation), and `checklist-failed` (the
checklist gate failed; distinguishes from other `needs-human` reasons without
reading comments).

A command is a comment whose **first line** is a recognized trigger phrase
(case-insensitive). Free-form discussion in other comments is ignored.

| Human comment (first line) | Manager action |
|--|--|
| `ship it` / `shipit` / `#shipit` / 🚀 / `lgtm` / `merge it` | Guard (no open rework tickets, no in-progress tickets) → re-verify CI green → merge epic PR (`--squash --delete-branch --auto`) → confirm with merge SHA |
| `rework [#N]: <description>` | Codex picks metadata (priority/complexity/model-tier) → file a new ticket with the plan marker + "Refines #N" if referenced → post filing comment with reasoning + retune hints |
| `abandon` | Close epic PR → close epic issue as "not planned" → final summary comment |
| *(other comments)* | Ignored — free-form discussion |

## The loop

```
1. Acquire lock:manager on the epic issue (singleton). Can't → exit.
2. Reconcile plan state from GitHub:
   - open tickets carrying this plan's marker, grouped:
       in-progress (any lock:* label)  needs-human  ready  closed
   - if any ready OR in-progress → post a progress comment + release + exit
     (executors are still working; the manager has nothing to do)
3. Backlog drained (no ready, no in-progress; only closed + maybe needs-human):
   a. Hybrid checklist gate. Any fail → no PR, post actionable failures on
      the epic issue, set needs-human + checklist-failed, release, exit.
   b. Open epic→main PR, idempotent (check for an existing open one first).
   c. Run final integration review (codex, advisory, holistic). Post findings
      as a comment on the epic issue + a summary on the PR. Blocking findings
      get a loud `review-blocked` comment, but the PR stays open — the human
      merges, not the manager.
4. Parse human commands from epic issue comments since last manager visit.
5. Release lock:manager.
```

Run as `--once` per cron firing (slow cadence, `--poll` default 300s — slower
than the executor's 30s because plan-level state changes less frequently and
the manager has no ticket work of its own to do).

## Singleton coordination

`lock:manager` on the epic issue, acquired at start, released at end. A firing
that cannot acquire it exits cleanly (the previous firing is still running).
This is the same label-lock pattern `execute-tickets` uses for ticket claims,
just at the plan level with a dedicated label outside the executor's
`lock:<name>` namespace.

If a manager firing crashes without releasing the lock, it goes stale.
Recovery: a subsequent firing detects the lock, checks the age of the
lock-acquisition comment the manager posts when it acquires
(`<!-- manager:lock-acquired:<iso8601> -->`), and after
`--stale-lock-threshold` (default 1h) force-claims it (removes the old label,
adds its own, posts a "recovered stale lock" note). The manager never runs two
instances against the same epic.

## Hybrid checklist gate

Per-repo checklist at `.execute-tickets/checklist.yml`. No file → skip the gate
entirely (backwards-compatible; repos without one go straight to the epic PR).
The manager ships the mechanism, not the rules — every repo has different "is
this kosher" criteria.

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

**`run:`** items execute in a worktree at the epic branch tip. Exit 0 = pass.
Output captured for the failure comment if non-zero.

**`judge:`** items compose a prompt (epic diff + the instruction) and run
`codex exec` with a `{passed, reasoning, confidence}` schema. Reuses the
executor's `codex exec --sandbox read-only` pattern but with a simpler
schema — this is a yes/no judgment, not a findings list.

**Failure behavior:** any item fails → epic PR does **not** open. The failure
comment on the epic issue is **actionable**: for each failed item, name, type,
the command or instruction, the failure output (for `run:`) or codex's
reasoning + confidence (for `judge:`), and a "what to do" suggestion where
obvious. The epic issue gets `needs-human` **and** `checklist-failed`. The
user fixes the issues, removes both labels, and the next manager firing
re-runs the gate from scratch.

A malformed checklist file (bad YAML, unknown type, missing field) is a hard
failure: no PR, `needs-human`, and the failure comment names the parse error
with the file path. The manager never silently skips a checklist it can't
understand.

## Final integration review

Distinct from per-ticket review, not a duplicate. Per-ticket review is scoped
to the ticket (the reviewer prompt explicitly says "don't flag out-of-scope
things"), so integration concerns are *out of scope by design*. The final
review's whole job is the integration view: do these N tickets collectively
implement the spec? Gaps between tickets, conflicts, cross-cutting bugs no
per-ticket review could catch.

- Runs after the epic PR opens, against the full epic…main diff.
- Uses a **different prompt and schema** than per-ticket review — the rubric
  is holistic, not scoped.
- **Advisory to the human.** Findings post as a comment on the epic issue and
  a summary on the PR. Blocking findings (priority 0/1) get a loud
  `review-blocked` comment (a clearly-marked comment, not a label — the label
  set stays minimal), but the PR stays open. The human decides whether to
  `ship it`, `rework:`, or `abandon`.
- The manager never prevents merge based on the final review. It surfaces
  findings; the human acts on them.

## Auto-rework loop

The final review being merely advisory doesn't mean the manager sits idle on
findings. If no human posts `ship it` / `rework:` / `abandon` in the same
cycle the review runs, and the review found anything at or below
`--auto-rework-priority-max` (default `2` — broader than the `review-blocked`
banner's `--block-priority-max`, default `1`, so minor findings get addressed
too, not just merge-blocking ones), the manager automatically files a rework
ticket from the review's own findings and waits for an executor to pick it up.

- The auto-filed ticket body is **not** a raw dump of the findings — codex
  expands them into a self-contained ticket (restated intent, concrete plan,
  files to touch, done criteria) using the same `expanded_description`
  pipeline as a human's `rework:` comment, so the executor has something
  actually actionable regardless of who triggered it.
- Capped at `--max-auto-rework-rounds` (default `5`, counted by prior
  auto-filed rework tickets for this plan — survives across cron firings).
  After the cap, the manager sets `needs-human` + `auto-rework-exhausted` and
  stops trying — the same "retry N times, then hand off" shape
  `execute-tickets` already uses for a single ticket's review-fix loop.
  `--max-auto-rework-rounds 0` disables auto-rework entirely (old
  advisory-only behavior: findings post, nothing auto-files).
- An explicit human command in the same cycle always wins — auto-rework never
  fires on top of a `rework:`/`ship it`/`abandon` the manager just processed.
- This does **not** change the ship-it gate itself: `ship it` still isn't
  blocked by open findings structurally. The loop exists so that, in the
  common case, the findings are already gone by the time a human looks —
  fewer things for the human's `ship it` to be a judgment call about.

## Approval-reset invariant

Any merge into the epic branch **after** a `ship it` invalidates that
approval. The manager detects the new merge (comparing the epic branch SHA
recorded at `ship it` time to the current tip), posts "diff updated since
`ship it`, please re-review," and will not merge until a fresh `ship it`
appears. This is what makes keeping the PR open across reworks safe: the
human's approval always refers to a specific diff state, and any change
forces re-confirmation.

The manager also guards `ship it` against in-flight work: if there are open
rework-filed tickets or any ticket carrying a `lock:*` label, `ship it` is
held with a "waiting on #N, #M to finish" comment rather than executed.

## Procedure

### 1. Dry-run first

```bash
skills/delivery-pipeline/epic-manager/scripts/epic-manager.sh \
  --plan <plan-slug> \
  --dry-run
```

Prints the reconciled plan state (ready/in-progress/needs-human/closed counts)
and the intended action. Mutates nothing — does not claim the lock, post
comments, open a PR, or run a review. Use this to confirm the manager sees the
epic and the ticket state the way you expect before going live.

### 2. Run on cron (`--once` per firing)

```bash
skills/delivery-pipeline/epic-manager/scripts/epic-manager.sh \
  --plan <plan-slug> --repo <owner/repo> --once
```

One cycle: acquire lock → reconcile → (progress-and-exit, or checklist → epic
PR → final review → commands) → release lock. Schedule it every few minutes;
the singleton lock means overlapping firings are safe (the loser exits).

### 3. Review the epic PR

When the backlog drains and the checklist passes, the manager opens the
epic→`main` PR and posts the final integration review as a comment on the
epic issue. Review the PR in GitHub. The final review's findings are advisory
— they inform your decision, they don't block merge.

### 4. Decide: `ship it`, `rework:`, or `abandon`

Post a comment on the **epic issue** (not the PR — the manager reads the epic
issue):

- **`ship it`** — the manager guards (no open rework tickets, no in-progress
  tickets), re-verifies CI green, and merges the epic PR. You get a
  confirmation comment with the merge SHA.
- **`rework: <description>`** — the manager files a new ticket with
  codex-chosen metadata, posts the reasoning + retune hints, and resets your
  approval. When an executor merges the new ticket, the epic PR's diff
  auto-updates; re-review and `ship it` again.
- **`rework #42: <description>`** — same, but the new ticket's body references
  #42 ("Refines #42") for executor context. #42 stays closed and untouched.
- **`abandon`** — closes the epic PR and the epic issue (not planned).

### 5. Handle `needs-human`

```bash
gh issue list --repo <owner/repo> --label needs-human --state open
```

The manager sets `needs-human` on the **epic issue** when: the checklist fails,
the auto-rework loop exhausts `--max-auto-rework-rounds` still finding
qualifying issues (also gets `auto-rework-exhausted`), the merge fails, or
there are `needs-human` tickets blocking the plan. A blocking final review on
its own is informational — you can still ship — and does not set
`needs-human` by itself. The comment body explains which. Fix the issue,
remove `needs-human` (and `checklist-failed` / `auto-rework-exhausted` if
present), and the next firing re-checks.

## Flags (`scripts/epic-manager.sh`)

| Flag | Effect |
|--|--|
| `--plan <slug>` | Plan slug. Same as `execute-tickets`. Optional — omit for repo-wide mode (see below). |
| `--repo <owner/repo>` | Target repo (default: current repo via `gh repo view`). |
| `--checklist <path>` | Override checklist file (default: `.execute-tickets/checklist.yml`). |
| `--reviewer-cmd <cmd>` | Final-review codex command (default: vendored). |
| `--final-review-schema <path>` | Override final-review schema (default: vendored). |
| `--final-review-prompt <path>` | Override final-review prompt (default: vendored). |
| `--block-priority-max <N>` | Findings at/below this priority get the loud `review-blocked` banner (still advisory). Default: 1. |
| `--auto-rework-priority-max <N>` | Findings at/below this priority trigger an auto-rework round. Default: 2. |
| `--max-auto-rework-rounds <N>` | Auto-rework rounds before escalating to `needs-human` + `auto-rework-exhausted`. `0` disables auto-rework. Default: 5. |
| `--poll <seconds>` | Sleep between cycles in loop mode. Default: 300. |
| `--stale-lock-threshold <seconds>` | Force-claim `lock:manager` after this staleness. Default: 3600. |
| `--once` | Run one cycle, then exit (cron mode). |
| `--dry-run` | Print reconciled state + intended actions; mutate nothing. |
| `--quiet` | Reduce stderr logging. Epic-issue audit comments always post. |
| `--help` | Show help. |

## Relationship to `execute-tickets`

The manager is a **peer**, not a replacement. Both run on cron; they coordinate
through GitHub state:

- Executors claim tickets via `lock:<name>`, merge ticket PRs into the epic
  branch, post ticket audit comments, set `needs-human` on tickets that fail.
- The manager claims the epic via `lock:manager`, observes executor state,
  gates the epic PR, runs the final review, and acts on human commands.
- Neither knows the other exists. Both read the same issue/PR/label state.
- The manager never touches `lock:<name>` labels or ticket issues (except
  filing new tickets for `rework:`). Executors never touch `lock:manager` or
  the epic PR.

## What this skill deliberately does not do

- **Re-plan.** When the decomposition itself is wrong, the manager surfaces it
  (`needs-human`) and points at `plan-to-tickets`. Re-planning is a human +
  plan-to-tickets action.
- **Assign tickets to workers.** Executors self-serve via `lock:*` labels.
- **Auto-merge without human approval.** The epic PR is never merged until a
  human posts `ship it`.
- **Touch individual tickets.** The manager reads ticket state for progress
  and files new tickets for `rework:`, but never edits/closes/labels an
  existing ticket. Ticket lifecycle is the executor's job.
- **Coordinate across repos.** One invocation, one repo — even in repo-wide
  mode, which processes multiple *plans* within that one repo, one epic per
  cycle, never multiple repos at once.
- **Prevent merge based on the final review.** The final review is advisory.
  Blocking findings are loud, but the human decides.
