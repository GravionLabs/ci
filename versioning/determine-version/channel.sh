#!/usr/bin/env bash
# Derives the release channel and the channel versions from the branch.
# Env: CHANNEL_INPUT (auto|stable|rc|beta), BRANCH, REF_TYPE (branch|tag), MMP (1.2.3),
#      SEMVER (GitVersion SemVer), PRE_TAG, PRE_LABEL, PRE_NUMBER, COMMITS (commits since version source), SHORT_SHA.
# Writes key=value lines to $GITHUB_OUTPUT (stdout when unset).
set -euo pipefail

input="${CHANNEL_INPUT:-auto}"
case "$input" in
  auto|"")
    if [ "${REF_TYPE:-branch}" = "tag" ] || [ "${BRANCH:-}" = "main" ]; then channel=stable
    elif [[ "${BRANCH:-}" == release/* ]]; then channel=rc
    else channel=beta; fi ;;
  stable|rc|beta) channel="$input" ;;
  *) echo "::error::Invalid channel '$input' (auto, stable, rc or beta)" >&2; exit 1 ;;
esac

mmp="${MMP:?MMP is required}"
if [ "$channel" = stable ]; then
  semver="${SEMVER:-$mmp}" tag="${PRE_TAG:-}" label="${PRE_LABEL:-}" num="${PRE_NUMBER:-}"
else
  n="${COMMITS:-0}"; [[ "$n" =~ ^[0-9]+$ ]] || n=0
  [ "$n" -ge 1 ] || n=1
  label="$channel" num="$n" tag="$channel.$n" semver="$mmp-$channel.$n"
fi

if [ -z "$label" ]; then py="$mmp"
elif [ "$label" = alpha ]; then py="${mmp}a${num}"
elif [ "$label" = beta ]; then py="${mmp}b${num}"
elif [ "$label" = rc ] || [ "$label" = preview ]; then py="${mmp}rc${num}"
else py="${mmp}.dev${num:-0}"; fi

[ "$channel" = stable ] && pre=false || pre=true
{
  echo "channel=$channel"
  echo "is-prerelease=$pre"
  echo "semver=$semver"
  echo "pre-release-tag=$tag"
  echo "pre-release-label=$label"
  echo "pre-release-number=$num"
  echo "python-version=$py"
  echo "docker-version=$semver-${SHORT_SHA:-}"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"
