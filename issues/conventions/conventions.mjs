// Issue conventions: the pure checks behind the issues/conventions action (no I/O).

const KNOWN_LEVELS = { epic: 'Epic', feature: 'Feature', pbi: 'PBI', task: 'Task', bug: 'Bug' };

export const MARKER = '<!-- gravionlabs-ci:issue-conventions -->';
export const NEEDS_REFINEMENT = 'needs-refinement';

/** Map level label -> display name from a CSV; the CSV order is the precedence order. */
export function parseLevels(csv) {
  const levels = {};
  for (const raw of String(csv ?? '').split(',')) {
    const label = raw.trim().toLowerCase();
    if (!label || label in levels) continue;
    levels[label] = KNOWN_LEVELS[label] ?? label.charAt(0).toUpperCase() + label.slice(1);
  }
  return levels;
}

/** The level label from the issue's labels (names or `{ name }` objects), or `null` when it has none. */
export function levelOf(labels, levels) {
  const names = new Set(
    (labels ?? []).map((label) => String(typeof label === 'string' ? label : label?.name).toLowerCase()),
  );
  return Object.keys(levels).find((level) => names.has(level)) ?? null;
}

/** The title with exactly one `[Level] ` prefix; other leading `[...]` and legacy prefixes are dropped. */
export function expectedTitle(title, level, levels) {
  let rest = title;
  for (;;) {
    const next = rest.replace(/^\s*(?:\[[^\]]*\]|(?:epic|feature|bug):)\s*/i, '');
    if (next === rest) break;
    rest = next;
  }
  rest = rest.trim();
  return rest ? `[${levels[level]}] ${rest}` : `[${levels[level]}]`;
}

/** Map level -> required headings from JSON; empty input means no section check. */
export function parseRequiredSections(json) {
  if (json == null || String(json).trim() === '') return {};
  let parsed;
  try {
    parsed = JSON.parse(json);
  } catch (error) {
    throw new Error(`Invalid required-sections JSON: ${error.message}`);
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('Invalid required-sections JSON: expected an object of level -> headings');
  }
  for (const [level, headings] of Object.entries(parsed)) {
    if (!Array.isArray(headings) || headings.some((h) => typeof h !== 'string')) {
      throw new Error(`Invalid required-sections JSON: "${level}" must be an array of heading strings`);
    }
  }
  return parsed;
}

/** The required headings (`## Name` to `#### Name`) that the body lacks, case-insensitive. */
export function missingSections(body, level, required) {
  const headings = new Set(
    [...(body ?? '').matchAll(/^#{2,4}\s+(.+?)\s*$/gm)].map((match) => match[1].toLowerCase()),
  );
  return (required[level] ?? []).filter((name) => !headings.has(name.toLowerCase()));
}

/** The comment once the issue's level requires no sections any more (level label changed or removed). */
export const NO_SECTIONS_BODY = `${MARKER}\nNo sections are required for this issue any more.`;

/** The comment for an issue that misses sections, or that has them all again. */
export function commentBody(levelName, missing) {
  if (missing.length === 0) {
    return `${MARKER}\nAll required sections for a ${levelName} are present. Thanks!`;
  }
  const list = missing.map((name) => `- \`### ${name}\``).join('\n');
  return `${MARKER}
This ${levelName} is missing required sections:

${list}

It is labeled \`${NEEDS_REFINEMENT}\` until they are added.`;
}

// --- Milestone rule: an Epic has no milestone; a Feature's open sub-issues share the Feature's milestone ---

export const MILESTONE_MARKER = '<!-- gravionlabs-ci:milestone-rule -->';
export const MILESTONE_RESOLVED_BODY = `${MILESTONE_MARKER}\nAll open sub-issues are in the milestone of this Feature now (milestone rule). Thanks!`;

/** `owner/repo` of an issue payload from `repository_url`, or `fallback` when absent. */
function repoOf(issue, fallback) {
  const match = /\/repos\/([^/]+\/[^/]+)$/.exec(issue?.repository_url ?? '');
  return match ? match[1] : fallback;
}

/**
 * The open sub-issues of a Feature that lie outside its milestone (other milestone, none, or another
 * repository), as `owner/repo#n (milestone|none)` strings. A Feature without milestone has no violations.
 */
export function milestoneViolations(issue, subIssues, repoFullName) {
  const milestone = issue?.milestone;
  if (!milestone) return [];
  return (subIssues ?? [])
    .filter((sub) => sub.state !== 'closed')
    .filter((sub) => repoOf(sub, repoFullName) !== repoFullName || sub.milestone?.number !== milestone.number)
    .map((sub) => `${repoOf(sub, repoFullName)}#${sub.number} (${sub.milestone?.title ?? 'none'})`);
}

/** The comment of a Feature whose sub-issues lie outside its milestone, or the resolved text when none do. */
export function milestoneCommentBody(milestoneTitle, violations) {
  if (violations.length === 0) return MILESTONE_RESOLVED_BODY;
  const list = violations.map((v) => `- ${v}`).join('\n');
  return `${MILESTONE_MARKER}
This Feature is in milestone ${milestoneTitle}, but these open sub-issues are not (milestone rule):

${list}`;
}

/** The comment after an Epic's milestone was removed. */
export function epicMilestoneBody(milestoneTitle) {
  return `${MILESTONE_MARKER}\nAn Epic never has a milestone (milestone rule), removed ${milestoneTitle}.`;
}
