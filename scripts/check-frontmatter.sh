#!/usr/bin/env bash
# Validate SKILL.md frontmatter: parses as YAML, has name + description,
# and name matches the skill's directory. Default: every skills/*/*/SKILL.md.
set -uo pipefail

cd "$(dirname "$0")/.."
YAML_CLI=(npx -y yaml@2.9.1 --json --single --strict)

if [ $# -eq 0 ]; then set -- skills/*/*/SKILL.md; fi

fail=0
for f in "$@"; do
  fm=$(awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {exit} f' "$f")
  if [ -z "$fm" ]; then echo "not ok $f: no frontmatter"; fail=1; continue; fi
  if ! json=$(printf '%s\n' "$fm" | "${YAML_CLI[@]}" 2>&1); then
    echo "not ok $f: invalid YAML"; printf '%s\n' "$json" | grep -m1 YAMLParseError; fail=1; continue
  fi
  name=$(jq -r '.name // empty' <<<"$json")
  desc=$(jq -r '.description // empty' <<<"$json")
  dir=$(basename "$(dirname "$f")")
  if [ -z "$name" ] || [ -z "$desc" ]; then echo "not ok $f: missing name or description"; fail=1
  elif [ "$name" != "$dir" ]; then echo "not ok $f: name '$name' != directory '$dir'"; fail=1
  else echo "ok   $f"; fi
done
exit $fail
