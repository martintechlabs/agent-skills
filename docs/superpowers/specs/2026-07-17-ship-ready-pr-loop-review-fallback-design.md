# `ship-ready-pr-loop` Review Fallback Design

## Goal

Make the pre-PR review loop portable when `/code-review max` is unavailable, including when the skill is run by Codex, without weakening the requirement to identify and fix valid Critical and Major findings.

## Review selection

Select the strongest available review mechanism by capability, not by agent identity:

1. Use `/code-review max` when the current environment exposes it.
2. Otherwise use the `codex-review` skill when it is available.
3. Otherwise run `codex exec review` directly when the `codex` CLI supports review mode.
4. Otherwise perform a native self-review of the full change against its intended base branch.

Availability means the mechanism can actually be invoked in the current harness. Do not run `/code-review max` as a shell command. If a selected mechanism cannot start or becomes unavailable, fall through to the next mechanism and record the change in the PR notes and final report. Keep a working mechanism for subsequent passes when possible. Do not treat an unavailable preferred reviewer as a blocker while another mechanism remains available.

## Common review contract

Every mechanism feeds the same loop:

- Review the complete branch diff against the intended PR base, including relevant uncommitted changes when present.
- Classify findings as Critical, Major, Minor, or lower priority.
- Triage findings on their merits rather than accepting them automatically.
- Fix every valid Critical and Major finding, document false positives, and leave lower-priority findings alone unless they directly support a required fix.
- Rerun project validation after changes.
- Stop when no valid Critical or Major findings remain or after five total review passes across all mechanisms.

The five-pass limit applies to the loop as a whole, not separately to each fallback mechanism.

## Native self-review contract

The native fallback must inspect the full diff and relevant surrounding code for:

- correctness and regressions
- security and authorization gaps
- data loss or destructive behavior
- error handling and failure recovery
- concurrency and state-consistency problems
- compatibility or public-API breakage
- missing or inadequate tests for changed behavior

It must produce concrete, file-level findings with severity and rationale. The agent must state that native self-review is not an independent second opinion; this is a transparency requirement, not a reason to skip the review.

## Skill and reporting changes

- Remove `/code-review max` from the frontmatter description so triggering is platform-neutral.
- Replace hard-coded code-review wording in the purpose, workflow, acceptance criteria, and final response with reviewer-neutral terminology.
- Keep concrete instructions for each review mechanism in the workflow.
- Record the mechanism used for every pass, any fallback transition, remaining findings, false positives, and validation commands in the PR description.
- Report total review passes and the mechanism or mechanisms used in the final response.
- Preserve the existing Greploop phase, five-pass Greploop limit, and 5/5 target unchanged.
- Increment the skill's metadata version for the behavior change.

No new scripts, references, assets, manifest entries, or README changes are required.

## Verification

- Establish the current skill's baseline behavior in a scenario where `/code-review max` is unavailable.
- Forward-test the revised skill in at least these scenarios: `codex-review` available, only direct `codex exec review` available, and native self-review as the sole option.
- Confirm each scenario continues into the review loop, uses the common severity and pass-limit contract, and reports its mechanism accurately.
- Validate frontmatter and folder/name consistency, review the final diff, and confirm the Greploop workflow is unchanged.
