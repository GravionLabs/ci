#!/usr/bin/env bash
# Closes the open milestones that shipped with the release tag <TAG_PREFIX><VERSION> and adds the version to their
# title. Shipped = no open item and a pull request of the release (previous stable tag...tag) or an issue it closes
# is in the milestone. Env: GH_TOKEN, GITHUB_REPOSITORY, VERSION; optional TAG_PREFIX (v), DRY_RUN=true.
# API problems only warn (exit 0): the release itself is done.
set -uo pipefail

REPO="${GITHUB_REPOSITORY:?}"
VERSION="${VERSION:?}"
PREFIX="${TAG_PREFIX-v}"
DRY_RUN="${DRY_RUN:-false}"
TAG="$PREFIX$VERSION"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Version $VERSION is not a stable x.y.z release; no milestone is closed."
  exit 0
fi

warn() { echo "::warning::$*"; exit 0; }

gh api "repos/$REPO/git/ref/tags/$TAG" --silent >/dev/null 2>&1 || warn "Tag $TAG not found; no milestone is closed."

# newest stable tag below this version
prev=$(gh api "repos/$REPO/git/matching-refs/tags/$PREFIX" --paginate --jq '.[].ref' 2>/dev/null \
  | sed 's#^refs/tags/##' | { grep -E "^${PREFIX}[0-9]+\.[0-9]+\.[0-9]+\$" || true; } | sed "s#^$PREFIX##" \
  | { grep -vxF "$VERSION" || true; } | sort -V | awk -v v="$VERSION" '
      function key(s,  a) { split(s, a, "."); return sprintf("%09d%09d%09d", a[1], a[2], a[3]) }
      key($0) < key(v) { last = $0 } END { print last }')

if [ -n "$prev" ]; then
  echo "Release $TAG: commits since $PREFIX$prev"
  messages=$(gh api "repos/$REPO/compare/$PREFIX$prev...$TAG?per_page=100" --paginate --jq '.commits[].commit.message | split("\n")[0]') \
    || warn "Cannot compare $PREFIX$prev...$TAG; no milestone is closed."
else
  echo "Release $TAG: no earlier stable tag, reading its whole history"
  messages=$(gh api "repos/$REPO/commits?sha=$TAG&per_page=100" --paginate --jq '.[].commit.message | split("\n")[0]') \
    || warn "Cannot read the commits of $TAG; no milestone is closed."
fi

prs=$(printf '%s\n' "$messages" | grep -oE '#[0-9]+' | tr -d '#' | sort -un || true)
echo "Pull requests of the release: $(echo $prs)"

declare -A SHIPPED=() SEEN=()
ms_of() { gh api "repos/$REPO/issues/$1" --jq '[(.pull_request != null), (.milestone.number // 0), (.body // "")] | @json' 2>/dev/null; }
mark() { # milestone number
  [ "${1:-0}" != 0 ] && SHIPPED[$1]=1
  return 0
}
for pr in $prs; do
  info=$(ms_of "$pr") || continue
  [ "$(jq -r '.[0]' <<<"$info")" = true ] || continue
  mark "$(jq -r '.[1]' <<<"$info")"
  refs=$(jq -r '.[2]' <<<"$info" | grep -ioE '\b(close[sd]?|fix(e[sd])?|resolve[sd]?)[: ]+#[0-9]+' | grep -oE '[0-9]+$' | sort -un || true)
  for n in $refs; do
    [ -n "${SEEN[$n]:-}" ] && continue
    SEEN[$n]=1
    iinfo=$(ms_of "$n") || continue
    [ "$(jq -r '.[0]' <<<"$iinfo")" = false ] && mark "$(jq -r '.[1]' <<<"$iinfo")"
  done
done

milestones=$(gh api "repos/$REPO/milestones?state=open&per_page=100" --paginate --jq '.[] | [.number, .title, .open_issues] | @tsv') \
  || warn "Cannot read the milestones; grant issues: write to the job."

while IFS=$'\t' read -r number title open_issues; do
  [ -z "$number" ] && continue
  [ -n "${SHIPPED[$number]:-}" ] || continue
  if [ "$open_issues" != 0 ]; then
    open=$(gh api "repos/$REPO/issues?milestone=$number&state=open&per_page=100" --paginate --jq '.[] | "#\(.number)"' 2>/dev/null | tr '\n' ' ')
    echo "::notice::Milestone '$title' shipped with $TAG but stays open: open issues ${open:-($open_issues)}"
    continue
  fi
  new=$title
  if [[ "$title" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    : # legacy title: closed without renaming
  elif [[ "$title" =~ ^M[0-9]+(\.[0-9]+)*($|\ ) ]]; then
    [[ "$title" =~ \([0-9]+\.[0-9]+\.[0-9]+\)$ ]] || new="$title ($VERSION)"
  else
    echo "::notice::Milestone '$title' shipped with $TAG but its title is not M<nnn> or x.y.z; left open."
    continue
  fi
  if [ "$DRY_RUN" = true ]; then
    echo "would close milestone '$title' as '$new'"
    continue
  fi
  if gh api -X PATCH "repos/$REPO/milestones/$number" -f "title=$new" -f state=closed --silent >/dev/null; then
    echo "closed milestone '$title' as '$new'"
  else
    echo "::warning::Cannot close milestone '$title'; grant issues: write to the job."
  fi
done <<<"$milestones"
exit 0
