#!/usr/bin/env bash
# Env: GH_TOKEN, GITHUB_REPOSITORY, RELEASE_BRANCH; optional BASE, LABEL (default merged), DRY_RUN=true,
# PROJECT_STATUS (set this project Status on the project items of the labelled issues), PROJECT_TOKEN (default GH_TOKEN)
set -euo pipefail

REPO="${GITHUB_REPOSITORY:?}"
BRANCH="${RELEASE_BRANCH:?}"
BASE="${BASE:-}"
LABEL="${LABEL:-merged}"
DRY_RUN="${DRY_RUN:-false}"
PROJECT_STATUS="${PROJECT_STATUS:-}"
PROJECT_TOKEN="${PROJECT_TOKEN:-${GH_TOKEN:-}}"
LABEL_JSON=$(jq -n --arg l "$LABEL" '$l')
CLOSES_RE='\b(close[sd]?|fix(e[sd])?|resolve[sd]?)[: ]+#[0-9]+'
declare -A MARKED=() SEEN=() UP=() NO_OPTION=()
label_ready=false
project_blocked=false

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

ITEM_QUERY='query ItemStatus($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) { issue(number: $number) { projectItems(first: 20) { nodes {
    id
    project { id title field(name: "Status") { ... on ProjectV2SingleSelectField { id options { id name } } } }
    fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
  } } } }
}'
SET_MUTATION='mutation SetStatus($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
  updateProjectV2ItemFieldValue(input: {projectId: $projectId, itemId: $itemId, fieldId: $fieldId,
    value: {singleSelectOptionId: $optionId}}) { projectV2Item { id } }
}'

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

set_status() {
  local n=$1 resp rows item project title current field option errf
  errf=$(mktemp)
  if ! resp=$(GH_TOKEN=$PROJECT_TOKEN gh api graphql -f query="$ITEM_QUERY" \
      -f owner="${REPO%%/*}" -f name="${REPO#*/}" -F number="$n" 2>"$errf"); then
    resp="$resp$(cat "$errf")"; rm -f "$errf"
    scope_error "$resp" || echo "::warning::Cannot read the project items of #$n: $resp"
    return 0
  fi
  rm -f "$errf"
  rows=$(jq -r --arg s "$PROJECT_STATUS" '.data.repository.issue.projectItems.nodes[]?
    | [.id, .project.id, .project.title, (.fieldValueByName.name // "-"), (.project.field.id // "-"),
       ([.project.field.options[]? | select(.name == $s) | .id][0] // "-")] | @tsv' <<<"$resp") || rows=""
  while IFS=$'\t' read -r item project title current field option; do
    [ -z "$item" ] && continue
    if [ "$current" = Done ] || [ "$current" = "$PROJECT_STATUS" ]; then
      echo "#$n is already $current in $title; status unchanged."
      continue
    fi
    if [ "$option" = "-" ]; then
      if [ -z "${NO_OPTION[$project]:-}" ]; then
        NO_OPTION[$project]=1
        echo "::warning::Project $title has no Status option '$PROJECT_STATUS'; status not set there."
      fi
      continue
    fi
    if [ "$DRY_RUN" = true ]; then
      echo "would set #$n to $PROJECT_STATUS in $title"
      continue
    fi
    echo "setting #$n to $PROJECT_STATUS in $title"
    if ! resp=$(GH_TOKEN=$PROJECT_TOKEN gh api graphql -f query="$SET_MUTATION" -f projectId="$project" \
        -f itemId="$item" -f fieldId="$field" -f optionId="$option" 2>&1); then
      scope_error "$resp" && return 0
      echo "::warning::Cannot set the status of #$n in $title: $resp"
    fi
  done <<<"$rows"
}

if [ -n "$PROJECT_STATUS" ]; then
  for n in $(printf '%s\n' "${!MARKED[@]}" | sort -n); do
    [ "$project_blocked" = true ] && break
    set_status "$n"
  done
fi
echo "Done."
