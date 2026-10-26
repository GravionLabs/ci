#!/usr/bin/env bash
# Env: GH_TOKEN, GITHUB_REPOSITORY, RELEASE_BRANCH; optional BASE, DRY_RUN=true
set -euo pipefail

REPO="${GITHUB_REPOSITORY:?}"
BRANCH="${RELEASE_BRANCH:?}"
BASE="${BASE:-}"
DRY_RUN="${DRY_RUN:-false}"

if ! [[ "$BRANCH" =~ ^release/[0-9]+\.[0-9]+$ ]]; then
  echo "$BRANCH is not a release/<x.y> branch; nothing to do."
  exit 0
fi
version="${BRANCH#release/}"

if [ -z "$BASE" ]; then
  BASE=$(gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name)
fi

cmp=$(gh api "repos/$REPO/compare/$BASE...$BRANCH" --jq '{ahead: .ahead_by, since: .merge_base_commit.commit.committer.date}')
ahead=$(printf '%s' "$cmp" | jq -r .ahead)
since=$(printf '%s' "$cmp" | jq -r .since)
if [ "$ahead" = 0 ]; then
  echo "$BRANCH has no commits ahead of $BASE; nothing to do."
  exit 0
fi

# only PRs merged since the branch left the base: a reused branch name (release/1.1 deleted and cut
# again) would otherwise list the PRs of its earlier life
merged=$(gh pr list -R "$REPO" --base "$BRANCH" --state merged --limit 200 \
  --json number,title,author,body,mergedAt | jq --arg since "$since" '[.[] | select(.mergedAt > $since)]')
list=$(printf '%s' "$merged" | jq -r '.[] | "- #\(.number) \(.title) (@\(.author.login))"')
refs=$(printf '%s' "$merged" | jq -r '.[].body // ""' \
  | grep -ioE '\b(close[sd]?|fix(e[sd])?|resolve[sd]?)[: ]+#[0-9]+' | grep -oE '[0-9]+$' | sort -un || true)

title="release: $version"
body=$(
  echo "## Release $version"
  echo
  if [ -n "$list" ]; then
    echo "Merged into \`$BRANCH\`:"
    echo
    echo "$list"
  else
    echo "No pull requests merged into \`$BRANCH\` yet."
  fi
  if [ -n "$refs" ]; then
    echo
    for n in $refs; do echo "Closes #$n"; done
  fi
  echo
  echo "Merge with a merge commit (\`gh pr merge --merge\`), never squash."
  echo
  echo "_Maintained by GravionLabs/ci versioning/release-pr; regenerated on every push to \`$BRANCH\`._"
)

existing=$(gh pr list -R "$REPO" --head "$BRANCH" --base "$BASE" --state open --json number --jq '.[0].number // empty')

if [ "$DRY_RUN" = true ]; then
  if [ -n "$existing" ]; then echo "would update PR #$existing"; else echo "would create PR $BRANCH -> $BASE"; fi
  echo "title: $title"
  echo "$body"
  exit 0
fi

file=$(mktemp)
printf '%s\n' "$body" > "$file"
if [ -z "$existing" ]; then
  url=$(gh pr create -R "$REPO" --base "$BASE" --head "$BRANCH" --title "$title" --body-file "$file")
  echo "Created $url"
else
  current=$(gh pr view "$existing" -R "$REPO" --json title,body --jq '.title + "\n" + .body')
  if [ "$current" = "$title"$'\n'"$body" ]; then
    echo "PR #$existing is current."
  else
    gh pr edit "$existing" -R "$REPO" --title "$title" --body-file "$file" >/dev/null
    echo "Updated PR #$existing"
  fi
fi
