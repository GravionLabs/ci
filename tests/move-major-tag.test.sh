#!/usr/bin/env bash
# Tests versioning/move-major-tag/move.sh against a local bare origin.
# Run: bash tests/move-major-tag.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/versioning/move-major-tag/move.sh"
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

remote() { git ls-remote --tags origin "refs/tags/$1" | cut -f1; }
move()   { OUT="$DIR/out"; : > "$OUT"; VERSION="$1" TAG_PREFIX="${2-v}" GITHUB_OUTPUT="$OUT" bash "$SCRIPT" >"$DIR/log" 2>&1; }
release() { git commit -q --allow-empty -m "release $1"; git tag "v$1"; git push -q origin "v$1" main 2>/dev/null; }

release 1.4.0
C140=$(git rev-parse HEAD)
move 1.4.0; eq "first release exits 0" 0 $?
eq "v1 created on v1.4.0" "$C140" "$(remote v1)"
eq "output major-tag" "major-tag=v1" "$(cat "$DIR/out")"

release 1.5.0
C150=$(git rev-parse HEAD)
git commit -q --allow-empty -m "docs: changelog after the tag"   # HEAD is not the release commit
move 1.5.0; eq "next release exits 0" 0 $?
eq "v1 moved to the commit of v1.5.0, not HEAD" "$C150" "$(remote v1)"

move 1.5.0; eq "rerun exits 0" 0 $?
grep -q "already points" "$DIR/log" && ok "rerun is a no-op" || fail "rerun is a no-op"

release 2.0.0
move 2.0.0
eq "v2 created on v2.0.0" "$(git rev-parse v2.0.0)" "$(remote v2)"
eq "v1 untouched by a major" "$C150" "$(remote v1)"

move 2.1.0-beta.1; eq "pre-release exits 0" 0 $?
eq "pre-release leaves v2" "$(git rev-parse v2.0.0)" "$(remote v2)"
eq "pre-release output empty" "major-tag=" "$(cat "$DIR/out")"

move 2.9.0; eq "missing release tag fails" 1 $?
move "not-a-version"; eq "invalid version fails" 1 $?

git tag x3.0.0 HEAD && git push -q origin x3.0.0
move 3.0.0 x
eq "custom prefix" "$(git rev-parse x3.0.0)" "$(remote x3)"

echo "$((total - failures))/$total passed"
[ "$failures" -eq 0 ]
