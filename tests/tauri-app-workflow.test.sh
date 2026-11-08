#!/usr/bin/env bash
# Invariants of .github/workflows/tauri-app.yml for recreate-branch, read structurally with yq.
# Run: bash tests/tauri-app-workflow.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WF="$ROOT/.github/workflows/tauri-app.yml"
failures=0

eq() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (expected '$2', got '$3')"; failures=$((failures + 1)); fi; }
q()  { yq -r "$1" "$WF"; }

command -v yq >/dev/null || { echo "yq is required"; exit 1; }

P='.jobs.publish'
STEP="$P.steps[] | select(.name == \"Recreate the release branch\")"
eq "recreate-branch input is a string" string "$(q '.on.workflow_call.inputs["recreate-branch"].type')"
eq "recreate-branch default empty (off)" '' "$(q '.on.workflow_call.inputs["recreate-branch"].default')"
eq "same description as node-package.yml" \
  "$(yq -r '.on.workflow_call.inputs["recreate-branch"].description' "$ROOT/.github/workflows/node-package.yml")" \
  "$(q '.on.workflow_call.inputs["recreate-branch"].description')"
eq "publish has contents: write" write "$(q "$P.permissions.contents")"
eq "recreate step runs recreate-branch.sh" 1 "$(q "[$STEP | select(.run | test(\"gh-release/recreate-branch.sh\"))] | length")"
eq "recreate step is off without the input" "\${{ inputs.recreate-branch != '' }}" "$(q "$STEP | .if")"
eq "recreate step passes the branch through env" '${{ inputs.recreate-branch }}' "$(q "$STEP | .env.BRANCH")"
eq "recreate step pushes with app token, PAT, then github.token" '${{ steps.app-token.outputs.token || secrets.GH_PAT || github.token }}' "$(q "$STEP | .env.PUSH_TOKEN")"
eq "recreate step never forces" 0 "$(q "[$STEP | select(.run | test(\"--force|-f \"))] | length")"
idx() { yq -r "$P.steps | to_entries | .[] | select(.value.name == \"$1\") | .key" "$WF"; }
if [ "$(idx 'Recreate the release branch')" -gt "$(idx 'Publish the release')" ]; then r=after; else r=before; fi
eq "recreate step comes after the release is published" after "$r"

CO="$P.steps[] | select(.uses == \"actions/checkout@v4\" and .with.path == null)"
eq "publish checkout does not persist github.token (would shadow the push token)" false "$(q "$CO | .with[\"persist-credentials\"]")"
eq "no extraheader is set back in the publish job" 0 "$(q "[$P.steps[] | select(.run != null) | select(.run | test(\"extraheader\"))] | length")"
for s in CI_APP_ID CI_APP_PRIVATE_KEY GH_PAT; do
  eq "secret $s is declared optional" false "$(q ".on.workflow_call.secrets.$s.required")"
done

CS="$P.steps[] | select(.name == \"Checksum the release assets\")"
AT="$P.steps[] | select(.name == \"Attest the build provenance\")"
eq "publish has id-token: write" write "$(q "$P.permissions[\"id-token\"]")"
eq "publish has attestations: write" write "$(q "$P.permissions.attestations")"
eq "checksum step uploads with --clobber" 1 "$(q "[$CS | select(.run | test(\"upload .*SHA256SUMS --clobber\"))] | length")"
eq "checksum step verifies with sha256sum -c" 1 "$(q "[$CS | select(.run | test(\"sha256sum -c\"))] | length")"
eq "checksum step leaves out sig, latest.json and SHA256SUMS" 1 "$(q "[$CS | select(.run | test(\"rm -f -- \\\\*\\\\.sig latest\\\\.json SHA256SUMS\"))] | length")"
eq "attestation runs only for public repositories" '${{ github.event.repository.private == false }}' "$(q "$AT | .if")"
eq "attestation uses subject-checksums" SHA256SUMS "$(q "$AT | .with[\"subject-checksums\"]")"
eq "attestation action is pinned to a SHA" 1 "$(q "[$AT | select(.uses | test(\"@[0-9a-f]{40}\"))] | length")"
if [ "$(idx 'Checksum the release assets')" -gt "$(idx 'Pin the updater URLs to the release')" ]; then r=after; else r=before; fi
eq "checksums come after the last asset upload" after "$r"
if [ "$(idx 'Attest the build provenance')" -gt "$(idx 'Checksum the release assets')" ]; then r=after; else r=before; fi
eq "attestation comes after the checksums" after "$r"

[ "$failures" = 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
