#!/usr/bin/env bash
# Every reference to GravionLabs/ci inside this repository (workflows, actions, templates, docs) uses the moving
# major tag of the next release (@v<major>), never @main, a SHA or another major. CHANGELOG.md (history) is skipped.
# Run: EXPECTED_MAJOR=1 bash tests/self-references.test.sh
#      (without EXPECTED_MAJOR: the major of the highest v<x.y.z> tag, else 1)
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1

MAJOR=${EXPECTED_MAJOR:-}
if [ -z "$MAJOR" ]; then
  latest=$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1)
  MAJOR=${latest:+${latest#v}}; MAJOR=${MAJOR%%.*}; MAJOR=${MAJOR:-1}
fi
WANT="@v${MAJOR}"

refs=$(grep -rnoE "GravionLabs/ci/[A-Za-z0-9_./-]+@[A-Za-z0-9._<>-]+" . \
  --exclude-dir=node_modules --exclude-dir=.git --exclude=CHANGELOG.md \
  --exclude=self-references.test.sh --exclude=move-major-tag.test.sh)
total=$(printf '%s\n' "$refs" | grep -c . || true)
# Docs may show an exact release of the same major (@v1.2.3) and placeholders (@<sha>); code may not.
bad=$(printf '%s\n' "$refs" | grep . | grep -vE "${WANT}\$" \
  | grep -vE "^[^:]+\.md:[0-9]+:.*(${WANT}\.[0-9]+\.[0-9]+|@<[a-z-]+>)\$" || true)

if [ "$total" -eq 0 ]; then echo "FAIL - no self-references found (grep broken?)"; exit 1; fi
if [ -n "$bad" ]; then
  echo "FAIL - self-references not at $WANT:"
  printf '%s\n' "$bad" | sed 's/^/  /'
  exit 1
fi
echo "ok   - $total self-references at $WANT"
