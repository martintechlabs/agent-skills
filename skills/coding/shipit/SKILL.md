---
name: shipit
description: >-
  Prepare a pull request to ship by running greploop, validating review findings,
  applying narrowly scoped fixes, and verifying relevant tests while preserving
  intended behavior and architecture. Do not merge, deploy, or release without
  explicit approval. Use when the user says "shipit", "ship this PR", "get this PR
  ready to ship", or wants a Greptile-reviewed PR brought to a verified,
  review-ready state. Use ship-ready-pr-loop or kodus-loop instead when the
  repository reviews with Kodus.
metadata:
  author: stephen-martin
  version: "0.1.0"
---

# Shipit

Bring a pull request to a verified, review-ready state using the existing
`/greploop` skill.

Preserve the intended behavior and architecture. Verify each review comment
against the code and requirements before fixing it. Keep changes narrowly
scoped, run the relevant tests, and flag any fix that would require a product
or architectural decision.

## Inputs and prerequisites

- Accept a PR number or PR URL as input.
- If no PR is supplied, identify the PR associated with the current branch.
- If the target is ambiguous, ask the user before proceeding.
- Confirm the local repository and branch correspond to the target PR.
- Inspect the working tree. Do not overwrite, discard, or include unrelated
  uncommitted changes.
- Ensure the existing `/greploop` skill is available. If it is unavailable,
  stop and report the missing prerequisite.
- Confirm that Greptile reviews this repository (below).
- Follow repository instructions and applicable approval requirements.

### Confirm Greptile is installed

Without Greptile on the repository, greploop waits for a review that never
arrives. Look for a Greptile bot comment or review on the target PR or the
last 20 PRs. Do not rely on a Greptile check run: Greptile-reviewed PRs often
have none.

GitHub:

```bash
for n in $(gh pr list --state all --limit 20 --json number -q '.[].number'); do
  gh api "repos/{owner}/{repo}/issues/$n/comments" --jq '.[].user.login'
  gh api "repos/{owner}/{repo}/pulls/$n/reviews" --jq '.[].user.login'
done | grep -qE '^greptile-apps(-staging)?\[bot\]$'
```

On GitLab or Perforce, look for notes by the Greptile bot user on recent
MRs or reviews.

- **Found:** continue.
- **Not found:** this does not prove Greptile is absent. It may have been
  installed after the last reviewed PR. Tell the user that Greptile could not
  be confirmed and ask whether it is installed. On a yes, continue. On a no,
  or when no user is available to ask, stop before the review loop.

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

## Run greploop

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
- **Stage only the files you changed.** greploop commits with `git add -A`.
  Stage explicit paths instead, so unrelated changes stay out of the commit.

## Validate every review finding

Before changing code for a review comment:

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

After applying and verifying fixes, continue the greploop review cycle.

- Revalidate new comments rather than treating them as automatically correct.
- Preserve the same scope and decision boundaries across iterations.
- Do not repeat ineffective changes or oscillate between conflicting fixes.
- If feedback repeats, conflicts, or cannot be resolved safely, stop and
  explain the blocker.
- Respect any iteration limits in the underlying greploop skill.
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
