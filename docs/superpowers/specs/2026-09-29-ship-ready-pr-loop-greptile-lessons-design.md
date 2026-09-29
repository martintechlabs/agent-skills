# `ship-ready-pr-loop` Greptile Lessons Design

## Goal

Cut Greptile spend. Findings that Greptile catches once should be caught by the cheap step-3 review on every later run in the same repository.

## Problem

Greptile reviews are the expensive part of the loop. Each Greptile finding the step-3 review missed costs at least one extra Greptile pass. The loop keeps no memory, so the same class of finding can slip past the step-3 review on every PR.

## Behavior

### Lessons file

The target repository keeps `docs/agents/greptile-lessons.md`, a sibling of the `docs/agents/issue-tracker.md` file that mechanism 3 already uses. The first run that has a lesson creates it. A missing file is not an error.

Each entry is a generalized pattern, not a file or line diff, and must be checkable:

```md
## <short pattern name>
- Pattern: <what goes wrong, in general terms>
- Check: <how to find it in a diff: a grep, or a question to ask of the change>
- Seen: <count>, last <YYYY-MM-DD> (PR #<n>)
```

### Read and apply

- Step 1: read the file if it exists.
- Step 3: give every entry to the selected review mechanism as an extra checklist. A change that matches an entry is a Major finding.
- Before step 7: confirm every entry was checked against the change before any Greptile review is requested.

### Record

- Record only valid Greptile findings that the step-3 review missed. Do not record false positives or findings the step-3 review already caught.
- Dedupe on write: when a finding matches an existing entry, bump its count and date instead of adding an entry. Generalize the entry when the new finding widens it.
- Keep at most 40 entries. When over, merge related entries, then drop the oldest entries seen once.
- Write the lessons update in the same commit as the Greptile fixes it describes. Never add a lessons-only commit after Greploop reports 5/5: it makes the 5/5 stale for the new head, and a review-on-push repository starts another paid review. The final 5/5 pass has no findings, so it never needs a lessons write.

### Report

The PR description and final response list the lessons applied and the entries added or updated.

## Out of scope

- Sharing lessons across repositories. Greptile configuration and codebase patterns are per repository.
- Writing lessons into Greptile's own configuration or custom rules.
- Recording step-3 review findings.
