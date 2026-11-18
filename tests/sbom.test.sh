#!/usr/bin/env bash
# Tests sbom/generate: the attestation decision (can-attest.sh), the action.yml invariants and, when `syft` is on
# the PATH, that the SBOM of a fixture lists the resolved versions of the lockfile, not the ranges of the manifest
# (the job `Test: SBOM` of ci.yml installs syft). Run: bash tests/sbom.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR=$(mktemp -d); trap 'rm -rf "$DIR"' EXIT
failures=0 total=0
ok()   { total=$((total + 1)); echo "ok   - $1"; }
fail() { total=$((total + 1)); failures=$((failures + 1)); echo "FAIL - $1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

decide() { # env as arguments; prints the GITHUB_OUTPUT lines
  : > "$DIR/out"
  env -u ACTIONS_ID_TOKEN_REQUEST_URL GITHUB_OUTPUT="$DIR/out" SBOM=sbom.spdx.json "$@" \
    bash "$ROOT/sbom/generate/can-attest.sh" >"$DIR/log" 2>&1
  tr '\n' ' ' < "$DIR/out"
}

eq "no id-token: not attested" "attest=false " "$(decide ATTEST=true)"
grep -q 'id-token: write' "$DIR/log" && ok "no id-token: says so in the log" || fail "no id-token: says so in the log"
eq "attest false: not attested" "attest=false " "$(decide ATTEST=false ACTIONS_ID_TOKEN_REQUEST_URL=https://x)"
eq "id-token: the SBOM is its own subject" "attest=true subject-path=sbom.spdx.json " "$(decide ATTEST=true ACTIONS_ID_TOKEN_REQUEST_URL=https://x)"
eq "id-token: given subject path" "attest=true subject-path=pkg.tgz " "$(decide ATTEST=true ACTIONS_ID_TOKEN_REQUEST_URL=https://x SUBJECT_PATH=pkg.tgz)"
eq "image subject" "attest=true subject-path= " "$(decide ATTEST=true ACTIONS_ID_TOKEN_REQUEST_URL=https://x SUBJECT_NAME=ghcr.io/o/a SUBJECT_DIGEST=sha256:abc)"
eq "image subject without digest: not attested" "attest=false " "$(decide ATTEST=true ACTIONS_ID_TOKEN_REQUEST_URL=https://x SUBJECT_NAME=ghcr.io/o/a)"

action=$ROOT/sbom/generate/action.yml
eq "format is SPDX JSON" spdx-json "$(yq '.runs.steps[] | select(.name == "Generate the SBOM") | .with.format' "$action")"
uses=$(yq '.runs.steps[].uses' "$action")
grep -qE '^anchore/sbom-action@[0-9a-f]{40}$' <<<"$uses" && ok "generator pinned to a commit SHA" || fail "generator pinned to a commit SHA"
grep -qE '^actions/attest-sbom@[0-9a-f]{40}$' <<<"$uses" && ok "attest-sbom pinned to a commit SHA" || fail "attest-sbom pinned to a commit SHA"
eq "a failed attestation does not fail the action" true "$(yq '.runs.steps[] | select(.id == "attest") | .continue-on-error' "$action")"

if command -v syft >/dev/null 2>&1; then
  syft "dir:$ROOT/tests/fixtures/sbom/node" -o spdx-json="$DIR/sbom.json" -q
  eq "SPDX version" "SPDX-2.3" "$(jq -r .spdxVersion "$DIR/sbom.json")"
  eq "is-odd at the locked version" 3.0.1 "$(jq -r '.packages[] | select(.name == "is-odd") | .versionInfo' "$DIR/sbom.json")"
  eq "transitive is-number at the locked version" 6.0.0 "$(jq -r '.packages[] | select(.name == "is-number") | .versionInfo' "$DIR/sbom.json")"
  jq -e '[.packages[].versionInfo] | any(startswith("^") or startswith("~"))' "$DIR/sbom.json" >/dev/null \
    && fail "no manifest range in the SBOM" || ok "no manifest range in the SBOM"
else
  echo "skip - syft not installed: fixture check not run (the CI job installs it)"
fi

echo "$((total - failures))/$total passed"
[ "$failures" -eq 0 ]
