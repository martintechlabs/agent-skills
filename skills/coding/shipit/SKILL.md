---
name: shipit
description: >-
  Bring a GitHub pull request to a verified, review-ready state. Codex reviews
  every PR against its base branch, and validated Critical and Major findings
  get narrowly scoped fixes. A minor change stops there. A larger change then
  runs greploop for a Greptile review, reusing a current review instead of
  paying for a new one. Validates every finding, escalates product and
  architecture decisions, and never merges, deploys, or releases without
  explicit approval. Use when the user says "shipit", "ship this PR", "get this
  PR ready to ship", "get this ready to ship", or "harden this change".
metadata:
  author: stephen-martin
  version: "0.2.0"
---

# Shipit

Bring a pull request to a verified, review-ready state. Codex reviews every
PR. A minor change ends there. A larger change then goes through the existing
`/greploop` skill.

Preserve the intended behavior and architecture. Verify each review comment
against the code and requirements before fixing it. Keep changes narrowly
scoped, run the relevant tests, and flag any fix that would require a product
or architectural decision.

## Inputs and prerequisites

Do these first. Do nothing else until a PR exists.

- Accept a PR number or PR URL as input.
- If no PR is supplied, identify the PR associated with the current branch.
- If no PR exists, ask the user for one, or for approval to open one. Do not
  open one unasked. When no user is available to ask, stop and report.
- If the target is ambiguous, ask the user before proceeding.
- The PR must be on GitHub, because every step uses `gh`. On GitLab or
  Perforce, stop and report that shipit is GitHub-only.
- Confirm the local repository and branch correspond to the target PR.
- The PR must be open. Read `gh pr view <PR> --json number,state,headRefOid`.
  If `state` is not `OPEN`, stop and report. Use the PR number, not a URL, in
  every later command.
- The local branch must contain the PR head:

  ```bash
  git fetch origin "pull/<PR_NUMBER>/head" &&
  git merge-base --is-ancestor <headRefOid> HEAD
  ```

  If this fails, the local branch is behind the PR or has diverged. Stop and
  report. Never pull, reset, or force-push over local work.
- Inspect the working tree. Do not overwrite, discard, or include unrelated
  uncommitted changes.
- Confirm Codex is installed and signed in (`codex login status`). If not,
  stop and report the missing prerequisite. There is no fallback reviewer.
  Under a ChatGPT-plan login, check `~/.codex/models_cache.json` before you
  assume the default model works.
- Follow repository instructions and applicable approval requirements.

The Greptile prerequisites come later, only for a larger change.

## Establish implementation context

Before starting the review loop:

1. Read the PR description, diff, relevant requirements, and repository
   instructions.
2. Use available implementation-chat context to understand design decisions,
   constraints, and intentionally rejected alternatives.
3. Inspect the relevant code and tests.
4. Identify the intended behavior, architectural boundaries, and appropriate
   verification commands.

Do not invent missing requirements. Flag ambiguity when it materially
affects a proposed fix.

## Run the Codex review

Codex reviews every change against the PR's own base branch:

```bash
PR=<PR_NUMBER>
BASE=$(gh pr view "$PR" --json baseRefName -q .baseRefName)
git fetch origin "$BASE"
codex exec review --base "origin/$BASE" -o <scratch file>
```

If the base does not resolve, stop and report a blocker. Never substitute
`main` or another default branch.

- `--base` takes no prompt, and Codex also reads uncommitted edits to
  tracked files. A finding caused only by uncommitted edits is out of scope,
  because those edits are not part of the PR. A finding about code that the
  PR breaks elsewhere is in scope.
- Classify each finding as Critical, Major, Minor, or lower. Validate it
  under "Validate every review finding". Fix only validated Critical and
  Major defects. List the rest in the report.
- Commit each fix before the next pass, so the review sees it.
- Verify after each fix pass (see "Verify changes").
- Repeat until no valid Critical or Major finding remains, or 5 passes.
- Do not push between passes. Push once, when the loop ends. On a
  repository that reviews every push, each push starts a paid Greptile
  review.
- If 5 passes end with valid Critical or Major findings, push the validated
  fixes, skip the size gate and greploop, and report "Blocked by review
  findings". Do not pay for a Greptile review of known defects.
- If Codex fails to run, stop and report a blocker.

## Size gate

After the Codex loop, inspect the final PR diff:

```bash
git diff --numstat "origin/$BASE...HEAD"            # added, deleted, path
git diff --name-status -M "origin/$BASE...HEAD"     # status, path
```

The change is minor only when all of these hold:

- 10 changed lines or fewer in total (added plus deleted).
- Every file status is `M`. An added, deleted, or renamed file is not minor.
- No binary file (`-` in the `--numstat` counts).
- Nothing in a risky area: auth or permissions, security, secrets or config,
  data model or migrations, public API, dependencies or lockfiles, CI or
  build config.

Anything else is a larger change. When in doubt, treat it as larger. The
user can override either way ("run Greptile anyway", "skip Greptile").

## Minor change

- Push, if the Codex loop has not.
- Do not request a Greptile review, and do not wait for one.
- Report "Greptile skipped: minor change" with the reason.
- If the PR already has unresolved Greptile review threads, list them as
  remaining items. The status then cannot be "Ready to merge".

## Run greploop

For a larger change only.

Ensure the existing `/greploop` skill is available. If it is unavailable,
stop and report the missing prerequisite.

### Confirm Greptile is installed

Without Greptile on the repository, greploop waits for a review that never
arrives. Look for a Greptile bot comment or review on the target PR or the
last 20 PRs. Do not rely on a Greptile check run: Greptile-reviewed PRs often
have none.

```bash
for n in $(gh pr list --state all --limit 20 --json number -q '.[].number'); do
  gh api --paginate "repos/{owner}/{repo}/issues/$n/comments" --jq '.[].user.login'
  gh api --paginate "repos/{owner}/{repo}/pulls/$n/reviews" --jq '.[].user.login'
done | grep -qE '^greptile-apps(-staging)?\[bot\]$'
```

- **Found:** continue.
- **Not found:** this does not prove Greptile is absent. It may have been
  installed after the last reviewed PR. Tell the user that Greptile could not
  be confirmed and ask whether it is installed. On a yes, continue. On a no,
  or when no user is available to ask, stop before the review loop.

### Review loop

Invoke the existing `/greploop` skill for the target PR.

Apply the guardrails below throughout every review-and-fix iteration,
including any delegated work.

Follow greploop's workflow for obtaining reviews and iterating on fixes,
subject to repository instructions, approval requirements, and this skill's
constraints.

Do not optimize for a review score at the expense of correctness,
requirements, or architecture.

These rules override greploop where they differ:

- **Close every thread you do not fix with a reply.** greploop resolves
  false positives silently. Instead, reply in the thread with the reason
  (false positive, or optional improvement out of scope), then resolve it.
  A rejected comment must not stay open only to block greploop's
  zero-unresolved exit.
- **Leave decision threads open.** A finding that needs user input (see
  "Escalate product and architectural decisions") stays unresolved. Do not
  resolve it to reach greploop's exit condition. Report it as a blocker.
- **Accept a score below 5/5** when the only remaining items are rejected or
  pending a decision. Do not change correct code to raise the score.
- **Stage only your fixes.** greploop commits with `git add -A`. Stage
  explicit paths instead. If a file you must change already has uncommitted
  user edits, stop and ask before editing it. Before each commit, check that
  `git diff --cached` contains only your fixes, with no files that were
  already staged.
- **Run greploop as a skill.** Never run it as a shell command.
- **Reuse a current review.** Greptile reviews cost money. Before every pass,
  run the check below.
- **Request one review per fix batch.** Commit fixes as you make them, and
  push once per batch. On a repository that reviews every push, each push
  starts a paid review. Request the next review only after every fix for the
  current findings is committed, pushed, and validated. Never request a
  review per commit.
- **Stop after 5 passes.** A pass that reuses a review counts.
- **Treat a timeout with care.** greploop waits about 10 minutes for a
  Greptile check run, and many repositories have none. On a timeout, run the
  reuse check. If it shows a score for `HEAD_SHA`, read that review and
  continue. If not, stop and report a blocker. Never fall back to another
  reviewer.
- **Claim 5/5 only from the latest run** on `HEAD_SHA`.

### Reuse a current review

greploop posts `@greptile review` whenever no Greptile check is running. It
does this even when a finished review already covers the head commit. Run
this check from the top before every pass:

```bash
PR=<PR_NUMBER>
HEAD_SHA=$(gh pr view "$PR" --json headRefOid -q .headRefOid)
if [ "$HEAD_SHA" != "$(git rev-parse HEAD)" ]; then
  echo "Local HEAD is not the PR head. Push, then rerun this check." >&2
else
  gh api --paginate "repos/{owner}/{repo}/commits/$HEAD_SHA/check-runs?per_page=100" \
    --jq '.check_runs[] | select(.name | test("greptile"; "i")) | "check run: \(.name) \(.status) \(.conclusion)"'
  # Greptile writes its summary to the PR description or to its latest PR comment.
  BODY=$(gh pr view "$PR" --json body -q .body)
  COMMENT=$(gh api --paginate "repos/{owner}/{repo}/issues/$PR/comments?per_page=100" |
    jq -rs 'add | map(select((.user.login | test("greptile"; "i")) and (.body | contains("greptile_confidence_score"))))
            | sort_by(.updated_at) | last | .body // empty')
  for TEXT in "$BODY" "$COMMENT"; do
    if printf '%s\n' "$TEXT" | grep -q "Last reviewed commit:.*/commit/$HEAD_SHA"; then
      printf '%s\n' "$TEXT" | grep -o 'greptile_confidence_score:[0-9]'
    fi
  done
fi
```

A score line means a summary covers `HEAD_SHA`. A summary that names
another commit is stale, so the check prints no score for it.

1. **Local HEAD is not the PR head:** the local branch is ahead (the
   prerequisites rule out behind). Push, never force-push, then run the check
   again.
2. **Check run `queued` or `in_progress`:** a review is running. Do not
   request one. Let greploop wait, then run the check again.
3. **Check run `completed` but not `success`:** that is not a review. A
   cancelled, timed-out, skipped, or failed check does not count.
4. **Score printed, and no check run or a `success` one:** reuse it. Tell
   greploop to read those results and not to post `@greptile review`.
5. **Otherwise:** request a new review. Right after a push, first run the
   check every 10 seconds for up to 2 minutes. A running check run or a
   score for `HEAD_SHA` means an automatic review exists, so do not request
   one.

The check keys on the summary, not on the check run, because many
Greptile-reviewed PRs have no check run. Known limit: on a repository that
reviews every push and has no check run, nothing shows until the summary
posts. A review that takes longer than 2 minutes then gets a second,
paid request. Greptile's manual-only setting (`"autoReview": []`) avoids
this.

## Validate every review finding

This applies to Codex and Greptile findings alike. Before changing code for
a review comment:

1. Inspect the referenced code and relevant surrounding call sites.
2. Compare the finding with requirements, intended behavior, and existing
   repository patterns.
3. Confirm whether the reported issue is reproducible or otherwise supported
   by concrete evidence.
4. Classify it as:
   - A validated defect.
   - An optional improvement.
   - A false positive.
   - An ambiguity or decision requiring user input.
5. Choose the smallest justified response.

Fix validated defects when the intended correction is clear.

Do not automatically implement optional improvements. Include them only
when they are directly relevant, low-risk, and within the PR's existing scope.

For false positives, explain why the finding does not apply. Do not change
correct code merely to silence a reviewer.

If evidence is insufficient, investigate or flag the uncertainty rather
than guessing.

## Keep fixes narrowly scoped

- Preserve intended behavior and architectural boundaries.
- Limit changes to validated findings and necessary supporting tests.
- Follow existing repository conventions.
- Avoid unrelated refactors, formatting churn, dependency upgrades, and
  speculative improvements.
- Do not weaken tests, disable checks, suppress errors, or remove safeguards
  merely to obtain a passing result.
- Add or update regression tests when relevant.
- Review each diff for unintended changes before committing or pushing.
- Never include unrelated user changes in a commit.

## Escalate product and architectural decisions

Do not autonomously apply a fix that requires:

- Changing product requirements or intended user-visible behavior.
- Changing public APIs or compatibility guarantees.
- Introducing new services, dependencies, or architectural boundaries.
- Making consequential data-model or migration changes.
- Changing security, authorization, permissions, or privacy policies.
- Choosing between materially different interpretations of the requirements.

When such a decision arises:

1. Describe the finding and supporting evidence.
2. Explain why the fix requires a decision.
3. Present the smallest viable options and their tradeoffs.
4. Request approval before implementing the affected change.

Continue with independent, unambiguous fixes only when doing so is safe.
Pause the loop if the unresolved decision blocks further work.

## Verify changes

For each fix or coherent batch of fixes:

1. Run focused tests covering the changed behavior.
2. Add or update regression coverage where appropriate.
3. Run applicable lint, type-check, and build checks when practical.
4. Run broader tests when the affected surface warrants them.
5. Inspect the final diff for scope creep and unintended behavior changes.

Record the commands run and their outcomes.

Distinguish newly introduced failures from pre-existing failures when
evidence permits. Do not claim a failure is pre-existing without evidence.

If a check cannot run, report the reason and resulting verification gap.
Never claim verification succeeded without execution evidence.

## Iterate responsibly

After applying and verifying fixes, continue the Codex or greploop review
cycle.

- Revalidate new comments rather than treating them as automatically correct.
- Preserve the same scope and decision boundaries across iterations.
- Do not repeat ineffective changes or oscillate between conflicting fixes.
- If feedback repeats, conflicts, or cannot be resolved safely, stop and
  explain the blocker.
- Respect the pass limits: 5 Codex passes, 5 greploop passes.
- Do not treat a high review score as a substitute for passing checks or
  satisfied requirements.

## Shipping boundary

“Ship” means bringing the PR to a verified, review-ready state.

This skill does not authorize merging, deploying, or releasing.
Do not perform those actions without explicit user approval.

Do not claim the PR is ready to merge if known blocking findings, failed
required checks, or unresolved consequential decisions remain.

## Completion report

Provide a concise report containing:

### Status

State one of:

- Ready to merge.
- Blocked pending a decision.
- Blocked by review findings or failed checks.
- Review loop complete, with verification gaps.

### Review path

- Minor change, with the reason Greptile was skipped, or larger change.
- Codex passes.
- For a larger change: greploop passes, final score, and how many passes
  reused a review.

### Changes

Summarize validated findings and the narrowly scoped fixes applied.

### Review disposition

List rejected, deferred, or unresolved comments with brief reasons.

### Verification

List the relevant commands run and their outcomes. Explicitly identify
checks that were not run or could not complete.

### Remaining actions

Identify any blockers, approval requests, or verification gaps.
Include the target PR and current review status.

Do not merge, deploy, or release as part of the completion report.
