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
eq "cache version reaches the action" '${{ inputs.apt-cache-version }}' "$(q '.runs.steps[] | select(.uses != null and (.uses | test("cache-apt"))) | .with.version')"

# the package list script, run for real
step=$(q '.runs.steps[] | select(.id == "apt") | .run')
run() { local out; out=$(mktemp); TAURI=$1 EXTRA=$2 GITHUB_OUTPUT=$out bash -c "$step"; cat "$out"; rm -f "$out"; }
tauri="libwebkit2gtk-4.1-dev build-essential libssl-dev libayatana-appindicator3-dev librsvg2-dev patchelf libxdo-dev"
eq "extra only" "packages=libfoo-dev" "$(run false 'libfoo-dev')"
eq "tauri plus extra" "packages=$tauri libfoo-dev" "$(run true ' libfoo-dev ')"
eq "tauri only" "packages=$tauri" "$(run true '')"

[ "$failures" -eq 0 ] || { echo "$failures failed"; exit 1; }
