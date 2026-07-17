# Portable Ship-Ready Review Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `ship-ready-pr-loop` continue through the strongest available review mechanism when `/code-review max` is unavailable, with native self-review as the final fallback.

**Architecture:** Keep one reviewer-neutral loop and put a capability ladder at its entrance: `/code-review max`, `codex-review`, direct `codex exec review`, then native self-review. Normalize every mechanism to the same severity, triage, validation, pass-count, PR-note, and final-report contract while leaving the Greploop phase unchanged.

**Tech Stack:** Agent Skills Markdown, YAML frontmatter, Git, Codex CLI review mode, behavioral forward-tests with fresh agents

## Global Constraints

- Select review mechanisms by capability, not by agent identity.
- Never execute `/code-review max` as a shell command.
- Count at most five total pre-PR review passes across all mechanisms.
- Fix every valid Critical and Major finding; triage findings rather than rubber-stamping them.
- State that native self-review is not an independent second opinion.
- Preserve the existing Greploop 5/5 target and five-pass limit.
- Do not add scripts, references, assets, manifest entries, or README changes.

## File map

- Modify `skills/coding/ship-ready-pr-loop/SKILL.md`: define review selection, the normalized review contract, fallback reporting, and reviewer-neutral acceptance criteria.
- Reference `skills/coding/codex-review/SKILL.md`: reuse its base-branch and Codex CLI review conventions; do not modify it.
- Reference `docs/superpowers/specs/2026-07-17-ship-ready-pr-loop-review-fallback-design.md`: authoritative approved behavior; do not modify it.

---

### Task 1: Make the pre-PR review loop capability-driven

**Files:**
- Modify: `skills/coding/ship-ready-pr-loop/SKILL.md`
- Test: behavioral scenarios executed by fresh agents; no persistent test file

**Interfaces:**
- Consumes: the intended PR base, the current branch diff, relevant uncommitted changes, available review capabilities, and project validation commands.
- Produces: severity-classified review findings, a maximum-five-pass review history, PR notes naming each mechanism used, and the unchanged Greploop gate.

- [ ] **Step 1: Run the native-only scenario against the current skill to verify the baseline failure**

Dispatch a fresh agent with the current `SKILL.md` and this prompt:

```text
Use the ship-ready-pr-loop skill at skills/coding/ship-ready-pr-loop/SKILL.md to prepare a completed feature branch for a pull request. The current harness cannot invoke /code-review max, the codex-review skill is not installed, and the codex CLI is unavailable. Do not modify files or create a pull request; describe the exact review workflow you would execute, its stopping condition, and what you would report.
```

Expected baseline: FAIL. The current skill requires `/code-review max`; it either attempts the unavailable action or stops without a native review path. Record the actual failure mode and wording before editing the skill.

- [ ] **Step 2: Replace the skill with the portable review contract**

Replace `skills/coding/ship-ready-pr-loop/SKILL.md` with exactly:

````markdown
---
name: ship-ready-pr-loop
description: Use when hardening a completed change or pull request through iterative review until it is ready to ship.
metadata:
  author: stephen-martin
  version: "0.2.0"
---

# Ship-Ready PR Loop

## Purpose

Take a completed change from review findings to a ship-ready PR.

The goal is:

1. Select the strongest available review mechanism.
2. Fix all valid Critical and Major issues.
3. Create a PR.
4. Run `/greploop`.
5. Iterate until Greploop reaches 5/5 or the maximum pass count is reached.

Keep the work narrow. Do not perform broad cleanup, style refactors, architecture rewrites, or low-priority fixes unless they directly resolve a Critical/Major issue or are required for Greploop 5/5.

## Workflow

### 1. Start clean

Before making changes:

- Confirm the working tree status.
- Create a new branch if needed.
- Identify the project's validation commands: tests, typecheck, lint, and build.

If commands are not obvious, inspect package files, CI config, Makefiles, README files, or project docs.

### 2. Select the review mechanism

Choose the first mechanism that can actually run in the current harness:

1. `/code-review max` when the harness exposes it. Invoke it as a skill or slash action; never run it as a shell command.
2. The `codex-review` skill when it is available and usable. Follow that skill against the intended PR base.
3. Direct Codex CLI review when `codex exec review` is available. Use a known PR base when one exists. Otherwise resolve the remote default branch, then run:

   ```bash
   BASE_BRANCH=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD)
   BASE_BRANCH=${BASE_BRANCH#origin/}
   codex exec review --base "$BASE_BRANCH" -o /tmp/codex-review.txt
   ```

   Use `--uncommitted` when needed. If committed and uncommitted scopes both contain part of the change, review both and combine their findings into one pass.
4. Native self-review when none of the preceding mechanisms can run.

Keep a working mechanism for later passes when possible. If it cannot start or becomes unavailable, fall through to the next mechanism and record the transition. An unavailable preferred reviewer is not a blocker while another mechanism remains.

### 3. Run the review

Review the complete change against the intended PR base, including relevant uncommitted and untracked files.

For native self-review:

- Resolve the intended PR base rather than assuming `main`.
- Inspect the branch diff, staged and unstaged changes, and every relevant untracked file listed by `git status --short`.
- Read changed files plus relevant tests, callers, and surrounding code.
- Check correctness and regressions, security and authorization, data loss or destructive behavior, error handling and recovery, concurrency and state consistency, compatibility and public APIs, and test coverage for changed behavior.
- Produce concrete findings with severity, file location, impact, and rationale.
- State: `Native self-review is not an independent second opinion.`

For every mechanism:

- Classify findings as Critical, Major, Minor, or lower priority.
- Triage each finding on its merits.
- Act only on valid Critical and Major findings.
- Document false positives instead of changing code for them.
- Leave Minor, style-only, naming-only, broad technical-debt, and speculative-refactor findings alone unless directly required by a Critical/Major fix.

### 4. Fix Critical and Major issues

For each valid Critical/Major issue:

- Fix the root cause.
- Keep the change minimal.
- Avoid unrelated rewrites.
- Preserve existing behavior unless the issue requires a behavior change.
- Add or update tests where appropriate.

After each fix pass, run the actual project validation suite, such as:

```bash
npm test
npm run typecheck
npm run lint
npm run build
```

Adapt the commands to the project.

### 5. Repeat the review loop

Repeat the selected review mechanism, fixing remaining valid Critical/Major issues after each pass.

Stop when either:

- no valid Critical or Major issues remain, or
- 5 total review passes have been completed across all mechanisms.

A pass is one complete review of the full change. Multiple invocations needed to cover committed and uncommitted scopes together count as one pass.

Maximum review passes: **5**

### 6. Create the PR

Create a PR after the review loop is complete.

The PR description must include:

- Critical/Major issues fixed.
- Validation commands run.
- Total review passes and passes per mechanism.
- Any mechanism transition and why it occurred.
- Any remaining findings and why they were not fixed.
- Any false positives and rationale.
- The native-review transparency note when native self-review was used.

Use a concise PR title that describes the actual risk reduced.

### 7. Run Greploop

Run:

```bash
/greploop
```

Greploop is a hard acceptance gate.

Target score: **5/5**

Review all Greploop findings. Fix anything required to reach 5/5. Do not game the score; fix the underlying issue.

### 8. Repeat the Greploop loop

Repeat `/greploop`, then fix remaining issues.

Stop when either:

- Greploop reports 5/5, or
- 5 total Greploop passes have been completed.

Maximum Greploop passes: **5**

After each Greploop fix pass, rerun relevant validation commands.

## Acceptance Criteria

The work is complete only when:

- At least one review mechanism completed successfully.
- No unresolved valid Critical review findings remain.
- No unresolved valid Major review findings remain.
- Project validation passes.
- A PR exists.
- Greploop score is 5/5.

If the review loop reaches five passes with valid Critical/Major findings, or Greploop does not reach 5/5 within five passes, the PR and final report must state the exact remaining blockers, why they remain, and what is needed to finish. Do not report the work as complete.

## Hard Rules

- Do not stop solely because a preferred review mechanism is unavailable.
- Do not run a slash action as a shell command.
- Do not present native self-review as independent review.
- Do not fix low-priority issues unless needed for a Critical/Major fix or Greploop 5/5.
- Do not perform broad rewrites.
- Do not change public APIs unless required.
- Do not suppress warnings without explaining why.
- Do not remove tests to make validation pass.
- Do not weaken validation.
- Do not skip validation after code changes.
- Do not create a PR that hides remaining blockers.
- Do not claim Greploop is 5/5 unless the latest run confirms it.

## Final Response Format

When finished, report:

```md
## Result

PR: <link>

Review mechanisms:
- <mechanism>: <passes>
Total review passes: <number>
Greploop passes: <number>
Final Greploop score: <score>

Validation:
- <command>: pass/fail

Fixed:
- <issue>

Remaining:
- None

Notes:
- <fallback transitions, native-review disclosure, false positives, blockers, or caveats>
```

If incomplete, replace `Remaining: None` with the exact remaining blockers.
````

- [ ] **Step 3: Run four forward-test scenarios with fresh agents**

Run each prompt in a fresh context with the revised skill. Do not tell the agent the expected mechanism.

Preferred mechanism:

```text
Use the ship-ready-pr-loop skill at skills/coding/ship-ready-pr-loop/SKILL.md to prepare a completed feature branch for a pull request. The harness can invoke /code-review max. Do not modify files or create a pull request; describe the exact review workflow, stopping condition, and final reporting fields you would use.
```

Codex skill fallback:

```text
Use the ship-ready-pr-loop skill at skills/coding/ship-ready-pr-loop/SKILL.md to prepare a completed feature branch for a pull request. The harness cannot invoke /code-review max, but the codex-review skill is installed and usable. Do not modify files or create a pull request; describe the exact review workflow, stopping condition, and final reporting fields you would use.
```

Direct CLI fallback:

```text
Use the ship-ready-pr-loop skill at skills/coding/ship-ready-pr-loop/SKILL.md to prepare a completed feature branch for a pull request. The harness cannot invoke /code-review max and the codex-review skill is not installed, but codex exec review is available. Do not modify files or create a pull request; describe the exact review workflow, stopping condition, and final reporting fields you would use.
```

Native fallback:

```text
Use the ship-ready-pr-loop skill at skills/coding/ship-ready-pr-loop/SKILL.md to prepare a completed feature branch for a pull request. The harness cannot invoke /code-review max, the codex-review skill is not installed, and the codex CLI is unavailable. Do not modify files or create a pull request; describe the exact review workflow, stopping condition, and final reporting fields you would use.
```

Expected for all four: select the strongest stated capability; cover the full change; share one five-pass limit across mechanisms; fix valid Critical/Major findings; name the mechanism and pass count in PR/final reporting; preserve the Greploop gate. Expected for native only: include the exact independence disclosure and the required risk categories. If a scenario fails, tighten only the ambiguous guidance and rerun the failing scenario in another fresh context.

- [ ] **Step 4: Run static skill validation**

Run:

```bash
python3 /Users/smartin/.codex/skills/.system/skill-creator/scripts/quick_validate.py skills/coding/ship-ready-pr-loop
git diff --check
```

Expected: validator reports `Skill is valid!`; `git diff --check` prints nothing and exits 0.

Run:

```bash
rg -n 'No unresolved valid (Critical|Major) `/code-review max`|Code-review passes' skills/coding/ship-ready-pr-loop/SKILL.md
git diff -- README.md skills.sh.json skills/coding/codex-review/SKILL.md
```

Expected: both commands print nothing. The first proves acceptance/reporting no longer depends on the preferred reviewer; the second proves out-of-scope files are unchanged.

- [ ] **Step 5: Review and commit the implementation**

Run:

```bash
git diff -- skills/coding/ship-ready-pr-loop/SKILL.md
git status --short
```

Confirm the diff implements every section of the approved design, preserves Greploop behavior, and changes no unrelated file.

Commit:

```bash
git add skills/coding/ship-ready-pr-loop/SKILL.md
git commit -m "Make ship-ready review fallback portable"
```

Expected: one implementation commit containing only `skills/coding/ship-ready-pr-loop/SKILL.md`.

---

## Final verification

- [ ] Re-run the native-only forward-test once after any refactor wording changes.
- [ ] Re-run `quick_validate.py` and `git diff --check` from Task 1.
- [ ] Run `git log -3 --oneline` and confirm the design, plan, and implementation are separate commits.
- [ ] Run `git status --short` and confirm the working tree is clean.
