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
eq "inputs" 'base,dry-run,label,project-status,project-url,release-branch,require-pat' "$(q '.on.workflow_call.inputs | keys | sort | join(",")')"
eq "label default empty (deprecated no-op)" '' "$(q '.on.workflow_call.inputs.label.default')"
eq "project-status default empty (deprecated no-op)" '' "$(q '.on.workflow_call.inputs["project-status"].default')"
eq "project-url default empty" '' "$(q '.on.workflow_call.inputs["project-url"].default')"
eq "release-branch default empty" '' "$(q '.on.workflow_call.inputs["release-branch"].default')"
eq "require-pat boolean" boolean "$(q '.on.workflow_call.inputs["require-pat"].type')"
eq "require-pat default false" false "$(q '.on.workflow_call.inputs["require-pat"].default')"
eq "dry-run boolean" boolean "$(q '.on.workflow_call.inputs["dry-run"].type')"
eq "dry-run default false" false "$(q '.on.workflow_call.inputs["dry-run"].default')"
eq "secrets" 'CI_APP_ID,CI_APP_PRIVATE_KEY,GH_PAT,PROJECT_TOKEN' "$(q '.on.workflow_call.secrets | keys | sort | join(",")')"
eq "GH_PAT optional" false "$(q '.on.workflow_call.secrets.GH_PAT.required')"
eq "PROJECT_TOKEN optional" false "$(q '.on.workflow_call.secrets.PROJECT_TOKEN.required')"

# --- step order and wiring ---
eq "CI_APP_ID optional" false "$(q '.on.workflow_call.secrets.CI_APP_ID.required')"
eq "CI_APP_PRIVATE_KEY optional" false "$(q '.on.workflow_call.secrets.CI_APP_PRIVATE_KEY.required')"
APP="$S[] | select(.id == \"app-token\")"
app_uses=$(q "$APP | .uses")
if [[ "$app_uses" =~ ^actions/create-github-app-token@[0-9a-f]{40}$ ]] && grep -qE "uses: actions/create-github-app-token@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$" "$WF"; then ok "app token action pinned by SHA with a version comment"; else fail "app token action pinned ($app_uses)"; fi
eq "app token only with the secrets" "steps.app.outputs.present == 'true'" "$(q "$APP | .if")"
eq "app token wiring" 'app-id=${{ secrets.CI_APP_ID }},private-key=${{ secrets.CI_APP_PRIVATE_KEY }}' "$(q "$APP | .with | to_entries | map(.key + \"=\" + .value) | sort | join(\",\")")"
eq "action order" 'actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510,GravionLabs/ci/versioning/release-pr@v1,GravionLabs/ci/versioning/close-merged-issues@v1,GravionLabs/ci/project/needs@v1' \
  "$(q "[$S[].uses | select(. != null)] | join(\",\")")"
eq "release-pr token app, else GH_PAT, else GITHUB_TOKEN" '${{ steps.app-token.outputs.token || secrets.GH_PAT || github.token }}' "$(q "$S[] | select(.uses == \"GravionLabs/ci/versioning/release-pr@v1\") | .with.token")"
MARK="$S[] | select(.id == \"close\")"
NEEDS="$S[] | select(.uses == \"GravionLabs/ci/project/needs@v1\")"
eq "needs token PROJECT_TOKEN, else GH_PAT" '${{ secrets.PROJECT_TOKEN || secrets.GH_PAT }}' "$(q "$NEEDS | .with.token")"
eq "needs syncs the closed issues" '${{ steps.close.outputs.closed }}' "$(q "$NEEDS | .with.issues")"
needs_if=$(q "$NEEDS | .if")
case "$needs_if" in *"inputs.project-url != ''"*) ok "needs off without project-url" ;; *) fail "needs off without project-url" ;; esac
case "$needs_if" in *"steps.close.outputs.closed != ''"*) ok "needs skipped without closed issues" ;; *) fail "needs skipped without closed issues" ;; esac
case "$needs_if" in "!inputs.dry-run"*) ok "needs skipped on dry run" ;; *) fail "needs skipped on dry run" ;; esac

# --- complete wiring ---
RP="$S[] | select(.uses == \"GravionLabs/ci/versioning/release-pr@v1\") | .with"
eq "release-pr wiring" 'base=${{ inputs.base }},dry-run=${{ inputs.dry-run }},release-branch=${{ inputs.release-branch }},token=${{ steps.app-token.outputs.token || secrets.GH_PAT || github.token }}' \
  "$(q "$RP | to_entries | map(.key + \"=\" + .value) | sort | join(\",\")")"
eq "close wiring" 'base=${{ inputs.base }},dry-run=${{ inputs.dry-run }},release-branch=${{ inputs.release-branch }},token=${{ github.token }}' \
  "$(q "$MARK | .with | to_entries | map(.key + \"=\" + .value) | sort | join(\",\")")"
eq "needs wiring" 'issues=${{ steps.close.outputs.closed }},project-url=${{ inputs.project-url }},token=${{ secrets.PROJECT_TOKEN || secrets.GH_PAT }}' \
  "$(q "$NEEDS | .with | to_entries | map(.key + \"=\" + .value) | sort | join(\",\")")"
eq "needs if exact" "!inputs.dry-run && inputs.project-url != '' && steps.close.outputs.closed != ''" "$needs_if"
eq "concurrency group" 'release-branch-${{ github.repository }}-${{ inputs.release-branch || github.ref_name }}' "$(q "$JOB.concurrency.group")"
eq "concurrency does not cancel" false "$(q "$JOB.concurrency[\"cancel-in-progress\"]")"

# --- deprecated inputs warning: run its script ---
DEP="$S[] | select(.name == \"Warn about deprecated inputs\")"
eq "deprecation step condition" "inputs.label != '' || inputs.project-status != ''" "$(q "$DEP | .if")"
dep_out=$(bash -c "$(q "$DEP | .run")"); dep_code=$?
eq "deprecation step green" 0 "$dep_code"
eq "deprecation step warns once" 1 "$(grep -c '^::warning::' <<<"$dep_out")"
eq "no mark-merged-issues step" 0 "$(q "[$S[].uses | select(. != null and test(\"mark-merged-issues\"))] | length")"

# --- dry-run Needs step: run its script ---
DRY="$S[] | select(.name == \"Needs sync (dry run)\")"
eq "dry-run step condition" "inputs.dry-run && inputs.project-url != ''" "$(q "$DRY | .if")"
dry_script=$(q "$DRY | .run")
out=$(CLOSED='' bash -c "$dry_script"); code=$?
eq "dry-run step green" 0 "$code"
eq "dry-run step without issues" 'would sync Needs of the issues closed in a real run, with parents and dependents' "$out"
out=$(CLOSED='4 7' bash -c "$dry_script")
eq "dry-run step lists issues" 'would sync Needs of the issues closed in a real run (4 7), with parents and dependents' "$out"

# --- app presence check: run its script ---
app_script=$(q "$S[] | select(.id == \"app\") | .run")
app_out=$(mktemp)
HAS_APP=true GITHUB_OUTPUT="$app_out" bash -c "$app_script"; eq "app secrets set: present=true" present=true "$(cat "$app_out")"
: > "$app_out"; HAS_APP=false GITHUB_OUTPUT="$app_out" bash -c "$app_script"; eq "app secrets missing: present=false" present=false "$(cat "$app_out")"
rm -f "$app_out"
eq "app presence needs both secrets" "\${{ secrets.CI_APP_ID != '' && secrets.CI_APP_PRIVATE_KEY != '' }}" "$(q "$S[] | select(.id == \"app\") | .env.HAS_APP")"

# --- token check: run its script ---
script=$(q "$S[] | select(.name == \"Check release PR token\") | .run")
check() {
  out=$(HAS_APP="$1" HAS_PAT="$2" REQUIRE_PAT="$3" bash -c "$script" 2>&1); code=$?
}
check true false false;  eq "app: green" 0 "$code"; eq "app: no output" '' "$out"
check false true false;  eq "PAT only: green" 0 "$code"; eq "PAT only: no output" '' "$out"
check false false false; eq "neither: green" 0 "$code"; eq "neither: one warning" 1 "$(grep -c '^::warning::' <<<"$out")"
check false false true;  eq "neither, require-pat: fails" 1 "$code"; eq "neither, require-pat: error" 1 "$(grep -c '^::error::' <<<"$out")"
check true false true;   eq "app, require-pat: green" 0 "$code"
check false true true;   eq "PAT, require-pat: green" 0 "$code"

echo "$((total - failures))/$total passed"
[ "$failures" -eq 0 ]
