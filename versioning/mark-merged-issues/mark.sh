#!/usr/bin/env bash
# Env: GH_TOKEN, GITHUB_REPOSITORY, RELEASE_BRANCH; optional BASE, LABEL (default merged), DRY_RUN=true
set -euo pipefail

REPO="${GITHUB_REPOSITORY:?}"
BRANCH="${RELEASE_BRANCH:?}"
BASE="${BASE:-}"
LABEL="${LABEL:-merged}"
DRY_RUN="${DRY_RUN:-false}"
LABEL_JSON=$(jq -n --arg l "$LABEL" '$l')
CLOSES_RE='\b(close[sd]?|fix(e[sd])?|resolve[sd]?)[: ]+#[0-9]+'
declare -A MARKED=() SEEN=() UP=()
label_ready=false

warn_exit() {
  echo "::warning::$1; grant contents: read, issues: write and pull-requests: read to the job."
  exit 0
}

if ! [[ "$BRANCH" =~ ^release/.+ ]]; then
  echo "$BRANCH is not a release/* branch; nothing to do."
  exit 0
fi

if [ -z "$BASE" ]; then
  BASE=$(gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name) \
    || warn_exit "Cannot read the default branch of $REPO"
fi

cmp=$(gh api "repos/$REPO/compare/$BASE...$BRANCH" --jq '{ahead: .ahead_by, since: .merge_base_commit.commit.committer.date}') \
  || warn_exit "Cannot compare $BASE...$BRANCH"
ahead=$(printf '%s' "$cmp" | jq -r .ahead)
since=$(printf '%s' "$cmp" | jq -r .since)
if [ "$ahead" = 0 ]; then
  echo "$BRANCH has no commits ahead of $BASE; nothing to do."
  exit 0
fi

# PR bodies merged into the branch since it left the base (as release-pr), plus the commit messages
# of base...branch (paginated: compare returns at most 250 commits per call)
bodies=$(gh pr list -R "$REPO" --base "$BRANCH" --state merged --limit 500 --json body,mergedAt \
  | jq -r --arg since "$since" '.[] | select(.mergedAt > $since) | .body // ""') \
  || warn_exit "Cannot list the pull requests merged into $BRANCH"
messages=$(gh api --paginate "repos/$REPO/compare/$BASE...$BRANCH?per_page=100" --jq '.commits[].commit.message') \
  || warn_exit "Cannot list the commits of $BASE...$BRANCH"

refs=$( {
  printf '%s\n%s\n' "$bodies" "$messages" | grep -ioE "$CLOSES_RE" | grep -oE '[0-9]+$' || true
  printf '%s\n' "$messages" | grep -iE '^refs #[0-9]+[[:space:]]*$' | grep -oE '[0-9]+' || true
} | sort -un)
echo "Referenced issues: $(echo $refs)"

ensure_label() {
  [ "$label_ready" = true ] && return 0
  gh label create "$LABEL" -R "$REPO" --force --color 0E8A16 \
    --description "Merged into a release branch; closes when the release lands on the default branch" >/dev/null \
    || warn_exit "Cannot create the label $LABEL in $REPO"
  label_ready=true
}

mark() {
  local n=$1
  MARKED[$n]=1
  if [ "$DRY_RUN" = true ]; then
    echo "would label #$n"
    return 0
  fi
  ensure_label
  echo "labelling #$n"
  gh api -X POST "repos/$REPO/issues/$n/labels" -f "labels[]=$LABEL" --silent \
    || warn_exit "Cannot label #$n"
  gh api -X POST "repos/$REPO/issues/$n/comments" --silent \
    -f body="Merged into \`$BRANCH\`; closes when the release lands on \`$BASE\`." \
    || echo "::warning::Cannot comment on #$n."
}

# prints "<pr> <state> <has-label>" or nothing when the issue cannot be read
issue_info() {
  gh api "repos/$REPO/issues/$1" \
    --jq '"\(.pull_request != null) \(.state) \(any(.labels[]; .name == '"$LABEL_JSON"'))"' 2>/dev/null || true
}

mark_parents() {
  local n=$1 p labels state all c has
  p=$(gh api "repos/$REPO/issues/$n/parent" --jq 'select(.repository_url | endswith("/'"$REPO"'")) | .number' 2>/dev/null || true)
  [[ "$p" =~ ^[0-9]+$ ]] || return 0
  # a labelled parent is walked upwards once; an incomplete one is re-checked for every child
  [ -n "${UP[$p]:-}" ] && return 0
  read -r state labels < <(gh api "repos/$REPO/issues/$p" --jq '"\(.state) ,\([.labels[].name] | join(",")),"' 2>/dev/null || echo "unknown ,,")
  [ "$state" = open ] || return 0
  case "$labels" in *,epic,*) return 0 ;; esac
  case "$labels" in *,pbi,*|*,feature,*) ;; *) return 0 ;; esac
  case "$labels" in *",$LABEL,"*) MARKED[$p]=1 ;; esac
  if [ -z "${MARKED[$p]:-}" ]; then
    all=1
    while read -r c has; do
      [ -z "$c" ] && continue
      [ "$has" = true ] || [ -n "${MARKED[$c]:-}" ] || all=0
    done < <(gh api "repos/$REPO/issues/$p/sub_issues" --paginate \
      --jq '.[] | select(.state == "open") | "\(.number) \(any(.labels[]; .name == '"$LABEL_JSON"'))"' 2>/dev/null || echo "x false")
    [ "$all" = 1 ] || return 0
    mark "$p"
  fi
  UP[$p]=1
  mark_parents "$p"
}

for n in $refs; do
  [ -n "${SEEN[$n]:-}" ] && continue
  SEEN[$n]=1
  read -r is_pr state has < <(issue_info "$n"; echo)
  if [ -z "${is_pr:-}" ]; then
    echo "#$n cannot be read; skipped."
    continue
  fi
  [ "$is_pr" = true ] && continue
  [ "$state" = open ] || continue
  if [ "$has" = true ]; then
    MARKED[$n]=1
  else
    mark "$n"
  fi
  mark_parents "$n"
done
echo "Done."
