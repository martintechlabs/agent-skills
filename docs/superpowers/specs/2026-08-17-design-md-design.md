# design-md — Design

**Date:** 2026-08-17
**Category:** `design` (new)
**Status:** Approved

## Purpose

Generate a spec-compliant `DESIGN.md` — the [designmd.app](https://designmd.app/what-is-design-md)
format: YAML front-matter design tokens + an 8-section Markdown body — at a target
repo's root. Two input modes converge on the same output:

- **Website mode**: given a brand/marketing site URL, extract real design tokens
  (colors, typography, spacing, radii, shadows) via browser automation reading
  actual computed styles, plus a screenshot for the brand-personality prose a
  stylesheet can't express.
- **Codebase mode**: given no URL (or an explicit "scan this repo" request), extract
  tokens from an existing codebase's design-token sources (Tailwind config, CSS
  custom properties, JS theme objects, existing token JSON).

Both modes feed one shared synthesis step that maps raw data onto the official
schema, writes the file, and validates it with the official `@google/design.md`
CLI (`npx @google/design.md lint`) when available.

## Non-goals

- **Not an update/diff/merge tool.** If `DESIGN.md` already exists at the target
  location, the skill refuses and tells the user to remove/rename it first. No
  "preserve hand-edited prose while refreshing tokens" logic — that's real
  complexity (diffing structured YAML + prose) with no validated demand yet. A
  future `design-md-refresh` skill can pick this up if it's actually needed.
- **Not a Tailwind/CSS-vars exporter.** `design.md export` already does this. The
  skill mentions the export command as a next-step hint in its final report; it
  does not run export commands automatically.
- **Not a general component-library scanner.** Codebase mode reads known
  design-token *sources* (config files, theme objects, CSS vars) — it does not
  attempt to reverse-engineer tokens from arbitrary component markup as a primary
  source; component files are only a fallback cross-check for spacing/radii in
  practice when the theme file looks incomplete.
- **Not a hard dependency on `@google/design.md`.** The CLI is real
  (`npm view` confirms `@google/design.md@0.4.0`, MIT-adjacent "Proprietary"
  license per npm metadata, maintained under `google-labs-code/design.md`) and is
  shelled out to via `npx` for linting, but if `npx` fails (no network, no npm),
  the skill skips validation with a note rather than failing the whole run.
- **Not built on `claude-in-chrome`.** Website mode uses `mcp__chrome-devtools__*`
  specifically, since it needs no logged-in session or user browser extension —
  just a fresh load of a public page. `claude-in-chrome` remains the right choice
  for tasks that need the user's own session; this skill deliberately avoids that
  dependency.

## Website mode — extraction

1. `navigate_page` to the given URL, plus up to 2 linked subpages (e.g. pricing,
   product) if visible in primary nav — capped at 3 pages total to bound the work.
2. Run the bundled extraction script (`references/extract-tokens.js`, adapted
   inline into `evaluate_script`) on each page. It walks the `html` and `body`
   roots plus their descendants and returns raw, uninterpreted JSON:
   - colors (`color`/`background-color`/`border-color` via `getComputedStyle`),
     bucketed by frequency and element prominence (CTA buttons and headings
     weighted higher than body text)
   - typography samples (`font-family`/`font-size`/`font-weight`/`line-height`/
     `letter-spacing`) grouped by heading level and common text classes
   - margin/padding value histogram, for inferring a spacing scale
   - `border-radius` values across buttons/cards/inputs
   - `box-shadow` values for elevation
3. `take_screenshot` of each page visited, for the agent's own visual judgment —
   this is what feeds prose the CSS values alone can't supply (brand personality,
   tone, "Do's and Don'ts").
4. Close the page(s).

The script performs mechanical extraction only — no semantic labeling. Clustering
raw colors into `primary`/`secondary`/`tertiary`/`neutral` roles, picking
representative typography levels, and inferring the spacing base unit (e.g., an
8px grid) from the histogram happens in the shared synthesis step, using agent
judgment, not more script logic.

## Codebase mode — extraction

No browser. Grep/Glob/Read the target repo for design-token sources, in priority
order (first strong match per category wins; sources can coexist, but a
lower-priority source never overrides a higher-priority match):

1. **Tailwind config** (`tailwind.config.{js,ts,mjs}`, or `@theme` blocks in CSS
   for Tailwind v4) — colors/spacing/fontFamily/borderRadius map almost 1:1 onto
   the schema.
2. **CSS custom properties** (`:root { --color-*, --spacing-*, --radius-* }`)
   across `.css`/`.scss` entry files.
3. **JS theme objects** (styled-components/Emotion `theme.js`, MUI
   `createTheme(...)`, Chakra theme) — read and interpreted by the agent; shapes
   vary too much to parse mechanically with a generic script.
4. **Existing design-token JSON** (Style Dictionary `tokens.json`, Figma Tokens
   export) — closest match, mostly a re-key exercise.
5. **Component files** (`Button.tsx`, `Card.tsx`, …) — fallback cross-check only,
   for spacing/radii actually used in practice when the theme file looks stale or
   incomplete.

`references/codebase-scan.md` documents the glob checklist and what each source
maps to, so the procedure itself doesn't have to inline it.

Brand-personality prose is harder without a live visual: the agent uses whatever
signal exists (README, marketing copy in-repo, a rendered Storybook if present)
and is explicit in the Overview section about what's inferred vs. sourced, rather
than inventing a personality wholesale.

## Synthesis, validation, output

**Synthesis** (shared regardless of mode): map raw extracted data onto the YAML
schema using `references/design-md-spec.md` — a **vendored, verbatim copy** of
`npx @google/design.md spec` output, so the schema stays exact rather than
re-derived from the designmd.app marketing page. Write all 8 sections in
canonical order (Overview, Colors, Typography, Layout, Elevation & Depth, Shapes,
Components, Do's and Don'ts). Use frontmatter `omitted: [{section, reason}]` for
any section with no real signal (e.g. no shadows detected on a flat-design site)
instead of fabricating content.

Typography tokens are limited to distinct observed records and properties;
partial records from codebase token sources remain valid, while the spec's
typical 9–15-level range is descriptive rather than a target to reach by
duplication or extrapolation. Spacing tokens likewise come only from observed
histogram/config values; any inferred rhythm belongs in prose. Component
padding follows the schema's single `Dimension` field: website extraction
captures all four sides, the token is included only when they are uniform, and
asymmetric padding is documented in prose rather than encoded as CSS shorthand.

**File placement:** target repo root, filename `DESIGN.md` (fixed, per spec
convention). Target repo defaults to cwd; refuse if `DESIGN.md` already exists
there (see Non-goals).

**Validation:** `npx --yes @google/design.md lint <path> --format json`, parse
`summary.{errors,warnings,infos}`:
- `errors > 0` → fix and re-lint before reporting done.
- `warnings`/`infos` (e.g. "no spacing section defined") → surface in the final
  report, non-blocking.
- `npx` failure (no network/npm) → skip validation, note it in the report; lint
  is a quality check, not a dependency the skill requires to function.

**Final report:** what was generated (mode used, pages/sources read, section
count, any omitted sections), lint result, and a one-line pointer to
`design.md export --format css-tailwind|css-vars|dtcg` as an optional next step —
never run automatically (see Non-goals).

## Files and components

| Path | Change |
|---|---|
| `skills/design/design-md/SKILL.md` | New — frontmatter (`name: design-md`, `metadata: {author: stephen-martin, version: "0.1.1"}`), the mode-detection → extraction → synthesis → validate → report procedure |
| `skills/design/design-md/references/design-md-spec.md` | New — vendored verbatim output of `npx @google/design.md spec`, refreshed at authoring time |
| `skills/design/design-md/references/extract-tokens.js` | New — browser `evaluate_script` template for website-mode raw extraction |
| `skills/design/design-md/references/codebase-scan.md` | New — glob checklist + source-to-schema mapping for codebase mode |
| `skills/design/design-md/tests/` | New — regression coverage for browser extraction behavior |
| `skills.sh.json` | New `design` grouping, listing `design-md` |
| `README.md` | New "Design" section in Available skills table, plus category added to Repository layout description |

## Success criteria

- Given a public marketing site URL and no existing `DESIGN.md` in cwd, the skill
  produces a `DESIGN.md` with valid YAML front matter and all 8 sections present
  or explicitly `omitted` with a reason — using real computed-style values, not
  guessed ones.
- Given a repo with a Tailwind config or CSS custom properties and no URL, the
  skill produces an equivalent `DESIGN.md` sourced from those files without
  opening a browser.
- Running `npx @google/design.md lint` against the generated file (when `npx` is
  available) reports zero errors.
- If `DESIGN.md` already exists at the target root, the skill refuses cleanly
  with a clear remediation message instead of overwriting or attempting a merge.
- `skills.sh.json` and `README.md` both reflect the new `design` category and the
  `design-md` entry, per this repo's review checklist.
