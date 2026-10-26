#!/usr/bin/env bash
# Invariants of the reusable workflow .github/workflows/release-branch.yml, read structurally with yq and jq.
# Run: bash tests/release-branch-workflow.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WF="$ROOT/.github/workflows/release-branch.yml"
failures=0 total=0

ok()   { total=$((total + 1)); echo "ok   - $1"; }
fail() { total=$((total + 1)); failures=$((failures + 1)); echo "FAIL - $1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
q()    { yq -r "$1" "${2:-$WF}"; }
qj()   { yq -o=json -I=0 "$1" "${2:-$WF}"; }

command -v yq >/dev/null || { echo "yq is required"; exit 1; }

JOB='.jobs["release-branch"]'
S="$JOB.steps"

# --- triggers, permissions, checkout ---
eq "only workflow_call trigger" workflow_call "$(q '.on | keys | join(",")')"
eq "top-level permissions empty" '{}' "$(qj '.permissions')"
eq "one job" release-branch "$(q '.jobs | keys | join(",")')"
eq "job permissions" '{"contents":"read","issues":"write","pull-requests":"write"}' "$(qj "$JOB.permissions")"
eq "no checkout" 0 "$(q "[$S[].uses | select(. != null and test(\"^actions/checkout@\"))] | length")"
eq "no run script expands an expression" 0 "$(q "[$S[].run | select(. != null and test(\"\\$\\{\\{\"))] | length")"

# --- inputs and secrets ---
eq "inputs" 'apm-hub-ref,base,dry-run,label,project-status,project-url,release-branch,require-pat' "$(q '.on.workflow_call.inputs | keys | sort | join(",")')"
eq "project-status default" 'In release' "$(q '.on.workflow_call.inputs["project-status"].default')"
eq "label default" merged "$(q '.on.workflow_call.inputs.label.default')"
eq "project-url default empty" '' "$(q '.on.workflow_call.inputs["project-url"].default')"
eq "release-branch default empty" '' "$(q '.on.workflow_call.inputs["release-branch"].default')"
eq "require-pat boolean" boolean "$(q '.on.workflow_call.inputs["require-pat"].type')"
eq "require-pat default false" false "$(q '.on.workflow_call.inputs["require-pat"].default')"
eq "dry-run boolean" boolean "$(q '.on.workflow_call.inputs["dry-run"].type')"
eq "dry-run default false" false "$(q '.on.workflow_call.inputs["dry-run"].default')"
eq "secrets" 'GH_PAT,PROJECT_TOKEN' "$(q '.on.workflow_call.secrets | keys | sort | join(",")')"
eq "GH_PAT optional" false "$(q '.on.workflow_call.secrets.GH_PAT.required')"
eq "PROJECT_TOKEN optional" false "$(q '.on.workflow_call.secrets.PROJECT_TOKEN.required')"

# --- step order and wiring ---
eq "action order" 'GravionLabs/ci/versioning/release-pr@main,GravionLabs/ci/versioning/mark-merged-issues@main,GravionLabs/ci/project/needs@main' \
  "$(q "[$S[].uses | select(. != null)] | join(\",\")")"
eq "release-pr token GH_PAT, else GITHUB_TOKEN" '${{ secrets.GH_PAT || github.token }}' "$(q "$S[] | select(.uses == \"GravionLabs/ci/versioning/release-pr@main\") | .with.token")"
MARK="$S[] | select(.id == \"mark\")"
eq "mark passes project-status" '${{ inputs.project-status }}' "$(q "$MARK | .with[\"project-status\"]")"
eq "mark project-token PROJECT_TOKEN, else GH_PAT" '${{ secrets.PROJECT_TOKEN || secrets.GH_PAT }}' "$(q "$MARK | .with[\"project-token\"]")"
NEEDS="$S[] | select(.uses == \"GravionLabs/ci/project/needs@main\")"
eq "needs token PROJECT_TOKEN, else GH_PAT" '${{ secrets.PROJECT_TOKEN || secrets.GH_PAT }}' "$(q "$NEEDS | .with.token")"
eq "needs syncs the labelled issues" '${{ steps.mark.outputs.labelled }}' "$(q "$NEEDS | .with.issues")"
needs_if=$(q "$NEEDS | .if")
case "$needs_if" in *"inputs.project-url != ''"*) ok "needs off without project-url" ;; *) fail "needs off without project-url" ;; esac
case "$needs_if" in *"steps.mark.outputs.labelled != ''"*) ok "needs skipped without labelled issues" ;; *) fail "needs skipped without labelled issues" ;; esac
case "$needs_if" in "!inputs.dry-run"*) ok "needs skipped on dry run" ;; *) fail "needs skipped on dry run" ;; esac

# --- complete wiring ---
RP="$S[] | select(.uses == \"GravionLabs/ci/versioning/release-pr@main\") | .with"
eq "release-pr wiring" 'base=${{ inputs.base }},dry-run=${{ inputs.dry-run }},release-branch=${{ inputs.release-branch }},token=${{ secrets.GH_PAT || github.token }}' \
  "$(q "$RP | to_entries | map(.key + \"=\" + .value) | sort | join(\",\")")"
eq "mark wiring" 'base=${{ inputs.base }},dry-run=${{ inputs.dry-run }},label=${{ inputs.label }},project-status=${{ inputs.project-status }},project-token=${{ secrets.PROJECT_TOKEN || secrets.GH_PAT }},release-branch=${{ inputs.release-branch }},token=${{ github.token }}' \
  "$(q "$MARK | .with | to_entries | map(.key + \"=\" + .value) | sort | join(\",\")")"
eq "needs wiring" 'apm-hub-ref=${{ inputs.apm-hub-ref }},issues=${{ steps.mark.outputs.labelled }},project-url=${{ inputs.project-url }},token=${{ secrets.PROJECT_TOKEN || secrets.GH_PAT }}' \
  "$(q "$NEEDS | .with | to_entries | map(.key + \"=\" + .value) | sort | join(\",\")")"
eq "needs if exact" "!inputs.dry-run && inputs.project-url != '' && steps.mark.outputs.labelled != ''" "$needs_if"
eq "concurrency group" 'release-branch-${{ github.repository }}-${{ inputs.release-branch || github.ref_name }}' "$(q "$JOB.concurrency.group")"
eq "concurrency does not cancel" false "$(q "$JOB.concurrency[\"cancel-in-progress\"]")"

# --- dry-run Needs step: run its script ---
DRY="$S[] | select(.name == \"Needs sync (dry run)\")"
eq "dry-run step condition" "inputs.dry-run && inputs.project-url != ''" "$(q "$DRY | .if")"
dry_script=$(q "$DRY | .run")
out=$(LABELLED='' bash -c "$dry_script"); code=$?
eq "dry-run step green" 0 "$code"
eq "dry-run step without issues" 'would sync Needs of the issues newly labelled in a real run, with parents and dependents' "$out"
out=$(LABELLED='4 7' bash -c "$dry_script")
eq "dry-run step lists issues" 'would sync Needs of the issues newly labelled in a real run (4 7), with parents and dependents' "$out"

# --- token check: run its script ---
script=$(q "$S[0].run")
check() {
  out=$(HAS_TOKEN="$1" REQUIRE_PAT="$2" bash -c "$script" 2>&1); code=$?
}
check true false;  eq "PAT: green" 0 "$code"; eq "PAT: no output" '' "$out"
check false false; eq "no PAT: green" 0 "$code"; eq "no PAT: one warning" 1 "$(grep -c '^::warning::' <<<"$out")"
check false true;  eq "no PAT, require-pat: fails" 1 "$code"; eq "no PAT, require-pat: error" 1 "$(grep -c '^::error::' <<<"$out")"
check true true;   eq "PAT, require-pat: green" 0 "$code"

echo "$((total - failures))/$total passed"
[ "$failures" -eq 0 ]
