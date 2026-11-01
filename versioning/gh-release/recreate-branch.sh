#!/usr/bin/env bash
# Recreates BRANCH on origin at the released commit when it does not exist. Never moves or force-pushes.
# Env: BRANCH (empty = off), optional SHA (default HEAD). Run inside a checkout whose origin has push access.
set -euo pipefail

BRANCH="${BRANCH:-}"
if [ -z "$BRANCH" ]; then
  echo "recreate-branch is off."
  exit 0
fi
SHA="${SHA:-$(git rev-parse HEAD)}"

# ls-remote --exit-code: 0 = found, 2 = no match, anything else = connection or auth failure
rc=0
git ls-remote --exit-code --heads origin "refs/heads/$BRANCH" >/dev/null 2>&1 || rc=$?
if [ "$rc" = 0 ]; then
  echo "$BRANCH exists on origin; left unchanged."
  exit 0
fi
if [ "$rc" != 2 ]; then
  echo "::error::Could not query origin for $BRANCH (exit $rc)."
  exit 1
fi

# no --force: a branch created meanwhile makes the push fail instead of being overwritten
git push origin "$SHA:refs/heads/$BRANCH"
echo "Created $BRANCH at $SHA."
