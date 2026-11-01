#!/usr/bin/env bash
# Moves <prefix><major> to the commit of <prefix><version> and force-pushes it to origin.
# Env: VERSION (required), TAG_PREFIX (default v), GITHUB_OUTPUT (optional).
set -euo pipefail

VERSION=${VERSION:?VERSION is required}
TAG_PREFIX=${TAG_PREFIX-v}
out() { if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1" >> "$GITHUB_OUTPUT"; fi; }

if ! [[ "$VERSION" =~ ^([0-9]+)\.[0-9]+\.[0-9]+(-.+)?(\+.+)?$ ]]; then
  echo "::error::'$VERSION' is not a semantic version"
  exit 1
fi
MAJOR=${BASH_REMATCH[1]}
if [ -n "${BASH_REMATCH[2]}" ]; then
  echo "$VERSION is a pre-release — major tag not moved."
  out "major-tag="
  exit 0
fi

RELEASE_TAG="${TAG_PREFIX}${VERSION}"
MAJOR_TAG="${TAG_PREFIX}${MAJOR}"
if ! COMMIT=$(git rev-parse --verify --quiet "refs/tags/${RELEASE_TAG}^{commit}"); then
  echo "::error::release tag $RELEASE_TAG does not exist; run create-version-tag first"
  exit 1
fi

if [ "$(git ls-remote --tags origin "refs/tags/${MAJOR_TAG}" | cut -f1)" = "$COMMIT" ]; then
  echo "$MAJOR_TAG already points to $RELEASE_TAG ($COMMIT)."
else
  git tag -f "$MAJOR_TAG" "$COMMIT" >/dev/null
  git push -f origin "refs/tags/${MAJOR_TAG}"
  echo "Moved $MAJOR_TAG to $RELEASE_TAG ($COMMIT)."
fi
out "major-tag=$MAJOR_TAG"
