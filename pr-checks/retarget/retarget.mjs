export const WORK_BRANCH = /^(feat|refactor|chore|docs|test|perf|build|ci)\/\d+-/;

/** True for a work branch (`<type>/<nr>-<slug>`); `release/**` and `fix/**` (hotfix) are not. */
export function isWorkBranch(ref) {
  return WORK_BRANCH.test(ref ?? '');
}

/**
 * Decides what to do with a PR: `skip` (nothing to do, with a reason), `retarget` or `missing` (target branch absent).
 * Only a same-repository work branch aimed at the default branch is moved.
 */
export function retargetDecision({ headRef, baseRef, defaultBranch, sameRepo = true, targetExists, target = 'release/next' }) {
  if (baseRef !== defaultBranch) return { action: 'skip', reason: `base is ${baseRef}, not the default branch` };
  if (!sameRepo) return { action: 'skip', reason: 'PR from a fork' };
  if (!isWorkBranch(headRef)) return { action: 'skip', reason: `${headRef} is not a work branch` };
  return targetExists ? { action: 'retarget', target } : { action: 'missing', target };
}

export function missingMessage(target, defaultBranch, number) {
  return (
    `Work branches belong into ${target}, but it does not exist. Create it from ${defaultBranch} ` +
    `(\`git push origin origin/${defaultBranch}:refs/heads/${target}\`), then run ` +
    `\`gh pr edit ${number} --base ${target}\`.`
  );
}

export function retargetComment(from, to) {
  return `Retargeted from \`${from}\` to \`${to}\`: work branches are merged into \`${to}\`; only release PRs and hotfixes (\`fix/<nr>-<slug>\`) go to \`${from}\`.`;
}
