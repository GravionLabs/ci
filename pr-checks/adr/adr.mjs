// Pure rules of the adr job: globs, ADR files, numbering and the Status line.

export const DEFAULT_SKIP_LABELS = ['skip-adr'];
export const ADR_STATUSES = ['Proposed', 'Accepted', 'Superseded', 'Deprecated'];

/** Glob to RegExp: `**` any depth, `*` within a segment, `?` one character; a leading `**\/` also matches the root. */
export function globToRegExp(glob) {
  let source = '';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*' && glob[i + 1] === '*') {
      if (glob[i + 2] === '/') {
        source += '(?:.*/)?';
        i += 2;
      } else {
        source += '.*';
        i += 1;
      }
    } else if (c === '*') source += '[^/]*';
    else if (c === '?') source += '[^/]';
    else source += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp(`^${source}$`);
}

/** The names that match at least one glob. */
export function matchPaths(names, globs) {
  const patterns = globs.map(globToRegExp);
  return names.filter((name) => patterns.some((pattern) => pattern.test(name)));
}

const trimDir = (dir) => String(dir).replace(/^\.?\//, '').replace(/\/+$/, '');

/** `<adrDir>/<name>.md`, directly inside the directory. */
export function isAdrFile(name, adrDir) {
  const dir = trimDir(adrDir);
  return name.startsWith(`${dir}/`) && /^[^/]+\.md$/.test(name.slice(dir.length + 1));
}

/** The leading number of an ADR file name (`0007-use-x.md` is 7), or null. */
export function adrNumber(name) {
  const match = /^(\d+)/.exec(name.split('/').pop());
  return match ? Number(match[1]) : null;
}

/**
 * Classifies the files of a PR (`{ filename, status, previous_filename }` of the API). A renamed file counts by its
 * new name; a removed file counts as neither added nor changed but still touches its path.
 */
export function classifyFiles(files, adrDir) {
  const touched = files.map((file) => file.filename);
  const present = files.filter((file) => file.status !== 'removed');
  const adrFiles = present.filter((file) => isAdrFile(file.filename, adrDir));
  const created = adrFiles.filter(
    (file) =>
      file.status === 'added' ||
      (file.status === 'renamed' && !isAdrFile(file.previous_filename ?? '', adrDir)),
  );
  return { touched, adrFiles: adrFiles.map((f) => f.filename), newAdrFiles: created.map((f) => f.filename) };
}

/** The Status line of an ADR (`Status: Accepted`, `**Status:** Accepted`, `- Status: Proposed`) or a problem. */
export function statusProblem(name, content) {
  const match = /^[\s>*_-]*Status\s*:?\**\s*:?\s*\**\s*([A-Za-z]+)/im.exec(content ?? '');
  const options = ADR_STATUSES.join(', ');
  if (!match) return `${name} has no \`Status:\` line (${options})`;
  if (!ADR_STATUSES.some((s) => s.toLowerCase() === match[1].toLowerCase())) {
    return `${name} has the status \`${match[1]}\`, expected one of ${options}`;
  }
  return null;
}

/** Number problems of the new ADR files against the numbers already used on the base branch. */
export function numberProblems(newNames, baseNames) {
  const used = new Map();
  for (const name of baseNames) {
    const n = adrNumber(name);
    if (n !== null) used.set(n, name);
  }
  const next = Math.max(0, ...used.keys()) + 1;
  const problems = [];
  const seen = new Map();
  for (const name of newNames) {
    const n = adrNumber(name);
    if (n === null) {
      problems.push(`${name} has no number prefix; the next free number is ${next}`);
    } else if (used.has(n)) {
      problems.push(`${name} duplicates the number ${n} of ${used.get(n)} on the base branch; the next free number is ${next}`);
    } else if (seen.has(n)) {
      problems.push(`${name} duplicates the number ${n} of ${seen.get(n)} in this PR`);
    }
    if (n !== null) seen.set(n, name);
  }
  return problems;
}

/** Reads `governance` of the config; null when ADRs are not configured. */
export function readGovernance(config) {
  const g = config?.governance;
  if (!g || !Array.isArray(g.adrPaths) || g.adrPaths.length === 0) return null;
  const skipLabels =
    Array.isArray(g.skipLabels) && g.skipLabels.length ? g.skipLabels.map(String) : DEFAULT_SKIP_LABELS;
  return { adrPaths: g.adrPaths.map(String), adrDir: g.adrDir ? String(g.adrDir) : '', skipLabels };
}
