# Codebase-mode extraction checklist

Search the target repo for these design-token sources, in priority order.
Multiple sources can coexist — read all that are present and merge, preferring
the more specific/recent source when values conflict (e.g. a CSS var overridden
in a component wins over a stale config default).

## 1. Tailwind config

Glob: `tailwind.config.{js,ts,mjs,cjs}`, or any `**/*.css` containing an
`@theme` block (Tailwind v4).

Maps to schema:
- `theme.colors` / `theme.extend.colors` → `colors.*`
- `theme.fontFamily` / `theme.extend.fontFamily` → `typography.*.fontFamily`
- `theme.fontSize` / `theme.extend.fontSize` → `typography.*.fontSize` (plus
  `lineHeight` if given as the `[size, {lineHeight}]` tuple form)
- `theme.spacing` / `theme.extend.spacing` → `spacing.*`
- `theme.borderRadius` / `theme.extend.borderRadius` → `rounded.*`
- `theme.boxShadow` / `theme.extend.boxShadow` → prose in Elevation & Depth (no
  direct token slot in the schema; describe the values, don't invent a token
  group for them)

## 2. CSS custom properties

Glob: `**/*.css`, `**/*.scss` (skip `node_modules`, build output directories).
Look for `:root { --... }` or `[data-theme] { --... }` blocks.

Maps to schema:
- `--color-*`, `--brand-*` → `colors.*`
- `--font-*`, `--text-*` → `typography.*`
- `--space-*`, `--spacing-*`, `--gap-*` → `spacing.*`
- `--radius-*`, `--rounded-*` → `rounded.*`
- `--shadow-*` → prose in Elevation & Depth

## 3. JS theme objects

Glob: `**/theme.{js,ts}`, `**/*Theme.{js,ts}`, or files importing
`createTheme` (MUI), using `styled-components`'/Emotion's `ThemeProvider`
value, or Chakra's `extendTheme`.

Read the file directly — shapes vary too much to parse mechanically with a
generic script. Map whatever palette/typography/spacing keys exist onto the
schema using the same role conventions as everywhere else (primary/secondary/
tertiary/neutral for colors; headline/body/label for typography).

## 4. Existing design-token JSON

Glob: `tokens.json`, `**/tokens/*.json`, `.figma/tokens.json` — Style
Dictionary or Figma Tokens export shape (e.g.
`{"color": {"primary": {"value": "#..."}}}` or similar nested `value` shape).

This is the closest match to the schema already — mostly a re-key exercise:
their `value` becomes the token value, their group names become the token
names.

## 5. Component files (fallback cross-check only)

Glob a handful of common component files (`**/Button.{tsx,jsx}`,
`**/Card.{tsx,jsx}`, `**/Input.{tsx,jsx}`) only if sources 1–4 are thin or
look stale — e.g. a Tailwind config with only default colors and no brand
customization. Use inline className/style values found there as a sanity
check against what the theme file claims, not as the primary source. Note in
the Overview or Do's/Don'ts section if you find drift between the theme file
and actual usage.

This is also the primary source for the **Components** schema group
(`components.button-primary: {backgroundColor, textColor, rounded, padding}`,
etc.) — if a `Button`/`Card`/`Input` component file exists, read its actual
className/style values and map them to token references (e.g.
`backgroundColor: "{colors.primary}"`) rather than restating a raw hex. If no
component file is found and sources 1–4 gave no per-component data either
(a Tailwind/CSS-var config only defines global scales, not which color+radius
combination makes a button), that's a legitimate case for
`omitted: [{section: "components", reason: "no component-level styling found, only global token scales"}]` —
don't fabricate a `button-primary` entry just to fill the section.

## When nothing is found

If none of the above yields any tokens, say so explicitly rather than
fabricating a design system — report that codebase mode found no extractable
design-token sources, and ask whether the user wants to point the skill at a
live site instead (website mode), or confirm there's genuinely no existing
design system to document.
