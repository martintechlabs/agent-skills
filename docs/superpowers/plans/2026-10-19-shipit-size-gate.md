# shipit size gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Content files (assets, docs, copy) no longer send a PR to Greptile. Only code changes count toward the size gate.

**Architecture:** Markdown-only change to the "Size gate" section of `skills/coding/shipit/SKILL.md`, plus the version bump.

**Spec:** `docs/superpowers/specs/2026-10-19-shipit-size-gate-design.md`

## Review Focus

- An added favicon (binary `A`) → minor.
- A new `.ts` file, a renamed code file, a new `.wasm` → larger.
- A `SKILL.md` edit → code, so it counts toward the 10 lines.

---

### Task 1: Rewrite the size gate

**Files:**
- Modify: `skills/coding/shipit/SKILL.md` ("Size gate" section, `metadata.version`)

- [ ] **Step 1: Replace the minor-change rules**

Keep the two `git diff` commands. Replace the four bullets with the spec's
content/code sorting and its five rules. Keep "When in doubt" and the override
line.

- [ ] **Step 2: Bump the version**

`metadata.version: "0.2.0"` → `"0.3.0"`.

- [ ] **Step 3: Frontmatter check**

Run: `bash scripts/check-frontmatter.sh`
Expected: exit 0, no `shipit` error.

- [ ] **Step 4: Walk the cases**

Apply the new section's text to each Review Focus case and the spec's
validation cases. Each must land where the spec says.

- [ ] **Step 5: Commit**

```bash
git add skills/coding/shipit/SKILL.md docs/superpowers/specs/2026-10-19-shipit-size-gate-design.md docs/superpowers/plans/2026-10-19-shipit-size-gate.md
git commit -m "fix(shipit): content files no longer send a PR to Greptile"
```
