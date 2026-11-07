#!/usr/bin/env bash
# Tests for versioning/mark-merged-issues/mark.sh, versioning/close-merged-issues/close.sh and the label removal in
# versioning/close-release-issues/close.sh against a fake gh (tests/stub/gh). Run: bash tests/versioning.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MARK="$ROOT/versioning/mark-merged-issues/mark.sh"
CLOSE="$ROOT/versioning/close-release-issues/close.sh"
CLOSE_MERGED="$ROOT/versioning/close-merged-issues/close.sh"
export PATH="$ROOT/tests/stub:$PATH" GITHUB_REPOSITORY=o/r
failures=0 total=0

ok()   { total=$((total + 1)); echo "ok   - $1"; }
fail() { total=$((total + 1)); failures=$((failures + 1)); echo "FAIL - $1"; }
has()      { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else fail "$1 (missing: $2)"; fi; }
hasnt()    { if grep -qF -- "$2" <<<"$3"; then fail "$1 (unexpected: $2)"; else ok "$1"; fi; }
count_is() { local c; c=$(grep -cF -- "$2" <<<"$4"); if [ "$c" = "$3" ]; then ok "$1"; else fail "$1 (expected $3 x '$2', got $c)"; fi; }

setup() {
  GH_FIX=$(mktemp -d) GH_LOG=$(mktemp)
  export GH_FIX GH_LOG
}
fix() { printf '%s\n' "$2" > "$GH_FIX/$1.json"; }
# issue <n> <state> <labels csv> [pr]
issue() {
  local labels pr=""
  labels=$(jq -cn --arg l "$3" '$l | split(",") | map(select(. != "") | {name: .})')
  [ -z "${4:-}" ] || pr=',"pull_request":{}'
  fix "GET_repos_o_r_issues_$1" "{\"number\":$1,\"state\":\"$2\",\"labels\":$labels,\"repository_url\":\"https://api.github.com/repos/o/r\"$pr}"
}
parent() { fix "GET_repos_o_r_issues_$1_parent" "{\"number\":$2,\"repository_url\":\"https://api.github.com/repos/${3:-o/r}\"}"; }
subs() { fix "GET_repos_o_r_issues_$1_sub_issues" "$2"; }
run_mark_out() { local f; f=$(mktemp); GITHUB_OUTPUT=$f run_mark; OUTF=$f; }
run_mark() { out=$(RELEASE_BRANCH="${BRANCH:-release/next}" bash "$MARK" 2>&1); code=$?; log=$(cat "$GH_LOG"); }

# release/next is 3 commits ahead of main: #10 (open, PBI), #11 (open, already labelled, via a Refs
# footer), #12 (a PR), #13 (closed), #14 only in a PR merged before the branch left main, #99 inline
mark_fixture() {
  setup
  fix repo-view-o_r '{"defaultBranchRef":{"name":"main"}}'
  fix "GET_repos_o_r_compare_main...release_next" '{"ahead_by":3,
    "merge_base_commit":{"commit":{"committer":{"date":"2026-01-01T00:00:00Z"}}},
    "commits":[{"commit":{"message":"feat: a (#10)\n\nRefs #11"}},
               {"commit":{"message":"fix: b\n\nFixes #13"}},
               {"commit":{"message":"docs: mention Refs #99 inline"}}]}'
  fix pr-list '[{"body":"Closes #10\nResolves #12","mergedAt":"2026-02-01T00:00:00Z"},
                {"body":"Closes #14","mergedAt":"2025-12-01T00:00:00Z"}]'
  issue 10 open pbi; issue 11 open pbi,merged; issue 12 open "" pr; issue 13 closed pbi; issue 14 open pbi
  parent 10 20; parent 11 20
  issue 20 open feature
  subs 20 '[{"number":10,"state":"open","labels":[]},{"number":11,"state":"open","labels":[{"name":"merged"}]},
            {"number":15,"state":"closed","labels":[]}]'
  parent 20 30; issue 30 open epic
  subs 30 '[{"number":20,"state":"open","labels":[]}]'
}

echo "# mark: labels open referenced issues and the complete parent, never the epic"
mark_fixture; run_mark
[ "$code" = 0 ] && ok "exit 0" || fail "exit $code: $out"
has "references from PR bodies, Closes and Refs footers" "Referenced issues: 10 11 12 13" "$out"
count_is "label created once" "gh label create merged" 1 "$log"
has "labels #10" "gh api -X POST repos/o/r/issues/10/labels -f labels[]=merged" "$log"
has "comments on #10" 'gh api -X POST repos/o/r/issues/10/comments --silent -f body=Merged into `release/next`; closes when the release lands on `main`.' "$log"
has "labels the feature parent #20" "repos/o/r/issues/20/labels" "$log"
hasnt "already labelled #11 untouched" "issues/11/labels" "$log"
hasnt "already labelled #11 not commented" "issues/11/comments" "$log"
hasnt "PR #12 skipped" "issues/12/labels" "$log"
hasnt "closed #13 skipped" "issues/13/labels" "$log"
hasnt "PR merged before the branch left main ignored" "issues/14" "$log"
hasnt "inline Refs ignored" "issues/99" "$log"
hasnt "epic #30 never labelled" "issues/30/labels" "$log"

echo "# mark: idempotent when everything carries the label"
mark_fixture; issue 10 open pbi,merged; issue 20 open feature,merged; run_mark
[ "$code" = 0 ] && ok "exit 0" || fail "exit $code"
hasnt "no write" "-X POST" "$log"
hasnt "no label create" "label create" "$log"

echo "# mark: parent with an unlabelled open sub-issue stays unlabelled"
mark_fixture
subs 20 '[{"number":10,"state":"open","labels":[]},{"number":16,"state":"open","labels":[]}]'
run_mark
has "labels #10" "issues/10/labels" "$log"
hasnt "parent #20 not labelled" "issues/20/labels" "$log"

echo "# mark: parent in another repository or without pbi/feature label is skipped"
mark_fixture; parent 10 20 other/repo; parent 11 20 other/repo; run_mark
hasnt "foreign parent skipped" "issues/20/labels" "$log"
mark_fixture; issue 20 open "" ; run_mark
hasnt "unlabelled parent skipped" "issues/20/labels" "$log"

echo "# mark: dry run writes nothing"
mark_fixture; DRY_RUN=true run_mark
has "prints would label #10" "would label #10" "$out"
has "prints would label #20" "would label #20" "$out"
hasnt "no #30" "would label #30" "$out"
hasnt "no write" "-X POST" "$log"
hasnt "no label create" "label create" "$log"

echo "# mark: output labelled lists the newly labelled issues"
mark_fixture; run_mark_out
[ "$(cat "$OUTF")" = "labelled=10 20" ] && ok "labelled=10 20" || fail "output: $(cat "$OUTF")"
mark_fixture; issue 10 open pbi,merged; issue 20 open feature,merged; run_mark_out
[ "$(cat "$OUTF")" = "labelled=" ] && ok "idempotent run: labelled empty" || fail "output: $(cat "$OUTF")"
mark_fixture; DRY_RUN=true run_mark_out
[ "$(cat "$OUTF")" = "labelled=" ] && ok "dry run: labelled empty" || fail "output: $(cat "$OUTF")"
mark_fixture; touch "$GH_FIX/POST_repos_o_r_issues_10_labels.fail"; run_mark_out
[ "$code" = 0 ] && [ "$(cat "$OUTF")" = "labelled=" ] && ok "label write failure: exit 0, labelled empty" || fail "exit $code, output: $(cat "$OUTF")"
mark_fixture; BRANCH=main run_mark_out
[ "$(cat "$OUTF")" = "labelled=" ] && ok "non-release branch: labelled empty" || fail "output: $(cat "$OUTF")"

echo "# mark: custom label and base"
mark_fixture
fix "GET_repos_o_r_compare_dev...release_next" "$(cat "$GH_FIX/GET_repos_o_r_compare_main...release_next.json")"
out=$(RELEASE_BRANCH=release/next BASE=dev LABEL="in release" bash "$MARK" 2>&1); log=$(cat "$GH_LOG")
has "creates the custom label" "gh label create in release" "$log"
has "labels #11 with the custom label" "issues/11/labels -f labels[]=in release" "$log"
has "comment names the base" 'lands on `dev`' "$log"
hasnt "default branch not queried" "repo view" "$log"

echo "# mark: not a release branch"
mark_fixture; BRANCH=main run_mark
[ "$code" = 0 ] && ok "exit 0" || fail "exit $code"
has "says nothing to do" "not a release/* branch" "$out"
[ -z "$log" ] && ok "no gh call" || fail "gh called: $log"

echo "# mark: branch not ahead of the base"
mark_fixture; fix "GET_repos_o_r_compare_main...release_next" '{"ahead_by":0,"merge_base_commit":{"commit":{"committer":{"date":"2026-01-01T00:00:00Z"}}},"commits":[]}'
run_mark
has "says nothing to do" "no commits ahead" "$out"
hasnt "no write" "-X POST" "$log"

echo "# mark: missing permission warns and exits 0"
mark_fixture; touch "$GH_FIX/GET_repos_o_r_compare_main...release_next.fail"; run_mark
[ "$code" = 0 ] && ok "compare failure exits 0" || fail "exit $code"
has "compare failure warns" "::warning::Cannot compare main...release/next" "$out"
mark_fixture; touch "$GH_FIX/repo-view-o_r.fail"; run_mark
[ "$code" = 0 ] && ok "repo view failure exits 0" || fail "exit $code"
has "repo view failure warns" "::warning::" "$out"
mark_fixture; touch "$GH_FIX/label-create-merged.fail"; run_mark
[ "$code" = 0 ] && ok "label create failure exits 0" || fail "exit $code"
has "label create failure warns" "::warning::Cannot create the label merged" "$out"
hasnt "nothing labelled" "-X POST" "$log"
mark_fixture; touch "$GH_FIX/pr-list.fail"; run_mark
[ "$code" = 0 ] && ok "pr list failure exits 0" || fail "exit $code"
has "pr list failure warns" "::warning::Cannot list the pull requests" "$out"
mark_fixture; touch "$GH_FIX/POST_repos_o_r_issues_10_labels.fail"; run_mark
[ "$code" = 0 ] && ok "label write failure exits 0" || fail "exit $code"
has "label write failure warns" "::warning::Cannot label #10" "$out"

echo "# mark: project status (REST only)"
# #10 and #20 get labelled; #11 is already labelled (also in MARKED)
status_fixture() {
  mark_fixture
  export PROJECT_STATUS="In release"
  PSEG=users; [ "${OWNER_TYPE:-User}" = Organization ] && PSEG=orgs
  fix GET_users_o "{\"login\":\"o\",\"type\":\"${OWNER_TYPE:-User}\"}"
  PLIST=(); declare -gA PITEMS=()
  fix "GET_${PSEG}_o_projectsV2" "[]"
}
# proj <number> <title> <with option true|false> [closed]: registers a project of the owner (list + Status field)
proj() {
  local opts='[{"id":"o1","name":{"raw":"Todo"}},{"id":"o2","name":{"raw":"In release"}}]' closed=null
  [ "$3" = false ] && opts='[{"id":"o1","name":{"raw":"Todo"}}]'
  [ -n "${4:-}" ] && closed='"2026-01-01T00:00:00Z"'
  PLIST+=("{\"number\":$1,\"title\":\"$2\",\"closed_at\":$closed}")
  fix "GET_${PSEG}_o_projectsV2" "[$(IFS=,; echo "${PLIST[*]}")]"
  fix "GET_${PSEG}_o_projectsV2_$1_fields" "[{\"id\":76,\"name\":\"Title\",\"data_type\":\"title\"},{\"id\":77,\"name\":\"Status\",\"data_type\":\"single_select\",\"options\":$opts}]"
  PITEMS[$1]=""
  fix "GET_${PSEG}_o_projectsV2_$1_items" "[]"
}
# pitem <project> <issue> <status or ""> [repo]: a project item of an issue (item id = issue number)
pitem() {
  local cur=null
  [ -n "$3" ] && cur="{\"name\":{\"raw\":\"$3\"}}"
  PITEMS[$1]="${PITEMS[$1]:+${PITEMS[$1]},}{\"id\":$2,\"content_type\":\"Issue\",\"content\":{\"number\":$2,\"repository\":{\"full_name\":\"${4:-o/r}\"}},\"fields\":[{\"id\":77,\"value\":$cur}]}"
  fix "GET_${PSEG}_o_projectsV2_$1_items" "[${PITEMS[$1]}]"
}
status_fixture
proj 1 Board true
pitem 1 10 Todo; pitem 1 11 Done; pitem 1 20 "In release"
run_mark
[ "$code" = 0 ] && ok "exit 0" || fail "exit $code: $out"
has "sets #10 via the REST projectsV2 endpoint" "gh api -X PATCH users/o/projectsV2/1/items/10 --input -" "$log"
hasnt "no GraphQL call at all" "graphql" "$log"
has "reads the items of the repository only" "projectsV2/1/items?per_page=100&fields[]=77&q=repo:o/r" "$log"
has "body carries the numeric field id and the option id" 'body={"fields":[{"id":77,"value":"o2"}]}' "$log"
count_is "only #10 mutated" "-X PATCH" 1 "$log"
hasnt "Done item skipped" "items/11" "$log"
hasnt "item already at the status skipped" "items/20" "$log"
has "reports the unchanged item" "#20 is already In release in Board" "$out"

status_fixture
proj 1 Board true
run_mark
[ "$code" = 0 ] && ok "exit 0 without project items" || fail "exit $code"
hasnt "issue without project item not written" "-X PATCH" "$log"
hasnt "no warning besides the deprecation" "::warning::" "$(grep -v deprecated <<<"$out")"

status_fixture
proj 1 Board true; pitem 1 10 Todo "o/x"
run_mark
hasnt "item of another repository ignored" "-X PATCH" "$log"

status_fixture
proj 1 Board true; proj 2 Old true closed
pitem 1 10 Todo
run_mark
hasnt "closed project not read" "projectsV2/2" "$log"
count_is "open project still written" "-X PATCH" 1 "$log"

status_fixture
proj 1 Board false; proj 2 Other false
pitem 1 10 Todo; pitem 1 11 Todo; pitem 2 20 Todo; pitem 1 20 Todo
run_mark
count_is "option warning once per project" "has no Status option" 2 "$out"
hasnt "no write without the option" "-X PATCH" "$log"

status_fixture
proj 1 Board true; pitem 1 10 Todo
echo "Resource not accessible by personal access token" > "$GH_FIX/GET_users_o_projectsV2_1_items.fail"
run_mark
[ "$code" = 0 ] && ok "scope failure exits 0" || fail "exit $code"
count_is "scope warning once" "::warning::The token cannot access the project" 1 "$out"
has "warning names the classic PAT" "classic PAT" "$out"
count_is "no further project call after the scope failure" "projectsV2/1/items" 1 "$log"
hasnt "nothing written after the scope failure" "-X PATCH" "$log"
has "labels still written" "issues/10/labels" "$log"

status_fixture
proj 1 Board true; pitem 1 10 Todo
echo "Your token has not been granted the required scopes: INSUFFICIENT_SCOPES" > "$GH_FIX/GET_users_o_projectsV2.fail"
run_mark
count_is "INSUFFICIENT_SCOPES warns once" "::warning::The token cannot access the project" 1 "$out"
count_is "INSUFFICIENT_SCOPES stops further project calls" "projectsV2" 1 "$log"

status_fixture
proj 1 Board true; pitem 1 10 Todo
echo "Resource not accessible by personal access token" > "$GH_FIX/PATCH_users_o_projectsV2_1_items_10.fail"
run_mark
count_is "mutation scope warning once" "::warning::The token cannot access the project" 1 "$out"
[ "$code" = 0 ] && ok "mutation scope failure exits 0" || fail "exit $code"

status_fixture
proj 1 Board true; pitem 1 10 Todo; pitem 1 20 Todo
echo "Resource not accessible by personal access token" > "$GH_FIX/PATCH_users_o_projectsV2_1_items_10.fail"
run_mark
count_is "no further mutation after a mutation scope failure" "-X PATCH" 1 "$log"

status_fixture
proj 1 Board true; pitem 1 10 Todo; pitem 1 20 Todo
echo "boom" > "$GH_FIX/PATCH_users_o_projectsV2_1_items_10.fail"
run_mark
[ "$code" = 0 ] && ok "mutation failure exits 0" || fail "exit $code"
has "mutation failure warns" "::warning::Cannot set the status of #10 in Board" "$out"
has "continues with the next issue after a mutation failure" "items/20" "$log"

status_fixture
proj 1 Board true; proj 2 Other false
pitem 1 10 Todo; pitem 2 10 Todo
run_mark
count_is "mutates only the project with the option" "-X PATCH" 1 "$log"
count_is "warns for the project without the option" "has no Status option" 1 "$out"
has "names the project without the option" "Project Other has no Status option" "$out"
count_is "projects read once for all issues" "gh api --paginate users/o/projectsV2?per_page=100" 1 "$log"

status_fixture
proj 1 Board true; pitem 1 20 Todo
run_mark
has "labelled parent #20 gets the status" "items/20" "$log"

OWNER_TYPE=Organization status_fixture
OWNER_TYPE=Organization proj 1 Board true
OWNER_TYPE=Organization pitem 1 10 Todo
OWNER_TYPE=Organization run_mark
has "organization project is read under /orgs/" "gh api --paginate orgs/o/projectsV2?per_page=100" "$log"
has "organization project is written under /orgs/" "gh api -X PATCH orgs/o/projectsV2/1/items/10 --input -" "$log"

status_fixture
proj 1 Board true; pitem 1 10 Todo
GH_TOKEN=base-tok PROJECT_TOKEN=pat-tok run_mark
has "the REST reads use PROJECT_TOKEN" "token=pat-tok" "$(grep -F -A1 -- 'gh api --paginate users/o/projectsV2/1/items' <<<"$log")"
has "the REST write uses PROJECT_TOKEN too" "token=pat-tok" "$(grep -F -A1 -- '-X PATCH users/o' <<<"$log")"
status_fixture
proj 1 Board true; pitem 1 10 Todo
GH_TOKEN=base-tok run_mark
has "PROJECT_TOKEN falls back to GH_TOKEN" "token=base-tok" "$(grep -F -A1 -- '-X PATCH users/o' <<<"$log")"

status_fixture
proj 1 Board true; pitem 1 10 Todo
echo "boom" > "$GH_FIX/GET_users_o_projectsV2_1_items.fail"
run_mark
[ "$code" = 0 ] && ok "other read failure exits 0" || fail "exit $code"
count_is "other failure warns once" "::warning::Cannot read the projects of o" 1 "$out"
hasnt "nothing written after a read failure" "-X PATCH" "$log"
has "labels still written after a read failure" "issues/10/labels" "$log"

status_fixture
proj 1 Board true; pitem 1 10 Todo
DRY_RUN=true run_mark
has "dry run prints would set" "would set #10 to In release in Board" "$out"
hasnt "dry run makes no write" "-X PATCH" "$log"

status_fixture
proj 1 Board true; pitem 1 10 Todo
PROJECT_STATUS="" run_mark
hasnt "no project call without PROJECT_STATUS" "projectsV2" "$log"
hasnt "no graphql without PROJECT_STATUS" "graphql" "$log"
unset PROJECT_STATUS

echo "# close: removes the label from closed and already closed referenced issues"
close_fixture() {
  setup
  fix GET_repos_o_r_commits_abc_pulls '[{"number":50,"head":{"ref":"release/1.0"}}]'
  fix pr-view-50 '{"headRefName":"release/1.0","body":"Closes #10"}'
  fix pr-list '[{"body":"Closes #11"}]'
  issue 10 open pbi,merged; issue 11 closed pbi,merged
}
close_fixture
out=$(GITHUB_SHA=abc bash "$CLOSE" 2>&1); code=$?; log=$(cat "$GH_LOG")
[ "$code" = 0 ] && ok "exit 0" || fail "exit $code: $out"
has "closes #10" "gh issue close 10" "$log"
has "unlabels the closed #10" "gh api -X DELETE repos/o/r/issues/10/labels/merged" "$log"
has "unlabels the already closed #11" "gh api -X DELETE repos/o/r/issues/11/labels/merged" "$log"
hasnt "does not close #11 again" "gh issue close 11" "$log"
count_is "unlabels #10 once" "issues/10/labels/merged" 1 "$log"

echo "# close: label removal errors are ignored, custom label is URL-encoded"
close_fixture; touch "$GH_FIX/DELETE_repos_o_r_issues_10_labels_in%20release.fail"
out=$(GITHUB_SHA=abc LABEL="in release" bash "$CLOSE" 2>&1); code=$?; log=$(cat "$GH_LOG")
[ "$code" = 0 ] && ok "exit 0 despite failed removal" || fail "exit $code: $out"
has "encoded label" "issues/11/labels/in%20release" "$log"

echo "# close: dry run removes nothing"
close_fixture
out=$(GITHUB_SHA=abc DRY_RUN=true bash "$CLOSE" 2>&1); log=$(cat "$GH_LOG")
has "prints the removal" "would remove merged from #11" "$out"
hasnt "no delete" "-X DELETE" "$log"

echo "# close-merged: closes the issues with a closing keyword, never Refs, PRs or closed issues"
# release/next is 4 commits ahead of main. PR #41 (merged after the branch left main): Fixes #12 (a PR), Resolves #14
# (milestone, labelled merged), Refs #15. PR #42 (merged before): Closes #19. Commits: Closes #10 footer of the squash
# commit of #40 (and Refs #11), Fixes #13 (already closed), #17 only in the subject, #18 only inline, Resolves #16 in a
# commit without PR. Parents: #20 (feature) of #10 and #14 under the epic #30; #22 (pbi) of #16 with the open #23.
milestone() { local f="$GH_FIX/GET_repos_o_r_issues_$1.json"; jq --arg t "$2" '.milestone = {title: $t}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"; }
sub() { printf '{"number":%s,"state":"%s","repository_url":"https://api.github.com/repos/%s"}' "$1" "$2" "${3:-o/r}"; }
close_merged_fixture() {
  setup
  fix repo-view-o_r '{"defaultBranchRef":{"name":"main"}}'
  fix "GET_repos_o_r_compare_main...release_next" '{"ahead_by":4,
    "merge_base_commit":{"commit":{"committer":{"date":"2026-01-01T00:00:00Z"}}},
    "commits":[{"sha":"aaaaaaa111","commit":{"message":"feat: a (#40)\n\nCloses #10\n\nRefs #11"}},
               {"sha":"bbbbbbb222","commit":{"message":"fix: b\n\nFixes #13"}},
               {"sha":"ccccccc333","commit":{"message":"fix: #17 subject only\n\nmentions closes #18 inline"}},
               {"sha":"ddddddd444","commit":{"message":"chore: c\n\nResolves #16"}}]}'
  fix pr-list '[{"number":41,"body":"Fixes #12\nResolves #14\nRefs #15","mergedAt":"2026-02-01T00:00:00Z"},
                {"number":42,"body":"Closes #19","mergedAt":"2025-12-01T00:00:00Z"}]'
  issue 10 open pbi; issue 11 open pbi; issue 12 open "" pr; issue 13 closed pbi; issue 14 open pbi,merged
  milestone 14 "M3 (1.2.0)"
  issue 15 open pbi; issue 16 open task; issue 17 open pbi; issue 18 open pbi; issue 19 open pbi
  parent 10 20; parent 14 20; issue 20 open feature
  subs 20 "[$(sub 10 open),$(sub 14 open),$(sub 21 closed)]"
  parent 20 30; issue 30 open epic; subs 30 "[$(sub 20 open)]"
  parent 16 22; issue 22 open pbi; subs 22 "[$(sub 16 open),$(sub 23 open)]"
}
run_close_merged() {
  local f; f=$(mktemp)
  out=$(GITHUB_OUTPUT=$f RELEASE_BRANCH="${BRANCH:-release/next}" bash "$CLOSE_MERGED" 2>&1); code=$?
  log=$(cat "$GH_LOG"); output=$(cat "$f")
}
close_merged_fixture; run_close_merged
[ "$code" = 0 ] && ok "exit 0" || fail "exit $code: $out"
has "closing references from PR bodies and commit footers" "Closing references: 10 12 13 14 16" "$out"
has "closes #10 (Closes footer) as completed" "gh issue close 10 -R o/r --reason completed" "$log"
has "closes #14 (Resolves in a PR body)" "gh issue close 14 -R o/r --reason completed" "$log"
has "closes #16 (Resolves footer of a commit without PR)" "gh issue close 16 -R o/r --reason completed" "$log"
has "comment names the PR of the squash commit, no milestone" 'repos/o/r/issues/10/comments --silent -f body=Merged into `release/next` in #40, ships with the next release.' "$log"
has "comment names the PR and the milestone" 'repos/o/r/issues/14/comments --silent -f body=Merged into `release/next` in #41, ships with M3 (1.2.0).' "$log"
has "comment names the commit without PR" 'repos/o/r/issues/16/comments --silent -f body=Merged into `release/next` in ddddddd, ships with the next release.' "$log"
count_is "one comment on #10" "issues/10/comments" 1 "$log"
has "removes the label merged from #14" "gh api -X DELETE repos/o/r/issues/14/labels/merged" "$log"
hasnt "no label removal where absent" "issues/10/labels" "$log"
hasnt "Refs #11 never closes" "issues/11/comments" "$log"
hasnt "Refs #15 in a PR body never closes" "close 15" "$log"
hasnt "PR #12 skipped" "close 12" "$log"
has "PR #12 reported" "#12 is a pull request; skipped." "$out"
hasnt "closed #13 skipped" "close 13" "$log"
hasnt "keyword in the commit subject ignored" "close 17" "$log"
hasnt "inline keyword in a commit body ignored" "close 18" "$log"
hasnt "PR merged before the branch left main ignored" "issues/19" "$log"
has "closes the feature #20 once its sub-issues are closed" "gh issue close 20 -R o/r --reason completed" "$log"
has "parent comment" 'repos/o/r/issues/20/comments --silent -f body=Merged into `release/next` in #41' "$log"
hasnt "epic #30 never closed" "close 30" "$log"
hasnt "pbi #22 with an open sub-issue stays open" "close 22" "$log"
[ "$output" = "closed=10 14 16 20" ] && ok "output closed=10 14 16 20" || fail "output: $output"

echo "# close-merged: idempotent rerun"
close_merged_fixture
issue 10 closed pbi; issue 14 closed pbi; issue 16 closed task; issue 20 closed feature
run_close_merged
[ "$code" = 0 ] && ok "exit 0" || fail "exit $code"
hasnt "closes nothing" "issue close" "$log"
hasnt "comments nothing" "-X POST" "$log"
hasnt "removes nothing" "-X DELETE" "$log"
[ "$output" = "closed=" ] && ok "output closed empty" || fail "output: $output"

echo "# close-merged: issues labelled merged before (first run) are closed and unlabelled"
close_merged_fixture; issue 10 open pbi,merged; run_close_merged
has "closes the labelled #10" "gh issue close 10" "$log"
has "unlabels #10" "-X DELETE repos/o/r/issues/10/labels/merged" "$log"

echo "# close-merged: parents"
close_merged_fixture; subs 20 "[$(sub 10 open),$(sub 14 open),$(sub 24 open)]"; run_close_merged
hasnt "parent with another open sub-issue stays open" "close 20" "$log"
close_merged_fixture; subs 20 "[$(sub 10 open),$(sub 14 open),$(sub 10 open o/x)]"; run_close_merged
hasnt "open sub-issue of another repository blocks the parent" "close 20" "$log"
close_merged_fixture; parent 10 20 other/repo; parent 14 20 other/repo; run_close_merged
hasnt "parent in another repository skipped" "close 20" "$log"
close_merged_fixture; issue 20 open ""; run_close_merged
hasnt "parent without pbi/feature label skipped" "close 20" "$log"
close_merged_fixture; issue 30 open feature; run_close_merged
has "closing repeats upwards to a complete feature" "gh issue close 30" "$log"
close_merged_fixture; touch "$GH_FIX/GET_repos_o_r_issues_20_sub_issues.fail"; run_close_merged
[ "$code" = 0 ] && ok "sub-issue read failure exits 0" || fail "exit $code"
hasnt "sub-issue read failure leaves the parent open" "close 20" "$log"

echo "# close-merged: dry run prints only"
close_merged_fixture; DRY_RUN=true run_close_merged
[ "$code" = 0 ] && ok "exit 0" || fail "exit $code"
has "prints would close #10 with the comment" 'would close #10: Merged into `release/next` in #40, ships with the next release.' "$out"
has "prints would close the parent #20" "would close #20" "$out"
has "prints the label removal" "would remove merged from #14" "$out"
hasnt "no epic" "would close #30" "$out"
hasnt "no close" "issue close" "$log"
hasnt "no comment" "-X POST" "$log"
hasnt "no label removal" "-X DELETE" "$log"
[ "$output" = "closed=" ] && ok "dry run: output closed empty" || fail "output: $output"

echo "# close-merged: custom base, no-op branches"
close_merged_fixture
fix "GET_repos_o_r_compare_dev...release_next" "$(cat "$GH_FIX/GET_repos_o_r_compare_main...release_next.json")"
out=$(RELEASE_BRANCH=release/next BASE=dev bash "$CLOSE_MERGED" 2>&1); log=$(cat "$GH_LOG")
has "compares with the given base" "compare/dev...release/next" "$log"
hasnt "default branch not queried" "repo view" "$log"
close_merged_fixture; BRANCH=main run_close_merged
[ "$code" = 0 ] && ok "not a release branch: exit 0" || fail "exit $code"
has "not a release branch: nothing to do" "not a release/* branch" "$out"
[ -z "$log" ] && ok "not a release branch: no gh call" || fail "gh called: $log"
[ "$output" = "closed=" ] && ok "not a release branch: output closed empty" || fail "output: $output"
close_merged_fixture
fix "GET_repos_o_r_compare_main...release_next" '{"ahead_by":0,"merge_base_commit":{"commit":{"committer":{"date":"2026-01-01T00:00:00Z"}}},"commits":[]}'
run_close_merged
has "not ahead: nothing to do" "no commits ahead" "$out"
hasnt "not ahead: no close" "issue close" "$log"

echo "# close-merged: missing permissions warn and exit 0"
close_merged_fixture; touch "$GH_FIX/repo-view-o_r.fail"; run_close_merged
[ "$code" = 0 ] && ok "repo view failure exits 0" || fail "exit $code"
has "repo view failure warns" "::warning::Cannot read the default branch" "$out"
close_merged_fixture; touch "$GH_FIX/GET_repos_o_r_compare_main...release_next.fail"; run_close_merged
[ "$code" = 0 ] && ok "compare failure exits 0" || fail "exit $code"
has "compare failure warns" "::warning::Cannot compare main...release/next" "$out"
close_merged_fixture; touch "$GH_FIX/pr-list.fail"; run_close_merged
[ "$code" = 0 ] && ok "pr list failure exits 0" || fail "exit $code"
has "pr list failure warns" "::warning::Cannot list the pull requests" "$out"
hasnt "pr list failure closes nothing" "issue close" "$log"
close_merged_fixture; touch "$GH_FIX/issue-close-10.fail"; run_close_merged
[ "$code" = 0 ] && ok "close failure exits 0" || fail "exit $code"
has "close failure warns" "::warning::Cannot close #10" "$out"
hasnt "no comment without a close" "issues/10/comments" "$log"
[ "$output" = "closed=" ] && ok "close failure: output closed empty" || fail "output: $output"
close_merged_fixture; touch "$GH_FIX/POST_repos_o_r_issues_10_comments.fail"; run_close_merged
[ "$code" = 0 ] && ok "comment failure exits 0" || fail "exit $code"
has "comment failure warns" "::warning::Cannot comment on #10." "$out"
has "continues after a comment failure" "gh issue close 14" "$log"
close_merged_fixture; touch "$GH_FIX/GET_repos_o_r_issues_10.fail"; run_close_merged
has "unreadable issue skipped" "#10 cannot be read; skipped." "$out"
hasnt "unreadable issue not closed" "close 10" "$log"

echo "# close-release-issues (safety net): leftovers of the release PR, one still open and one already closed"
setup
fix GET_repos_o_r_commits_abc_pulls '[{"number":50,"head":{"ref":"release/1.0"}}]'
fix pr-view-50 '{"headRefName":"release/1.0","body":"Closes #12\nFixes #13"}'
fix pr-list '[]'
issue 12 open pbi,merged; issue 13 closed pbi,merged
out=$(GITHUB_SHA=abc VERSION=1.0.0 bash "$CLOSE" 2>&1); code=$?; log=$(cat "$GH_LOG")
[ "$code" = 0 ] && ok "leftover: exit 0" || fail "leftover: exit $code: $out"
has "leftover: closes the open #12" "gh issue close 12 -R o/r --reason completed --comment Shipped in v1.0.0 (release PR #50)." "$log"
has "leftover: removes the merged label of #12" "gh api -X DELETE repos/o/r/issues/12/labels/merged" "$log"
hasnt "leftover: does not close the already closed #13" "gh issue close 13" "$log"
has "leftover: removes the merged label of the closed #13" "gh api -X DELETE repos/o/r/issues/13/labels/merged" "$log"

echo "# close-release-issues (safety net): rerun after the leftovers are closed changes nothing"
setup
fix GET_repos_o_r_commits_abc_pulls '[{"number":50,"head":{"ref":"release/1.0"}}]'
fix pr-view-50 '{"headRefName":"release/1.0","body":"Closes #12"}'
fix pr-list '[]'
issue 12 closed pbi
out=$(GITHUB_SHA=abc VERSION=1.0.0 bash "$CLOSE" 2>&1); code=$?; log=$(cat "$GH_LOG")
[ "$code" = 0 ] && ok "rerun: exit 0" || fail "rerun: exit $code: $out"
hasnt "rerun: closes nothing" "gh issue close" "$log"

echo "# mark-merged-issues: deprecation warning"
mark_fixture; run_mark
has "deprecation warning when used" "::warning::versioning/mark-merged-issues is deprecated" "$out"
has "deprecation warning names the replacement" "close-merged-issues" "$out"
setup
out=$(RELEASE_BRANCH=feature/x bash "$MARK" 2>&1)
has "deprecation warning also on a no-op run" "::warning::versioning/mark-merged-issues is deprecated" "$out"

echo "# release-pr: recreated branch without commits ahead opens no PR"
RELEASE_PR="$ROOT/versioning/release-pr/release-pr.sh"
setup; fix repo-view-o_r '{"defaultBranchRef":{"name":"main"}}'
fix "GET_repos_o_r_compare_main...release_1.5" '{"ahead_by":0,"merge_base_commit":{"commit":{"committer":{"date":"2026-01-01T00:00:00Z"}}},"commits":[]}'
out=$(RELEASE_BRANCH=release/1.5 bash "$RELEASE_PR" 2>&1); code=$?; log=$(cat "$GH_LOG")
[ "$code" = 0 ] && ok "exit 0" || fail "exit $code"
has "says nothing to do" "no commits ahead" "$out"
hasnt "no PR created" "pr create" "$log"
setup; fix repo-view-o_r '{"defaultBranchRef":{"name":"main"}}'
fix "GET_repos_o_r_compare_main...release_next" '{"ahead_by":0,"merge_base_commit":{"commit":{"committer":{"date":"2026-01-01T00:00:00Z"}}},"commits":[]}'
out=$(RELEASE_BRANCH=release/next DRY_RUN=true bash "$RELEASE_PR" 2>&1); code=$?; log=$(cat "$GH_LOG")
[ "$code" = 0 ] && ok "release/next without commits: exit 0" || fail "exit $code"
has "release/next without commits: nothing to do" "no commits ahead" "$out"
hasnt "release/next without commits: no PR" "pr create" "$log"
setup
out=$(RELEASE_BRANCH=feature/x bash "$RELEASE_PR" 2>&1); code=$?; log=$(cat "$GH_LOG")
[ "$code" = 0 ] && ok "other branch: exit 0" || fail "exit $code"
has "other branch: nothing to do" "nothing to do" "$out"
[ -z "$log" ] && ok "other branch: no gh call" || fail "gh called: $log"

echo "# release-pr: dry run for release/next and release/<x.y>"
for b in next 1.5; do
  setup; fix repo-view-o_r '{"defaultBranchRef":{"name":"main"}}'
  fix "GET_repos_o_r_compare_main...release_$b" '{"ahead_by":2,"merge_base_commit":{"commit":{"committer":{"date":"2026-01-01T00:00:00Z"}}}}'
  fix pr-list '[{"number":7,"title":"fix: a","author":{"login":"al"},"body":"Closes #42","mergedAt":"2026-02-01T00:00:00Z"}]'
  out=$(RELEASE_BRANCH=release/$b DRY_RUN=true bash "$RELEASE_PR" 2>&1); code=$?
  [ "$code" = 0 ] && ok "release/$b: exit 0" || fail "release/$b exit $code"
  has "release/$b: title" "title: release: $b" "$out"
  has "release/$b: lists the PR" "- #7 fix: a (@al)" "$out"
  has "release/$b: Closes line" "Closes #42" "$out"
done

echo
echo "$((total - failures))/$total passed"
[ "$failures" = 0 ]
