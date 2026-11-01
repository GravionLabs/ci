// Pure rules of the spec job: the spec map, ignored files, the opt-out line.
import { matchPaths } from '../adr/adr.mjs';

export const SPEC_MODES = ['warn', 'require'];

/** Tests and Markdown files do not count as a change that needs a spec. */
export function isIgnored(name) {
  return (
    /\.md$/i.test(name) ||
    /(^|\/)(tests?|__tests__|specs?)\//i.test(name) ||
    /\.(test|spec)\.[^./]+$/i.test(name) ||
    /(^|\/)[^/]*(_test|\.Tests?)\.[^/]+$/.test(name) ||
    /(^|\/)[^/]*\.Tests?\//.test(name)
  );
}

/** A line of the PR body: "no spec change needed", optionally as list item or ticked checkbox, with a reason after it. */
export function specOptOut(body) {
  return /^[ \t]*(?:[-*][ \t]+)?(?:\[[xX]\][ \t]+)?no spec change needed\b/im.test(body ?? '');
}

/**
 * Reads `governance.specMap` (glob -> spec path or list of spec paths) and `specMode`; null without a usable map.
 * A mode other than warn or require falls back to warn.
 */
export function readSpecConfig(config) {
  const g = config?.governance;
  const map = g?.specMap;
  if (!map || typeof map !== 'object' || Array.isArray(map)) return null;
  const entries = Object.entries(map)
    .map(([glob, spec]) => ({ glob, specs: (Array.isArray(spec) ? spec : [spec]).filter(Boolean).map(String) }))
    .filter((entry) => entry.specs.length);
  if (entries.length === 0) return null;
  const mode = SPEC_MODES.includes(g.specMode) ? g.specMode : 'warn';
  return { entries, mode };
}

/**
 * Entries with a counted changed file but none of the mapped specs changed.
 * `files` are the API file objects; a removed file still counts as touched.
 */
export function findMissing(files, entries) {
  const names = files.map((file) => file.filename);
  const counted = names.filter((name) => !isIgnored(name));
  const missing = [];
  for (const { glob, specs } of entries) {
    const changed = matchPaths(counted, [glob]).filter((name) => !specs.includes(name));
    if (changed.length === 0) continue;
    if (specs.some((spec) => names.includes(spec))) continue;
    missing.push({ glob, specs, files: changed });
  }
  return missing;
}
