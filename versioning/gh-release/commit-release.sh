#!/usr/bin/env bash
# Commits CHANGELOG and every file changed by the version command in one [skip ci] commit.
# A re-run after a pushed commit (e.g. the tag push failed) finds it at the tip and commits nothing.
# Env: TAG, CHANGELOG, VERSION_COMMAND (empty = only the changelog is staged).
set -euo pipefail
message="docs: update $CHANGELOG for $TAG [skip ci]"
if [ "$(git log -1 --format=%s)" = "$message" ]; then
  echo "HEAD is already the changelog commit of $TAG — skipping."
  git reset -q --hard HEAD # drop what was regenerated: the tree must match the commit to be tagged
  exit 0
fi
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
  git commit -m "$message"
  git push
fi
