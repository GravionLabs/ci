#!/usr/bin/env bash
# Rate-limit helpers for gh-release. Source it, or run `bash rate-limit.sh check`.
# Env: RATE_LIMIT_MAX_WAIT (seconds, default 900), RATE_LIMIT_MIN_REMAINING (default 50),
#      RATE_LIMIT_SLEEP (sleep command, default sleep; tests override it).

_rl_max_wait() { echo "${RATE_LIMIT_MAX_WAIT:-900}"; }

# Seconds until the exhausted core/graphql budget resets; empty when none is exhausted.
# Argument: calls remaining below which a budget counts as exhausted.
_rl_wait_seconds() {
  local min=$1 reset now
  reset=$(gh api rate_limit --jq "[.resources.core, .resources.graphql] | map(select(.remaining < $min) | .reset) | max // empty" 2>/dev/null) || return 0
  [ -n "$reset" ] || return 0
  now=$(date +%s)
  echo $((reset - now + 5))
}

# Returns 0 after waiting or when nothing is exhausted, 1 when the wait is too long.
_rl_wait_or_fail() {
  local min=$1 secs
  secs=$(_rl_wait_seconds "$min")
  [ -n "$secs" ] || return 0
  [ "$secs" -gt 0 ] || secs=1
  if [ "$secs" -gt "$(_rl_max_wait)" ]; then
    echo "::error::GitHub API rate limit is exhausted and resets in ${secs}s (more than $(_rl_max_wait)s). Re-run the job after the reset; a re-run completes an existing tag without release." >&2
    return 1
  fi
  echo "GitHub API rate limit exhausted; waiting ${secs}s for the reset." >&2
  ${RATE_LIMIT_SLEEP:-sleep} "$secs"
}

# Run before the first write: wait for the reset (bounded) when the budget is nearly empty.
rate_limit_check() {
  _rl_wait_or_fail "${RATE_LIMIT_MIN_REMAINING:-50}"
}

# gh_retry <command...>: run it; on a rate-limit error wait for the reset and retry (twice at most).
gh_retry() {
  local attempt out rc
  for attempt in 1 2 3; do
    out=$("$@" 2>&1); rc=$?
    if [ $rc -eq 0 ]; then printf '%s\n' "$out"; return 0; fi
    if ! printf '%s' "$out" | grep -qiE 'rate limit|RATE_LIMITED'; then
      printf '%s\n' "$out" >&2; return $rc
    fi
    printf '%s\n' "$out" >&2
    if [ "$attempt" -eq 3 ]; then
      echo "::error::GitHub API rate limit still exceeded after waiting; giving up." >&2
      return $rc
    fi
    # No known reset time means nothing to wait for: wait 1s and retry is pointless, fail.
    _rl_wait_or_fail 1 || return $rc
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = check ]; then
  rate_limit_check
fi
