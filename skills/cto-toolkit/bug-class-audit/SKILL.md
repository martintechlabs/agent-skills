---
name: bug-class-audit
description: Quantify how systemic ONE specific bug class is in a codebase by classifying every recent fix-prefixed merged PR against explicit inclusion/exclusion criteria, then producing a headline percentage plus representative examples, patterns, and caveats. Use whenever the user names (or can be guided to name) a single recurring bug pattern and wants a defensible number — "is the stale-state pattern really a problem?", "how often do we forget to invalidate?", "is silent error swallowing a real issue here?", "what % of our fixes are auth bugs?" — especially to justify a refactor, scope an initiative, or replace a vibe with evidence. Use codebase-triage for fast orientation, codebase-audit for a graded multi-dimensional review, tech-due-diligence for a deal decision, and weekly-risk-review for top open issues; reach for bug-class-audit specifically when the question is about ONE pattern's frequency over historical PRs rather than the codebase's overall state.
metadata:
  author: stephen-martin
  version: "0.1.0"
---

# Bug-Class Audit

Quantify how systemic a specific bug class is by classifying every recent `fix:` PR against explicit inclusion/exclusion criteria, then reporting a headline percentage plus the representative examples and patterns that make the number actionable.

The output of this skill is a number the user can put in front of stakeholders ("19% of our fix PRs in the last 100 merged were the same bug") plus the examples they can point at to make the case for whatever change the audit motivates. Without this rigor, "we keep shipping the same bug" is a vibe — with it, it's an argument.

## When to use

- The user names a bug class they think is recurring and wants to size it: "is the stale-state pattern really a problem?", "how often do we forget to invalidate?", "is silent error swallowing a real issue here?"
- The user asks for a brittleness or quality audit of an unfamiliar codebase ("we just took this codebase over — what's most fragile?")
- An architectural change is being considered and needs justification ("should we migrate to X?" — audit the bugs X would prevent)
- A specific incident just happened and you want to know if it was a one-off or the tip of a pattern

## When NOT to use

- The user just wants a code review of a specific PR — use a PR-review skill instead
- The user wants to investigate a single bug — use git-blame / debugging skills instead
- The user has no specific hypothesis and wants a generic codebase review — push back and either (a) propose a class from `references/bug-classes.md`, or (b) suggest a broader audit skill instead

## Procedure

### Step 1 — Scope the hypothesis

The audit's defensibility comes from a precise bug-class definition. Vague hypotheses produce vague numbers. Before doing anything else:

- If the user gave a specific class, restate it back in one sentence and confirm.
- If the user gave a vague ask ("what's brittle?"), do NOT start auditing. Either propose 2–3 candidate classes from `references/bug-classes.md` and ask which to investigate, or ask one direct clarifying question to narrow.
- Identify the **denominator**. Almost always: `fix:`-prefixed merged PRs within the last N (default 100). Other denominators are valid (only `feat:` PRs to surface "features that ship with bugs", only PRs touching a specific path) — name it explicitly.

### Step 2 — Write inclusion and exclusion criteria

This is the most important step. Both lists must be explicit *before* reading any PRs, so judgment doesn't drift toward inflation as you go.

Write the criteria following this template:

```
A PR is COUNTED when ALL of:
  - <symptom or mechanism in one sentence>
  - <a fix-shape that matches: what was added, removed, or rewired>
  - <any other necessary condition>

A PR is EXCLUDED when ANY of:
  - <plausible but wrong category 1>
  - <plausible but wrong category 2>
  - <category 3>
```

Then write 2–3 concrete EXAMPLES of each, ideally drawn from the bug-classes reference catalog or from the user's own description. The examples are how the per-PR judge stays calibrated.

If the criteria can't be written without ambiguity, the class is too fuzzy — narrow it before continuing.

### Step 3 — Delegate the per-PR loop to a subagent

For N ≥ 30 PRs, do NOT read PRs in the main context. Delegate to a subagent (`general-purpose` or similar) with a self-contained prompt. The main context stays clean for synthesis.

The subagent's brief must include:

- One paragraph of context (what just happened in the conversation that motivates this audit)
- The data source command: `gh pr list --repo <owner>/<repo> --state merged --limit N --json number,title,mergedAt,author,additions,deletions`. Tell the subagent to fetch PR details with `gh pr view <num>` and, if descriptions are thin, `gh pr diff <num> | head -200`
- The full inclusion criteria, exclusion criteria, and examples verbatim
- An instruction to **bias toward false negatives**: "When in doubt, classify as ambiguous rather than guessing preventable. Better to undercount than to inflate the number."
- The exact output format (see Step 4)

### Step 4 — Output format

The report must follow this shape so it's usable as-is:

1. **One-line headline.** "Of the last N `fix:` PRs in M merged PRs, X were <class> bugs (Y%). Z more are ambiguous."
2. **Breakdown table.** Markdown columns: PR #, title (truncated), verdict (preventable / ambiguous / not), one-sentence reason. Sorted preventable → ambiguous → not.
3. **Top 5 representative "preventable" examples.** 2–3 sentences each. What specifically went wrong, what the fix did. These are what the user shows the team.
4. **Top 3 "ambiguous" examples.** One sentence each on what made them hard to classify. These tell you whether the criteria need sharpening.
5. **Patterns.** 2–3 sentences on which subsystem / author / time window keeps showing up. What recurring code smell the fixes share.
6. **Caveats.** Anything that makes the count uncertain (PRs not classifiable, thin descriptions, judgment calls).

Cap the report at ~800 words. Prefer PR numbers over prose. The user wants a number to quote and examples to point at.

### Step 5 — Synthesize and present

Take the subagent's report and give the user:

- The headline number, framed for their stated purpose (justifying a refactor? making a hire? scoping an initiative?)
- A "stricter count" if any classifications were borderline ("if you exclude PR #X because of caveat Y, it's 5/31 = 16%")
- A direct ask: what action does this number unlock? If it justifies a refactor, offer to scope a spec. If it's lower than expected, offer to audit a different class.

## Anti-patterns

These tank the audit's credibility:

| Anti-pattern | What goes wrong | Fix |
|---|---|---|
| Classifying based on PR titles alone | Titles are marketing; the actual fix often differs | Always read the description or diff |
| Inflating ambiguous → preventable | The number becomes indefensible | Bias toward false negatives, hard |
| Skipping the criteria step | Judgment drifts mid-audit | Write inclusion + exclusion lists before any PR is read |
| Counting non-`fix:` PRs in the denominator | Dilutes the rate, looks dishonest | Denominator is `fix:` PRs only unless explicitly redefined |
| Reading 100 PRs in the main context | Drowns the main thread, costs tokens | Delegate; main context only synthesizes |
| Reporting without examples | The number isn't actionable | Always include 5 representative + 3 ambiguous |
| Pattern claims without evidence | "Author X writes buggy code" — unfalsifiable | Pattern claims need PR numbers as receipts |

## Common classes to audit

See `references/bug-classes.md` for ready-to-use inclusion/exclusion criteria for ~22 common bug classes. These split into *root-cause* classes — stale client state after server writes, silent error swallowing, authorization drift, validation bypass, N+1 queries, race conditions, external-service sync drift, schema-caller drift, null dereference, off-by-one / boundary, timezone / date-time, money / numeric precision, resource leaks, injection / unsanitized input, non-atomic multi-step writes, control-flow / branch-precedence errors, environment / config-contract drift — and *how-introduced* classes common to rushed or agent-generated code: invented defaults / hidden fallbacks, incomplete refactor / orphaned call sites, type/lint suppression, assertion-free / mock-only tests, and duplicated logic / divergent copies. A single PR can match one of each. When the user names a class, check the catalog first — odds are good there's a starter criterion set to adapt.

## Extensions

After an audit produces a meaningful number, the natural follow-ups are:

- **Bug-origin trace** on the top 1–2 examples (git blame, `git log -S`) to determine whether each is a regression, a latent bug surfaced by a later change, or always-broken. Useful for understanding *why* the class keeps shipping.
- **Spec scoping** for the architectural change the audit motivates. If the audit's purpose was justifying a refactor, offer to draft a spec referencing the audit's headline number as the problem statement.
- **Repeat for adjacent classes** if the first audit comes back near zero. Sometimes the user's intuition was right but they named the wrong class.
