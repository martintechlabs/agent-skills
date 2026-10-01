---
name: ship-ready-pr-loop
description: Use when hardening a completed change or pull request through iterative review until it is ready to ship.
metadata:
  author: stephen-martin
  version: "0.7.0"
---

# Ship-Ready PR Loop

## Purpose

Take a completed change from review findings to a ship-ready PR.

The goal is:

1. Select the strongest available review mechanism.
2. Check the change against the repository's Kodus lessons.
3. Fix all valid Critical and Major issues.
4. Create or update the PR.
5. Run the `kodus-loop` skill.
6. Record new Kodus lessons until the Kodus loop completes or reaches its pass limit.

Keep the work narrow. Do not perform broad cleanup, style refactors, architecture rewrites, or low-priority fixes unless they directly resolve a Critical/Major issue or are required to complete the Kodus loop.

## Workflow

### 1. Start clean

Before making changes:

- Confirm the working tree status.
- Create a new branch if needed.
- Identify the project's validation commands: tests, typecheck, lint, and build.

If commands are not obvious, inspect package files, CI config, Makefiles, README files, or project docs.

Check that Kodus is installed on the repository with kodus-loop's install check (its step 0, reference §0). If it finds no Kody check run on the current branch's PR or the last 20 PRs, stop before any review work: the step-7 gate can never pass. Give the user kodus-loop's "Kodus is not installed" explanation and fix steps. If no PR exists yet and recent PRs show no Kody check run, give the same stop.

Read `docs/agents/kodus-lessons.md` in the target repository if it exists. It lists patterns that Kody (the Kodus review bot) caught on earlier PRs after the step-3 review missed them. A missing file is not an error; the first run with a lesson creates it (step 8).

### 2. Select the review mechanism

Choose the first mechanism that can actually run in the current harness:

1. The `code-review-and-quality` skill ([skills.sh](https://www.skills.sh/addyosmani/agent-skills/code-review-and-quality)), a user-installed skill from `addyosmani/agent-skills` identified by its five-axis review (correctness, readability, architecture, security, performance). If it is missing, ask the user whether to install it. On a yes, install it globally so the target repo stays clean:

   ```bash
   npx -y skills add addyosmani/agent-skills --skill code-review-and-quality -g -y
   ```

   If the harness cannot load a newly installed skill until restart, read the installed `SKILL.md` (under `~/.agents/skills/code-review-and-quality/`) and follow it directly. If the user declines, no user is available to ask (an unattended run), or the install fails (no network, no `npx`), do not install; record why and fall through to mechanism 2. Invoke it as a skill for review only; never run it as a shell command. Point it at the complete change against the intended PR base (use the known intended base, or resolve one with the discovery in mechanism 2), including uncommitted and untracked files, plus the spec or issue path when one exists. Run it in a fresh subagent when the harness has one, so the reviewer does not share the author's context. It asks you to confirm before deleting dead code and to split oversized changes; record those as findings for step 3 instead of pausing the loop. Map its labels onto this loop: `Critical:` → Critical, an unprefixed (required) finding → Major, `Optional:`/`Consider:`/`Nit:`/`FYI` → Minor or lower. Its presumptive blockers (relocated complexity, oversized files, feature logic in shared modules, near-duplicate helpers, silent fallbacks) are Minor unless they hide a real defect. When it runs in the author's own context rather than a subagent, state: `code-review-and-quality ran in the author's context and is not an independent second opinion.`
2. Direct Codex CLI review when `codex exec review` is available. Set `BASE_REF` through exactly one of these mutually exclusive paths:

   - **Known intended PR base:** Assign its exact local or remote ref to `BASE_REF`, then verify that it resolves to a commit:

     ```bash
     BASE_REF="<exact known intended local or remote ref>"
     git rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null
     ```

     If verification fails, optionally resolve or fetch that same intended base when doing so is in scope, then verify the same ref again. Never substitute `origin/HEAD`, `main`, or `master` for a different known intended base. If the intended base remains unresolved, do not invoke Codex. Record why and fall through to the next mechanism.

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

   If no base resolves, do not invoke Codex with an empty or unresolvable base. Fall through to the next mechanism and record why.

   Use `--uncommitted` when needed. If committed and uncommitted scopes both contain part of the change, review both and combine their findings into one pass.
3. Matt Pocock's `code-review` skill ([skills.sh](https://www.skills.sh/mattpocock/skills/code-review)), a user-installed skill from `mattpocock/skills`, not a built-in skill of Claude, Codex, Grok, or any other agent. Identify it by its description (a two-axis Standards and Spec review since a fixed point), not by the `/code-review` name alone, which other tools also use. If it is missing when this mechanism is reached, ask the user whether to install it. On a yes, install it globally so the target repo stays clean:

   ```bash
   npx -y skills add mattpocock/skills --skill code-review -g -y
   ```

   Do not install over an existing `~/.agents/skills/code-review` that is a different skill. If the harness cannot load a newly installed skill until restart, read `~/.agents/skills/code-review/SKILL.md` and follow it directly. If the user declines, no user is available to ask (an unattended run), or the install fails, do not install; record why and fall through to mechanism 4.

   It expects the one-time per-repo setup from [`setup-matt-pocock-skills`](https://www.skills.sh/mattpocock/skills/setup-matt-pocock-skills), which writes `docs/agents/issue-tracker.md`. If that file is missing from the target repo, ask the user whether to run the setup now. On a yes, install the setup skill globally if it is missing (`npx -y skills add mattpocock/skills --skill setup-matt-pocock-skills -g -y`), then ask the user to run `/setup-matt-pocock-skills`: it disables model invocation and asks the user questions, so the agent cannot run it alone. Its output (`docs/agents/*.md` and an `## Agent skills` block in `CLAUDE.md` or `AGENTS.md`) changes the target repo, so commit it separately and list it in the PR description. If the user declines or no user is available, skip the setup and still run the review; pass the spec or issue path directly, because the skill cannot fetch issues without the setup.

   Invoke it with the resolved base as the fixed point (use the known intended base, or the discovery in mechanism 2), plus the spec or issue path when one exists; if none exists, say so, so it skips the Spec axis instead of waiting for an answer. It reviews only `<base>...HEAD`, so commit the change before every invocation, including repeat passes after step 4 fixes, then confirm `git status --porcelain` is empty; any file still listed is outside its review, so commit it or record why it is not part of the change. It assigns no severities and applies no fixes, so classify each finding yourself: a missing or wrongly implemented spec requirement, or a documented-standard violation that causes a real defect, can be Critical or Major; code-smell findings are judgement calls and count as Minor unless they hide a real defect.
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

- Give every entry in `docs/agents/kodus-lessons.md` to the reviewer as an extra checklist: check the change against each entry's Pattern and Check. A change that matches an entry is a Major finding. When the mechanism cannot take extra instructions (such as `codex exec review`), check the entries yourself in the same pass.
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
- The number of Kodus lessons checked, any that matched, and the entries added or updated during the run.
- The transparency note when native self-review, or `code-review-and-quality` without a subagent, was used.

Use a concise PR title that describes the actual risk reduced.

### 7. Run the Kodus loop

Invoke the `kodus-loop` skill. Never run it as a shell command.

The Kodus loop is a hard acceptance gate. It passes when Kody's review of the PR head commit is complete and no Kody review thread is unresolved. Kody gives no score.

Before the first Kodus review, confirm that every entry in `docs/agents/kodus-lessons.md` was checked against the change and that no match remains unfixed.

Push every local commit before you invoke it: `git rev-parse HEAD` must equal the PR's `headRefOid`. Automatic Kodus reviews are normally off, so kodus-loop triggers each review itself and reuses a completed review of the head commit when one exists. Do not post `@kody start-review` yourself.

Fix every valid Kody finding. Do not resolve threads to pass the gate: fix the underlying issue, or reply with the reason a finding is wrong.

### 8. Let the Kodus loop iterate

kodus-loop runs its own review, fix, and push passes, at most 5. One review per fix batch. Do not restart it after it stops at its pass limit; report the remaining blockers instead. If it stops because Kodus did not respond, skipped the review, or failed twice, the gate cannot pass: stop and report that as a blocker. Do not fall back to another reviewer for this gate.

After each Kodus fix batch, rerun relevant validation commands before the push.

#### Record Kodus lessons

In each Kodus fix batch (kodus-loop step E), update `docs/agents/kodus-lessons.md` and commit it with the fixes, before the push that precedes the next review. Record only valid Kody findings that the step-3 review missed. Do not record false positives or findings that the step-3 review already caught.

Write each lesson as a general pattern, not a file or line diff, so that it also catches similar code:

```md
## <short pattern name>
- Pattern: <what goes wrong, in general terms>
- Check: <how to find it in a diff: a grep, or a question to ask of the change>
- Seen: <count>, last <YYYY-MM-DD> (PR #<n>)
```

Record a finding only when it passes every one of these tests. If it fails one, do not record it:

- **It can recur.** It is a class of mistake that another change in this repository could make again. A one-off typo, a wrong constant, or a fix tied to a single line is not a lesson.
- **It has a concrete Check.** You can write a grep or a specific yes/no question that finds it in a diff. "Be careful with X" is not a Check.
- **Nothing else already catches it.** A linter, type checker, test, or the repository's existing docs do not already enforce it.

Before you add an entry, read the whole file and compare the finding against every existing entry by what goes wrong, not by wording. If an entry covers the same mistake, update that entry: increase its count, set the date, and widen its Pattern or Check if the new finding is broader. Add a new entry only when no existing entry covers the finding. If two existing entries describe the same mistake, merge them into one and add their counts.

Create the file with a `# Kodus lessons` heading if it does not exist. Keep at most 40 entries: when over, merge related entries, then drop the oldest entries seen once.

Never write the lessons file in a separate commit after the Kodus loop completes. That commit moves the head, so the completed review no longer covers it. A completing pass has no findings, so it never needs a lessons write.

When the Kodus loop ends, update the existing PR description with the lesson entries added or updated during the run (or `none`), even if the pass limit was reached. If Kody wrote a summary into the description (PR summaries enabled), keep it.

## Acceptance Criteria

The work is complete only when:

- At least one review mechanism completed successfully.
- No unresolved valid Critical review findings remain.
- No unresolved valid Major review findings remain.
- Project validation passes.
- A PR exists.
- The Kodus loop completed: Kody's review of the head commit is complete and no Kody thread is unresolved.

If the review loop reaches five passes with valid Critical/Major findings, or the Kodus loop does not complete within five passes, the PR and final report must state the exact remaining blockers, why they remain, and what is needed to finish. Do not report the work as complete.

## Hard Rules

- Do not stop solely because a preferred review mechanism is unavailable.
- Do not run a slash action as a shell command.
- Do not present native self-review, or `code-review-and-quality` run in the author's context, as independent review.
- Do not fix low-priority issues unless needed for a Critical/Major fix or to complete the Kodus loop.
- Do not perform broad rewrites.
- Do not change public APIs unless required.
- Do not suppress warnings without explaining why.
- Do not remove tests to make validation pass.
- Do not weaken validation.
- Do not skip validation after code changes.
- Do not create a PR that hides remaining blockers.
- Do not claim the Kodus loop completed unless its latest run confirms it.
- Do not request a Kodus review before checking the change against every Kodus lesson.
- Do not commit Kodus lessons after the Kodus loop completes; commit them with the fixes they describe.

## Final Response Format

When finished, report:

```md
## Result

PR: <link>

Review mechanisms:
- <mechanism>: <passes>
Total review passes: <number>
Kodus loop passes: <number>
Kodus loop result: complete / stopped (<reason>)

Validation:
- <command>: pass/fail

Fixed:
- <issue>

Kodus lessons:
- Checked: <number>, matched: <number>
- Added or updated: <entry names, or none>

Remaining:
- None

Notes:
- <fallback transitions, native-review disclosure, false positives, blockers, or caveats>
```

If incomplete, replace `Remaining: None` with the exact remaining blockers.
