---
name: ship-ready-pr-loop
description: Run `/code-review max`, fix Critical and Major issues, create a PR, then run `/greploop` until the PR reaches 5/5 or the pass limit is hit. Use this when the user wants to harden a PR until it is ready to ship.
metadata:
  author: stephen-martin
  version: "0.1.0"
---

# Ship-Ready PR Loop

## Purpose

Use this skill to take a codebase from review findings to a ship-ready PR.

The goal is:

1. Run `/code-review max`.
2. Fix all valid Critical and Major issues.
3. Create a PR.
4. Run `/greploop`.
5. Iterate until Greploop reaches 5/5 or the maximum pass count is reached.

This skill is intentionally narrow. Do not perform broad cleanup, style refactors, architecture rewrites, or low-priority fixes unless they directly resolve a Critical/Major issue or are required for Greploop 5/5.

---

## Workflow

### 1. Start clean

Before making changes:

* Confirm the working tree status.
* Create a new branch if needed.
* Identify the project's validation commands:

  * tests
  * typecheck
  * lint
  * build

If commands are not obvious, inspect package files, CI config, Makefiles, README files, or project docs.

---

### 2. Run code review

Run:

```bash
/code-review max
```

Review the output and classify findings.

Only act on:

* Critical issues
* Major issues

Ignore unless directly relevant:

* Minor issues
* Low-priority issues
* style-only comments
* naming-only comments
* broad technical debt
* speculative refactors

---

### 3. Fix Critical and Major issues

For each valid Critical/Major issue:

* Fix the root cause.
* Keep the change minimal.
* Avoid unrelated rewrites.
* Preserve existing behavior unless the issue requires behavior change.
* Add or update tests where appropriate.

If a finding is a false positive:

* Do not change the code.
* Document why it is a false positive in the final PR notes.

After each fix pass, run the project validation suite:

```bash
# Use actual project commands
npm test
npm run typecheck
npm run lint
npm run build
```

Adapt commands to the project.

---

### 4. Repeat code-review loop

Repeat:

```bash
/code-review max
```

Then fix remaining Critical/Major issues.

Stop this loop when either:

* `/code-review max` reports no remaining Critical or Major issues, or
* 5 total `/code-review max` passes have been completed.

Maximum code-review passes: **5**

---

### 5. Create the PR

Create a PR after the code-review loop is complete.

The PR description must include:

* Summary of Critical/Major issues fixed.
* Validation commands run.
* Number of `/code-review max` passes completed.
* Any remaining findings and why they were not fixed.
* Any false positives and rationale.

Use a concise PR title that describes the actual risk reduced.

---

### 6. Run Greploop

Run:

```bash
/greploop
```

Greploop is a hard acceptance gate.

Target score: **5/5**

Review all Greploop findings. Fix anything required to reach 5/5.

Do not game the score. Fix the underlying issue.

---

### 7. Repeat Greploop loop

Repeat:

```bash
/greploop
```

Then fix remaining issues.

Stop this loop when either:

* Greploop reports 5/5, or
* 5 total Greploop passes have been completed.

Maximum Greploop passes: **5**

After each Greploop fix pass, rerun relevant validation commands.

---

## Acceptance Criteria

The work is complete only when:

* No unresolved valid Critical `/code-review max` findings remain.
* No unresolved valid Major `/code-review max` findings remain.
* Project validation passes.
* PR exists.
* Greploop score is 5/5.

If Greploop does not reach 5/5 within 5 passes, the PR must clearly document:

* final Greploop score
* number of Greploop passes completed
* remaining blockers
* why they remain
* what is needed to finish

---

## Hard Rules

* Do not fix low-priority issues unless needed for a Critical/Major fix or Greploop 5/5.
* Do not perform broad rewrites.
* Do not change public APIs unless required.
* Do not suppress warnings without explaining why.
* Do not remove tests to make validation pass.
* Do not weaken validation.
* Do not skip validation after code changes.
* Do not create a PR that hides remaining blockers.
* Do not claim Greploop is 5/5 unless the latest run confirms it.

---

## Final Response Format

When finished, report:

```md
## Result

PR: <link>

Code-review passes: <number>
Greploop passes: <number>
Final Greploop score: <score>

Validation:
- <command>: pass/fail
- <command>: pass/fail

Fixed:
- <issue>
- <issue>

Remaining:
- None

Notes:
- <false positives, blockers, or caveats>
```

If incomplete, replace `Remaining: None` with the exact remaining blockers.
