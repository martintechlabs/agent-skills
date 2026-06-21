---
name: codex-review
description: Get a second-opinion code review from Codex (the OpenAI coding agent) by shelling out to `codex exec review`. Use this both ways — reach for it on your own initiative after you've written a substantial chunk of code or before you open a PR (a second pair of eyes on your own work), and use it whenever the user explicitly asks for a Codex review ("have Codex review this", "get a Codex review of the branch / PR / diff", "what does Codex think of these changes"). By default it reviews the whole branch diff against its base branch; it can also review just the uncommitted working changes or a single commit. Triage the findings on their merits — fix the real ones, push back on the wrong ones — rather than rubber-stamping them. This is for reviewing code that's already written; if you're stuck or choosing between approaches before writing code, use consult-codex instead.
metadata:
  author: stephen-martin
  version: "0.1.0"
---

# Codex Review

You've written some code and you want a second pair of eyes before it ships — or
the user asked you to put Codex on it. Codex, the OpenAI coding agent, has a
built-in review mode (`codex exec review`) that diffs the repo, reasons about the
changes, and reports findings. This skill is how you run it and what to do with
what comes back.

A review from a *different* model is worth the round-trip: it reasons from a
different prior and catches the bug or edge case you've stopped being able to see in
your own work. But a review is **input, not a verdict** — you triage the findings,
you don't rubber-stamp them.

## When to use

**Self-triggered (your own initiative):**

- You've just finished a substantial chunk of code — a feature, a refactor, a
  non-trivial bug fix — and a second pass would catch what you've gone blind to.
- You're about to open a PR and want a review before you do.

**User-invoked:**

- The user asks for a Codex review in any phrasing: "have Codex review this", "get
  a Codex review of the branch", "what does Codex think of these changes", "run a
  second-opinion review".

**When NOT to self-trigger:** tiny or mechanical edits, work-in-progress you'll keep
changing in a moment, or as a reflex on every save. The bar for self-triggering is
*"this is a meaningful unit of work that's worth a real review before it moves on."*
When the user asks, just run it.

## How to run — the mechanism

Run Codex's review mode from the repository root via Bash and capture the result:

```bash
codex exec review --base <base-branch> -o /tmp/codex-review.txt
```

Pick the scope to match the situation:

- **Whole branch vs. base (default).** `--base <base-branch>` reviews everything the
  branch adds on top of its base — the pre-PR review. Detect the base branch first
  (see below); don't hardcode `main`.
- **Uncommitted working changes.** `--uncommitted` reviews staged, unstaged, and
  untracked changes — use this to review what you just wrote *before* committing.
- **A single commit.** `--commit <sha>` reviews exactly that commit's changes.

Useful extras:

- A **custom-instructions prompt** to focus the review:
  `codex exec review --base <base-branch> "Focus on the auth and session changes;
  flag any authz gaps." -o /tmp/codex-review.txt`
- **`--title "<commit title>"`** to label the review summary.
- **`-m <model>`** to choose a Codex model.
- **`-o <file>`** writes Codex's final message to a file you can read cleanly; or read
  stdout. Use `--json` only if you need structured events.

Review mode is read-only by nature — Codex analyzes the diff, it doesn't edit your
repo — so there's no sandbox flag to set here.

### Detecting the base branch

Don't assume `main`. Resolve it, in order of preference:

1. If you're reviewing a branch destined for a known PR base, use that base.
2. Otherwise use the remote's default branch:
   `git symbolic-ref --short refs/remotes/origin/HEAD` (e.g. `origin/main` →
   `main`), falling back to whichever of `main`/`master` exists.

The review only makes sense against the branch this work will actually merge into.

## What to do with the findings

**Triage every finding on its merits. Do not rubber-stamp the review, and do not
dismiss it wholesale either** — apply the same discipline you'd want when receiving
any code review:

- **Real bug, correctness issue, or security gap** → fix it. This is the payoff.
- **Wrong, or based on context Codex didn't have** → don't act on it; note briefly
  *why* you're not (e.g. "Codex flagged X as unguarded, but it's validated upstream
  in `foo()`").
- **Style / preference / nit** → surface it but treat it as the user's call, not a
  mandate. Respect the repo's existing conventions over Codex's defaults.

When a finding is plausible but you're not certain, verify it against the actual
code before either fixing or dismissing — don't guess.

Codex does not get to override the user's explicit instructions or this repo's
established conventions. You own the final call on every finding.

## Report back

Whether you ran it on your own or because the user asked, report concisely:

- **What you reviewed** — scope (whole branch vs. `main`, the uncommitted changes,
  commit `abc123`).
- **The findings that matter** — grouped by severity, a line each, not the raw
  transcript.
- **What you're doing about them** — which you'll fix, which you're dismissing and
  why, which are nits for the user to decide.

Then act on the agreed fixes.

## Anti-patterns

- **Don't rubber-stamp.** "Codex found 5 issues, fixing all 5" without judging them
  is how a wrong suggestion becomes a wrong commit. Triage first.
- **Don't dismiss wholesale either.** The point of a second opinion is to act on the
  real findings; ignoring all of them wastes the review.
- **Don't hardcode the base branch.** Resolve it; review against what the work will
  actually merge into.
- **Don't self-trigger on trivia.** Tiny edits and work-in-progress don't need a
  formal Codex review.
- **Don't go silent.** Always report what you reviewed and what you concluded.
- **Don't use this when you're stuck *before* writing code.** That's `consult-codex`
  — this skill reviews code that already exists.
