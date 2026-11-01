#!/usr/bin/env bash
# Tests versioning/gh-release/rate-limit.sh and release.sh against a stubbed gh.
# Run: bash tests/gh-release-rate-limit.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
failures=0 total=0
ok()   { total=$((total + 1)); echo "ok   - $1"; }
fail() { total=$((total + 1)); failures=$((failures + 1)); echo "FAIL - $1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

mkdir "$DIR/bin"
# Stub: `gh api rate_limit` prints $STUB_RESET as reset (core remaining $STUB_REMAINING); `gh release view`
# fails (no release) unless $STUB_RELEASE_EXISTS=1; `gh release create` fails with a rate-limit error
# $STUB_FAILS times (counter file), then succeeds. Every call is logged.
cat > "$DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$STUB_LOG"
case "$1 $2" in
  "api rate_limit")
    now=$(date +%s)
    jq -n --argjson r "$((now + STUB_RESET_IN))" --argjson n "$STUB_REMAINING" \
      '{resources:{core:{remaining:$n,reset:$r},graphql:{remaining:5000,reset:$r}}}' |
      jq -r "${4:-.}" ;;
  "release view") [ "${STUB_RELEASE_EXISTS:-0}" = 1 ] && exit 0; echo "release not found" >&2; exit 1 ;;
  "release create")
    n=$(cat "$STUB_COUNT" 2>/dev/null || echo 0)
    if [ "$n" -lt "$STUB_FAILS" ]; then echo $((n + 1)) > "$STUB_COUNT"; echo "GraphQL: API rate limit already exceeded" >&2; exit 1; fi
    echo "created" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$DIR/bin/gh"
cat > "$DIR/sleep" <<'EOF'
#!/usr/bin/env bash
echo "sleep $*" >> "$STUB_LOG"
EOF
chmod +x "$DIR/sleep"

export PATH="$DIR/bin:$PATH" STUB_LOG="$DIR/log" STUB_COUNT="$DIR/count"
export RATE_LIMIT_SLEEP="$DIR/sleep" TAG=v1.2.3 VERSION=1.2.3 GENERATE_NOTES=true
reset() { rm -f "$STUB_LOG" "$STUB_COUNT"; touch "$STUB_LOG"; export STUB_RESET_IN=60 STUB_REMAINING=5000 STUB_FAILS=0 STUB_RELEASE_EXISTS=0; }
creates() { grep -c '^gh release create' "$STUB_LOG"; }

reset
bash "$ROOT/versioning/gh-release/rate-limit.sh" check; eq "check: healthy budget passes" 0 $?
eq "check: healthy budget does not sleep" 0 "$(grep -c '^sleep' "$STUB_LOG")"

reset; STUB_REMAINING=0
bash "$ROOT/versioning/gh-release/rate-limit.sh" check; eq "check: empty budget within the bound waits and passes" 0 $?
grep -q '^sleep' "$STUB_LOG" && ok "check: slept until the reset" || fail "check: slept until the reset"

reset; STUB_REMAINING=0 STUB_RESET_IN=3600
bash "$ROOT/versioning/gh-release/rate-limit.sh" check 2>"$DIR/err"; eq "check: reset beyond 15 minutes fails" 1 $?
grep -q 'resets in' "$DIR/err" && ok "check: clear message" || fail "check: clear message"
eq "check: no sleep beyond the bound" 0 "$(grep -c '^sleep' "$STUB_LOG")"

reset; STUB_FAILS=1 STUB_REMAINING=0
bash "$ROOT/versioning/gh-release/release.sh" >/dev/null 2>&1; eq "release: rate-limit error once, then success" 0 $?
eq "release: create attempted twice" 2 "$(creates)"
grep -q '^sleep' "$STUB_LOG" && ok "release: waited for the reset" || fail "release: waited for the reset"

reset; STUB_FAILS=9 STUB_REMAINING=0
bash "$ROOT/versioning/gh-release/release.sh" >/dev/null 2>"$DIR/err"; eq "release: persistent rate limit fails" 1 $?
eq "release: bounded attempts" 3 "$(creates)"
grep -q 'giving up' "$DIR/err" && ok "release: clear message" || fail "release: clear message"

reset; STUB_FAILS=1 STUB_REMAINING=0 STUB_RESET_IN=3600
bash "$ROOT/versioning/gh-release/release.sh" >/dev/null 2>&1; eq "release: reset beyond the bound fails" 1 $?
eq "release: no retry beyond the bound" 1 "$(creates)"

reset; STUB_RELEASE_EXISTS=1
bash "$ROOT/versioning/gh-release/release.sh" >/dev/null 2>&1; eq "release: existing release is skipped" 0 $?
eq "release: nothing created" 0 "$(creates)"

reset
bash "$ROOT/versioning/gh-release/release.sh" >/dev/null 2>&1; eq "release: existing tag without release gets its release" 0 $?
eq "release: created once" 1 "$(creates)"

reset; VERSION=1.2.3-rc.1 GENERATE_NOTES=true bash "$ROOT/versioning/gh-release/release.sh" >/dev/null 2>&1
grep -q -- '--prerelease' "$STUB_LOG" && ok "release: pre-release flag" || fail "release: pre-release flag"

echo "$((total - failures))/$total passed"
[ "$failures" -eq 0 ]
