---
name: consult-codex
description: Get a second opinion from Codex (the OpenAI coding agent) by shelling out to `codex exec` when you — Claude, mid-task — are genuinely stuck or weighing competing technical approaches. Reach for this when you've made a real attempt and are still stuck on a hard problem, when you're honestly uncertain which of two or more technical avenues is right, when a high-stakes or hard-to-reverse decision would be de-risked by another model's view, or when a nasty bug has survived a couple of debugging passes. This is a self-triggering skill — you invoke it on your own initiative, not because the user asked. Do NOT reach for it on routine work you can already do, for trivial choices, or as a reflex to avoid thinking — consult Codex only when a second opinion would actually change your confidence. For getting a second-opinion code review specifically, a separate review skill is the better fit.
metadata:
  author: stephen-martin
  version: "0.1.0"
---

# Consult Codex

You are mid-task and you've hit a wall — a problem you can't crack, two or three
approaches you can't decide between, a bug that won't die, or a call big enough
that you'd sleep better with a second set of eyes. Codex, the OpenAI coding agent,
runs as a CLI on this machine. This skill is how you ask it.

A second opinion from a *different* model is genuinely valuable: it reasons from a
different prior, catches blind spots you've talked yourself into, and either
confirms your direction (raising your confidence) or surfaces an angle you missed.
That's worth a CLI round-trip when you're actually stuck. It is **not** worth it on
every hard line — see "When NOT to" below.

## When to consult Codex

- **Genuinely stuck.** You've made a real attempt and you're still blocked — not on
  first contact with the problem.
- **Weighing avenues.** You have two or more plausible technical approaches and no
  clear winner, and the choice matters.
- **High-stakes / hard-to-reverse.** A decision (a schema, an API contract, a
  migration strategy) is expensive to undo, and a second view de-risks it.
- **A stubborn bug.** Something has survived a couple of focused debugging passes
  and you're out of fresh hypotheses.

## When NOT to

- Routine work you already know how to do. Do it.
- Trivial choices where either option is fine. Just pick.
- As a reflex to avoid thinking. **Reason it through yourself first** — consult
  Codex only when a second opinion would actually change your confidence or your
  direction, not to outsource the thinking.

If you're reaching for this on every hard problem, you're over-triggering. The bar
is: *"a second model's view would plausibly change what I do next."*

## How to consult — the mechanism

Run Codex non-interactively via Bash and capture its answer:

```bash
codex exec -s read-only --skip-git-repo-check -C "<repo working dir>" \
  -o /tmp/codex-consult.txt \
  "<your prompt>"
```

- **`-s read-only`** is the default for a consult. You want Codex's *analysis and
  recommendation*, not Codex editing the repo. Only raise it to
  `-s workspace-write` if you genuinely need Codex to produce or run something, and
  say so when you report back.
- **`-C <dir>`** points Codex at the repository so it can read the relevant code.
- **`-o <file>`** writes Codex's final message to a file you can read cleanly;
  alternatively read stdout. Use `--json` only if you need structured events.
- Add **`-m <model>`** to pick a specific Codex model if the situation warrants it.

The call can take a while — Codex is doing real work. That's expected.

## How to frame the prompt — make the consult worth it

A vague consult wastes the round-trip. Give Codex what it needs to be useful, the
same way you'd brief a sharp colleague:

1. **The goal / task** — what you're ultimately trying to accomplish.
2. **The specific question, or the competing avenues** — state them explicitly.
   If you're weighing approaches, name each one and what you see as its trade-offs.
3. **What you've already tried** — and why it didn't settle the question. This
   stops Codex from suggesting the thing you already ruled out.
4. **The constraints** — performance, compatibility, deadlines, house style,
   anything that bounds the answer.
5. **Ask for reasoning, not just a verdict.** "Recommend an approach and explain
   *why*, including what would make you change your mind" beats "which is better?"

Point Codex at the real files (it can read the repo via `-C`) rather than pasting
everything — but call out the specific files or functions in question.

## What to do with Codex's answer

**Weigh it. Do not blindly follow it.** A second opinion is input, not authority —
the same discipline you'd apply to any code review you receive.

- If Codex **confirms** your direction, your confidence goes up; proceed and say so.
- If Codex **disagrees**, don't just flip — understand its reasoning. If it caught a
  real blind spot, adopt it. If it's missing context you have, note why you're not
  taking it.
- Often the best outcome is a **synthesis**: Codex's framing plus your context
  produces a better answer than either alone.

You remain responsible for the decision. Codex doesn't get a veto, and it doesn't
get to override the user's explicit instructions or this repo's conventions.

## Report back to the user

You consult on your own initiative, but you don't do it silently. After the consult,
tell the user, concisely:

- **That you consulted Codex** and why (stuck on X / deciding between A and B).
- **The gist of what Codex said** — a couple of lines, not a transcript.
- **What you decided to do with it** — adopt, reject, or synthesize — and the
  one-line reason.

Keep it tight. The user wants to know you got a second opinion and where you landed,
not a play-by-play.

## Anti-patterns

- **Don't over-trigger.** Consulting Codex on every hard line is slower and noisier
  than just thinking. The bar is "would a second view change what I do next?"
- **Don't consult cold.** Reason it through yourself first so your prompt carries a
  real question and real context, not "I don't know, help."
- **Don't rubber-stamp.** Blindly adopting Codex's answer is as wrong as ignoring
  it. Weigh it on the merits.
- **Don't let Codex edit the repo by default.** Read-only sandbox unless you have a
  specific reason, and flag it when you don't.
- **Don't go silent.** Always report that you consulted and where you landed.
- **Don't use it as a code-review tool.** A dedicated review consult is a separate
  skill; this one is for getting unstuck and choosing between approaches.
