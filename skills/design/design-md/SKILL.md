---
name: design-md
description: Generate a spec-compliant DESIGN.md — the designmd.app format, combining YAML front-matter design tokens with an 8-section human-readable body — at a target repo's root. Two modes, chosen automatically. Point it at a live brand/marketing website URL to extract real colors, fonts, spacing, and shadows via browser automation reading actual computed styles. Or point it at an existing codebase (no URL) to scan Tailwind config, CSS custom properties, and theme files for already-defined tokens. Validates the result with the official @google/design.md lint CLI when available. Use when asked to "create a DESIGN.md from [url]", "generate a design system doc from our brand site", "document our design tokens", or "point design-md at this codebase". Prefer frontend-design when building new distinctive UI rather than documenting an existing visual language; prefer web-perf for Core Web Vitals auditing rather than visual-token extraction.
metadata:
  author: stephen-martin
  version: "0.1.1"
---

# design-md

Generate a spec-compliant `DESIGN.md` — machine-readable YAML design tokens
plus an 8-section human-readable body — at a target repo's root, following the
[designmd.app](https://designmd.app/what-is-design-md) format. Point it at a
live brand/marketing site to extract real tokens from computed styles, or at
an existing codebase to scan for design-token sources already in the repo.

## Triggers

- "create a DESIGN.md from <url>"
- "generate a design system doc from our brand site"
- "document our design tokens in DESIGN.md"
- "point design-md at this codebase"
- "scan our repo and write a DESIGN.md"

## Before you start

Determine the **target repo root** — default to the current working directory
unless the user names another path. If `DESIGN.md` already exists there,
**stop** and tell the user: this skill only creates a new file, not updates
one — ask them to remove or rename the existing file first. Do not overwrite
it or attempt to merge content into it.

## Step 1: Determine mode

- A URL was given (or is clearly implied, e.g. "our marketing site is
  example.com") → **website mode**.
- No URL, or the user said "scan this repo" / "use our existing components" →
  **codebase mode**.
- If genuinely ambiguous, ask which one before doing anything else.

## Step 2 (website mode): extract raw tokens from the live site

Uses `mcp__chrome-devtools__*` tools — load them first via `ToolSearch` if
deferred: `select:mcp__chrome-devtools__new_page,mcp__chrome-devtools__navigate_page,mcp__chrome-devtools__evaluate_script,mcp__chrome-devtools__take_screenshot,mcp__chrome-devtools__close_page,mcp__chrome-devtools__list_pages`.
Do not use `claude-in-chrome` for this — it needs no logged-in session, just a
fresh load of a public page.

1. `new_page` with the given URL.
2. If the homepage's primary nav links to other clearly-relevant pages (e.g. a
   pricing or product page), pick up to 2 more to sample — cap at 3 pages
   total including the homepage. Skip this for a single-page site.
3. On each page, read `references/extract-tokens.js` and call
   `evaluate_script` with its exact contents as the `function` argument (it's
   already a bare `() => {...}` arrow function in the format the tool
   expects). This returns raw JSON: `colors` (ranked by weighted frequency),
   `typography` (samples per tag/class), `spacingHistogram`, `radii`,
   `shadows`, `components` (raw per-element data for button/input-shaped
   elements). This step is purely mechanical — don't interpret or relabel
   anything yet, that happens in Step 4.
4. `take_screenshot` (`fullPage: true`) of each page visited — this feeds the
   brand-personality judgment in Step 4 that raw CSS values can't supply.
5. `close_page` when done with each page.

## Step 2 (codebase mode): extract tokens from the repo

No browser. Follow `references/codebase-scan.md`'s checklist: search for a
Tailwind config, CSS custom properties, JS theme objects, and existing
design-token JSON, in that priority order, falling back to a handful of
component files only as a cross-check if those look thin or stale. If truly
nothing is found, say so explicitly and ask the user how to proceed rather
than fabricating a design system (see that reference's "When nothing is
found").

## Step 3: Load the schema

Read `references/design-md-spec.md` — the vendored, verbatim `design.md spec`
output. This is the authoritative token schema and section spec; don't rely
on memory of the designmd.app marketing page for exact field names or types.

That reference includes a `### Design Tokens` fenced YAML block under several
sections (Colors, Typography, Layout, Shapes) — those are illustrating *the
spec itself* (how each token group is shaped), not a template to repeat in
the file you write. The frontmatter is the single source of truth for tokens;
don't add a matching `### Design Tokens` code block restating them under the
corresponding prose section — the linter flags that as a duplicate-definition
warning (confirmed empirically: `"Section 'colors' is defined in both
frontmatter and code block 1"`). Section bodies are prose only.

## Step 4: Synthesize

Always set `name` (the brand/product name — from the site's title/header in
website mode, or the repo/package name in codebase mode) and `version: alpha`
in the frontmatter.

Map the raw extracted data onto the schema:

- **Colors**: cluster the ranked raw colors into semantic roles
  (`primary`/`secondary`/`tertiary`/`neutral`, extending with `surface`,
  `on-surface`, `error`, etc. if the data supports it). A color used almost
  exclusively on CTAs/interactive elements is usually `primary` or `tertiary`
  per the spec's naming convention; the dominant background is usually
  `neutral`.
- **Typography**: Use only distinct, observed typography records from the
  samples (headline sizes from `h1`–`h3`, body from `p`, labels/buttons from
  small/bold samples). For each token, emit only the properties actually observed;
  never fill missing properties from convention. Partial records from codebase token sources are valid.
  Name them with the spec's recommended convention (`headline-lg`, `body-md`, `label-sm`, etc.). Fewer than 9 levels
  is correct when the evidence is sparse; do not duplicate or extrapolate
  styles to reach the spec's typical 9–15 range. Omit the group only when no
  typography property was observed at all.
- **Layout/spacing**: Create spacing tokens only from distinct values present in the histogram.
  You may describe an inferred base rhythm in prose, but do not generate unobserved
  scale values or fill `xs` through `xl` by convention.
- **Rounded**: map the observed `radii` values to `sm`/`md`/`lg`/`full` scale
  levels.
- **Components**: for each entry in the raw `components` data (website mode)
  or each component file read (codebase mode), define a
  `components.<name>` token group referencing the colors/rounded tokens
  already defined, e.g.
  `components: {button-primary: {backgroundColor: "{colors.primary}", textColor: "{colors.neutral}", rounded: "{rounded.md}", padding: "{spacing.md}"}}`
  — use `{path.to.token}` references, not restated raw values, when the
  component's value matches a token you already defined. Compare all four
  extracted padding sides. Component `padding` accepts one `Dimension`, so
  emit it only when all four sides are uniform; describe asymmetric padding
  in prose instead of using CSS shorthand. If no
  component-level data was extracted in either mode, omit the section (see
  below) rather than inventing a `button-primary` block from nothing.
- **Elevation & Depth**: describe the observed `shadows` in prose; if none
  were found, say so and describe whatever alternative hierarchy mechanism
  you observed (borders, tonal contrast) instead of inventing shadow values.
  This section has no token group — always write it, however briefly (see
  below).
- **Overview / Do's and Don'ts**: write from the screenshot(s) (website mode)
  or whatever in-repo signal exists — README, marketing copy, Storybook
  (codebase mode). Be explicit when personality is inferred rather than
  directly sourced. Neither section has a token group, and both are always
  writable from at least minimal signal — always write them, never omit.
- **Omit, don't fabricate**: `omitted` in the frontmatter only accepts
  **token-group names** — `colors`, `typography`, `spacing`, `rounded`,
  `components` — not prose section names. A group with no real signal gets
  `omitted: [{section: "<colors|typography|spacing|rounded|components>", reason: "<why>"}]`
  instead of fabricated tokens. This does **not** apply to Overview, Elevation
  & Depth, or Do's and Don'ts — those have no token group, so there's nothing
  to mark omitted; just write them (briefly, if signal is thin) rather than
  skip the heading.

Write all present sections in canonical order: Overview, Colors, Typography,
Layout, Elevation & Depth, Shapes, Components, Do's and Don'ts.

## Step 5: Write the file

Write to `<target repo root>/DESIGN.md`.

## Step 6: Validate

Run `npx --yes @google/design.md lint DESIGN.md --format json` from the target
repo root. Parse `summary.{errors,warnings,infos}`:

- `errors > 0` → fix the file and re-run before reporting done.
- `warnings`/`infos` → note them in your final report; non-blocking (e.g. "no
  spacing section defined" when spacing was legitimately omitted).
- If `npx` itself fails (no network/npm) → skip validation and note that in
  the report. This is a quality check, not a hard dependency.

## Step 7: Report

Summarize: mode used, pages/sources read, which sections were written vs.
omitted (and why), and the lint result. Close with a one-line pointer that
`npx @google/design.md export --format css-tailwind|css-vars|dtcg DESIGN.md`
can convert the file to Tailwind/CSS-vars/DTCG if useful — don't run it
yourself.

## Anti-patterns

- **Don't invent token values.** Every color/font/spacing value in the output
  must trace back to something actually observed (computed style or repo
  file), never a plausible guess.
- **Don't skip the lint pass** when `npx` is available — catching structural
  errors before handing the file back is cheap and part of the deliverable.
- **Don't overwrite an existing DESIGN.md.** Refuse and ask instead.
- **Don't run `export` automatically.** That's a separate, user-initiated
  step.
- **Don't fabricate a design system in codebase mode when nothing is found.**
  Report the gap; don't paper over it with invented defaults.
