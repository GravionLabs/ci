#!/usr/bin/env bash
# Tests for the composite action project/reopen-status: reopen-status.sh against a stub gh that serves a fixture of the
# GraphQL response and records the mutation, plus structural invariants of action.yml read with yq (mikefarah).
# Run: bash tests/project-reopen-status.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ACTION="$ROOT/project/reopen-status/action.yml"
SCRIPT="$ROOT/project/reopen-status/reopen-status.sh"
failures=0 total=0

ok()   { total=$((total + 1)); echo "ok   - $1"; }
fail() { total=$((total + 1)); failures=$((failures + 1)); echo "FAIL - $1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
has()  { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else fail "$1 (missing: $2)"; fi; }

command -v yq >/dev/null || { echo "yq is required"; exit 1; }
command -v jq >/dev/null || { echo "jq is required"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/bin"
# stub gh: a query prints $FIXTURE (or fails when GH_FAIL_QUERY=1); a mutation is appended to $MUTATIONS (fails when GH_FAIL_MUTATION=1)
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"updateProjectV2ItemFieldValue"* ]]; then
  [ "${GH_FAIL_MUTATION:-0}" = 1 ] && { echo "boom"; exit 1; }
  echo "$args" >> "$MUTATIONS"
  echo '{"data":{}}'
else
  [ "${GH_FAIL_QUERY:-0}" = 1 ] && { echo "bad credentials"; exit 1; }
  cat "$FIXTURE"
fi
STUB
chmod +x "$TMP/bin/gh"

# fixture STATUS [NUMBER] [OWNER] [TODO_NAME]: GraphQL response with two project items of the issue
fixture() {
  local status=$1 num=${2:-17} owner=${3:-GravionLabs} todo=${4:-Todo}
  local value="null"
  [ -n "$status" ] && value="{\"name\":\"$status\"}"
  cat <<JSON
{"data":{"repository":{"issue":{"projectItems":{"nodes":[
 {"id":"ITEM_OTHER","project":{"id":"PVT_OTHER","number":3,"owner":{"login":"GravionLabs"},"field":{"id":"F_OTHER","options":[{"id":"O1","name":"Todo"}]}},"fieldValueByName":{"name":"Done"}},
 {"id":"ITEM_1","project":{"id":"PVT_1","number":$num,"owner":{"login":"$owner"},"field":{"id":"FIELD_STATUS","options":[{"id":"OPT_TODO","name":"$todo"},{"id":"OPT_PROG","name":"In Progress"},{"id":"OPT_DONE","name":"Done"}]}},"fieldValueByName":$value}
]}}}}}
JSON
}

# run_script VAR=value ... : fixture in $TMP/fx.json; sets out, code and mutations
run_script() {
  : > "$TMP/mutations"
  out=$(env -i PATH="$TMP/bin:$PATH" FIXTURE="$TMP/fx.json" MUTATIONS="$TMP/mutations" \
    PROJECT_URL=https://github.com/users/GravionLabs/projects/17 GH_REPO=GravionLabs/ci ISSUE_NUMBER=228 "$@" bash "$SCRIPT" 2>&1)
  code=$?
  mutations=$(cat "$TMP/mutations")
}

echo "# status reset"
fixture Done > "$TMP/fx.json"
run_script
eq "Done: exit 0" 0 "$code"
has "Done: mutation targets project" "p=PVT_1" "$mutations"
has "Done: mutation targets item" "i=ITEM_1" "$mutations"
has "Done: mutation targets Status field" "f=FIELD_STATUS" "$mutations"
has "Done: mutation sets Todo option" "o=OPT_TODO" "$mutations"
eq "Done: exactly one mutation" 1 "$(grep -c . "$TMP/mutations")"

for s in Todo "In Progress"; do
  fixture "$s" > "$TMP/fx.json"
  run_script
  eq "$s stays: exit 0" 0 "$code"
  eq "$s stays: no mutation" "" "$mutations"
done
fixture "" > "$TMP/fx.json"
run_script
eq "unset status stays: no mutation" "" "$mutations"
eq "unset status: exit 0" 0 "$code"

echo "# not in the project"
fixture Done 99 > "$TMP/fx.json"
run_script
eq "other project number: no mutation" "" "$mutations"
eq "other project number: exit 0" 0 "$code"
fixture Done 17 SomeoneElse > "$TMP/fx.json"
run_script
eq "other project owner: no mutation" "" "$mutations"
echo '{"data":{"repository":{"issue":{"projectItems":{"nodes":[]}}}}}' > "$TMP/fx.json"
run_script
eq "issue without items: exit 0" 0 "$code"
eq "issue without items: no mutation" "" "$mutations"
echo '{"data":{"repository":{"issue":null}}}' > "$TMP/fx.json"
run_script
eq "unknown issue: exit 0" 0 "$code"
fixture Done 17 gravionlabs > "$TMP/fx.json"
run_script
has "owner compared case-insensitively" "i=ITEM_1" "$mutations"

echo "# project without Todo / API errors"
fixture Done 17 GravionLabs Backlog > "$TMP/fx.json"
run_script
eq "no Todo option: no mutation" "" "$mutations"
has "no Todo option: warning" "::warning::" "$out"
eq "no Todo option: exit 0" 0 "$code"
fixture Done > "$TMP/fx.json"
run_script GH_FAIL_QUERY=1
has "query failure: warning" "::warning::Reading the project item" "$out"
eq "query failure: exit 0" 0 "$code"
run_script GH_FAIL_MUTATION=1
has "mutation failure: warning" "::warning::Setting Status Todo" "$out"
eq "mutation failure: exit 0" 0 "$code"

echo "# invalid input"
run_script PROJECT_URL=https://example.com/x
eq "bad project-url: exit 1" 1 "$code"
run_script ISSUE_NUMBER=abc
eq "bad issue number: exit 1" 1 "$code"
run_script GH_REPO=nope
eq "bad repo: exit 1" 1 "$code"

echo "# action.yml"
q() { yq -r "$1" "$ACTION"; }
eq "inputs" 'project-url,token' "$(q '.inputs | keys | sort | join(",")')"
eq "project-url required" true "$(q '.inputs["project-url"].required')"
eq "composite" composite "$(q '.runs.using')"
eq "reset step only with a token" "steps.token.outputs.present == 'true'" "$(q '.runs.steps[1].if')"
eq "no expression in run scripts" 0 "$(q '[.runs.steps[].run | select(. != null and test("\$\{\{"))] | length')"
has "no token warns" "::warning::No token" "$(q '.runs.steps[0].run')"

echo
echo "$((total - failures))/$total passed"
[ "$failures" -eq 0 ]
