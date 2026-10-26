#!/usr/bin/env bash
# Invariants of the reusable workflow .github/workflows/issues.yml and its caller issue-events.yml.
# Run: bash tests/issues-workflow.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WF="$ROOT/.github/workflows/issues.yml"
CALLER="$ROOT/.github/workflows/issue-events.yml"
failures=0 total=0

ok()   { total=$((total + 1)); echo "ok   - $1"; }
fail() { total=$((total + 1)); failures=$((failures + 1)); echo "FAIL - $1"; }
has()   { if grep -qF -- "$2" "$3"; then ok "$1"; else fail "$1 (missing: $2)"; fi; }
hasnt() { if grep -qE -- "$2" "$3"; then fail "$1 (unexpected: $(grep -nE -- "$2" "$3" | head -1))"; else ok "$1"; fi; }

# --- untrusted data and checkout ---
hasnt "no title/body expressions" 'github\.event\.(issue|pull_request|comment)\.(title|body)' "$WF"
hasnt "no checkout" 'actions/checkout' "$WF"
hasnt "no job dependencies (jobs fail independently)" '^[[:space:]]+needs:' "$WF"
hasnt "no run step expands an expression" 'run:.*\$\{\{' "$WF"

# --- pins and permissions ---
if grep -qE 'uses: actions/add-to-project@[0-9a-f]{40}( |$)' "$WF"; then ok "add-to-project pinned by SHA"; else fail "add-to-project pinned by SHA"; fi
if grep -qx 'permissions: {}' "$WF"; then ok "top-level permissions empty"; else fail "top-level permissions empty"; fi
has "conventions writes issues only" '      issues: write' "$WF"
has "conventions uses GITHUB_TOKEN" 'token: ${{ github.token }}' "$WF"
has "add-to-project uses GH_PAT" 'github-token: ${{ secrets.GH_PAT }}' "$WF"
has "concurrency per issue" 'group: issue-conventions-${{ github.repository }}-${{ github.event.issue.number }}' "$WF"
has "concurrency does not cancel" 'cancel-in-progress: false' "$WF"

# --- if: conditions ---
has "add-to-project off without project-url" "inputs.project-url != ''" "$WF"
has "add-to-project issue types" "github.event_name == 'issues' && contains(fromJSON('[\"opened\",\"reopened\",\"transferred\"]'), github.event.action)" "$WF"
has "add-to-project PR types" "github.event_name == 'pull_request_target' && contains(fromJSON('[\"opened\",\"reopened\"]'), github.event.action)" "$WF"
has "conventions only open issues" "github.event_name == 'issues' && github.event.issue.state == 'open'" "$WF"
has "conventions issue types" "contains(fromJSON('[\"opened\",\"edited\",\"labeled\",\"unlabeled\",\"reopened\"]'), github.event.action)" "$WF"

# --- inputs ---
for input in 'project-url:' 'required-sections:' 'levels:' 'GH_PAT:'; do has "declares $input" "      $input" "$WF"; done
has "levels default" "default: 'epic,feature,pbi,task,bug'" "$WF"
has "required-sections default" "default: '{}'" "$WF"

# --- caller ---
has "caller issue types are the union" 'types: [opened, reopened, transferred, edited, labeled, unlabeled]' "$CALLER"
has "caller PR types" 'types: [opened, reopened]' "$CALLER"
has "caller calls issues.yml" 'uses: ./.github/workflows/issues.yml' "$CALLER"
has "caller grants issues: write" '  issues: write' "$CALLER"
hasnt "caller checks out nothing" 'actions/checkout' "$CALLER"

# --- token check step: run its script ---
script=$(awk '/- name: Check GH_PAT/{f=1} f&&/run: \|/{r=1; next} r&&/^[[:space:]]*$/{exit} r{sub(/^          /, ""); print}' "$WF")
if [ -n "$script" ]; then ok "token check script found"; else fail "token check script found"; fi
check_token() { GITHUB_OUTPUT=$(mktemp); out=$(HAS_TOKEN="$1" GITHUB_OUTPUT="$GITHUB_OUTPUT" bash -c "$script" 2>&1); code=$?; output=$(cat "$GITHUB_OUTPUT"); rm -f "$GITHUB_OUTPUT"; }

check_token false
[ "$code" = 0 ] && ok "no token: step green" || fail "no token: step green (exit $code)"
c=$(grep -c '^::warning::' <<<"$out"); [ "$c" = 1 ] && ok "no token: exactly one warning" || fail "no token: exactly one warning (got $c)"
[ "$output" = "present=false" ] && ok "no token: add step skipped" || fail "no token: add step skipped (output: $output)"

check_token true
[ "$code" = 0 ] && ok "token: step green" || fail "token: step green (exit $code)"
grep -q '::warning::' <<<"$out" && fail "token: no warning" || ok "token: no warning"
[ "$output" = "present=true" ] && ok "token: add step runs" || fail "token: add step runs (output: $output)"

check_token ''
[ "$output" = "present=false" ] && ok "empty value: add step skipped" || fail "empty value: add step skipped (output: $output)"

echo "$((total - failures))/$total passed"
[ "$failures" -eq 0 ]
