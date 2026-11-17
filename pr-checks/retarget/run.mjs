import { missingMessage, retargetComment, retargetDecision } from './retarget.mjs';

/** Moves a work-branch PR aimed at the default branch to the release branch; fails when that branch is missing. */
export default async function run({ github, context, core, inputs }) {
  const { owner, repo } = context.repo;
  const pull_number = context.payload.pull_request.number;
  const target = inputs.releaseBranch || 'release/next';
  const { data: pr } = await github.rest.pulls.get({ owner, repo, pull_number });
  const defaultBranch = pr.base.repo?.default_branch ?? context.payload.repository?.default_branch;
  const sameRepo = !!pr.head.repo && pr.head.repo.full_name === pr.base.repo?.full_name;
  const summary = async (text) => core.summary.addHeading('PR target', 3).addRaw(`${text}\n`).write();

  const early = retargetDecision({
    headRef: pr.head.ref,
    baseRef: pr.base.ref,
    defaultBranch,
    sameRepo,
    targetExists: true,
    target,
  });
  if (early.action === 'skip') {
    await summary(`Unchanged: ${early.reason}.`);
    return;
  }

  const targetExists = await github.rest.repos
    .getBranch({ owner, repo, branch: target })
    .then(() => true, (error) => {
      if (error.status === 404) return false;
      throw error;
    });
  const decision = retargetDecision({
    headRef: pr.head.ref,
    baseRef: pr.base.ref,
    defaultBranch,
    sameRepo,
    targetExists,
    target,
  });
  if (decision.action === 'missing') {
    const message = missingMessage(target, defaultBranch, pull_number);
    await summary(`Not retargeted: ${message}`);
    core.setFailed(message);
    return;
  }

  await github.rest.pulls.update({ owner, repo, pull_number, base: target });
  await github.rest.issues.createComment({
    owner,
    repo,
    issue_number: pull_number,
    body: retargetComment(pr.base.ref, target),
  });
  await summary(`Retargeted from ${pr.base.ref} to ${target}.`);
  core.notice(`Retargeted PR #${pull_number} from ${pr.base.ref} to ${target}.`);
}
