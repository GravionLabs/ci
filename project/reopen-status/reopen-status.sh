#!/usr/bin/env bash
# Sets the project field Status of the item of a reopened issue to Todo when it is Done (other values stay).
# One GraphQL query (item, Status field, options) and at most one updateProjectV2ItemFieldValue mutation.
# Never fails the run for an issue outside the project, a project without Status/Todo or an API error (warning, exit 0).
#   PROJECT_URL   https://github.com/(users|orgs)/<owner>/projects/<n> (required)
#   GH_REPO       owner/repo of the issue (required)
#   ISSUE_NUMBER  number of the reopened issue (required)
#   GH_TOKEN      classic PAT with the scope project (plus repo for a private repository)
set -uo pipefail

if [[ ! "${PROJECT_URL:-}" =~ ^https://github\.com/(users|orgs)/([A-Za-z0-9][A-Za-z0-9-]*)/projects/([0-9]+)/?$ ]]; then
  echo "::error::Invalid project-url '${PROJECT_URL:-}' (expected https://github.com/users|orgs/<owner>/projects/<n>)"
  exit 1
fi
owner=${BASH_REMATCH[2]}
number=${BASH_REMATCH[3]}
if [[ ! "${GH_REPO:-}" =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]]; then
  echo "::error::Invalid GH_REPO '${GH_REPO:-}' (expected owner/repo)"
  exit 1
fi
repo_owner=${BASH_REMATCH[1]}
repo_name=${BASH_REMATCH[2]}
if [[ ! "${ISSUE_NUMBER:-}" =~ ^[0-9]+$ ]]; then
  echo "::error::Invalid ISSUE_NUMBER '${ISSUE_NUMBER:-}'"
  exit 1
fi

# shellcheck disable=SC2016
query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){projectItems(first:50){nodes{id project{id number owner{... on User{login} ... on Organization{login}} field(name:"Status"){... on ProjectV2SingleSelectField{id options{id name}}}} fieldValueByName(name:"Status"){... on ProjectV2ItemFieldSingleSelectValue{name}}}}}}}'

if ! resp=$(gh api graphql -f query="$query" -F o="$repo_owner" -F r="$repo_name" -F n="$ISSUE_NUMBER" 2>&1); then
  echo "::warning::Reading the project item of #$ISSUE_NUMBER failed: $resp"
  exit 0
fi

item=$(jq -c --arg owner "$owner" --argjson num "$number" \
  '[.data.repository.issue.projectItems.nodes[]? | select(.project.number == $num and ((.project.owner.login // "") | ascii_downcase) == ($owner | ascii_downcase))] | first // empty' <<<"$resp")
if [ -z "$item" ]; then
  echo "Issue #$ISSUE_NUMBER is not in project $owner/$number; nothing to do."
  exit 0
fi

status=$(jq -r '.fieldValueByName.name // ""' <<<"$item")
if [ "$status" != "Done" ]; then
  echo "Status of #$ISSUE_NUMBER is '${status:-unset}', not Done; nothing to do."
  exit 0
fi

project_id=$(jq -r '.project.id' <<<"$item")
item_id=$(jq -r '.id' <<<"$item")
field_id=$(jq -r '.project.field.id // ""' <<<"$item")
todo_id=$(jq -r '[.project.field.options[]? | select(.name == "Todo")] | first | .id // ""' <<<"$item")
if [ -z "$field_id" ] || [ -z "$todo_id" ]; then
  echo "::warning::Project $owner/$number has no Status field with the option Todo; skipping."
  exit 0
fi

# shellcheck disable=SC2016
mutation='mutation($p:ID!,$i:ID!,$f:ID!,$o:String!){updateProjectV2ItemFieldValue(input:{projectId:$p,itemId:$i,fieldId:$f,value:{singleSelectOptionId:$o}}){projectV2Item{id}}}'
if ! out=$(gh api graphql -f query="$mutation" -F p="$project_id" -F i="$item_id" -F f="$field_id" -F o="$todo_id" 2>&1); then
  echo "::warning::Setting Status Todo on #$ISSUE_NUMBER failed: $out"
  exit 0
fi
echo "Set Status of #$ISSUE_NUMBER to Todo (was Done)."
