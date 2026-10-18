#!/usr/bin/env bash
# Tests for scripts/check-frontmatter.sh against fixtures.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
check="$here/../check-frontmatter.sh"
fx="$here/fixtures"
fail=0

expect() { # expect <0|1> <description> <file>
  "$check" "$3" >/dev/null 2>&1; got=$?
  if [ "$got" -eq "$1" ]; then echo "ok   $2"; else echo "not ok $2 (exit $got, want $1)"; fail=1; fi
}

expect 0 "valid folded description passes" "$fx/good-skill/SKILL.fixture.md"
expect 1 "': ' in plain scalar fails" "$fx/bad-yaml/SKILL.fixture.md"
expect 1 "name/directory mismatch fails" "$fx/name-mismatch/SKILL.fixture.md"

# `npx skills update` can walk the whole repo and parse every file named SKILL.md.
stray=$(git -C "$here" ls-files --full-name ':/' | grep -E '(^|/)SKILL\.md$' | grep -v '^skills/[^/]*/[^/]*/SKILL\.md$')
if [ -z "$stray" ]; then echo "ok   no SKILL.md outside skills/<category>/<name>/"
else echo "not ok SKILL.md outside skills/<category>/<name>/:"; echo "$stray"; fail=1; fi
exit $fail
