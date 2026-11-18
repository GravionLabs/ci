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

# token input (#249): PUSH_TOKEN replaces the checkout credentials for the push; without it git is called as before.
REAL_GIT=$(command -v git)
mkdir -p "$DIR/bin"
printf '%s\n' '#!/usr/bin/env bash' 'case " $* " in *" push "*) printf "%s\n" "$*" >> "$GIT_LOG" ;; esac' "exec $REAL_GIT \"\$@\"" > "$DIR/bin/git"
chmod +x "$DIR/bin/git"
release 1.6.0
export GIT_LOG="$DIR/gitlog"; : > "$GIT_LOG"
OUT="$DIR/out"; : > "$OUT"
PATH="$DIR/bin:$PATH" PUSH_TOKEN="s3cret-token" VERSION=1.6.0 GITHUB_OUTPUT="$OUT" bash "$SCRIPT" >"$DIR/log" 2>&1; eq "push with a token exits 0" 0 $?
eq "token: v1 moved to v1.6.0" "$(git rev-parse v1.6.0)" "$(remote v1)"
EXPECTED=$(printf 'x-access-token:s3cret-token' | base64 | tr -d '\n')
grep -q "http.https://github.com/.extraheader=AUTHORIZATION: basic $EXPECTED" "$GIT_LOG" && ok "token: pushed with the Authorization header of the token" || fail "token: pushed with the Authorization header of the token"
grep -q "http.https://github.com/.extraheader= " "$GIT_LOG" && ok "token: checkout header reset before" || fail "token: checkout header reset before"
grep -v "^::add-mask::" "$DIR/log" | grep -q "s3cret-token" && fail "token: not printed" || ok "token: not printed"
grep -q "::add-mask::s3cret-token" "$DIR/log" && ok "token: masked" || fail "token: masked"

release 1.7.0
: > "$GIT_LOG"
PATH="$DIR/bin:$PATH" VERSION=1.7.0 GITHUB_OUTPUT="$OUT" bash "$SCRIPT" >"$DIR/log" 2>&1; eq "push without a token exits 0" 0 $?
grep -q "extraheader" "$GIT_LOG" && fail "no token: checkout credentials are used as they are" || ok "no token: checkout credentials are used as they are"

echo "$((total - failures))/$total passed"
[ "$failures" -eq 0 ]
