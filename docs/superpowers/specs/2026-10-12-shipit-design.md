# shipit — design

## Goal

A guardrail wrapper around the external `greploop` skill. It brings a PR to a
verified, review-ready state without letting the review loop change intended
behavior, architecture, or scope.

## Decisions

- Content is user-authored (the "Ship PR" draft), renamed to `shipit`.
- Delegates the review mechanics to `greploop`; it adds finding validation,
  scope limits, escalation rules, verification, and a fixed completion report.
- `greploop` is not part of this repo. The skill stops if it is unavailable.
- Never merges, deploys, or releases.
- Overlap: `ship-ready-pr-loop` and `kodus-loop` cover Kodus-reviewed repos. The
  description points there.
- greploop's exit (5/5, zero unresolved) conflicts with rejecting findings.
  shipit overrides it: reply then resolve rejected threads, leave decision
  threads open, accept a score below 5/5, stage explicit paths (greploop uses
  `git add -A`).

## Source facts (verified 2026-10-13)

Read-only `gh` queries on public Greptile-reviewed PRs
(OmniNetOpensource/agent#254, Wet-Ink-Corporation/happenstance#304,
BigSimmo/Ward-Flow#261): all three have `greptile-apps[bot]` comments or
reviews, and none has a Greptile check run. So the install check looks for the
bot login, not a check run. The detection loop returned "found" on
BigSimmo/Ward-Flow and "not found" on jqlang/jq.
