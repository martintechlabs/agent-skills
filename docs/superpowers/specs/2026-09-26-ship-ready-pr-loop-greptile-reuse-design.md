# `ship-ready-pr-loop` Greptile Review Reuse Design

## Goal

Stop the Greploop phase from spending Greptile reviews that add no information: a second review of a commit Greptile already reviewed, or one review per intermediate fix commit.

## Problem

`/greploop` is a third-party skill. Before each pass it posts `@greptile review` whenever no Greptile check is `PENDING` or `IN_PROGRESS`. A check that already `completed` on the current head commit does not stop it, so the loop can request a second review of the same commit. When a repository still reviews on push, each intermediate push also starts a review.

## Behavior

### Reuse a completed review for the head commit

Before every Greploop pass:

1. Confirm the local `HEAD` equals the PR's `headRefOid`. If not, push first; the review must describe the pushed commit.
2. Look for a Greptile check run on `headRefOid` with status `completed`, or a Greptile PR review whose `commit_id` equals `headRefOid`.
3. If one exists, that review is current. Invoke Greploop with the instruction to read those results and not post a new trigger.
4. Request a new review only when the head commit has no completed Greptile review.

A pass that reuses a current review counts toward the five-pass limit, because it yields a score and findings the same way a new review does.

### One trigger per fix batch

Greptile can be configured for manual-only reviews (`"autoReview": []`), so pushes start no reviews. Commit and push fixes as they are made, but request a review once per pass, after every fix for the current findings is committed, pushed, and validated. Never request a review per commit.

If the repository still reviews on push, push once per pass so each push maps to one review, and let the reuse check pick up that automatic review instead of triggering another.

## Out of scope

- Editing the third-party `greploop` skill.
- Committing `greptile.json`; the dashboard setting already exists, and whether a partial file replaces other dashboard settings is unverified.
- Preserving Greptile's score block when step 6 edits the PR body.
