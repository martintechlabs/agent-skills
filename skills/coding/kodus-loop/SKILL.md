---
name: kodus-loop
description: Iteratively drive a GitHub pull request through Kodus code review until Kody (the Kodus review bot) has completed a review of the current head commit and no Kody review thread is left unresolved. Waits for or triggers the Kody review, fixes valid findings, replies to and resolves false positives, pushes, and repeats for up to 5 passes. On a merged or closed PR, it runs a closeout instead: it asks Kody in each thread to mark the matching Kody Issue resolved or dismissed, so the Kodus Issues page does not keep them open. Use when the user says "run the Kodus loop", "get Kody to sign off on this PR", "fix all the Kody comments", "kodus loop", "close out the Kody issues", "Kody issues still show open", or wants a PR fully cleaned up against Kodus review. Works only through Kody on the GitHub PR. Use greploop instead when the repository reviews with Greptile.
metadata:
  author: stephen-martin
  version: "0.2.0"
---

# Kodus Loop

Fix a GitHub PR until Kody's review of the head commit is complete and every Kody
thread is resolved. Kody gives no confidence score, so "done" is a completed review
of `HEAD_SHA` plus zero unresolved Kody threads.

Exact queries, field shapes, and the bot's two login spellings are in
[references/github-queries.md](references/github-queries.md). Read it before the
first pass.

## Inputs

- **PR number** (optional). Without it, use the PR for the current branch:
  `gh pr view --json number -q .number`. Check out the PR branch if needed.

Read the PR state first: `gh pr view "$PR" --json state -q .state`. If it is
`MERGED` or `CLOSED`, skip step 0 and the loop, and run
[Closeout](#closeout-merged-or-closed-pr).

## GitHub threads and Kody Issues are separate

Resolving a GitHub thread does not change anything in Kodus. Kodus keeps its own
status for each suggestion. Only Kodus sets it: on every push it checks whether the
new code implements the suggestion. When the PR closes, each suggestion that is
still "not implemented" becomes an **Open Kody Issue**. That includes every finding
you declined, and fixes that look different from Kody's suggested code. The loop
cannot close these issues, because they do not exist until the PR closes. The
closeout does that after the merge.

## Preconditions

- `gh auth status` is green and the remote is GitHub.
- The working tree is clean, or every change in it belongs to this PR.
- Automatic reviews are normally off, so this skill triggers every review itself.

## 0. Check that Kodus is installed

Run this before anything else, including before you post a trigger.

When the Kodus GitHub App can see a repository, it adds a `Kody Code Review` check
run on every push to a PR, even with automatic reviews off (the run is `skipped`
with "Automated Review is disabled"). Look for that check run on this PR's head and
on the heads of the last 20 PRs (reference §0). If you just pushed, recheck every
10 s for up to 2 minutes before you decide.

- **Found:** Kodus is installed. Use the check run's `app.slug` as the bot login.
- **Not found:** stop. Do not post `@kody start-review`. Tell the user:

```
Kodus is not installed on <owner/repo>, so the Kodus review loop cannot run.

Why: there is no "Kody Code Review" check run on this PR or on the last 20 PRs.
Kodus adds that check on every PR push when its GitHub App can see the repository,
even when automatic reviews are off.

How to fix:
1. Kodus cloud: sign in at https://app.kodus.io, connect GitHub, and install the
   Kodus GitHub App when prompted. Then select <owner/repo> as a repository to review.
2. App already installed? Give it access to this repository:
   - Organization: https://github.com/organizations/<owner>/settings/installations
   - Personal account: https://github.com/settings/installations
   Open the Kodus app → Configure → Repository access, and add <owner/repo>.
3. Self-hosted Kodus: install your own Kodus GitHub App on <owner/repo>.
4. Connected Kodus with a personal access token instead of the app? This loop needs
   the GitHub App: only an app can create the check runs it reads.

Then push a commit to the PR and run the loop again.
```

## Loop

Repeat. **At most 5 passes.** A pass is one A→E cycle. A retry trigger after a
failure is part of the same pass.

### A. Get a review of `HEAD_SHA`

1. Push any committed work: `git push`.
2. Read the newest Kody check run on `HEAD_SHA` (reference §1). Save its `id` and
   take the bot login from its `app.slug`; self-hosted installs use their own app.
3. Act on its state:

| State | Action |
| ----- | ------ |
| `queued` / `in_progress` | A review is running. Do not trigger. Poll (step 4). |
| `completed` + `success` | Review is current. Go to B. |
| `completed` + `skipped`, summary says "Automated Review is disabled" | Kodus is installed but did not review this head. Treat it as "no check run" below. |
| `completed` + `skipped`, summary says no new commits or only merge commits | An earlier review covers this head (for example, after you merged `main` in). Go to B. |
| `completed` + `skipped`, any other reason | Stop. Report the reason (file limit, draft, branch not in scope, all files ignored). Looping cannot fix it. |
| `completed` + `failure` | Read Kody's newest PR comment for the reason (reference §4). Stop on a license or configuration error. Otherwise wait 3–5 minutes (a rate limit says "try again in a few minutes"), then post `@kody start-review` once. Only a check run with a higher `id` than the failed one is the retry; the old failed run does not count. A second consecutive failure stops the loop. |
| no check run | No review of this head exists. Reuse a pending trigger (reference §6: yours, under 5 minutes old, no Kody reaction yet), or post `@kody start-review`. Keep the comment id. |

4. Poll every 30 s for up to 30 minutes (a full review can take over 10 minutes)
   until the review you wait for is `completed`:
   - **Review already running** (`queued` / `in_progress` row): wait for the saved
     run itself. Do not wait for a newer `id`; none will come.
   - **After a trigger:** wait for a Kody check run on `HEAD_SHA` with an `id`
     higher than the saved one (any `id` if there was no run).

   Then apply the table in step 3 to that run. Kody's reaction on the trigger comment is a secondary signal (reference §6). If
   no new check run and no Kody reaction appear within 5 minutes of the trigger,
   stop and report that Kodus did not respond (it may not be installed on this
   repository). On timeout, stop and report. Never read findings from an older
   commit's review.

Post at most one trigger per pass. Never post a trigger while a Kody check run on
`HEAD_SHA` is queued or in progress.

### B. Collect findings

1. List unresolved review threads started by Kody (reference §2). Filter by author.
   Never touch threads that humans started.
2. For each thread, read the severity and category badges and the
   `Prompt for LLM` block (reference §3).
3. Read Kody PR-level suggestion comments (reference §4, badge filter). Kody edits
   its comments in place, so do not judge "new" by timestamp. Keep a list of the
   comment ids you already handled this run; only an id not on that list is a new
   finding. A suggestion with no inline thread is still a finding.
4. Look for Kody replies: the same §2 query also returns resolved Kody threads
   whose last comment is a Kody reply (`rebuttal: true`). Kody answers inside the
   thread and does not reopen it. Read `lastReply` and handle it with
   [Talking with Kody](#talking-with-kody-in-a-thread). Only a `lastReplyId` not on
   the handled list is new.

### C. Exit check

Stop when the step-A review is current **and** B found zero unresolved Kody threads
and no unhandled PR-level suggestions or Kody replies. Also stop at the pass
limit.

### D. Triage and fix

For each finding, read the code in context and decide:

- **Valid** (any severity): fix it. Fix `critical` and `high` first. When Kody's
  suggested code is acceptable, use it. Kodus compares each push with the
  suggestion, and a fix in a different shape can stay "not implemented" and become
  an Open Kody Issue.
- **False positive or won't fix:** do not change code. You reply in step E.
- **Outdated thread** (`isOutdated: true`): check if the current code still has the
  problem. If it does not, treat it as fixed in the commit that removed it. If it
  does, treat it as Valid.
- **PR-level suggestion:** fix it, or decline it in the final report. You cannot
  resolve it; add its id to the handled list either way.

Run the repository's tests, lint, and typecheck before you commit. Do not push
broken code to get another review.

### E. Commit, resolve, push

1. If you changed no code this pass (every finding was declined or already
   addressed), skip to step 4. Do not make an empty commit.
2. Stage only the files you changed: `git add <paths>`. Do not use `git add -A`.
   Then commit: `git commit -m "fix: address Kodus review feedback (kodus-loop pass N)"`.
3. `git push`
4. Reply on each Kody thread you handled (reference §5). Give Kody enough evidence
   to check the fix itself, the way a reviewer would want it:
   - Fixed: `Fixed in <short sha>. <what changed, with path:line>. <the test that
     covers it, or how you checked it>.` Start with `Fixed in`; the closeout uses
     it to tell fixed threads from declined ones.
   - Declined: one or two sentences with the concrete reason (the code, a caller, a
     config, or a convention that makes the finding wrong).
5. Wait for Kody's answers and respond with
   [Talking with Kody](#talking-with-kody-in-a-thread). Resolve a thread when Kody
   agrees, or when it does not answer in time. Leave it unresolved when Kody still
   disagrees; the next pass picks it up in B.
6. Go back to A. A push does not start a review, so step A posts the next
   trigger.

One review per fix batch: commit all fixes for the pass, then push once.

## Talking with Kody in a thread

Kody answers replies in its own review threads, with or without `@kody`. A reply
is the start of a short exchange, not the end of the thread. Kody's answer tells you
if it accepts the fix or the reason. Read it and answer what it actually says.

1. After you post, poll every 30 s for up to 5 minutes for a Kody reply after your
   newest reply in each thread (reference §8). Post all of a pass's replies first,
   then poll them together.
2. Read Kody's answer and act on it:

| Kody's answer | Your response |
| ------------- | ------------- |
| Agrees: verified the fix, accepts the reason | Done. Resolve the thread (loop only). |
| Offers to change a Kody Issue ("would you like me to mark it resolved?", "say the word") | Loop: Kody agrees, so treat it as agreement. Do not say yes: this PR's issues do not exist until it closes, and an attempt fails (seen live: "the comment id isn't the issue id"). Closeout: say yes as an instruction, with the lookup (below). |
| Says the problem is still there, or only partly fixed | Check its claim in the code. If it is right, the finding is Valid again: leave the thread unresolved for the next pass (loop), or report it (closeout). If it is wrong, reply once with stronger evidence: the exact `path:line`, the test name, or the command output. |
| Asks a question ("which line?", "what about X?") | Answer it with the concrete fact. |
| Says no open Kody Issue matches (closeout) | Done. Kodus already counts the suggestion as implemented. |
| Says the status update failed, or it could not find the issue (closeout) | Reply with the lookup again, and add the file, the PR number, and the first line of the finding. The usual cause is that Kody passed the comment id as the issue id. |
| No answer in 5 minutes | Loop: resolve and note "Kody did not answer". Closeout: report it to check by hand. |

3. To make Kody act, write an instruction, not a question. Kody changes a Kody Issue
   only when your latest message tells it to. Good: `@kody Yes, mark the Kody issue
   for this finding as resolved now.` Not good: `Could you resolve this?`
4. Post at most 3 replies of your own per thread in one run, counting the first. If
   Kody still has not agreed, stop the exchange and report the thread as disputed
   with Kody's last point. Never argue in circles; a third unchanged reason will
   not convince it.
5. Add each Kody reply id you handled to the handled list.

## Teaching Kody

Reactions (👍/👎) on Kody comments do not change future reviews. When the same false
positive comes back in two passes, suggest a Kody Rule or `@kody remember <convention>`
to the user. Do not post it yourself; it changes review behavior for the whole team.

## Report

```
Kodus loop complete.            (or: Kodus loop stopped: <reason>)
  PR:            #123
  Head:          <short sha>
  Passes:        2
  Review:        success on <short sha>
  Fixed:         5 (critical 1, high 2, medium 2)
  Declined:      1 (replied + resolved)
  Remaining:     0
```

When the pass limit stops the loop after a push, say that the last push was never
reviewed. When stopped early, list every remaining finding as
`path:line [severity] one-line summary`, and give the next step (for example: assign
a Kodus license, add the base branch to Kody's config, split the PR).

End every loop report with: `After the PR merges, run the Kodus loop on it again to
close its Kody Issues.`

## Closeout (merged or closed PR)

Kodus creates Kody Issues when the PR closes. Kody's chat in a thread can change an
issue's status, but it only acts when your latest message tells it to. A 👍
reaction does not change an issue's status.

1. Read `closedAt` (`gh pr view "$PR" --json closedAt`). If the PR closed less than
   5 minutes ago, wait until 5 minutes have passed. Kodus creates the issues after
   the close.
2. Get the bot login from §1 on the PR's head commit. If §1 is empty, Kodus never
   reviewed this head: report "nothing to close out" and stop. Then list every Kody
   thread with its closeout class (reference §7).
3. For each thread, by class:

| Class | Meaning | Reply |
| ----- | ------- | ----- |
| `fixed` | Your `Fixed in` / `Addressed in` reply, or resolved with no reply from you | `@kody Yes, mark the Kody issue for this finding as resolved now. It was fixed in <sha>. <LOOKUP>` |
| `declined` | You replied with a reason | `@kody Yes, dismiss the Kody issue for this finding now. <one-sentence reason> <LOOKUP>` |
| `unanswered` | Unresolved, no reply from you | None. List it in the report. |
| `done` | A closeout reply is already there (an earlier closeout run) | None. Continue the exchange from Kody's newest answer in step 4. |

   `<LOOKUP>` tells Kody how to find the issue. The thread's comment id is not the
   issue id, and Kody fails when it uses it. Write: `The comment id is not the issue
   id: find the open issue with KODUS_LIST_KODY_ISSUES (repository <name>, file
   <path>, from PR #<n>, "<finding title>") and update it with
   KODUS_UPDATE_KODY_ISSUE_STATUS.` Use the `<sha>` from your earlier reply when
   there is one; otherwise omit that sentence. Post each reply with §5.
4. Wait for Kody's answers and respond with
   [Talking with Kody](#talking-with-kody-in-a-thread) until Kody confirms that it
   changed the issue, says no open issue matches, or the reply limit is reached. A
   thread counts as closed out only when Kody says it changed the issue (or that
   none is open). "I can do that" is not a confirmation: answer it with the
   instruction.
5. Do not resolve, unresolve, or edit any thread in the closeout.

Report:

```
Kodus closeout complete.
  PR:            #123 (merged)
  Resolved:      4 (Kody confirmed)
  Dismissed:     1 (Kody confirmed)
  Check by hand: 2  (no answer, disputed, or not confirmed: path:line, Kody's last point)
  Unanswered:    0
```

For each "check by hand" thread, tell the user to set the status on the Kodus
Issues page (https://app.kodus.io, or their self-hosted Kodus).

## Hard rules

- Do not resolve a thread that a human started.
- Do not resolve a Kody thread without a pushed fix or a posted reply.
- Do not trust a review of any commit other than `HEAD_SHA`.
- Do not post `@kody start-review` while a Kody review of `HEAD_SHA` is running.
- Do not use `@kody review --force` unless the user asks. A "No New Commits" skip
  means the head is already reviewed.
- Do not merge the PR.
- Do not ask Kody to change a Kody Issue while the PR is open. Do it only in the
  closeout.
- Do not install or run the Kodus CLI (`kodus`). Get every review from Kody on the
  GitHub PR.
