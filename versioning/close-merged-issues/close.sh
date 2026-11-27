#!/usr/bin/env bash
# Closes the open issues delivered to a release branch, sets the release milestone and comments where they ship.
# Env: GH_TOKEN, GITHUB_REPOSITORY, RELEASE_BRANCH; optional BASE (default: the default branch), DRY_RUN=true,
# GITHUB_OUTPUT (outputs closed, milestoned).
# Closing references: Closes|Fixes|Resolves #n in the bodies of the PRs merged into the branch since it left the base,
# and in the footer lines (not the subject) of the commit messages of base...branch. "Refs #n" never closes.
# Release milestone: the open milestone with the lowest M<nnn> number (M007 < M007.1 < M008); no M<nnn> open: the lowest
# open x.y.z title. A closed issue labelled pbi or bug (not epic, feature, objective, release-test) without an open
# milestone gets it before the comment.
set -euo pipefail

REPO="${GITHUB_REPOSITORY:?}"
BRANCH="${RELEASE_BRANCH:?}"
BASE="${BASE:-}"
DRY_RUN="${DRY_RUN:-false}"
LABEL=merged
KEYWORD_RE='(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)[: ]+#([0-9]+)'
FOOTER_RE='(?i)^\s*(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)[: ]+#[0-9]+'
# SOURCE[n] = where #n was closed ("#<pr>" or a short commit sha); CLOSED = closed (or would be) in this run;
# NEWLY = really closed in this run (output closed); MILESTONED = got the release milestone in this run (output milestoned)
declare -A SOURCE=() CLOSED=() NEWLY=() MILESTONED=()
# release milestone, read once on first use: MS_STATE = '' (not read yet), found, none or error
MS_STATE="" MS_NUMBER="" MS_TITLE=""

sorted() { [ "$#" -eq 0 ] || printf '%s\n' "$@" | sort -n | tr '\n' ' '; }
write_output() {
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  local closed milestoned
  closed=$(sorted "${!NEWLY[@]}")
  milestoned=$(sorted "${!MILESTONED[@]}")
  printf 'closed=%s\nmilestoned=%s\n' "${closed% }" "${milestoned% }" >> "$GITHUB_OUTPUT"
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

# prints "<pr>\t<state>\t<has label>\t,<labels>,\t<milestone state or none>\t<milestone title>" or nothing when the issue
# cannot be read (the title is last: it may be empty, and read collapses empty tab-separated fields)
issue_info() {
  gh api "repos/$REPO/issues/$1" --jq '"\(.pull_request != null)\t\(.state)\t\(any(.labels[]; .name == "'"$LABEL"'"))\t,\([.labels[].name] | join(",")),\t\(if .milestone then .milestone.state else "none" end)\t\(.milestone.title // "")"' 2>/dev/null || true
}

# reads the open milestones once and picks the release milestone
find_release_milestone() {
  [ -z "$MS_STATE" ] || return 0
  local list best
  if ! list=$(gh api --paginate "repos/$REPO/milestones?state=open&per_page=100" --jq '.[] | [.number, .title] | @tsv'); then
    MS_STATE=error
    return 0
  fi
  # sort key: M<nnn> before x.y.z, then every number part padded (M007 < M007.1 < M008, 1.9.0 < 1.10.0)
  best=$(jq -rRn '
    def key($rank): split(".") | map("00000000" + . | .[-8:]) | "\($rank) \(join("."))";
    [ inputs | select(. != "") | split("\t") | . as [$number, $title]
      | ( ($title | capture("^M(?<n>[0-9]{1,8}(\\.[0-9]{1,8}){0,7})( [^()]+)?( \\([0-9]+\\.[0-9]+\\.[0-9]+\\))?$") | .n | key(0)),
          ($title | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) | key(1)) ) as $key
      | {$key, $number, $title} ]
    | min_by(.key) // empty | "\(.number)\t\(.title)"' <<<"$list")
  if [ -z "$best" ]; then
    MS_STATE=none
    return 0
  fi
  MS_STATE=found
  IFS=$'\t' read -r MS_NUMBER MS_TITLE <<<"$best"
}

# sets the release milestone on a PBI or Bug without an open one; MILESTONE = the title the comment names
set_milestone() {
  local n=$1 state=$2 labels=$3
  case "$labels" in *,epic,*|*,feature,*|*,objective,*|*,release-test,*) return 0 ;; esac
  case "$labels" in *,pbi,*|*,bug,*) ;; *) return 0 ;; esac
  [ "$state" != open ] || return 0
  find_release_milestone
  case "$MS_STATE" in
    none) echo "::warning::no open milestone, #$n left without"; return 0 ;;
    error) echo "::warning::Cannot read the milestones, #$n left without"; return 0 ;;
  esac
  if [ "$DRY_RUN" = true ]; then
    echo "would set $MS_TITLE on #$n"
  elif gh api -X PATCH "repos/$REPO/issues/$n" -F "milestone=$MS_NUMBER" --silent >/dev/null; then
    echo "set $MS_TITLE on #$n"
    MILESTONED[$n]=1
  else
    echo "::warning::Cannot set the milestone $MS_TITLE on #$n."
    return 0
  fi
  MILESTONE=$MS_TITLE
}

close_issue() {
  local n=$1 src=$2 has=$3 labels=$4 state=$5 body
  MILESTONE=$6
  CLOSED[$n]=1
  if [ "$DRY_RUN" != true ]; then
    echo "closing #$n"
    gh issue close "$n" -R "$REPO" --reason completed >/dev/null || warn_exit "Cannot close #$n"
    NEWLY[$n]=1
  fi
  set_milestone "$n" "$state" "$labels"
  body="Merged into \`$BRANCH\` in $src, ships with ${MILESTONE:-the next release}."
  if [ "$DRY_RUN" = true ]; then
    echo "would close #$n: $body"
    [ "$has" != true ] || echo "would remove $LABEL from #$n"
    return 0
  fi
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
  local n=$1 src=$2 p info is_pr state has labels ms_state milestone open c
  p=$(gh api "repos/$REPO/issues/$n/parent" --jq 'select(.repository_url | endswith("/'"$REPO"'")) | .number' 2>/dev/null || true)
  [[ "$p" =~ ^[0-9]+$ ]] || return 0
  [ -z "${CLOSED[$p]:-}" ] || return 0
  info=$(issue_info "$p")
  [ -n "$info" ] || return 0
  IFS=$'\t' read -r is_pr state has labels ms_state milestone <<<"$info"
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
  close_issue "$p" "$src" "$has" "$labels" "$ms_state" "$milestone"
  close_parents "$p" "$src"
}

for n in $issues; do
  [ -z "${CLOSED[$n]:-}" ] || continue
  info=$(issue_info "$n")
  if [ -z "$info" ]; then
    echo "#$n cannot be read; skipped."
    continue
  fi
  IFS=$'\t' read -r is_pr state has labels ms_state milestone <<<"$info"
  if [ "$is_pr" = true ]; then
    echo "#$n is a pull request; skipped."
    continue
  fi
  [ "$state" = open ] || continue
  close_issue "$n" "${SOURCE[$n]}" "$has" "$labels" "$ms_state" "$milestone"
  close_parents "$n" "${SOURCE[$n]}"
done
echo "Done."
