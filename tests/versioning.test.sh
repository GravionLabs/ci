#!/usr/bin/env bash
# Tests for versioning/mark-merged-issues/mark.sh against a fake gh (tests/stub/gh). Run: bash tests/versioning.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MARK="$ROOT/versioning/mark-merged-issues/mark.sh"
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
  local labels
  labels=$(jq -cn --arg l "$3" '$l | split(",") | map(select(. != "") | {name: .})')
  fix "GET_repos_o_r_issues_$1" "{\"number\":$1,\"state\":\"$2\",\"labels\":$labels,\"repository_url\":\"https://api.github.com/repos/o/r\"${4:+,\"pull_request\":{}}}"
}
parent() { fix "GET_repos_o_r_issues_$1_parent" "{\"number\":$2,\"repository_url\":\"https://api.github.com/repos/${3:-o/r}\"}"; }
subs() { fix "GET_repos_o_r_issues_$1_sub_issues" "$2"; }
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

echo
echo "$((total - failures))/$total passed"
[ "$failures" = 0 ]
