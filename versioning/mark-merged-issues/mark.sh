#!/usr/bin/env bash
# Env: GH_TOKEN, GITHUB_REPOSITORY, RELEASE_BRANCH; optional BASE, LABEL (default merged), DRY_RUN=true,
# GITHUB_OUTPUT (output labelled), PROJECT_STATUS (set this project Status on the project items of the labelled issues), PROJECT_TOKEN (default GH_TOKEN)
set -euo pipefail

REPO="${GITHUB_REPOSITORY:?}"
BRANCH="${RELEASE_BRANCH:?}"
BASE="${BASE:-}"
LABEL="${LABEL:-merged}"
DRY_RUN="${DRY_RUN:-false}"
PROJECT_STATUS="${PROJECT_STATUS:-}"
PROJECT_TOKEN="${PROJECT_TOKEN:-${GH_TOKEN:-}}"
LABEL_JSON=$(jq -n --arg l "$LABEL" '$l')
# Deprecated: versioning/close-merged-issues replaces it (closes the issues at merge, no label). Removed in the next major.
echo "::warning::versioning/mark-merged-issues is deprecated and will be removed in the next major; use versioning/close-merged-issues."
CLOSES_RE='\b(close[sd]?|fix(e[sd])?|resolve[sd]?)[: ]+#[0-9]+'
declare -A MARKED=() LABELLED=() SEEN=() UP=() NO_OPTION=()
label_ready=false
project_blocked=false

# Output `labelled`: issues newly labelled in this run (not those already labelled), also on warn exits.
write_output() {
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  local list=""
  [ "${#LABELLED[@]}" -eq 0 ] || list=$(printf '%s\n' "${!LABELLED[@]}" | sort -n | tr '\n' ' ')
  echo "labelled=${list% }" >> "$GITHUB_OUTPUT"
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
  LABELLED[$n]=1
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

# true (and one warning, then no more project calls) when the token cannot reach the projects
scope_error() {
  case "$1" in
    *"Resource not accessible"*|*INSUFFICIENT_SCOPES*|*"required scopes"*)
      echo "::warning::The token cannot access the project (Resource not accessible / missing scope): use a classic PAT with the scope 'project' as project-token; fine-grained tokens cannot access user-owned projects. Project status not set."
      project_blocked=true
      return 0 ;;
  esac
  return 1
}

# Project reads and writes are REST (no GraphQL): GET /{users|orgs}/{owner}/projectsV2 lists the projects of the repository owner,
# /fields gives the Status field and its options, /items?q=repo:{owner}/{repo} the project items of the repository's issues with their Status;
# the write is PATCH /{users|orgs}/{owner}/projectsV2/{number}/items/{id}. GitHub has no REST endpoint from an issue to its project items, so the
# owner's projects are read once per run (one request set per project). An issue is found in the projects of the repository owner only.
projects_loaded=false
PROJ_SEG=""
PROJ_OWNER="${REPO%%/*}"
PROJ_NUMBERS=()
declare -A PROJ_TITLE=() PROJ_FIELD=() PROJ_OPT=() ITEM_ID=() ITEM_STATUS=()

# true (and one warning, then no more project calls) when the projects cannot be read
project_read_failed() {
  scope_error "$1" || echo "::warning::Cannot read the projects of $PROJ_OWNER: $1"
  project_blocked=true
}

load_projects() {
  projects_loaded=true
  local kind list num title fields fid opt items id status
  if ! kind=$(GH_TOKEN=$PROJECT_TOKEN gh api "users/$PROJ_OWNER" --jq .type 2>&1); then
    project_read_failed "$kind"; return 0
  fi
  if [ "$kind" = Organization ]; then PROJ_SEG=orgs; else PROJ_SEG=users; fi
  if ! list=$(GH_TOKEN=$PROJECT_TOKEN gh api --paginate "$PROJ_SEG/$PROJ_OWNER/projectsV2?per_page=100" \
      --jq '.[] | select(.closed_at == null) | "\(.number)\t\(.title)"' 2>&1); then
    project_read_failed "$list"; return 0
  fi
  while IFS=$'\t' read -r num title; do
    [ -z "$num" ] && continue
    if ! fields=$(GH_TOKEN=$PROJECT_TOKEN gh api --paginate "$PROJ_SEG/$PROJ_OWNER/projectsV2/$num/fields?per_page=100" \
        --jq '.[] | select(.name == "Status" and .data_type == "single_select")' 2>&1); then
      project_read_failed "$fields"; return 0
    fi
    fid=$(jq -r '.id // empty' <<<"$fields" | head -n1)
    opt=$(jq -r --arg s "$PROJECT_STATUS" '[.options[]? | select((.name.raw // .name) == $s) | .id][0] // empty' <<<"$fields")
    PROJ_TITLE[$num]=$title
    PROJ_FIELD[$num]=${fid:--}
    PROJ_OPT[$num]=${opt:--}
    if ! items=$(GH_TOKEN=$PROJECT_TOKEN gh api --paginate "$PROJ_SEG/$PROJ_OWNER/projectsV2/$num/items?per_page=100&fields[]=${fid:-0}&q=repo:$REPO" \
        --jq '.[] | select(.content_type == "Issue" and (.content.repository.full_name // "") == "'"$REPO"'") | "\(.content.number)\t\(.id)\t\([.fields[]? | select(.id == '"${fid:-0}"') | .value.name.raw // .value.name][0] // "-")"' 2>&1); then
      project_read_failed "$items"; return 0
    fi
    PROJ_NUMBERS+=("$num")
    while IFS=$'\t' read -r id item status; do
      [ -z "$id" ] && continue
      ITEM_ID["$num#$id"]=$item
      ITEM_STATUS["$num#$id"]=$status
    done <<<"$items"
  done <<<"$list"
}

set_status() {
  local n=$1 resp p key item current option title body
  [ "$projects_loaded" = true ] || load_projects
  [ "$project_blocked" = true ] && return 0
  for p in "${PROJ_NUMBERS[@]}"; do
    key="$p#$n"
    item=${ITEM_ID[$key]:-}
    [ -n "$item" ] || continue
    title=${PROJ_TITLE[$p]} current=${ITEM_STATUS[$key]} option=${PROJ_OPT[$p]}
    if [ "$current" = Done ] || [ "$current" = "$PROJECT_STATUS" ]; then
      echo "#$n is already $current in $title; status unchanged."
      continue
    fi
    if [ "$option" = "-" ] || [ "${PROJ_FIELD[$p]}" = "-" ]; then
      if [ -z "${NO_OPTION[$p]:-}" ]; then
        NO_OPTION[$p]=1
        echo "::warning::Project $title has no Status option '$PROJECT_STATUS'; status not set there."
      fi
      continue
    fi
    if [ "$DRY_RUN" = true ]; then
      echo "would set #$n to $PROJECT_STATUS in $title"
      continue
    fi
    echo "setting #$n to $PROJECT_STATUS in $title"
    body=$(jq -nc --argjson f "${PROJ_FIELD[$p]}" --arg o "$option" '{fields: [{id: $f, value: $o}]}')
    if ! resp=$(GH_TOKEN=$PROJECT_TOKEN gh api -X PATCH "$PROJ_SEG/$PROJ_OWNER/projectsV2/$p/items/$item" --input - <<<"$body" 2>&1); then
      scope_error "$resp" && return 0
      echo "::warning::Cannot set the status of #$n in $title: $resp"
    fi
  done
}

if [ -n "$PROJECT_STATUS" ]; then
  for n in $(printf '%s\n' "${!MARKED[@]}" | sort -n); do
    [ "$project_blocked" = true ] && break
    set_status "$n"
  done
fi
echo "Done."
