#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$HERE/../SKILL.md"

assert_contains() {
  local expected="$1"
  if ! grep -Fq -- "$expected" "$SKILL"; then
    echo "not ok - SKILL.md must contain: $expected" >&2
    return 1
  fi
}

assert_absent() {
  local forbidden="$1"
  if grep -Fq -- "$forbidden" "$SKILL"; then
    echo "not ok - SKILL.md must not contain: $forbidden" >&2
    return 1
  fi
}

assert_contains "Use only distinct, observed typography records"
assert_contains "emit only the properties actually observed"
assert_contains "Partial records from codebase token sources are valid"
assert_contains 'convention (`headline-lg`, `body-md`, `label-sm`, etc.). Fewer than 9 levels'
assert_contains "is correct when the evidence is sparse; do not duplicate or extrapolate"
assert_absent "pick 9–15 representative levels"
assert_absent "If no complete typography tuple is observed"
assert_contains "Create spacing tokens only from distinct values present in the histogram"
assert_contains "describe an inferred base rhythm in prose, but do not generate unobserved"
assert_absent 'define `xs`/`sm`/`md`/`lg`/`xl` accordingly'
assert_contains 'Component `padding`'
assert_contains 'emit it only when all four sides are uniform; describe asymmetric padding'
assert_absent 'padding: \"12px 24px\"'

echo "ok   synthesis instructions preserve observed typography and schema-valid padding"
