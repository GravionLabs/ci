#!/usr/bin/env bash
# Third-party actions are pinned (#240): every `uses:` of an action outside GravionLabs, in the workflows and in every
# composite action.yml, names a full commit SHA followed by the version as a comment (`owner/action@<sha> # v1.2.3`).
# A tag can be moved by the owner of the action; the next run would then execute new code with the callers' secrets.
# Local actions (`./...`) and this repository's own actions (major tag) are checked by tests/self-references.test.sh.
# Run: bash tests/pinned-actions.test.sh [<root>]   (root: a directory to check instead of the repository, for the self-test)
set -uo pipefail

ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd)}
PINNED='@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$'

# Prints `file:line: text` for every foreign `uses:` that is not pinned.
unpinned() {
  local root=$1
  { find "$root/.github/workflows" -name '*.yml' 2>/dev/null
    find "$root" -name action.yml -not -path '*/node_modules/*' -not -path '*/.claude/*' -not -path '*/.git/*'
  } | sort | while IFS= read -r file; do
    grep -nE '^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]' "$file" \
      | grep -vE 'uses:[[:space:]]+(\./|GravionLabs/)' \
      | grep -vE "$PINNED" \
      | sed "s|^|${file#"$root"/}:|"
  done
}

if [ $# -eq 0 ]; then
  failures=0
  # Self-test: the check must find the forms it exists for.
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/.github/workflows" "$tmp/x"
  printf '%s\n' 'jobs:' '  a:' '    steps:' \
    '      - uses: actions/checkout@v4' \
    '      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262' \
    '      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4' \
    '      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0' \
    '      - uses: ./local' \
    '      - uses: GravionLabs/ci/node/setup@v1' > "$tmp/.github/workflows/w.yml"
  printf '%s\n' 'runs:' '  steps:' '    - name: x' '      uses: some/action@main' > "$tmp/x/action.yml"
  found=$(unpinned "$tmp" | wc -l | tr -d ' ')
  if [ "$found" = 4 ]; then echo "ok   - self-test: tag, bare SHA, major-only comment and branch are reported"
  else echo "FAIL - self-test: expected 4 findings, got $found"; unpinned "$tmp"; failures=1; fi

  out=$(unpinned "$ROOT")
  if [ -z "$out" ]; then echo "ok   - every third-party action is pinned to a commit SHA with a version comment"
  else echo "FAIL - third-party actions without a commit SHA and version comment:"; echo "$out"; failures=1; fi
  exit $failures
fi

out=$(unpinned "$ROOT")
[ -z "$out" ] || { echo "$out"; exit 1; }
