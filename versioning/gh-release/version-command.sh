#!/usr/bin/env bash
# Runs the caller's version command with VERSION set. Env: COMMAND, VERSION.
set -euo pipefail
[ -n "${COMMAND:-}" ] || { echo "No version-command — skipping."; exit 0; }
export VERSION
bash -c "$COMMAND"
