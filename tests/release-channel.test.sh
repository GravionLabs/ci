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
eq "channel: release/next is rc" "rc|true|1.2.0-rc003|1.2.0rc3|1.2.0-rc003-abc1234" "$(chan release/next branch auto)"
eq "channel: release/1.2 is rc" "rc|true|1.2.0-rc003|1.2.0rc3|1.2.0-rc003-abc1234" "$(chan release/1.2 branch auto)"
eq "channel: feature branch is beta" "beta|true|1.2.0-beta003|1.2.0b3|1.2.0-beta003-abc1234" "$(chan feat/1-x branch auto)"
eq "channel: empty input means auto" "beta|true|1.2.0-beta003|1.2.0b3|1.2.0-beta003-abc1234" "$(chan feat/1-x branch '')"
eq "channel: override beats the branch" "rc|true|1.2.0-rc003|1.2.0rc3|1.2.0-rc003-abc1234" "$(chan main branch rc)"
eq "channel: stable override on a feature branch" "stable|false|1.2.0|1.2.0|1.2.0-abc1234" "$(chan feat/1-x branch stable)"
eq "channel: zero commits still gives n=1" "beta|true|1.2.0-beta001|1.2.0b1|1.2.0-beta001-abc1234" "$(COMMITS_IN=0 chan x branch auto)"
eq "channel: two-digit count is padded" "rc|true|1.2.0-rc010|1.2.0rc10|1.2.0-rc010-abc1234" "$(COMMITS_IN=10 chan release/next branch auto)"
eq "channel: three-digit count is kept" "rc|true|1.2.0-rc123|1.2.0rc123|1.2.0-rc123-abc1234" "$(COMMITS_IN=123 chan release/next branch auto)"
# Text order of the padded versions is the release order (GitHub's release list compares them as text).
eq "channel: padded versions sort as text" "1.2.0-rc009 1.2.0-rc010 1.2.0-rc100" "$(for n in 100 9 10; do COMMITS_IN=$n chan release/next branch auto | cut -d'|' -f3; done | LC_ALL=C sort | xargs)"
if CHANNEL_INPUT=nightly BRANCH=x MMP=1.0.0 GITHUB_OUTPUT=/dev/null bash "$ROOT/versioning/determine-version/channel.sh" 2>/dev/null; then fail "channel: invalid override is rejected"; else ok "channel: invalid override is rejected"; fi

echo "$((total - failures))/$total passed"
[ "$failures" -eq 0 ]
