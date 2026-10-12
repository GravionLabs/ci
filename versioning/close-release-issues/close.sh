#!/usr/bin/env bash
# Env: GH_TOKEN, GITHUB_REPOSITORY, GITHUB_SHA; optional VERSION, DRY_RUN=true, ASSUME_OPEN=true
# (ASSUME_OPEN treats every referenced issue as open; use it with DRY_RUN to test against a finished release).
set -euo pipefail

REPO="${GITHUB_REPOSITORY:?}"
SHA="${GITHUB_SHA:?}"
DRY_RUN="${DRY_RUN:-false}"
ASSUME_OPEN="${ASSUME_OPEN:-false}"
VERSION="${VERSION:-}"
declare -A DONE=()

release_pr=$(gh api "repos/$REPO/commits/$SHA/pulls" \
  --jq '[.[] | select(.head.ref | startswith("release/"))][0].number // empty')
if [ -z "$release_pr" ]; then
  echo "Commit $SHA is not a merged release PR; nothing to do."
  exit 0
fi
branch=$(gh pr view "$release_pr" -R "$REPO" --json headRefName -q .headRefName)
echo "Release PR #$release_pr from $branch"

bodies=$( { gh pr list -R "$REPO" --base "$branch" --state merged --limit 500 --json body --jq '.[].body // ""'
            gh pr view "$release_pr" -R "$REPO" --json body -q '.body // ""'; } )
refs=$(printf '%s\n' "$bodies" | grep -ioE '\b(close[sd]?|fix(e[sd])?|resolve[sd]?)[: ]+#[0-9]+' | grep -oE '[0-9]+$' | sort -un || true)
echo "Referenced issues: $(echo $refs)"

state_of() {
  if [ -n "${DONE[$1]:-}" ]; then echo closed; return; fi
  if [ "$ASSUME_OPEN" = true ]; then echo open; return; fi
  gh api "repos/$REPO/issues/$1" --jq '.state'
}

close_issue() {
  local n=$1
  [ "$(state_of "$n")" = closed ] && return 0
  local tag=""
  [ -n "$VERSION" ] && tag="v$VERSION "
  if [ "$DRY_RUN" = true ]; then
    echo "would close #$n"
  else
    echo "closing #$n"
    gh issue close "$n" -R "$REPO" --reason completed \
      --comment "Shipped in ${tag}(release PR #$release_pr)."
  fi
  DONE[$n]=1
}

close_children() {
  local n=$1 c
  for c in $(gh api "repos/$REPO/issues/$n/sub_issues" --paginate --jq '.[] | select(.state == "open") | .number' 2>/dev/null || true); do
    close_issue "$c"
    close_children "$c"
  done
}

close_parents() {
  local n=$1 p info labels open
  p=$(gh api "repos/$REPO/issues/$n/parent" --jq 'select(.repository_url | endswith("/'"$REPO"'")) | .number' 2>/dev/null || true)
  [[ "$p" =~ ^[0-9]+$ ]] || return 0
  labels=$(gh api "repos/$REPO/issues/$p" --jq '[.labels[].name] | join(",")')
  case ",$labels," in *,epic,*) return 0 ;; esac
  case ",$labels," in *,pbi,*|*,feature,*) ;; *) return 0 ;; esac
  open=0
  for c in $(gh api "repos/$REPO/issues/$p/sub_issues" --paginate --jq '.[] | select(.state == "open") | .number'); do
    [ -z "${DONE[$c]:-}" ] && open=1
  done
  if [ "$open" = 0 ]; then
    close_issue "$p"
    close_parents "$p"
  fi
}

for n in $refs; do
  close_issue "$n"
  close_children "$n"
  close_parents "$n"
done
echo "Done."
