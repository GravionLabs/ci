#!/usr/bin/env bash
# Tests versioning/gh-release/version-command.sh and commit-release.sh against a local bare origin.
# Run: bash tests/version-command.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
D="$ROOT/versioning/gh-release"
failures=0 total=0
ok()   { total=$((total + 1)); echo "ok   - $1"; }
fail() { total=$((total + 1)); failures=$((failures + 1)); echo "FAIL - $1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
git init -q --bare "$DIR/origin.git"
git init -q -b main "$DIR/work" && cd "$DIR/work" || exit 1
git config user.name test && git config user.email test@example.com && git config commit.gpgsign false
git remote add origin "$DIR/origin.git"
echo 0.0.0 > version.txt; echo old > CHANGELOG.md
git add -A && git commit -qm init && git push -q -u origin main

COMMAND="" VERSION=1.0.0 bash "$D/version-command.sh" >/dev/null; eq "empty command exits 0" 0 $?
eq "empty command changes nothing" "" "$(git status --porcelain)"

COMMAND='echo "$VERSION" > version.txt' VERSION=1.0.0-rc.1 bash "$D/version-command.sh" >/dev/null
eq "command sees prerelease VERSION" "1.0.0-rc.1" "$(cat version.txt)"

COMMAND='echo "$VERSION" > v2.txt' VERSION='1.0.0; touch pwned' bash "$D/version-command.sh" >/dev/null
eq "VERSION is data, not code" "no" "$([ -e pwned ] && echo yes || echo no)"
rm -f v2.txt

COMMAND='exit 3' VERSION=1.0.0 bash "$D/version-command.sh" >/dev/null 2>&1; eq "failing command fails" 3 $?

echo new > CHANGELOG.md; echo x > extra.txt
TAG=v1.0.0-rc.1 CHANGELOG=CHANGELOG.md VERSION_COMMAND='x' bash "$D/commit-release.sh" >/dev/null 2>&1
eq "one commit added" 2 "$(git rev-list --count HEAD)"
eq "commit holds changelog and command files" "CHANGELOG.md
extra.txt
version.txt" "$(git show --name-only --format= HEAD | sort)"
eq "commit message" "docs: update CHANGELOG.md for v1.0.0-rc.1 [skip ci]" "$(git log -1 --format=%s)"
eq "pushed" "$(git rev-parse HEAD)" "$(git ls-remote origin refs/heads/main | cut -f1)"

echo again > CHANGELOG.md; echo y > other.txt
TAG=v1.0.1 CHANGELOG=CHANGELOG.md VERSION_COMMAND='' bash "$D/commit-release.sh" >/dev/null 2>&1
eq "empty command stages only changelog" "CHANGELOG.md" "$(git show --name-only --format= HEAD)"

TAG=v1.0.2 CHANGELOG=CHANGELOG.md VERSION_COMMAND='' bash "$D/commit-release.sh" >/dev/null 2>&1; eq "nothing staged exits 0" 0 $?
eq "nothing staged: no new commit" 3 "$(git rev-list --count HEAD)"

echo "$((total - failures))/$total passed"
[ "$failures" -eq 0 ]
