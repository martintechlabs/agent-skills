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
- No webhook code acts on 👍 reactions for issue status. Reactions feed fine-tuning
  only.

## Decision

The user chose in-thread replies over a Kodus Team API key (no new secret).

- **Closeout mode.** When the PR is merged or closed, kodus-loop runs closeout
  instead of the loop: for every Kody thread, reply
  `@kody Yes, mark the Kody issue for this finding as resolved/dismissed`, then read
  Kody's answer and report the threads it did not confirm.
- **Classification.** Fixed = the thread has the user's `Fixed in` / `Addressed in`
  reply, or it is resolved with no reply from the user (older runs and Kodus
  auto-resolves). Declined = the user replied with a reason. Unresolved with no
  reply = left alone and reported.
- **Loop changes that make classification possible:** reply `Fixed in <sha>.` on a
  fixed thread before resolving it. Prefer Kody's suggested code when it is
  acceptable, so Kodus's own check marks it implemented and no issue is created.
- **Open-PR offers.** While the PR is open, no Kody Issue exists. A Kody offer to
  mark an issue is added to the handled list and not answered.
- Version 0.1.1 → 0.2.0 (new capability).

## Rejected

- Kodus MCP endpoint with a Team API key: deterministic, but needs a secret in the
  target repo. Can be added later if in-thread replies prove unreliable.
- Reacting 👍: no code path changes issue status from a reaction.
