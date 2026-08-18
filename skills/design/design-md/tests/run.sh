#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$HERE/skill-contract.test.sh"
node --test "$HERE/extract-tokens.test.js"
