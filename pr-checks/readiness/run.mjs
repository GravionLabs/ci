import { closingRefs, isReleaseBranch, parseLabels, readinessProblems } from './readiness.mjs';

/** Checks that the issues a PR closes are ready; fails the job with every problem listed. */
export default async function run({ github, context, core, inputs }) {
  const { owner, repo } = context.repo;
  const pull_number = context.payload.pull_request.number;
  // Re-read the PR: an edited body is not in the payload of a synchronize event.
  const { data: pr } = await github.rest.pulls.get({ owner, repo, pull_number });
  const refs = closingRefs(pr.body);

  const summary = async (text) =>
    core.summary.addHeading('PR readiness', 3).addRaw(`${text}\n`).write();

  if (refs.length === 0) {
    if (inputs.requireIssue && !isReleaseBranch(pr.head.ref)) {
      const message = 'This PR closes no issue: add "Closes #n" to its body.';
      await summary(`Not ready:\n\n- ${message}`);
      core.setFailed(message);
    } else {
      core.notice('This PR closes no issue (no "Closes #n" in its body); nothing to check.');
      await summary('No closing issue; nothing to check.');
    }
    return;
  }

  const notReadyLabels = parseLabels(inputs.notReadyLabels);
  const problems = [];
  for (const issue_number of refs) {
    const { data: issue } = await github.rest.issues
      .get({ owner, repo, issue_number })
      .catch(() => ({ data: null }));
    if (!issue) {
      problems.push(`#${issue_number} does not exist or cannot be read`);
      continue;
    }
    if (issue.pull_request) continue;
    let blockers;
    try {
      ({ data: blockers } = await github.request(
        'GET /repos/{owner}/{repo}/issues/{issue_number}/dependencies/blocked_by',
        { owner, repo, issue_number },
      ));
    } catch (error) {
      problems.push(`#${issue_number}: the blocked-by issues cannot be read (${error.status ?? error.message})`);
      blockers = [];
    }
    problems.push(...readinessProblems(issue, blockers, notReadyLabels));
  }

  const lines = problems.map((problem) => `- ${problem}`).join('\n');
  await summary(
    problems.length ? `Not ready:\n\n${lines}` : `Ready: ${refs.map((n) => `#${n}`).join(', ')}`,
  );
  if (problems.length) core.setFailed(`Issues closed by this PR are not ready:\n${lines}`);
}
