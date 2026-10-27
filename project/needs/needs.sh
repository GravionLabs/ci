#!/usr/bin/env bash
# Builds the arguments for Sync-ProjectNeeds.ps1 of the github-project skill from the event and runs it with pwsh.
# All input comes from the environment; event data (head ref, label) is only matched, never evaluated.
#   PROJECT_URL   https://github.com/(users|orgs)/<owner>/projects/<n> (required)
#   GH_REPO       owner/repo whose items are synced (required)
#   SYNC_SCRIPT   path of Sync-ProjectNeeds.ps1 (required)
#   MODE          event (default) | full
#   ISSUES        issue numbers (space, comma or newline separated); with MODE=event each is synced with parents and
#                 dependents, independent of the event (MODE=full wins)
#   EVENT_NAME, EVENT_ACTION, ISSUE_NUMBER, HEAD_REF, LABEL_NAME   event data
# Exit code: the one of Sync-ProjectNeeds.ps1; 1 on invalid input; 0 when the event has nothing to sync.
set -euo pipefail

MODE=${MODE:-event}
EVENT_NAME=${EVENT_NAME:-}
EVENT_ACTION=${EVENT_ACTION:-}
ISSUE_NUMBER=${ISSUE_NUMBER:-}
HEAD_REF=${HEAD_REF:-}
LABEL_NAME=${LABEL_NAME:-}
ISSUES=${ISSUES:-}

if [[ ! "${PROJECT_URL:-}" =~ ^https://github\.com/(users|orgs)/([A-Za-z0-9][A-Za-z0-9-]*)/projects/([0-9]+)/?$ ]]; then
  echo "::error::Invalid project-url '${PROJECT_URL:-}' (expected https://github.com/users|orgs/<owner>/projects/<n>)"
  exit 1
fi
owner=${BASH_REMATCH[2]}
number=${BASH_REMATCH[3]}

if [[ ! "${GH_REPO:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "::error::Invalid GH_REPO '${GH_REPO:-}' (expected owner/repo)"
  exit 1
fi
case "$MODE" in event | full) ;; *)
  echo "::error::Invalid mode '$MODE' (expected event or full)"
  exit 1
  ;;
esac
if [ ! -f "${SYNC_SCRIPT:-}" ]; then
  echo "::error::Sync-ProjectNeeds.ps1 not found at '${SYNC_SCRIPT:-}'"
  exit 1
fi

args=(-Owner "$owner" -Number "$number" -Repo "$GH_REPO")

if [ "$MODE" = event ] && [ -n "${ISSUES//[[:space:],]/}" ]; then
  list=()
  declare -A seen=()
  IFS=$' \t\n,' read -r -d '' -a tokens <<<"$ISSUES" || true
  for n in "${tokens[@]}"; do
    [ -n "$n" ] || continue
    if [[ ! "$n" =~ ^[0-9]+$ ]]; then
      echo "::error::Invalid issue number '$n' in issues (expected numbers separated by space, comma or newline)"
      exit 1
    fi
    n=$((10#$n))
    [ -n "${seen[$n]:-}" ] && continue
    seen[$n]=1
    list+=("$n")
  done
  rc=0
  for n in "${list[@]}"; do
    pwsh -NoProfile -File "$SYNC_SCRIPT" "${args[@]}" -Issue "$n" -IncludeParents -IncludeDependents || { c=$?; [ "$rc" -ne 0 ] || rc=$c; }
  done
  exit "$rc"
elif [ "$MODE" = full ] || [ "$EVENT_NAME" = schedule ] || [ "$EVENT_NAME" = workflow_dispatch ]; then
  : # full sync of the repository's items
elif [ "$EVENT_NAME" = issues ]; then
  if [[ ! "$ISSUE_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "::error::Invalid issue number '$ISSUE_NUMBER' for an issues event"
    exit 1
  fi
  args+=(-Issue "$ISSUE_NUMBER" -IncludeParents)
  # blocker events: a closed, reopened or merged blocker changes the Needs of the issues it blocks
  case "$EVENT_ACTION" in
    closed | reopened) args+=(-IncludeDependents) ;;
    labeled | unlabeled) [ "$LABEL_NAME" = merged ] && args+=(-IncludeDependents) ;;
  esac
elif [ "$EVENT_NAME" = pull_request_target ]; then
  if [[ "$HEAD_REF" =~ (^|/)([0-9]+)- ]]; then
    args+=(-Issue "${BASH_REMATCH[2]}" -IncludeParents)
  else
    echo "::notice::No issue number in head ref '$HEAD_REF': Needs sync skipped"
    exit 0
  fi
else
  echo "::notice::Event '$EVENT_NAME' is not handled: Needs sync skipped"
  exit 0
fi

exec pwsh -NoProfile -File "$SYNC_SCRIPT" "${args[@]}"
