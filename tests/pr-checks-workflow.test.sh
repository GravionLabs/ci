#!/usr/bin/env bash
# Invariants of the reusable workflow .github/workflows/pr-checks.yml, read structurally with yq (mikefarah) and jq,
# plus the aggregate script of the job "PR checks" run against sample `needs` results.
# Run: bash tests/pr-checks-workflow.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WF="$ROOT/.github/workflows/pr-checks.yml"
failures=0 total=0

ok()   { total=$((total + 1)); echo "ok   - $1"; }
fail() { total=$((total + 1)); failures=$((failures + 1)); echo "FAIL - $1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
q()    { yq -r "$1" "$WF"; }
qj()   { yq -o=json -I=0 "$1" "$WF"; }

command -v yq >/dev/null || { echo "yq is required"; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }

# --- inputs ---
eq "inputs" 'adr,not-ready-labels,readiness,require-issue,spec' "$(q '.on.workflow_call.inputs | keys | sort | join(",")')"
for name in readiness adr spec require-issue; do
  eq "input $name is a boolean defaulting to true" 'boolean true' "$(q ".on.workflow_call.inputs[\"$name\"] | .type + \" \" + (.default | tostring)")"
done
eq "not-ready-labels default" 'needs-refinement,needs-decision' "$(q '.on.workflow_call.inputs["not-ready-labels"].default')"
eq "no secrets" 'null' "$(q '.on.workflow_call.secrets')"

# --- permissions ---
eq "top-level permissions empty" '{}' "$(qj '.permissions')"
eq "readiness permissions" '{"issues":"read","pull-requests":"read"}' "$(qj '.jobs.readiness.permissions')"
eq "adr permissions" '{"contents":"read","issues":"read","pull-requests":"read"}' "$(qj '.jobs.adr.permissions')"
eq "result permissions empty" '{}' "$(qj '.jobs.result.permissions')"
eq "every job sets permissions" 0 "$(q '[.jobs[] | select(has("permissions") | not)] | length')"

# --- untrusted data and checkout ---
eq "no checkout" 0 "$(q '[.jobs[].steps[].uses | select(. != null and test("^actions/checkout@"))] | length')"
eq "no run script expands an expression" 0 "$(q '[.jobs[].steps[].run | select(. != null and test("\$\{\{"))] | length')"
eq "no title/body expressions" 0 "$(grep -cE '\$\{\{[^}]*github\.event\.(issue|pull_request|comment)\.(title|body)' "$WF")"

# --- the aggregate ---
eq "result job name is PR checks" 'PR checks' "$(q '.jobs.result.name')"
eq "result runs always" 'always()' "$(q '.jobs.result.if')"
needs=$(q '.jobs | to_entries | map(select(.key != "result") | .key) | sort | join(",")')
eq "result needs every other job" "$needs" "$(q '.jobs.result.needs | sort | join(",")')"
eq "readiness is skipped by its input" 'inputs.readiness' "$(q '.jobs.readiness.if')"
eq "adr is skipped by its input" 'inputs.adr' "$(q '.jobs.adr.if')"

script=$(q '.jobs.result.steps[0].run')
aggregate() { NEEDS="$1" bash -c "$script" >/dev/null 2>&1; echo $?; }
eq "aggregate passes on success"  0 "$(aggregate '{"readiness":{"result":"success"}}')"
eq "aggregate passes on skipped"  0 "$(aggregate '{"readiness":{"result":"skipped"},"adr":{"result":"success"}}')"
eq "aggregate fails on failure"   1 "$(aggregate '{"readiness":{"result":"failure"}}')"
eq "aggregate fails on cancelled" 1 "$(aggregate '{"readiness":{"result":"success"},"adr":{"result":"cancelled"}}')"

echo
echo "$((total - failures))/$total passed"
[ "$failures" -eq 0 ]
