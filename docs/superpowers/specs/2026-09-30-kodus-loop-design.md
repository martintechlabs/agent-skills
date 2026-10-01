# kodus-loop — design

## Goal

A Greploop-style skill for Kodus: drive a GitHub PR through Kody (the Kodus review
bot) until Kody's latest review of the PR head is complete and no Kody review thread
is unresolved. Fix valid findings, reply to and resolve false positives, push, and
repeat, capped at 5 passes.

## Source facts (verified 2026-09-30)

From https://docs.kodus.io/en/how_to_use/code_review/flow and related pages:

- Kody reviews on PR open, on new commits (cadence: `automatic` | `auto_pause` |
  `manual`), or on `@kody start-review`. `@kody review --force` overrides a skip.
- Skips: no new commits, merge-only commits, all files ignored, file limit, draft
  (if configured), branch not in scope, invalid config.
- Status reactions: 🚀 processing, 🎉 done, 👀 skipped, 👎 unlicensed, 😕 error.
- No confidence score. Reactions to suggestions do not train future reviews; Kody
  Rules and `@kody remember` do.

From live, read-only `gh` queries against public Kodus-reviewed PRs:

- REST author login `kody-ai[bot]`; GraphQL author login `kody-ai` (Kodus cloud).
  Self-hosted installs use their own app (seen: `kodus-27b[bot]`), so the skill reads
  the login from the `Kody Code Review` check run's `app.slug`.
- A full review can take about 11 minutes from trigger to completion. The only
  reaction seen on real triggers is 🎉 at completion.
- Check run name `Kody Code Review`. Outcomes seen: `success` ("Code Review
  Complete"), `skipped` ("Code Review Skipped", summary gives the reason, e.g.
  "No New Commits"), `failure` (review could not complete; Kody also posts a PR
  comment with the reason).
- Inline comments start with badges: category (`Bug`, `Security`, `Performance`,
  ...) and `severity_level-<low|medium|high|critical>`, and carry a
  "Prompt for LLM" `<details>` block.

## Decisions

- **Install check first.** GitHub does not let a user token list app
  installations. Instead, the skill looks for a `Kody Code Review` check run on the
  PR head and the last 20 PR heads. Kodus adds one on every PR push even with
  automatic reviews off (seen on martintechlabs/agent-skills#46: `skipped`,
  "Automated Review is disabled"). None found → stop with an explanation and fix
  steps, and post no trigger. A "Automated Review is disabled" skip means "trigger a
  review", not "stop".

- **GitHub only.** This is the only platform the skill supports. Every query is
  verified against real output.
- **Web review only.** Reviews come from Kody on the GitHub PR. The skill does not
  install or run the Kodus CLI.
- **Exit:** the newest `Kody Code Review` check run on `HEAD_SHA` is `completed`
  with `success` (or `skipped` with "No New Commits", which means an earlier review
  covers this head; a merge-only skip counts the same) AND zero unresolved review
  threads started by `kody-ai` AND no unhandled PR-level suggestion or Kody
  rebuttal. Handled PR-level comments are tracked by id, because Kody edits its
  comments in place.
- **Hard stops:** `skipped` for any other reason (file limit, draft, branch,
  ignored files), `👎` unlicensed, two consecutive `failure`s, 5 passes, or a
  10-minute wait with no completed check.
- **Trigger discipline:** automatic reviews are off by default, so the skill posts
  `@kody start-review` whenever no Kody check run exists on `HEAD_SHA`. Never post a
  trigger while a Kody check run on `HEAD_SHA` is queued or in progress. One review
  per fix batch. Progress is read from the check run and from Kody's reaction on the
  trigger comment; no response within 2 minutes stops the loop.
- **Thread handling:** resolve only `kody-ai` threads. A false positive gets a reply
  with the reason before it is resolved. Never resolve human threads.
- **Commits:** stage only the files the fixes touched (no `git add -A`).
- **Prose only, no `scripts/`.** The skill is inline `gh` commands plus a
  `references/github-queries.md`; no fake-`gh` test suite is needed. Validation is
  the live read-only query run above.
- Not wired into `ship-ready-pr-loop` (not requested).

## Lessons carried from the greploop review

Greploop resolves threads without an author filter, reads "unresolved" comments from
a REST endpoint that has no resolution state, keeps going after a non-success check,
never ties the score to the head commit, and posts a review trigger even when a push
already started one. kodus-loop avoids each of these by design.
