#!/usr/bin/env bash
# Release channel of determine-version: branch -> stable / rc / beta (versioning/determine-version/channel.sh).
# Run: bash tests/release-channel.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
failures=0 total=0
ok()   { total=$((total + 1)); echo "ok   - $1"; }
fail() { total=$((total + 1)); failures=$((failures + 1)); echo "FAIL - $1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

# Release channel: branch -> stable / rc / beta (channel.sh)
chan() { # branch ref_type input -> prints channel|is-prerelease|semver|python|docker
  out=$(CHANNEL_INPUT="$3" BRANCH="$1" REF_TYPE="$2" MMP=1.2.0 SEMVER="${SEMVER_IN:-1.2.0}" PRE_TAG="" PRE_LABEL="" PRE_NUMBER="" \
    COMMITS="${COMMITS_IN:-3}" SHORT_SHA=abc1234 GITHUB_OUTPUT=/dev/stdout bash "$ROOT/versioning/determine-version/channel.sh")
  g() { echo "$out" | sed -n "s/^$1=//p"; }
  echo "$(g channel)|$(g is-prerelease)|$(g semver)|$(g python-version)|$(g docker-version)"
}
eq "channel: main is stable" "stable|false|1.2.0|1.2.0|1.2.0-abc1234" "$(chan main branch auto)"
eq "channel: tag is stable" "stable|false|1.2.0|1.2.0|1.2.0-abc1234" "$(chan v1.2.0 tag auto)"
eq "channel: release/next is rc" "rc|true|1.2.0-rc.3|1.2.0rc3|1.2.0-rc.3-abc1234" "$(chan release/next branch auto)"
eq "channel: release/1.2 is rc" "rc|true|1.2.0-rc.3|1.2.0rc3|1.2.0-rc.3-abc1234" "$(chan release/1.2 branch auto)"
eq "channel: feature branch is beta" "beta|true|1.2.0-beta.3|1.2.0b3|1.2.0-beta.3-abc1234" "$(chan feat/1-x branch auto)"
eq "channel: empty input means auto" "beta|true|1.2.0-beta.3|1.2.0b3|1.2.0-beta.3-abc1234" "$(chan feat/1-x branch '')"
eq "channel: override beats the branch" "rc|true|1.2.0-rc.3|1.2.0rc3|1.2.0-rc.3-abc1234" "$(chan main branch rc)"
eq "channel: stable override on a feature branch" "stable|false|1.2.0|1.2.0|1.2.0-abc1234" "$(chan feat/1-x branch stable)"
eq "channel: zero commits still gives n=1" "beta|true|1.2.0-beta.1|1.2.0b1|1.2.0-beta.1-abc1234" "$(COMMITS_IN=0 chan x branch auto)"
if CHANNEL_INPUT=nightly BRANCH=x MMP=1.0.0 GITHUB_OUTPUT=/dev/null bash "$ROOT/versioning/determine-version/channel.sh" 2>/dev/null; then fail "channel: invalid override is rejected"; else ok "channel: invalid override is rejected"; fi

echo "$((total - failures))/$total passed"
[ "$failures" -eq 0 ]
