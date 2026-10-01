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

- REST author login `kody-ai[bot]`; GraphQL author login `kody-ai`.
- Check run name `Kody Code Review`. Outcomes seen: `success` ("Code Review
  Complete"), `skipped` ("Code Review Skipped", summary gives the reason, e.g.
  "No New Commits"), `failure` (review could not complete; Kody also posts a PR
  comment with the reason).
- Inline comments start with badges: category (`Bug`, `Security`, `Performance`,
  ...) and `severity_level-<low|medium|high|critical>`, and carry a
  "Prompt for LLM" `<details>` block.

## Decisions

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
- **Trigger discipline:** after a push, wait up to 2 minutes for an automatic check
  run to appear before posting `@kody start-review`. Never post a trigger while a
  Kody check run on `HEAD_SHA` is queued or in progress. One review per fix batch.
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
