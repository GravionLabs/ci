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
