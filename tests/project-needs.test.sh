#!/usr/bin/env bash
# Tests for the composite action project/needs: needs.sh (env in, pwsh arguments out) against a stub pwsh,
# the token check step, and structural invariants of action.yml read with yq (mikefarah).
# Run: bash tests/project-needs.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ACTION="$ROOT/project/needs/action.yml"
NEEDS="$ROOT/project/needs/needs.sh"
failures=0 total=0

ok()    { total=$((total + 1)); echo "ok   - $1"; }
fail()  { total=$((total + 1)); failures=$((failures + 1)); echo "FAIL - $1"; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
has()   { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else fail "$1 (missing: $2)"; fi; }
q()     { yq -r "$1" "$ACTION"; }

command -v yq >/dev/null || { echo "yq is required"; exit 1; }

# stub pwsh: prints its arguments space-separated on one line, exits with $PWSH_EXIT (default 0)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/bin"
cat > "$TMP/bin/pwsh" <<'EOF'
#!/usr/bin/env bash
echo "pwsh $*"
exit "${PWSH_EXIT:-0}"
EOF
chmod +x "$TMP/bin/pwsh"
SCRIPT="$TMP/Sync-ProjectNeeds.ps1"
touch "$SCRIPT"
BASE="pwsh -NoProfile -File $SCRIPT -Owner GravionLabs -Number 17 -Repo GravionLabs/ci"

# run_needs VAR=value ... : runs needs.sh with defaults overridden by the arguments
run_needs() {
  out=$(env -i PATH="$TMP/bin:$PATH" PROJECT_URL=https://github.com/users/GravionLabs/projects/17 \
    GH_REPO=GravionLabs/ci SYNC_SCRIPT="$SCRIPT" "$@" bash "$NEEDS" 2>&1)
  code=$?
}

echo "# issues events"
run_needs EVENT_NAME=issues EVENT_ACTION=opened ISSUE_NUMBER=63
eq "opened: issue and parents" "$BASE -Issue 63 -IncludeParents" "$out"
eq "opened: exit 0" 0 "$code"
run_needs EVENT_NAME=issues EVENT_ACTION=edited ISSUE_NUMBER=63
eq "edited: no dependents" "$BASE -Issue 63 -IncludeParents" "$out"
run_needs EVENT_NAME=issues EVENT_ACTION=closed ISSUE_NUMBER=63
eq "closed: dependents" "$BASE -Issue 63 -IncludeParents -IncludeDependents" "$out"
run_needs EVENT_NAME=issues EVENT_ACTION=reopened ISSUE_NUMBER=63
eq "reopened: dependents" "$BASE -Issue 63 -IncludeParents -IncludeDependents" "$out"
run_needs EVENT_NAME=issues EVENT_ACTION=labeled ISSUE_NUMBER=63 LABEL_NAME=merged
eq "labeled merged: dependents" "$BASE -Issue 63 -IncludeParents -IncludeDependents" "$out"
run_needs EVENT_NAME=issues EVENT_ACTION=unlabeled ISSUE_NUMBER=63 LABEL_NAME=merged
eq "unlabeled merged: dependents" "$BASE -Issue 63 -IncludeParents -IncludeDependents" "$out"
run_needs EVENT_NAME=issues EVENT_ACTION=labeled ISSUE_NUMBER=63 LABEL_NAME=needs-review
eq "labeled other label: no dependents" "$BASE -Issue 63 -IncludeParents" "$out"
eq "labeled other label: exit 0" 0 "$code"
run_needs EVENT_NAME=issues EVENT_ACTION=unlabeled ISSUE_NUMBER=63 LABEL_NAME=merged-later
eq "unlabeled label with merged prefix: no dependents" "$BASE -Issue 63 -IncludeParents" "$out"
run_needs EVENT_NAME=issues EVENT_ACTION=opened ISSUE_NUMBER=
has "issues without number: error" "::error::Invalid issue number" "$out"
eq "issues without number: exit 1" 1 "$code"
run_needs EVENT_NAME=issues EVENT_ACTION=opened 'ISSUE_NUMBER=1;id'
eq "issues with non-numeric number: exit 1" 1 "$code"

echo "# pull_request_target"
run_needs EVENT_NAME=pull_request_target EVENT_ACTION=opened HEAD_REF=feat/63-needs-job
eq "PR feat/63-x: issue 63" "$BASE -Issue 63 -IncludeParents" "$out"
run_needs EVENT_NAME=pull_request_target EVENT_ACTION=opened HEAD_REF=63-needs-job
eq "PR 63-x: issue 63" "$BASE -Issue 63 -IncludeParents" "$out"
run_needs EVENT_NAME=pull_request_target EVENT_ACTION=opened HEAD_REF=main
eq "PR main: notice only" "::notice::No issue number in head ref 'main': Needs sync skipped" "$out"
eq "PR main: exit 0" 0 "$code"
run_needs EVENT_NAME=pull_request_target EVENT_ACTION=opened 'HEAD_REF=x/$(touch '"$TMP"'/pwned)-1'
eq "PR ref with a command substitution is data" 0 "$( [ -e "$TMP/pwned" ] && echo 1 || echo 0)"
eq "PR ref with a command substitution: exit 0" 0 "$code"
run_needs EVENT_NAME=pull_request_target EVENT_ACTION=opened HEAD_REF=v2-63-x
has "PR ref without a leading number: notice" "::notice::No issue number" "$out"

echo "# full sync"
run_needs MODE=full EVENT_NAME=issues EVENT_ACTION=opened ISSUE_NUMBER=63
eq "mode full: no -Issue" "$BASE" "$out"
run_needs EVENT_NAME=schedule
eq "schedule: full sync" "$BASE" "$out"
run_needs EVENT_NAME=workflow_dispatch
eq "workflow_dispatch: full sync" "$BASE" "$out"
run_needs EVENT_NAME=push
has "unknown event: notice" "::notice::Event 'push' is not handled" "$out"
eq "unknown event: exit 0" 0 "$code"

echo "# project-url, inputs, exit code"
run_needs PROJECT_URL=https://github.com/orgs/acme-co/projects/4 EVENT_NAME=schedule
eq "orgs URL: owner and number" "pwsh -NoProfile -File $SCRIPT -Owner acme-co -Number 4 -Repo GravionLabs/ci" "$out"
run_needs PROJECT_URL=https://github.com/users/GravionLabs/projects/17/ EVENT_NAME=schedule
eq "trailing slash accepted" "$BASE" "$out"
for url in '' https://github.com/GravionLabs/projects/17 https://github.com/users/GravionLabs/projects/x \
  https://example.com/users/a/projects/1 'https://github.com/users/a b/projects/1'; do
  run_needs PROJECT_URL="$url" EVENT_NAME=schedule
  eq "invalid project-url '$url': exit 1" 1 "$code"
  has "invalid project-url '$url': error" "::error::Invalid project-url" "$out"
done
run_needs MODE=all EVENT_NAME=schedule
eq "invalid mode: exit 1" 1 "$code"
run_needs GH_REPO= EVENT_NAME=schedule
eq "missing GH_REPO: exit 1" 1 "$code"
run_needs SYNC_SCRIPT="$TMP/missing.ps1" EVENT_NAME=schedule
has "missing script: error" "::error::Sync-ProjectNeeds.ps1 not found" "$out"
eq "missing script: exit 1" 1 "$code"
run_needs PWSH_EXIT=3 EVENT_NAME=schedule
eq "pwsh exit code propagated" 3 "$code"

echo "# token check step"
script=$(q '.runs.steps[] | select(.id == "token") | .run')
if [ -n "$script" ]; then ok "token check script found"; else fail "token check script found"; fi
check_token() {
  local file; file=$(mktemp)
  tout=$(HAS_TOKEN="$1" GITHUB_OUTPUT="$file" bash -c "$script" 2>&1); tcode=$?
  toutput=$(cat "$file"); rm -f "$file"
}
check_token false
eq "no token: step green" 0 "$tcode"
eq "no token: exactly one warning" 1 "$(grep -c '^::warning::' <<<"$tout")"
eq "no token: sync skipped" present=false "$toutput"
check_token true
eq "token: no warning" 0 "$(grep -c '::warning::' <<<"$tout")"
eq "token: sync runs" present=true "$toutput"
eq "HAS_TOKEN from the token input" "\${{ inputs.token != '' }}" "$(q '.runs.steps[] | select(.id == "token") | .env.HAS_TOKEN')"
eq "later steps run only with a token" "steps.token.outputs.present == 'true'" \
  "$(q '[.runs.steps[] | select(.id != "token") | .if] | unique | join(",")')"

echo "# action.yml structure"
CO='.runs.steps[] | select(.uses != null and (.uses | test("^actions/checkout@")))'
eq "exactly one checkout" 1 "$(q "[$CO] | length")"
co_uses=$(q "$CO | .uses")
if [[ "$co_uses" =~ ^actions/checkout@[0-9a-f]{40}$ ]]; then ok "checkout pinned by SHA"; else fail "checkout pinned by SHA ($co_uses)"; fi
eq "checkout repository" GravionLabs/apm-hub "$(q "$CO | .with.repository")"
eq "checkout ref from input, empty falls back to the pin" "\${{ inputs.apm-hub-ref || 'v2.5.4' }}" "$(q "$CO | .with.ref")"
eq "checkout path" .apm-hub "$(q "$CO | .with.path")"
eq "persist-credentials false" false "$(q "$CO | .with[\"persist-credentials\"]")"
eq "sparse cone mode off" false "$(q "$CO | .with[\"sparse-checkout-cone-mode\"]")"
eq "sparse dirs" 'packages/github/.apm/skills/github-issue/scripts/,packages/github/.apm/skills/github-project/scripts/' \
  "$(q "$CO | .with[\"sparse-checkout\"] | split(\"\n\") | map(select(. != \"\")) | sort | join(\",\")")"
eq "no run script expands an expression" 0 "$(q '[.runs.steps[].run | select(. != null and test("\$\{\{"))] | length')"
eq "SYNC_SCRIPT points into the sparse checkout" \
  '${{ github.workspace }}/.apm-hub/packages/github/.apm/skills/github-project/scripts/Sync-ProjectNeeds.ps1' \
  "$(q '.runs.steps[] | select(.env.SYNC_SCRIPT != null) | .env.SYNC_SCRIPT')"
eq "inputs" 'apm-hub-ref,mode,project-url,token' "$(q '.inputs | keys | sort | join(",")')"
eq "project-url required" true "$(q '.inputs["project-url"].required')"
eq "mode default" event "$(q '.inputs.mode.default')"
eq "apm-hub-ref default" v2.5.4 "$(q '.inputs["apm-hub-ref"].default')"
eq "empty-ref fallback equals the input default" "$(q '.inputs["apm-hub-ref"].default')" \
  "$(q "$CO | .with.ref" | sed -nE "s/.*\|\| '([^']*)'.*/\1/p")"
eq "token default empty" '' "$(q '.inputs.token.default')"

echo "$((total - failures))/$total passed"
[ "$failures" -eq 0 ]
