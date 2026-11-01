#!/usr/bin/env bash
# Creates the GitHub Release of TAG; skips when it exists (safe re-run of a half-done release).
# Rate-limit errors are retried after the reset (rate-limit.sh).
# Env: TAG, VERSION, NOTES, CLIFF_NOTES, GENERATE_NOTES, GH_TOKEN.
set -uo pipefail
. "$(dirname "$0")/rate-limit.sh"

if gh_retry gh release view "$TAG" >/dev/null 2>&1; then
  echo "Release $TAG already exists — skipping."
  exit 0
fi

flags=()
if echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+-'; then flags+=(--prerelease); fi

if [ -n "${CLIFF_NOTES:-}" ]; then
  notes_file=$(mktemp)
  printf '%s\n' "$CLIFF_NOTES" > "$notes_file"
  gh_retry gh release create "$TAG" --title "$TAG" --notes-file "$notes_file" ${flags[@]+"${flags[@]}"}
elif [ -n "${NOTES:-}" ]; then
  gh_retry gh release create "$TAG" --title "$TAG" --notes "$NOTES" ${flags[@]+"${flags[@]}"}
elif [ "${GENERATE_NOTES:-}" = "true" ]; then
  gh_retry gh release create "$TAG" --title "$TAG" --generate-notes ${flags[@]+"${flags[@]}"}
else
  gh_retry gh release create "$TAG" --title "$TAG" --notes "" ${flags[@]+"${flags[@]}"}
fi
