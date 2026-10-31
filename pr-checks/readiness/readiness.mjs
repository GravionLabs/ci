// Definition of ready: the pure rules of the readiness job (derived from elysion's pr-ready.mjs).

export const DEFAULT_NOT_READY_LABELS = 'needs-refinement,needs-decision';

/** Issue numbers the PR body closes with GitHub's keywords (`Closes #1`, `fixes: #2`, `Resolved #3`). */
export function closingRefs(body) {
  const refs = [
    ...(body ?? '').matchAll(/\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s+#(\d+)\b/gi),
  ];
  return [...new Set(refs.map((match) => Number(match[1])))];
}

/** Comma-separated list to trimmed, non-empty names; an empty input falls back to the default list. */
export function parseLabels(value) {
  const names = String(value ?? '')
    .split(',')
    .map((name) => name.trim())
    .filter(Boolean);
  return names.length ? names : DEFAULT_NOT_READY_LABELS.split(',');
}

/** Release PRs come from `release/<x.y>` or `release/next`; they carry the Closes lines of the release. */
export function isReleaseBranch(ref) {
  return /^release\//.test(ref ?? '');
}

/**
 * Why an issue is not ready to be closed by a PR: a not-ready label, or a "blocked by" issue that is
 * still open. `blockers` are the issues it is blocked by, each `{ number, state }`.
 */
export function readinessProblems(issue, blockers, notReadyLabels = parseLabels('')) {
  const labels = issue.labels.map((label) => (typeof label === 'string' ? label : label.name));
  return [
    ...notReadyLabels
      .filter((name) => labels.includes(name))
      .map((name) => `#${issue.number} has the label \`${name}\``),
    ...blockers
      .filter((blocker) => blocker.state === 'open')
      .map((blocker) => `#${issue.number} is blocked by #${blocker.number}, which is still open`),
  ];
}
