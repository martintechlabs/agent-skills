#!/usr/bin/env bash
# Validate scripts/neondb-branch.ts the only way this repo can: in a THROWAWAY harness outside it.
#
# Unlike the other skills' suites here, this one needs the network — it installs vitest, typescript,
# dotenv and @electric-sql/pglite into a temp directory. Nothing is written inside this repo, and no
# Neon credentials are used or needed: the control plane is faked, and the purge runs against
# PGlite (in-process Postgres), not a live database.
#
#   bash skills/devops/neondb-branch/tests/run.sh
#   NEONDB_HARNESS_KEEP=1 bash .../run.sh   # keep the harness dir for debugging
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="$(mktemp -d "${TMPDIR:-/tmp}/neondb-branch-harness-XXXXXX")"

cleanup() {
  if [ -n "${NEONDB_HARNESS_KEEP:-}" ]; then
    echo "harness kept at $HARNESS"
  else
    rm -rf "$HARNESS"
  fi
}
trap cleanup EXIT

echo "# harness: $HARNESS"
mkdir -p "$HARNESS/scripts" "$HARNESS/tests"
cp "$SKILL_DIR/scripts/neondb-branch.ts" "$HARNESS/scripts/"
cp "$SKILL_DIR/scripts/load-env.cjs" "$HARNESS/scripts/"
cp "$SKILL_DIR/scripts/workspace-state.cjs" "$HARNESS/scripts/"
cp "$SKILL_DIR/tests/"*.test.ts "$HARNESS/tests/"

cat > "$HARNESS/package.json" <<'JSON'
{
  "name": "neondb-branch-harness",
  "private": true,
  "type": "module",
  "devDependencies": {
    "@electric-sql/pglite": "^0.2.17",
    "@types/node": "^22.10.2",
    "dotenv": "^16.4.7",
    "typescript": "^5.7.2",
    "vitest": "^2.1.8"
  }
}
JSON

cat > "$HARNESS/tsconfig.json" <<'JSON'
{
  "compilerOptions": {
    "target": "ES2022",
    "lib": ["ES2023"],
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "noUnusedLocals": true,
    "noUnusedParameters": false,
    "noEmit": true,
    "skipLibCheck": true,
    "types": ["node"]
  },
  "include": ["scripts/**/*.ts", "tests/**/*.ts"]
}
JSON

echo "# installing harness dependencies (network required)…"
( cd "$HARNESS" && npm install --silent --no-audit --no-fund )

echo "# tsc --noEmit"
( cd "$HARNESS" && npx tsc --noEmit )
echo "ok   scripts/neondb-branch.ts typechecks under strict TypeScript"

echo "# vitest run"
( cd "$HARNESS" && npx vitest run --reporter=verbose )
