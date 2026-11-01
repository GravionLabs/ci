#!/usr/bin/env bash
# Scenario table of #106 for the Conventional Commit bump rules of versioning/determine-version.
# The rules are read from the action itself and passed as /overrideconfig, like gittools does.
# Run: bash tests/conventional-commits.test.sh (needs gitversion or dotnet-gitversion on PATH)
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
failures=0 total=0
ok()   { total=$((total + 1)); echo "ok   - $1"; }
fail() { total=$((total + 1)); failures=$((failures + 1)); echo "FAIL - $1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

GV=$(command -v dotnet-gitversion || command -v gitversion || true)
if [ -z "$GV" ]; then
  if [ "${CI:-}" = "true" ]; then echo "FAIL - no gitversion binary on PATH"; exit 1; fi
  echo "SKIP - no gitversion binary on PATH"; exit 0
fi

# The three rule lines come from the action's own run step, so the test cannot drift from it.
RULES=$(grep -E "^ +echo '(major|minor|patch)-version-bump-message=" "$ROOT/versioning/determine-version/action.yml" \
  | sed -E "s/^ +echo '//; s/'\$//")
MAJOR=$(printf '%s\n' "$RULES" | grep '^major-')
MINOR=$(printf '%s\n' "$RULES" | grep '^minor-')
PATCH=$(printf '%s\n' "$RULES" | grep '^patch-')
eq "action carries three bump rules" "3" "$(printf '%s\n' "$RULES" | grep -c .)"

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT

# Minimal caller config: only mode and next-version (no increment rules).
mkrepo() {
  rm -rf "$DIR/r" && mkdir "$DIR/r" && cd "$DIR/r" || exit 1
  git init -q -b main . && git config user.name test && git config user.email test@example.com
  git config commit.gpgsign false
  printf 'mode: ContinuousDeployment\nnext-version: 1.0.0\n' > GitVersion.yml
  git add GitVersion.yml && git commit -q -m "chore: init"
  git tag v1.0.0
}

# $1 = on|off (conventional rules); prints MajorMinorPatch
var() {
  local args=()
  if [ "$1" = on ]; then args=(/overrideconfig "$MAJOR" /overrideconfig "$MINOR" /overrideconfig "$PATCH"); fi
  env -u GITHUB_ACTIONS -u GITHUB_REF -u GITHUB_REF_NAME -u GITHUB_HEAD_REF -u GITHUB_BASE_REF \
    -u GITHUB_SHA -u TF_BUILD -u GITLAB_CI -u TEAMCITY_VERSION -u JENKINS_URL -u APPVEYOR \
    "$GV" . /output json /showvariable MajorMinorPatch "${args[@]}" 2>/dev/null | tail -n 1
}

mkrepo; git commit -q --allow-empty -m "fix: a bug"
eq "fix direct to main is a patch" "1.0.1" "$(var on)"

mkrepo; git commit -q --allow-empty -m "feat: a thing"
eq "feat direct to main is a minor" "1.1.0" "$(var on)"

mkrepo; git commit -q --allow-empty -m "docs: words"
eq "docs only is a patch" "1.0.1" "$(var on)"

mkrepo; git commit -q --allow-empty -m "feat(api)!: drop v1"
eq "feat! is a major" "2.0.0" "$(var on)"

mkrepo; git commit -q --allow-empty -m "fix: x" -m "BREAKING CHANGE: the format changed"
eq "BREAKING CHANGE footer is a major" "2.0.0" "$(var on)"

mkrepo; git commit -q --allow-empty -m "fix: x" -m "BREAKING-CHANGE: the format changed"
eq "BREAKING-CHANGE footer is a major" "2.0.0" "$(var on)"

mkrepo; git commit -q --allow-empty -m "feat(action.yml): a thing"
eq "feat with a dotted scope is a minor" "1.1.0" "$(var on)"

mkrepo; git commit -q --allow-empty -m "feat: squashed thing (#7)" -m "* feat!: intermediate
* fix: another"
eq "! only in a squash body line is no major" "1.1.0" "$(var on)"

# GitVersion matches without RegexOptions.Multiline: ^ is the start of the message, not of a body line.
mkrepo; git commit -q --allow-empty -m "fix: squashed thing (#7)" -m "feat!: intermediate
feat: another"
eq "unprefixed body lines bump nothing" "1.0.1" "$(var on)"

mkrepo; git commit -q --allow-empty -m "chore: tidy" -m "+semver: major"
eq "+semver: major stays an escape hatch" "2.0.0" "$(var on)"

mkrepo; git commit -q --allow-empty -m "feat: a thing"
eq "rules off keeps the GitVersion default (patch)" "1.0.1" "$(var off)"

# release/next merged into main with a merge commit: the squash commits on the branch count.
mkrepo; git checkout -q -b release/next
git commit -q --allow-empty -m "fix: a bug (#1)"
git commit -q --allow-empty -m "feat: a thing (#2)"
git commit -q --allow-empty -m "docs: words (#3)"
git checkout -q main && git merge -q --no-ff release/next -m "Merge pull request #4 from GravionLabs/release/next"
eq "release/next with feat merged into main is a minor" "1.1.0" "$(var on)"

mkrepo; git checkout -q -b release/next
git commit -q --allow-empty -m "fix: a bug (#1)"
git commit -q --allow-empty -m "docs: words (#3)"
git checkout -q main && git merge -q --no-ff release/next -m "Merge pull request #4 from GravionLabs/release/next"
eq "release/next with fix and docs only is a patch" "1.0.1" "$(var on)"

echo "$((total - failures))/$total passed"
[ "$failures" -eq 0 ]
