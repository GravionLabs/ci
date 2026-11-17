#!/usr/bin/env bash
# Tests for versioning/close-milestones/close.sh against a fake gh (tests/stub/gh). Run: bash tests/close-milestones.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/versioning/close-milestones/close.sh"
export PATH="$ROOT/tests/stub:$PATH" GITHUB_REPOSITORY=o/r
failures=0 total=0

ok()    { total=$((total + 1)); echo "ok   - $1"; }
fail()  { total=$((total + 1)); failures=$((failures + 1)); echo "FAIL - $1"; }
has()   { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else fail "$1 (missing: $2)"; fi; }
hasnt() { if grep -qF -- "$2" <<<"$3"; then fail "$1 (unexpected: $2)"; else ok "$1"; fi; }

fix() { printf '%s\n' "$2" > "$GH_FIX/$1.json"; }
# pr <n> <milestone|0> <body>; issue <n> <milestone|0>
item() { # n milestone body is_pr
  fix "GET_repos_o_r_issues_$1" "$(jq -cn --argjson m "$2" --arg b "$3" --argjson p "$4" \
    '{number: 1, body: $b, milestone: (if $m == 0 then null else {number: $m} end)} + (if $p then {pull_request: {}} else {} end)')"
}
setup() {
  GH_FIX=$(mktemp -d) GH_LOG=$(mktemp); export GH_FIX GH_LOG
  fix GET_repos_o_r_git_ref_tags_v1.2.0 '{}'
  fix GET_repos_o_r_git_matching-refs_tags_v '[{"ref":"refs/tags/v1.0.0"},{"ref":"refs/tags/v1.1.0"},{"ref":"refs/tags/v1.2.0"},{"ref":"refs/tags/v1.10.0"},{"ref":"refs/tags/v1.2.0-rc.1"}]'
  # v1.10.0 is above 1.2.0 and must not count as previous; the previous stable tag is v1.1.0
  fix "GET_repos_o_r_compare_v1.1.0...v1.2.0" '{"commits":[
    {"commit":{"message":"feat: a (#10)\n\nbody #99"}},
    {"commit":{"message":"Merge pull request #11 from o/release/next"}},
    {"commit":{"message":"fix: c (#12)"}}]}'
  item 10 0 "Closes #20" true     # PR without milestone, closes issue 20 (milestone 1)
  item 11 3 "nothing" true        # PR itself in milestone 3 (legacy 1.2.0 title)
  item 12 0 "Fixes #21 and Refs #22" true
  item 20 1 "" false
  item 21 2 "" false              # milestone 2 has open issues
  item 22 6 "" false              # Refs never counts
  fix "GET_repos_o_r_milestones" '[
    {"number":1,"title":"M016 Topic","open_issues":0},
    {"number":2,"title":"M017","open_issues":2},
    {"number":3,"title":"1.2.0","open_issues":0},
    {"number":4,"title":"M018 Other","open_issues":0},
    {"number":6,"title":"M020","open_issues":0}]'
  fix GET_repos_o_r_issues '[{"number":31},{"number":32}]'
}
run() { out=$(bash "$SCRIPT" 2>&1); code=$?; log=$(cat "$GH_LOG"); }

echo "# shipped milestones are closed and renamed"
setup; VERSION=1.2.0 run
[ "$code" = 0 ] && ok "exit 0" || fail "exit $code: $out"
has "previous stable tag is v1.1.0" "since v1.1.0" "$out"
has "renames and closes M016" "gh api -X PATCH repos/o/r/milestones/1" "$log"
has "title with version" "title=M016 Topic (1.2.0)" "$log"
has "legacy title closed" "gh api -X PATCH repos/o/r/milestones/3" "$log"
has "legacy title unchanged" "title=1.2.0" "$log"
hasnt "a milestone no release PR touches stays" "milestones/4" "$log"
hasnt "a Refs issue does not ship its milestone" "milestones/6" "$log"
echo "# open issues keep the milestone open"
hasnt "milestone with open issues is not patched" "milestones/2" "$log"
has "notice names milestone and issues" "Milestone 'M017' shipped with v1.2.0 but stays open: open issues #31 #32" "$out"

echo "# dry run changes nothing"
setup; VERSION=1.2.0 DRY_RUN=true run
has "dry run prints the plan" "would close milestone 'M016 Topic' as 'M016 Topic (1.2.0)'" "$out"
hasnt "dry run writes nothing" "-X PATCH" "$log"

echo "# second run: the milestones are closed, nothing to do"
setup; fix GET_repos_o_r_milestones '[]'; VERSION=1.2.0 run
hasnt "no patch" "-X PATCH" "$log"

echo "# pre-release closes nothing"
setup; VERSION=1.2.0-rc.1 run
has "message" "no milestone is closed" "$out"
[ -z "$log" ] && ok "no gh call" || fail "gh called: $log"

echo "# missing tag only warns"
setup; rm "$GH_FIX/GET_repos_o_r_git_ref_tags_v1.2.0.json"; VERSION=1.2.0 run
[ "$code" = 0 ] && ok "exit 0" || fail "exit $code"
has "warning" "::warning::Tag v1.2.0 not found" "$out"

echo
echo "$((total - failures))/$total passed"
[ "$failures" = 0 ]
