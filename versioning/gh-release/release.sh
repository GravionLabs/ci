#!/usr/bin/env bash
# Creates the GitHub Release of TAG; skips when it exists (safe re-run of a half-done release).
# Rate-limit errors are retried after the reset (rate-limit.sh).
# With an SBOM (SBOM=true and SBOM_GIVEN or SBOM_GENERATED exists) the release is created as a draft with the SBOM
# as asset and published afterwards: a published release of an immutable-releases repository accepts no upload.
# A draft left by an earlier run is completed (asset uploaded, then published).
# Env: TAG, VERSION, NOTES, CLIFF_NOTES, GENERATE_NOTES, GH_TOKEN, SBOM, SBOM_GIVEN, SBOM_GENERATED.
set -uo pipefail
. "$(dirname "$0")/rate-limit.sh"

sbom_src=""
if [ "${SBOM:-}" = "true" ]; then
  if [ -n "${SBOM_GIVEN:-}" ]; then sbom_src=$SBOM_GIVEN; else sbom_src=${SBOM_GENERATED:-}; fi
  if [ -z "$sbom_src" ] || [ ! -f "$sbom_src" ]; then
    echo "::warning::No SBOM file at '${sbom_src}'; the release is created without one."
    sbom_src=""
  fi
fi
asset=()
if [ -n "$sbom_src" ]; then
  # The asset is named sbom.spdx.json whatever the source file is called.
  sbom_dir=$(mktemp -d); cp "$sbom_src" "$sbom_dir/sbom.spdx.json"
  asset=("$sbom_dir/sbom.spdx.json")
fi

if gh_retry gh release view "$TAG" >/dev/null 2>&1; then
  draft=$(gh_retry gh release view "$TAG" --json isDraft --jq .isDraft 2>/dev/null || echo false)
  if [ "$draft" = "true" ]; then
    echo "Release $TAG is a draft of an earlier run — completing it."
    if [ ${#asset[@]} -gt 0 ]; then gh_retry gh release upload "$TAG" "${asset[@]}" --clobber; fi
    gh_retry gh release edit "$TAG" --draft=false
    exit 0
  fi
  echo "Release $TAG already exists — skipping."
  exit 0
fi

flags=()
if echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+-'; then flags+=(--prerelease); fi
if [ ${#asset[@]} -gt 0 ]; then flags+=(--draft); fi

if [ -n "${CLIFF_NOTES:-}" ]; then
  notes_file=$(mktemp)
  printf '%s\n' "$CLIFF_NOTES" > "$notes_file"
  gh_retry gh release create "$TAG" ${asset[@]+"${asset[@]}"} --title "$TAG" --notes-file "$notes_file" ${flags[@]+"${flags[@]}"} || exit 1
elif [ -n "${NOTES:-}" ]; then
  gh_retry gh release create "$TAG" ${asset[@]+"${asset[@]}"} --title "$TAG" --notes "$NOTES" ${flags[@]+"${flags[@]}"} || exit 1
elif [ "${GENERATE_NOTES:-}" = "true" ]; then
  gh_retry gh release create "$TAG" ${asset[@]+"${asset[@]}"} --title "$TAG" --generate-notes ${flags[@]+"${flags[@]}"} || exit 1
else
  gh_retry gh release create "$TAG" ${asset[@]+"${asset[@]}"} --title "$TAG" --notes "" ${flags[@]+"${flags[@]}"} || exit 1
fi

if [ ${#asset[@]} -gt 0 ]; then gh_retry gh release edit "$TAG" --draft=false; fi
