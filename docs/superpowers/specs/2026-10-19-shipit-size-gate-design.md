# shipit size gate: content files do not need Greptile — design

## Intent

A PR that added only a favicon went to Greptile. The size gate treats every
added file and every binary file as a larger change, and a favicon is both.
The user wants simple changes, text changes, and new files with no logic to
stop after the Codex review. Greptile costs money and adds little there.

This reverses one decision of the 2026-10-17 consolidation spec: "a new
one-line file → not minor". A new content file is now minor. A new code file
is still larger.

## User decisions

- Sort each changed file as content or code (proposal accepted in chat).
- Keep the 10-line limit for code changes "for now".

## The gate

Sort each changed file into one of two kinds:

- **Content:** images, icons, fonts, media, prose docs (README, `docs/`,
  changelogs), translation or locale files. A file whose diff only changes
  comments, whitespace, or user-visible copy is also content.
- **Code:** everything else. Markdown that instructs an agent (`SKILL.md`,
  `AGENTS.md`, `CLAUDE.md`, prompt files) is code.

The change is minor when all of these hold:

- Content files do not count, whatever their size or status (added,
  deleted, renamed, binary).
- Every code file status is `M`. A new, deleted, or renamed code file is not
  minor (a rename can break imports).
- Code files have 10 changed lines or fewer in total (added plus deleted).
- Every binary file is a static asset. A binary that is not (`.jar`, `.so`,
  `.wasm`, a compiled blob) is not minor. `--numstat` prints `-` for a
  binary, so its size cannot be counted.
- Nothing in a risky area. The list is unchanged. JSON, YAML, and TOML other
  than locale files are config, so they stay risky.

Unchanged: "when in doubt, larger", and the user can override either way.

## Builder's calls

- Locale files are content, although they are often JSON.
- Agent-instruction Markdown is code. In a skills repo it is the logic.
- `metadata.version` 0.2.0 → 0.3.0: the change moves which PRs get a paid
  review.
- The gate's two `git diff` commands stay. They show every input the rules
  need (status, path, line counts, binary).
- The description and README row stay. They say "minor" and "larger" without
  the rules.

## Out of scope

- A classifier script or a Codex prompt that decides "is this logic?". The
  agent running shipit has the diff, and a prose rule is enough, as with the
  risky-area list.
- A change to the risky-area list or the 10-line limit.

## Validation

shipit has no test suite. Run `bash scripts/check-frontmatter.sh`. Walk the
user's cases through the new rules: an added favicon (binary asset), a copy
change, a new docs page → minor; a new `.ts` file, an 11-line code change, a
renamed code file, a new `.wasm` → larger.
