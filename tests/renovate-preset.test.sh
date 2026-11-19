#!/usr/bin/env bash
# The shared Renovate preset (#241): default.json holds releases back for 7 days, pins action digests, exempts security
# fixes, GravionLabs/ci itself and the helix packages (#253); this repository extends it and npm has the same age on install.
# Run: bash tests/renovate-preset.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
failures=0 total=0
ok()   { total=$((total + 1)); echo "ok   - $1"; }
fail() { total=$((total + 1)); failures=$((failures + 1)); echo "FAIL - $1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }
P="$ROOT/default.json"
R="$ROOT/renovate.json"

eq "preset: minimum release age" "7 days" "$(jq -r '.minimumReleaseAge' "$P")"
eq "preset: a version that is too young is not proposed" "strict" "$(jq -r '.internalChecksFilter' "$P")"
eq "preset: action digests are pinned" true "$(jq -r '.extends | index("helpers:pinGitHubActionDigests") != null' "$P")"
eq "preset: security fixes are not held back" null "$(jq -r '.vulnerabilityAlerts | if has("minimumReleaseAge") then .minimumReleaseAge else "missing" end' "$P")"
own='.packageRules[] | select((.matchPackageNames // []) | index("GravionLabs/ci") != null)'
eq "preset: GravionLabs/ci is exempt from the age" null "$(jq -r "$own | if has(\"minimumReleaseAge\") then .minimumReleaseAge else \"missing\" end" "$P")"
eq "preset: the exemption covers the action paths" true "$(jq -r "$own | .matchPackageNames | index(\"GravionLabs/ci/**\") != null" "$P")"
helix='.packageRules[] | select((.matchPackageNames // []) | index("@gravionlabs/helix-*") != null)'
eq "preset: the helix packages are exempt from the age" null "$(jq -r "$helix | if has(\"minimumReleaseAge\") then .minimumReleaseAge else \"missing\" end" "$P")"
eq "preset: the helix rule is for the npm datasource" '["npm"]' "$(jq -c "$helix | .matchDatasources" "$P")"
eq "preset: the helix rule matches nothing but @gravionlabs/helix-*" '["@gravionlabs/helix-*"]' "$(jq -c "$helix | .matchPackageNames" "$P")"
eq "preset: only GravionLabs/ci and the helix packages are exempt from the age" 2 "$(jq -r '[.packageRules[] | select(has("minimumReleaseAge") and .minimumReleaseAge == null)] | length' "$P")"
eq "preset: the helix rule says it is own code" true "$(jq -r "$helix | .description | test(\"[Oo]wn code\")" "$P")"
eq "preset: at most two open pull requests" 2 "$(jq -r '.prConcurrentLimit' "$P")"
eq "preset: no base branch (the default branch)" null "$(jq -r '.baseBranchPatterns' "$P")"
eq "preset: no schedule, labels or automerge (the repository decides)" 0 "$(jq -r '[.schedule, .labels, .automerge] | map(select(. != null)) | length' "$P")"

eq "renovate.json: extends the preset" true "$(jq -r '.extends | index("github>GravionLabs/ci") != null' "$R")"
eq "renovate.json: sets no minimum release age of its own" 0 "$(jq -r '[.. | objects | select(has("minimumReleaseAge"))] | length' "$R")"
eq "renovate.json: pull requests target the default branch" null "$(jq -r '.baseBranchPatterns' "$R")"
eq "renovate.json: self-references are left alone" false "$(jq -r "$own | .enabled" "$R")"

eq ".npmrc: npm holds releases back for 7 days" "min-release-age=7" "$(grep -E '^min-release-age=' "$ROOT/.npmrc" 2>/dev/null)"

echo "$((total - failures))/$total passed"
[ "$failures" -eq 0 ]
