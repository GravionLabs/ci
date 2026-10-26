#!/usr/bin/env bash
# Invariants of the reusable workflow .github/workflows/issues.yml and its callers issue-events.yml and project-needs.yml,
# read structurally with yq (mikefarah, preinstalled on GitHub's ubuntu runners) and jq.
# Run: bash tests/issues-workflow.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WF="$ROOT/.github/workflows/issues.yml"
CALLER="$ROOT/.github/workflows/issue-events.yml"
SCHED="$ROOT/.github/workflows/project-needs.yml"
failures=0 total=0

ok()   { total=$((total + 1)); echo "ok   - $1"; }
fail() { total=$((total + 1)); failures=$((failures + 1)); echo "FAIL - $1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
q()    { yq -r "$1" "${2:-$WF}"; }
qj()   { yq -o=json -I=0 "$1" "${2:-$WF}"; }
# events of <event_name> in an if: expression, as a sorted CSV (from its fromJSON('[...]') list)
events() {
  grep -oE "github\.event_name == '$1'[^)]*fromJSON\('\[[^]]*\]'\)" <<<"$2" \
    | grep -oE '\[[^]]*\]' | jq -r 'sort | join(",")'
}

command -v yq >/dev/null || { echo "yq is required"; exit 1; }

ATP='.jobs["add-to-project"]'
CONV='.jobs.conventions'
NEEDS='.jobs.needs'

# --- untrusted data and checkout ---
eq "no title/body expressions" 0 "$(grep -cE '\$\{\{[^}]*github\.event\.(issue|pull_request|comment)\.(title|body)' "$WF")"
eq "no step uses a checkout" 0 "$(q '[.jobs[].steps[].uses | select(. != null and test("^actions/checkout@"))] | length')"
eq "no run script expands an expression" 0 "$(q '[.jobs[].steps[].run | select(. != null and test("\$\{\{"))] | length')"
eq "jobs have no needs (fail independently)" 0 "$(q '[.jobs[] | select(has("needs"))] | length')"

# --- pins and permissions ---
atp_uses=$(q "$ATP.steps[] | select(.uses != null and (.uses | test(\"^actions/add-to-project@\"))) | .uses")
if [[ "$atp_uses" =~ ^actions/add-to-project@[0-9a-f]{40}$ ]]; then ok "add-to-project pinned by SHA"; else fail "add-to-project pinned by SHA ($atp_uses)"; fi
eq "top-level permissions empty" '{}' "$(qj '.permissions')"
eq "add-to-project permissions empty" '{}' "$(qj "$ATP.permissions")"
eq "conventions writes issues only" '{"issues":"write"}' "$(qj "$CONV.permissions")"
eq "conventions uses GITHUB_TOKEN" '${{ github.token }}' "$(q "$CONV.steps[0].with.token")"
eq "add-to-project uses GH_PAT" '${{ secrets.GH_PAT }}' "$(q "$ATP.steps[] | select(.with[\"github-token\"] != null) | .with[\"github-token\"]")"
eq "concurrency per issue" 'issue-conventions-${{ github.repository }}-${{ github.event.issue.number }}' "$(q "$CONV.concurrency.group")"
eq "concurrency does not cancel" false "$(q "$CONV.concurrency[\"cancel-in-progress\"]")"

# --- if: conditions ---
atp_if=$(q "$ATP.if")
conv_if=$(q "$CONV.if")
case "$atp_if" in "inputs.project-url != '' &&"*) ok "add-to-project off without project-url" ;; *) fail "add-to-project off without project-url" ;; esac
eq "add-to-project issue types" 'opened,reopened,transferred' "$(events issues "$atp_if")"
eq "add-to-project PR types" 'opened,reopened' "$(events pull_request_target "$atp_if")"
case "$conv_if" in *"github.event.issue.state == 'open'"*) ok "conventions only open issues" ;; *) fail "conventions only open issues" ;; esac
eq "conventions issue types" 'edited,labeled,opened,reopened,unlabeled' "$(events issues "$conv_if")"
eq "conventions ignores PRs" '' "$(events pull_request_target "$conv_if")"

# --- inputs ---
eq "inputs" 'apm-hub-ref,levels,mode,needs,project-url,required-sections' "$(q '.on.workflow_call.inputs | keys | sort | join(",")')"
eq "project-url default" '' "$(q '.on.workflow_call.inputs["project-url"].default')"
eq "levels default" 'epic,feature,pbi,task,bug' "$(q '.on.workflow_call.inputs.levels.default')"
eq "required-sections default" '{}' "$(q '.on.workflow_call.inputs["required-sections"].default')"
eq "GH_PAT optional" false "$(q '.on.workflow_call.secrets.GH_PAT.required')"
eq "needs input is boolean" boolean "$(q '.on.workflow_call.inputs.needs.type')"
eq "needs default false" false "$(q '.on.workflow_call.inputs.needs.default')"
eq "mode default event" event "$(q '.on.workflow_call.inputs.mode.default')"
eq "apm-hub-ref default empty" '' "$(q '.on.workflow_call.inputs["apm-hub-ref"].default')"
eq "PROJECT_TOKEN optional" false "$(q '.on.workflow_call.secrets.PROJECT_TOKEN.required')"
eq "secrets" 'GH_PAT,PROJECT_TOKEN' "$(q '.on.workflow_call.secrets | keys | sort | join(",")')"

# --- needs job ---
needs_if=$(q "$NEEDS.if")
case "$needs_if" in "inputs.needs && inputs.project-url != '' &&"*) ok "needs off unless inputs.needs and project-url" ;; *) fail "needs off unless inputs.needs and project-url" ;; esac
eq "needs issue types" 'closed,labeled,reopened,unlabeled' "$(events issues "$needs_if")"
eq "needs PR types" 'closed,opened,ready_for_review' "$(events pull_request_target "$needs_if")"
for branch in "inputs.mode == 'full'" "github.event_name == 'schedule'" "github.event_name == 'workflow_dispatch'"; do
  case "$needs_if" in *"$branch ||"*) ok "needs runs on $branch" ;; *) fail "needs runs on $branch" ;; esac
done
eq "needs permissions empty" '{}' "$(qj "$NEEDS.permissions")"
eq "needs concurrency per issue/PR/event" \
  'project-needs-${{ github.repository }}-${{ github.event.issue.number || github.event.pull_request.number || github.event_name }}' \
  "$(q "$NEEDS.concurrency.group")"
eq "needs concurrency cancels" true "$(q "$NEEDS.concurrency[\"cancel-in-progress\"]")"
eq "needs has one step" 1 "$(q "$NEEDS.steps | length")"
eq "needs uses project/needs" 'GravionLabs/ci/project/needs@main' "$(q "$NEEDS.steps[0].uses")"
eq "needs token PROJECT_TOKEN, else GH_PAT" '${{ secrets.PROJECT_TOKEN || secrets.GH_PAT }}' "$(q "$NEEDS.steps[0].with.token")"
eq "needs passes project-url, mode, apm-hub-ref" \
  'apm-hub-ref=${{ inputs.apm-hub-ref }},mode=${{ inputs.mode }},project-url=${{ inputs.project-url }}' \
  "$(q "$NEEDS.steps[0].with | del(.token) | to_entries | map(.key + \"=\" + .value) | sort | join(\",\")")"
eq "add-to-project skips schedule/dispatch" 0 "$(grep -cE "schedule|workflow_dispatch|inputs\.mode" <<<"$(q "$ATP.if")")"
eq "conventions skips schedule/dispatch" 0 "$(grep -cE "schedule|workflow_dispatch|inputs\.mode" <<<"$(q "$CONV.if")")"

# --- caller ---
eq "caller issue types are the union" 'closed,edited,labeled,opened,reopened,transferred,unlabeled' "$(q '.on.issues.types | sort | join(",")' "$CALLER")"
eq "caller PR types are the union" 'closed,opened,ready_for_review,reopened' "$(q '.on.pull_request_target.types | sort | join(",")' "$CALLER")"
eq "caller calls issues.yml" './.github/workflows/issues.yml' "$(q '.jobs.issues.uses' "$CALLER")"
eq "caller top-level permissions empty" '{}' "$(qj '.permissions' "$CALLER")"
eq "caller job grants issues: write only" '{"issues":"write"}' "$(qj '.jobs.issues.permissions' "$CALLER")"
eq "caller passes only GH_PAT and PROJECT_TOKEN" '{"GH_PAT":"${{ secrets.GH_PAT }}","PROJECT_TOKEN":"${{ secrets.PROJECT_TOKEN }}"}' "$(qj '.jobs.issues.secrets' "$CALLER")"
eq "caller enables needs" true "$(q '.jobs.issues.with.needs' "$CALLER")"
eq "caller keeps event mode" null "$(q '.jobs.issues.with.mode' "$CALLER")"

# --- scheduled caller ---
eq "scheduled caller runs hourly" '0 * * * *' "$(q '.on.schedule[0].cron' "$SCHED")"
eq "scheduled caller has one schedule" 1 "$(q '.on.schedule | length' "$SCHED")"
eq "scheduled caller on workflow_dispatch" true "$(q '.on | has("workflow_dispatch")' "$SCHED")"
eq "scheduled caller triggers" 'schedule,workflow_dispatch' "$(q '.on | keys | sort | join(",")' "$SCHED")"
eq "scheduled caller calls issues.yml" './.github/workflows/issues.yml' "$(q '.jobs.needs.uses' "$SCHED")"
eq "scheduled caller top-level permissions empty" '{}' "$(qj '.permissions' "$SCHED")"
eq "scheduled caller job grants issues: write only" '{"issues":"write"}' "$(qj '.jobs.needs.permissions' "$SCHED")"
eq "scheduled caller with" '{"project-url":"https://github.com/users/GravionLabs/projects/17","needs":true,"mode":"full"}' "$(qj '.jobs.needs.with' "$SCHED")"
eq "scheduled caller passes only GH_PAT and PROJECT_TOKEN" '{"GH_PAT":"${{ secrets.GH_PAT }}","PROJECT_TOKEN":"${{ secrets.PROJECT_TOKEN }}"}' "$(qj '.jobs.needs.secrets' "$SCHED")"

# --- token check step: run its script ---
script=$(q "$ATP.steps[] | select(.id == \"token\") | .run")
if [ -n "$script" ]; then ok "token check script found"; else fail "token check script found"; fi
eq "add step runs only with a token" "steps.token.outputs.present == 'true'" "$(q "$ATP.steps[] | select(.uses == \"$atp_uses\") | .if")"
check_token() {
  local file; file=$(mktemp)
  out=$(HAS_TOKEN="$1" GITHUB_OUTPUT="$file" bash -c "$script" 2>&1); code=$?
  output=$(cat "$file"); rm -f "$file"
}

check_token false
eq "no token: step green" 0 "$code"
eq "no token: exactly one warning" 1 "$(grep -c '^::warning::' <<<"$out")"
eq "no token: add step skipped" present=false "$output"

check_token true
eq "token: step green" 0 "$code"
eq "token: no warning" 0 "$(grep -c '::warning::' <<<"$out")"
eq "token: add step runs" present=true "$output"

check_token ''
eq "empty value: add step skipped" present=false "$output"

echo "$((total - failures))/$total passed"
[ "$failures" -eq 0 ]
