#!/usr/bin/env bash
# Fixture test for GitVersion.yml: release/next increments the minor, main stays patch.
# Run: bash tests/determine-version.test.sh (needs gitversion or dotnet-gitversion on PATH)
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

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
cd "$DIR" || exit 1
git init -q -b main . && git config user.name test && git config user.email test@example.com
git config commit.gpgsign false
cp "$ROOT/GitVersion.yml" .
git add GitVersion.yml && git commit -q -m "chore: init"
git tag v1.0.60
git commit -q --allow-empty -m "fix: after tag"

var() { "$GV" . /output json /showvariable "$1" 2>/dev/null; }

eq "main after tag is a patch" "1.0.61" "$(var MajorMinorPatch)"

git checkout -q -b release/next
git commit -q --allow-empty -m "feat: new thing"
eq "release/next increments minor" "1.1.0" "$(var MajorMinorPatch)"
pre=$(var PreReleaseTag)
if [ -n "$pre" ]; then ok "release/next is a pre-release ($pre)"; else fail "release/next has empty pre-release tag"; fi

# On main the minor does not follow from the branch rule alone: a plain merge stays a patch,
# so the release commit carries the "+semver: minor" bump (see concerns in the task report).
git checkout -q main
git merge -q --no-ff release/next -m "Merge pull request #0 from GravionLabs/release/next"
eq "main after a plain release/next merge is only a patch" "1.0.61" "$(var MajorMinorPatch)"
git reset -q --hard HEAD~1
git checkout -q release/next
git commit -q --allow-empty -m "release: next" -m "+semver: minor"
git checkout -q main
git merge -q --no-ff release/next -m "Merge pull request #1 from GravionLabs/release/next"
eq "main after merging release/next with +semver: minor is 1.1.0" "1.1.0" "$(var MajorMinorPatch)"

git tag v1.1.0
git commit -q --allow-empty -m "fix: hotfix"
eq "hotfix on main stays a patch" "1.1.1" "$(var MajorMinorPatch)"

echo "$((total - failures))/$total passed"
[ "$failures" -eq 0 ]
