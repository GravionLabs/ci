#!/usr/bin/env bash
# Invariants of rust/setup/action.yml: the Linux apt packages come from a pinned cache action.
# Run: bash tests/rust-setup.test.sh
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
A="$ROOT/rust/setup/action.yml"
failures=0
eq() { if [ "$2" = "$3" ]; then echo "ok   - $1"; else echo "FAIL - $1 (expected '$2', got '$3')"; failures=$((failures + 1)); fi; }
command -v yq >/dev/null || { echo "yq is required"; exit 1; }
q() { yq -r "$1" "$A"; }

eq "cache action pinned to a full SHA" 1 "$(q '[.runs.steps[].uses | select(. != null and test("^awalsh128/cache-apt-pkgs-action@[0-9a-f]{40}$"))] | length')"
eq "no direct apt-get install left" 0 "$(q '[.runs.steps[].run | select(. != null and test("apt-get install"))] | length')"
eq "cache step skipped without packages" "\${{ steps.apt.outputs.packages != '' }}" "$(q '.runs.steps[] | select(.name == "Install Linux packages (cached)") | .if')"
eq "list step linux only" 1 "$(q '[.runs.steps[] | select(.id == "apt") | .if | select(test("runner.os == .Linux."))] | length')"
eq "list step covers tauri deps and extra packages" 1 "$(q '[.runs.steps[] | select(.id == "apt") | .if | select(test("tauri-linux-deps") and test("linux-packages"))] | length')"
eq "cache version input default" v1 "$(q '.inputs["apt-cache-version"].default')"
eq "cache version is the key of runner os, image and apt-cache-version" '${{ steps.aptkey.outputs.key }}' "$(q '.runs.steps[] | select(.uses != null and (.uses | test("cache-apt"))) | .with.version')"
eq "key step passes apt-cache-version via env" '${{ inputs.apt-cache-version }}' "$(q '.runs.steps[] | select(.id == "aptkey") | .env.APT_CACHE_VERSION')"
eq "key step comes before the cache step" yes "$(q '([.runs.steps | to_entries[] | select(.value.id == "aptkey") | .key][0]) as $k | ([.runs.steps | to_entries[] | select(.value.uses != null and (.value.uses | test("cache-apt"))) | .key][0]) as $c | if $k < $c then "yes" else "no" end')"
eq "key step has the same if as the cache step" 1 "$(q '[.runs.steps[] | select(.id == "aptkey" or (.uses != null and (.uses | test("cache-apt")))) | .if] | unique | length')"

# apt-cache-version is passed through the wrappers
W="$ROOT/.github/workflows/tauri-app.yml"
for f in rust/ci/action.yml tauri/installers/action.yml; do
  eq "$f has apt-cache-version default v1" v1 "$(yq -r '.inputs["apt-cache-version"].default' "$ROOT/$f")"
  eq "$f forwards apt-cache-version to rust/setup" '${{ inputs.apt-cache-version }}' "$(yq -r '.runs.steps[] | select(.uses != null and (.uses | test("rust/setup"))) | .with["apt-cache-version"]' "$ROOT/$f")"
done
eq "tauri-app.yml input apt-cache-version" v1 "$(yq -r '.on.workflow_call.inputs["apt-cache-version"].default' "$W")"
eq "tauri-app.yml forwards to rust/ci" '${{ inputs.apt-cache-version }}' "$(yq -r '.jobs[].steps[]? | select(.uses != null and (.uses | test("rust/ci"))) | .with["apt-cache-version"]' "$W")"
eq "tauri-app.yml forwards to tauri/installers" '${{ inputs.apt-cache-version }}' "$(yq -r '.jobs[].steps[]? | select(.uses != null and (.uses | test("tauri/installers"))) | .with["apt-cache-version"]' "$W")"
key=$(q '.runs.steps[] | select(.id == "aptkey") | .run')
keyrun() { local out; out=$(mktemp); RUNNER_OS=$1 ImageOS=$2 APT_CACHE_VERSION=$3 GITHUB_OUTPUT=$out bash -c "$key"; cat "$out"; rm -f "$out"; }
eq "key has os, image and version" "key=Linux-ubuntu24-v1" "$(keyrun Linux ubuntu24 v1)"
eq "key differs per image" "key=Linux-ubuntu22-v1" "$(keyrun Linux ubuntu22 v1)"
eq "key without ImageOS" "key=Linux-unknown-v2" "$(keyrun Linux '' v2)"

# the package list script, run for real
step=$(q '.runs.steps[] | select(.id == "apt") | .run')
run() { local out; out=$(mktemp); TAURI=$1 EXTRA=$2 GITHUB_OUTPUT=$out bash -c "$step"; cat "$out"; rm -f "$out"; }
tauri="libwebkit2gtk-4.1-dev build-essential libssl-dev libayatana-appindicator3-dev librsvg2-dev patchelf libxdo-dev"
eq "extra only" "packages=libfoo-dev" "$(run false 'libfoo-dev')"
eq "tauri plus extra" "packages=$tauri libfoo-dev" "$(run true ' libfoo-dev ')"
eq "tauri only" "packages=$tauri" "$(run true '')"

[ "$failures" -eq 0 ] || { echo "$failures failed"; exit 1; }
