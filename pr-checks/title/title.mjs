// Conventional Commit rules of the title job: the PR title and the commits of the PR (pure functions).

const TITLE = /^(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\([^)]+\))?(!)?: .+/;

/** Parses a title or commit subject; null when it is not a Conventional Commit. */
export function parseConventional(subject) {
  const match = TITLE.exec(subject ?? '');
  return match ? { type: match[1], breaking: match[3] === '!' } : null;
}

/** True when the commit message marks a breaking change: `!` after the type or a BREAKING CHANGE footer. */
export function isBreaking(message) {
  const [subject = '', ...rest] = String(message ?? '').split('\n');
  return parseConventional(subject)?.breaking === true || /^BREAKING[ -]CHANGE: /m.test(rest.join('\n'));
}

/** Release PRs (head release/**) and merge-back PRs (head is the default branch) are exempt. */
export function isExempt(headRef, defaultBranch) {
  return /^release\//.test(headRef ?? '') || (headRef ?? '') === defaultBranch;
}

/** Hotfix rule: a PR into the default branch from a branch other than release/** checks every commit. */
export function checksEveryCommit(baseRef, headRef, defaultBranch) {
  return baseRef === defaultBranch && !isExempt(headRef, defaultBranch);
}

/**
 * Problems of a PR title and its commits. `commits` are `{ sha, message, parents }` (`parents` is a count);
 * merge commits (more than one parent) are ignored. `everyCommit` makes non-conventional commits a problem.
 */
export function titleProblems(title, commits, { everyCommit = false } = {}) {
  const problems = [];
  const parsed = parseConventional(title);
  if (!parsed) {
    problems.push(
      `The title "${title}" is not a Conventional Commit: use \`type(scope)!: description\` with a type of build, chore, ci, docs, feat, fix, perf, refactor, revert, style, test.`,
    );
  }
  const own = (commits ?? []).filter((commit) => (commit.parents ?? 1) <= 1);
  for (const commit of own) {
    const subject = String(commit.message ?? '').split('\n')[0];
    const short = String(commit.sha ?? '').slice(0, 7);
    const conv = parseConventional(subject);
    if (!conv) {
      if (everyCommit) problems.push(`Commit ${short} "${subject}" is not a Conventional Commit.`);
      continue;
    }
    if (!parsed) continue;
    if (isBreaking(commit.message) && !parsed.breaking) {
      problems.push(`Commit ${short} "${subject}" is a breaking change: the title needs \`!\` after its type.`);
    }
    if (conv.type === 'feat' && parsed.type !== 'feat') {
      problems.push(`Commit ${short} "${subject}" is a feat: the title must be \`feat\`, not \`${parsed.type}\`.`);
    }
  }
  return problems;
}
