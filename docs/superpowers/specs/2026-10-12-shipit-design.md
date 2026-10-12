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
