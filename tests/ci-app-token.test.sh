#!/usr/bin/env bash
# The GitHub App token wiring (#127): every workflow that used GH_PAT mints a token with actions/create-github-app-token
# (SHA-pinned with a version comment) and keeps a github.token fallback. Run: bash tests/ci-app-token.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
W="$ROOT/.github/workflows"
failures=0 total=0
ok()   { total=$((total + 1)); echo "ok   - $1"; }
fail() { total=$((total + 1)); failures=$((failures + 1)); echo "FAIL - $1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
q()    { yq -r "$1" "$2"; }
command -v yq >/dev/null || { echo "yq is required"; exit 1; }

PIN='actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510'
APP_ID='${{ secrets.CI_APP_ID }}'
KEY='${{ secrets.CI_APP_PRIVATE_KEY }}'
TOKEN_FALLBACK='${{ steps.app-token.outputs.token || secrets.GH_PAT || github.token }}'

for f in nuget-package python-package docker-package tauri-app release-branch; do
  file="$W/$f.yml"
  step='.. | select(has("id") and .id == "app-token")'
  eq "$f: mints the token with the pinned action" "$PIN" "$(q "[$step | .uses] | .[0]" "$file")"
  grep -qE "uses: actions/create-github-app-token@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$" "$file" && ok "$f: pin carries a version comment" || fail "$f: pin carries a version comment"
  eq "$f: app-id" "$APP_ID" "$(q "[$step | .with[\"app-id\"]] | .[0]" "$file")"
  eq "$f: private-key" "$KEY" "$(q "[$step | .with[\"private-key\"]] | .[0]" "$file")"
  # tauri-app also has a recreate-branch step (#138) that runs only with that input set; every app-token step must still require the secrets
  conds="$(q "[$step | .if] | .[]" "$file" | sed -E "s/^\\$\\{\\{ inputs\\.recreate-branch != '' && (.*) \\}\\}$/\\1/" | sort -u)"
  eq "$f: only when both secrets are set" "steps.app.outputs.present == 'true'" "$conds"
  eq "$f: CI_APP_ID is an optional secret" false "$(q '.on.workflow_call.secrets.CI_APP_ID.required' "$file")"
  eq "$f: CI_APP_PRIVATE_KEY is an optional secret" false "$(q '.on.workflow_call.secrets.CI_APP_PRIVATE_KEY.required' "$file")"
  eq "$f: GH_PAT stays an optional (deprecated) secret" false "$(q '.on.workflow_call.secrets.GH_PAT.required' "$file")"
done

for f in nuget-package python-package docker-package tauri-app; do
  eq "$f: token is app, else GH_PAT, else github.token" "$TOKEN_FALLBACK" "$(q '[.. | select(has("token")) | .token] | map(select(test("GH_PAT"))) | unique | .[0]' "$W/$f.yml")"
done

# ci.yml: the app, else github.token (this repository has no GH_PAT any more)
eq "ci.yml: release token is app, else github.token" '${{ steps.app-token.outputs.token || github.token }}' "$(q '.jobs.release.steps[] | select(.uses == "./versioning/gh-release") | .with.token' "$W/ci.yml")"
eq "ci.yml: mints the token" "$PIN" "$(q '.jobs.release.steps[] | select(.id == "app-token") | .uses' "$W/ci.yml")"
# the major tag is moved with the app token (#249): the app is created, and required, before the tag steps
R='.jobs.release.steps'
idx() { q "[$R | to_entries[] | select($1) | .key] | .[0]" "$W/ci.yml"; }
eq "ci.yml: move-major-tag pushes with the app token" '${{ steps.app-token.outputs.token }}' "$(q "$R[] | select(.uses == \"./versioning/move-major-tag\") | .with.token" "$W/ci.yml")"
[ "$(idx '.value.id == "app-token"')" -lt "$(idx '.value.uses == "./versioning/move-major-tag"')" ] && ok "ci.yml: the app token exists before the major tag moves" || fail "ci.yml: the app token exists before the major tag moves"
[ "$(idx '.value.id == "app-token"')" -lt "$(idx '.value.uses == "./versioning/create-version-tag"')" ] && ok "ci.yml: the release stops without the app before it tags" || fail "ci.yml: the release stops without the app before it tags"
eq "ci.yml: a release without the app fails with a message" "steps.app.outputs.present != 'true'" "$(q "$R[] | select(.name == \"Require CI app\") | .if" "$W/ci.yml")"
eq "ci.yml: no GH_PAT in the code" 0 "$(grep -v '^ *#' "$W/ci.yml" | grep -c GH_PAT)"

# renovate runs as the app
eq "renovate: mints the token" "$PIN" "$(q '.jobs.renovate.steps[] | select(.id == "app-token") | .uses' "$W/renovate.yml")"
eq "renovate: uses the app token" '${{ steps.app-token.outputs.token }}' "$(q '.jobs.renovate.steps[] | select(.uses | test("^renovatebot/")) | .with.token' "$W/renovate.yml")"
eq "renovate: no GH_PAT in the code" 0 "$(grep -v '^ *#' "$W/renovate.yml" | grep -c GH_PAT)"
# without a repository Renovate ends green and does nothing (#250)
eq "renovate: names its repository" '${{ github.repository }}' "$(q '.jobs.renovate.steps[] | select(.uses | test("^renovatebot/")) | .env.RENOVATE_REPOSITORIES' "$W/renovate.yml")"
eq "renovate: pull requests target release/next" 'release/next' "$(jq -r '.baseBranchPatterns[0]' "$ROOT/renovate.json")"

# the project callers pass only PROJECT_TOKEN (a GitHub App cannot write to a user-owned project)
for f in issue-events project-needs; do
  eq "$f.yml: no GH_PAT in the code" 0 "$(grep -v '^ *#' "$W/$f.yml" | grep -c GH_PAT)"
done

echo "$((total - failures))/$total passed"
[ "$failures" -eq 0 ]
