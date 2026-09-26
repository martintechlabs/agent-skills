# `ship-ready-pr-loop` Greptile Review Reuse Design

## Goal

Stop the Greploop phase from spending Greptile reviews that add no information: a second review of a commit Greptile already reviewed, or one review per intermediate fix commit.

## Problem

`/greploop` is a third-party skill. Before each pass it posts `@greptile review` whenever no Greptile check is `PENDING` or `IN_PROGRESS`. A check that already `completed` on the current head commit does not stop it, so the loop can request a second review of the same commit. When a repository still reviews on push, each intermediate push also starts a review.

## Behavior

### Reuse a completed review for the head commit

Before every Greploop pass:

1. Confirm the local `HEAD` equals the PR's `headRefOid`. If not, stop, push, and rerun the check from the start so it queries the new head.
2. Require the Greptile check run on `headRefOid` to be `completed` with conclusion `success`. A cancelled, timed-out, skipped, or failed check is not a review.
3. If the check run is `queued` or `in_progress`, a review is already running: do not trigger; let Greploop wait, then rerun the check. In a review-on-push repository, allow a bounded wait (2 minutes) after a push for the automatic check run to appear before treating it as absent. Query check runs with pagination so a Greptile check past the first page is not missed.
4. Require a Greptile summary (PR description, or the latest-updated Greptile PR comment that carries a score) to show a confidence score whose `Last reviewed commit` link ends in `headRefOid`. A score for another commit is stale. (A PR review object alone is not enough: a clean 5/5 review posts none, and a review object carries no score.)
5. When both hold, invoke Greploop with the instruction to read those results and not post a new trigger. Otherwise request a new review.

A pass that reuses a current review counts toward the five-pass limit, because it yields a score and findings the same way a new review does.

### One trigger per fix batch

Greptile can be configured for manual-only reviews (`"autoReview": []`), so pushes start no reviews. Commit and push fixes as they are made, but request a review once per pass, after every fix for the current findings is committed, pushed, and validated. Never request a review per commit.

If the repository still reviews on push, push once per pass so each push maps to one review, and let the reuse check pick up that automatic review instead of triggering another.

## Out of scope

- Editing the third-party `greploop` skill.
- Committing `greptile.json`; the dashboard setting already exists, and whether a partial file replaces other dashboard settings is unverified.
- Preserving Greptile's score block when step 6 edits the PR body.
