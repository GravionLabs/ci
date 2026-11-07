#!/usr/bin/env bash
# Closes the open issues delivered to a release branch and comments where they ship.
# Env: GH_TOKEN, GITHUB_REPOSITORY, RELEASE_BRANCH; optional BASE (default: the default branch), DRY_RUN=true,
# GITHUB_OUTPUT (output closed).
# Closing references: Closes|Fixes|Resolves #n in the bodies of the PRs merged into the branch since it left the base,
# and in the footer lines (not the subject) of the commit messages of base...branch. "Refs #n" never closes.
set -euo pipefail

REPO="${GITHUB_REPOSITORY:?}"
BRANCH="${RELEASE_BRANCH:?}"
BASE="${BASE:-}"
DRY_RUN="${DRY_RUN:-false}"
LABEL=merged
KEYWORD_RE='(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)[: ]+#([0-9]+)'
FOOTER_RE='(?i)^\s*(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)[: ]+#[0-9]+'
# SOURCE[n] = where #n was closed ("#<pr>" or a short commit sha); CLOSED = closed (or would be) in this run;
# NEWLY = really closed in this run (output closed)
declare -A SOURCE=() CLOSED=() NEWLY=()

write_output() {
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  local list=""
  [ "${#NEWLY[@]}" -eq 0 ] || list=$(printf '%s\n' "${!NEWLY[@]}" | sort -n | tr '\n' ' ')
  echo "closed=${list% }" >> "$GITHUB_OUTPUT"
}
trap write_output EXIT

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
ahead=$(jq -r .ahead <<<"$cmp")
since=$(jq -r .since <<<"$cmp")
if [ "$ahead" = 0 ]; then
  echo "$BRANCH has no commits ahead of $BASE; nothing to do."
  exit 0
fi

prs=$(gh pr list -R "$REPO" --base "$BRANCH" --state merged --limit 500 --json number,body,mergedAt) \
  || warn_exit "Cannot list the pull requests merged into $BRANCH"
# raw pages (compare returns at most 250 commits per call), filtered by the local jq
commits=$(gh api --paginate "repos/$REPO/compare/$BASE...$BRANCH?per_page=100") \
  || warn_exit "Cannot list the commits of $BASE...$BRANCH"

# "<issue>\t<source>" lines: PRs merged since the branch left the base (oldest first), then the commit footers
refs=$( {
  jq -r --arg since "$since" --arg re "$KEYWORD_RE" '
    sort_by(.mergedAt) | .[] | select(.mergedAt > $since) | .number as $pr
    | [(.body // "") | scan($re)[0]] | unique[] | "\(.)\t#\($pr)"' <<<"$prs"
  jq -r --arg re "$KEYWORD_RE" --arg foot "$FOOTER_RE" '
    .commits[]? | (.commit.message | split("\n")) as $lines
    | ([$lines[0] | match("\\(#([0-9]+)\\)\\s*$|^Merge pull request #([0-9]+) ").captures[].string | select(. != null)] | first) as $pr
    | (if $pr then "#\($pr)" else .sha[0:7] end) as $src
    | [$lines[1:][] | select(test($foot)) | scan($re)[0]] | unique[] | "\(.)\t\($src)"' <<<"$commits"
} ) || warn_exit "Cannot read the closing references of $BASE...$BRANCH"

while IFS=$'\t' read -r n src; do
  [ -n "$n" ] || continue
  n=$((10#$n))
  [ -n "${SOURCE[$n]:-}" ] || SOURCE[$n]=$src
done <<<"$refs"
issues=$( [ "${#SOURCE[@]}" -eq 0 ] || printf '%s\n' "${!SOURCE[@]}" | sort -n)
echo "Closing references: $(tr '\n' ' ' <<<"$issues" | sed 's/ *$//')"

# prints "<pr>\t<state>\t<has label>\t,<labels>,\t<milestone title>" or nothing when the issue cannot be read
issue_info() {
  gh api "repos/$REPO/issues/$1" --jq '"\(.pull_request != null)\t\(.state)\t\(any(.labels[]; .name == "'"$LABEL"'"))\t,\([.labels[].name] | join(",")),\t\(.milestone.title // "")"' 2>/dev/null || true
}

close_issue() {
  local n=$1 src=$2 milestone=$3 has=$4 body
  body="Merged into \`$BRANCH\` in $src, ships with ${milestone:-the next release}."
  CLOSED[$n]=1
  if [ "$DRY_RUN" = true ]; then
    echo "would close #$n: $body"
    [ "$has" != true ] || echo "would remove $LABEL from #$n"
    return 0
  fi
  echo "closing #$n"
  gh issue close "$n" -R "$REPO" --reason completed >/dev/null || warn_exit "Cannot close #$n"
  NEWLY[$n]=1
  # commented only after the close succeeded: a rerun skips the closed issue, so it never comments twice
  gh api -X POST "repos/$REPO/issues/$n/comments" --silent -f body="$body" \
    || echo "::warning::Cannot comment on #$n."
  if [ "$has" = true ]; then
    gh api -X DELETE "repos/$REPO/issues/$n/labels/$LABEL" --silent >/dev/null \
      || echo "::warning::Cannot remove the label $LABEL from #$n."
  fi
}

# closes the parent (pbi or feature, same repository, never an epic) once all its sub-issues are closed, repeating upwards
close_parents() {
  local n=$1 src=$2 p info is_pr state has labels milestone open c
  p=$(gh api "repos/$REPO/issues/$n/parent" --jq 'select(.repository_url | endswith("/'"$REPO"'")) | .number' 2>/dev/null || true)
  [[ "$p" =~ ^[0-9]+$ ]] || return 0
  [ -z "${CLOSED[$p]:-}" ] || return 0
  info=$(issue_info "$p")
  [ -n "$info" ] || return 0
  IFS=$'\t' read -r is_pr state has labels milestone <<<"$info"
  [ "$state" = open ] || return 0
  case "$labels" in *,epic,*) return 0 ;; esac
  case "$labels" in *,pbi,*|*,feature,*) ;; *) return 0 ;; esac
  # an open sub-issue of another repository blocks ("x"); a read failure leaves the parent open
  open=$(gh api "repos/$REPO/issues/$p/sub_issues" --paginate \
    --jq '.[] | select(.state == "open") | if ((.repository_url // "") | endswith("/'"$REPO"'")) then .number else "x" end' 2>/dev/null) \
    || { echo "Cannot read the sub-issues of #$p; left open."; return 0; }
  for c in $open; do
    [ -n "${CLOSED[$c]:-}" ] || return 0
  done
  close_issue "$p" "$src" "$milestone" "$has"
  close_parents "$p" "$src"
}

for n in $issues; do
  [ -z "${CLOSED[$n]:-}" ] || continue
  info=$(issue_info "$n")
  if [ -z "$info" ]; then
    echo "#$n cannot be read; skipped."
    continue
  fi
  IFS=$'\t' read -r is_pr state has labels milestone <<<"$info"
  if [ "$is_pr" = true ]; then
    echo "#$n is a pull request; skipped."
    continue
  fi
  [ "$state" = open ] || continue
  close_issue "$n" "${SOURCE[$n]}" "$milestone" "$has"
  close_parents "$n" "${SOURCE[$n]}"
done
echo "Done."
