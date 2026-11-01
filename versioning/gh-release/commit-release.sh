#!/usr/bin/env bash
# Commits CHANGELOG and every file changed by the version command in one [skip ci] commit.
# Env: TAG, CHANGELOG, VERSION_COMMAND (empty = only the changelog is staged).
set -euo pipefail
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"
if [ -n "${VERSION_COMMAND:-}" ]; then
  git add -A
else
  git add "$CHANGELOG"
fi
if git diff --cached --quiet; then
  echo "No changes to commit — skipping."
else
  git commit -m "docs: update $CHANGELOG for $TAG [skip ci]"
  git push
fi
