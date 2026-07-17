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
3. Create or update the PR.
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
3. Direct Codex CLI review when `codex exec review` is available. Set `BASE_REF` through exactly one of these mutually exclusive paths:

   - **Known intended PR base:** Assign its exact local or remote ref to `BASE_REF`, then verify that it resolves to a commit:

     ```bash
     BASE_REF="<exact known intended local or remote ref>"
     git rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null
     ```

     If verification fails, optionally resolve or fetch that same intended base when doing so is in scope, then verify the same ref again. Never substitute `origin/HEAD`, `main`, or `master` for a different known intended base. If the intended base remains unresolved, do not invoke Codex. Record why and fall through to native self-review.

   - **No intended PR base known:** Resolve `BASE_REF` in this order:

     1. `refs/remotes/origin/HEAD`, only when the symbolic ref and its target both resolve.
     2. The first ref that resolves to a commit from `refs/heads/main`, `refs/remotes/origin/main`, `refs/heads/master`, and `refs/remotes/origin/master`.

   Use this fallback discovery only when no intended PR base is known:

   ```bash
   BASE_REF=""
   if ORIGIN_HEAD=$(git symbolic-ref --quiet refs/remotes/origin/HEAD) &&
      git rev-parse --verify --quiet "${ORIGIN_HEAD}^{commit}" >/dev/null
   then
     BASE_REF="$ORIGIN_HEAD"
   else
     for candidate in refs/heads/main refs/remotes/origin/main refs/heads/master refs/remotes/origin/master; do
       if git rev-parse --verify --quiet "${candidate}^{commit}" >/dev/null; then
         BASE_REF="$candidate"
         break
       fi
     done
   fi
   ```

   Invoke Codex only when the selected base is nonempty and still resolves immediately before review:

   ```bash
   test -n "$BASE_REF" &&
   git rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null &&
   codex exec review --base "$BASE_REF" -o /tmp/codex-review.txt
   ```

   If no base resolves, do not invoke Codex with an empty or unresolvable base. Fall through to native self-review and record why.

   Use `--uncommitted` when needed. If committed and uncommitted scopes both contain part of the change, review both and combine their findings into one pass.
4. Native self-review when none of the preceding mechanisms can run.

Keep a working mechanism for later passes when possible. If it cannot start or becomes unavailable, fall through to the next mechanism and record the transition. An unavailable preferred reviewer is not a blocker while another mechanism remains.

### 3. Run the review

Review the complete change against the intended PR base, including relevant uncommitted and untracked files.

For native self-review:

- Resolve the intended PR base rather than assuming `main`.
- When an intended base is known, use that same base. If it remains unresolved after any in-scope resolution or fetch, report the base as a blocker; do not substitute a default branch.
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

### 6. Create or update the PR

After the review loop is complete, reuse and update an existing PR for the current branch. Create a PR only when none exists.

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

Invoke `/greploop` as the Greploop skill or slash action. Never run it as a shell command.

Greploop is a hard acceptance gate.

Target score: **5/5**

Review all Greploop findings. Fix anything required to reach 5/5. Do not game the score; fix the underlying issue.

### 8. Repeat the Greploop loop

Repeat the Greploop skill or slash action, then fix remaining issues.

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
