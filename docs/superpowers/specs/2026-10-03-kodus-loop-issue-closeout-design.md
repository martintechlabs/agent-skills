# kodus-loop issue closeout — design

## Problem

The loop resolves Kody threads on GitHub, but the same findings show as **Open** in
the Kodus Issues UI. Resolving a GitHub thread does not change any Kodus state.

## Source facts (kodustech/kodus-ai source, read 2026-10-03)

- Kodus tracks each suggestion's `implementationStatus`. Only Kodus sets it: an LLM
  check (`CHECK_SUGGESTION_IMPLEMENTATION`) runs on every `synchronize` push and
  compares the new code against the suggestion. GitHub thread resolution is not an
  input.
- Kody Issues are created only when the PR closes (`processClosedPr`). Each
  suggestion still `not_implemented` becomes an Open issue. Declined findings are
  always `not_implemented`. A fix that differs from Kody's suggested code can be
  judged `not_implemented` too.
- On the same close, Kodus re-checks open issues for the changed files and resolves
  the ones whose problem is gone. That check missed the screenshot case.
- Kody's conversation agent has `KODUS_UPDATE_KODY_ISSUE_STATUS`. It only **offers**
  the write ("say the word") and acts only when the developer's latest message
  instructs it. Kody answers replies in its own threads.
- Kody's chat gets the issue tools and the thread's file path and PR number, but
  not an issue id. Seen live on PR #46 (open at the time): Kody tried to update the
  issue, passed the comment id, and the tool failed ("the comment id isn't the
  issue id"). The closeout reply therefore tells Kody to look the issue up with
  `KODUS_LIST_KODY_ISSUES` first.
- No webhook code acts on 👍 reactions for issue status. Reactions feed fine-tuning
  only.

## Decision

The user chose in-thread replies over a Kodus Team API key (no new secret).

- **Closeout mode.** When the PR is merged or closed, kodus-loop runs closeout
  instead of the loop: for every Kody thread, reply
  `@kody Yes, mark the Kody issue for this finding as resolved/dismissed`, then read
  Kody's answer and report the threads it did not confirm.
- **Classification.** The latest user reply must state `Fixed in` / `Addressed in`
  or `Declined:`. Other replies and resolution without a reply need triage from
  the full thread and code evidence before a status command. A clarification is
  not a decline. Unresolved with no reply = left alone and reported. An existing
  closeout instruction resumes its exchange instead of posting a new instruction.
- **Loop changes that make classification possible:** reply `Fixed in <sha>.` on a
  fixed thread before resolving it. Prefer Kody's suggested code when it is
  acceptable, so Kodus's own check marks it implemented and no issue is created.
- **Open-PR offers.** While the PR is open, no Kody Issue exists. A Kody offer to
  mark an issue is added to the handled list and not answered.
- Version 0.1.1 → 0.2.0 (new capability).
- **Missing head check.** Absence does not establish an empty closeout. Recover
  the bot login from the last 20 PRs and inspect older threads. If identity or
  thread data cannot be confirmed, report manual follow-up with remediation.
  History queries must preserve API errors and stop with failure; a failed read
  must not look like an empty successful lookup.

## Talking with Kody

A single reply is not enough. Kody answers each reply in its threads: it verifies,
disputes, asks a question, or offers to act. The skill reads that answer (reference
§8) and responds to it: evidence on a dispute, an answer to a question, an explicit
instruction on an offer (closeout only), the lookup hint when an update fails. At
most 3 replies per thread per run; after that the thread is reported as disputed.
In the loop, a thread stays unresolved while Kody still disagrees, so the next pass
picks it up. Track pending findings independently of GitHub resolution state:
a late rebuttal on a resolved thread must still block completion and enter the
next fix batch. Count only replies posted since this run began toward the limit;
keep older messages available to resume a closeout exchange.

## Rejected

- Kodus MCP endpoint with a Team API key: deterministic, but needs a secret in the
  target repo. Can be added later if in-thread replies prove unreliable.
- Reacting 👍: no code path changes issue status from a reaction.
