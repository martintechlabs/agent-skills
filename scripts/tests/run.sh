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

expect 0 "valid folded description passes" "$fx/good-skill/SKILL.md"
expect 1 "': ' in plain scalar fails" "$fx/bad-yaml/SKILL.md"
expect 1 "name/directory mismatch fails" "$fx/name-mismatch/SKILL.md"
exit $fail
