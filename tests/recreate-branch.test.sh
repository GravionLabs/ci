#!/usr/bin/env bash
# Tests versioning/gh-release/recreate-branch.sh against a local bare origin.
# Run: bash tests/recreate-branch.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/versioning/gh-release/recreate-branch.sh"
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

remote() { git ls-remote --heads origin "refs/heads/$1" | cut -f1; }
run()    { BRANCH="$1" bash "$SCRIPT" >"$DIR/log" 2>&1; }

git commit -q --allow-empty -m "release 1.0.0"
C1=$(git rev-parse HEAD)
git push -q origin main

run ""; eq "empty input exits 0" 0 $?
eq "empty input creates nothing" "" "$(remote release/next)"

run release/next; eq "absent branch: exits 0" 0 $?
eq "absent branch: created at the release commit" "$C1" "$(remote release/next)"

git commit -q --allow-empty -m "release 1.1.0"
C2=$(git rev-parse HEAD)
git push -q origin main
run release/next; eq "present branch: exits 0" 0 $?
eq "present branch: not moved" "$C1" "$(remote release/next)"
grep -q "left unchanged" "$DIR/log" && ok "present branch: says so" || fail "present branch: says so"

git push -q origin "$C2:refs/heads/release/other"
run release/other; eq "present branch ahead of HEAD~: exits 0" 0 $?
eq "present branch ahead of HEAD~: unchanged" "$C2" "$(remote release/other)"

git remote set-url origin "$DIR/missing.git"
run release/gone; eq "unreachable origin fails" 1 $?

echo "$((total - failures))/$total passed"
[ "$failures" -eq 0 ]
