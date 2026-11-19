#!/usr/bin/env bash
# Secrets and inputs reach the scripts through env (#242): a `run:` block of a composite action.yml must not expand
# `${{ inputs.*token* }}`, `${{ inputs.*key* }}` or `${{ inputs.*password* }}` (or `secrets.*`) into the script text.
# A quote or `$(` in such a value would change the script and the value would show up in the script text.
# Run: bash tests/action-secrets-env.test.sh [<root>]   (root: a directory to check instead of the repository, for the self-test)
set -uo pipefail

ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd)}

# Prints `file:line: text` for every secret-like expression inside a `run:` block.
offenders() {
  local root=$1
  find "$root" -name action.yml -not -path '*/node_modules/*' -not -path '*/.claude/*' -not -path '*/.git/*' | sort \
    | while IFS= read -r file; do
      awk -v f="${file#"$root"/}" '
        function indent(s) { match(s, /^ */); return RLENGTH }
        {
          line = $0
          if (inrun && line !~ /^[[:space:]]*$/ && indent(line) <= runindent) inrun = 0
          if (!inrun && match(line, /^[[:space:]]*(- )?run:/)) {
            runindent = indent(line) + (line ~ /^[[:space:]]*- run:/ ? 2 : 0)
            rest = line; sub(/^[[:space:]]*(- )?run:[[:space:]]*/, "", rest)
            if (rest ~ /^[|>][-+]?$/) { inrun = 1; next }
            check = rest
          } else if (inrun) check = line
          else next
          if (check ~ /\$\{\{[^}]*(inputs\.[A-Za-z0-9_-]*(token|key|password)[A-Za-z0-9_-]*|secrets\.[A-Za-z0-9_-]+)/)
            printf "%s:%d: %s\n", f, NR, line
        }' "$file"
    done
}

if [ $# -eq 0 ]; then
  failures=0
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/a" "$tmp/b" "$tmp/c"
  printf '%s\n' 'runs:' '  steps:' '    - name: x' '      shell: bash' '      run: |' '        echo "${{ inputs.npm-token }}"' > "$tmp/a/action.yml"
  printf '%s\n' 'runs:' '  steps:' '    - shell: bash' '      run: echo ${{ inputs.api-key }}' > "$tmp/b/action.yml"
  printf '%s\n' 'runs:' '  steps:' '    - name: ok' '      shell: bash' '      env:' '        T: ${{ inputs.token }}' '      run: |' '        echo "$T"' '        echo "${{ inputs.docs-path }}"' > "$tmp/c/action.yml"
  found=$(offenders "$tmp" | wc -l | tr -d ' ')
  if [ "$found" = 2 ]; then echo "ok   - self-test: block and one-line run expansions are reported, env use is not"
  else echo "FAIL - self-test: expected 2 findings, got $found"; offenders "$tmp"; failures=1; fi

  out=$(offenders "$ROOT")
  if [ -z "$out" ]; then echo "ok   - no run block expands a token, key, password or secret"
  else echo "FAIL - run blocks that expand a token, key, password or secret:"; echo "$out"; failures=1; fi
  exit $failures
fi

out=$(offenders "$ROOT")
[ -z "$out" ] || { echo "$out"; exit 1; }
