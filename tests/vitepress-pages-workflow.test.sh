#!/usr/bin/env bash
# Invariants of the reusable workflow .github/workflows/vitepress-pages.yml, read structurally with yq (mikefarah).
# Run: bash tests/vitepress-pages-workflow.test.sh
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WF="$ROOT/.github/workflows/vitepress-pages.yml"
failures=0 total=0

ok()   { total=$((total + 1)); echo "ok   - $1"; }
fail() { total=$((total + 1)); failures=$((failures + 1)); echo "FAIL - $1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
q()    { yq -r "$1" "$WF"; }

command -v yq >/dev/null || { echo "yq is required"; exit 1; }

eq "inputs" 'deploy,package-manager,pre-build,site-path' "$(q '.on.workflow_call.inputs | keys | sort | join(",")')"
eq "site-path default" 'site' "$(q '.on.workflow_call.inputs["site-path"].default')"
eq "package-manager default" 'npm' "$(q '.on.workflow_call.inputs["package-manager"].default')"
eq "pre-build optional, empty default" '' "$(q '.on.workflow_call.inputs["pre-build"].default')"
eq "deploy is a boolean defaulting to true" 'boolean true' "$(q '.on.workflow_call.inputs.deploy | .type + " " + (.default | tostring)')"
eq "no required input" 0 "$(q '[.on.workflow_call.inputs[] | select(.required == true)] | length')"

eq "top-level permissions" 'read' "$(q '.permissions.contents')"
eq "deploy permissions" 'pages: write id-token: write' "$(q '.jobs.deploy.permissions | "pages: " + .pages + " id-token: " + .["id-token"]')"
eq "deploy environment" 'github-pages' "$(q '.jobs.deploy.environment.name')"
eq "deploy needs build" 'build' "$(q '.jobs.deploy.needs')"
eq "deploy only on push to main with deploy" "inputs.deploy && github.event_name == 'push' && github.ref == 'refs/heads/main'" "$(q '.jobs.deploy.if')"
eq "upload only on push to main with deploy" "inputs.deploy && github.event_name == 'push' && github.ref == 'refs/heads/main'" "$(q '.jobs.build.steps[] | select(.name == "Upload the site") | .if')"
eq "upload path" '${{ inputs.site-path }}/.vitepress/dist' "$(q '.jobs.build.steps[] | select(.name == "Upload the site") | .with.path')"
eq "node version from .nvmrc" '.nvmrc' "$(q '.jobs.build.steps[] | select(.uses != null and (.uses | test("setup-node"))) | .with["node-version-file"]')"
eq "SITE_BASE" '/${{ github.event.repository.name }}/' "$(q '.jobs.build.env.SITE_BASE')"
DEPLOY="inputs.deploy && github.event_name == 'push' && github.ref == 'refs/heads/main'"
eq "deploy runs share the group pages-deploy, others use their ref" "\${{ (\$DEPLOY) && 'deploy' || github.ref }}" "$(q '.concurrency.group' | sed 's/^pages-//')"
eq "only non-deploy runs cancel" "\${{ !(\$DEPLOY) }}" "$(q '.concurrency["cancel-in-progress"]')"
inst=$(q '.jobs.build.steps[] | select(.name == "Install") | .run')
case "$inst" in *"pnpm install --frozen-lockfile"*"npm ci"*) ok "installs with the lockfile" ;; *) fail "installs with the lockfile" ;; esac
eq "third-party actions pinned to SHAs" 0 "$(q '[.jobs[].steps[].uses | select(. != null and (test("@[0-9a-f]{40}( |$)") | not))] | length')"
eq "no input expanded in a run script" 0 "$(q '[.jobs[].steps[].run | select(. != null and test("\$\{\{"))] | length')"

pnpm_step='.jobs.build.steps[] | select(.uses != null and (.uses | test("pnpm/action-setup")))'
eq "pnpm setup pinned to the v4 commit" 'pnpm/action-setup@b906affcce14559ad1aafd4ab0e942779e9f58b1' "$(q "$pnpm_step | .uses" | sed 's/ #.*//')"
eq "pnpm setup reads the packageManager field of the site" '${{ inputs.site-path }}/package.json' "$(q "$pnpm_step | .with.package_json_file")"

echo "$((total - failures))/$total passed"
[ "$failures" -eq 0 ]
