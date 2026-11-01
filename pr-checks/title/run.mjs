import { checksEveryCommit, isExempt, titleProblems } from './title.mjs';

/** Checks the PR title and its commits; fails the job with every problem listed. */
export default async function run({ github, context, core }) {
  const { owner, repo } = context.repo;
  const pull_number = context.payload.pull_request.number;
  // Re-read the PR: an edited title is not in the payload of a synchronize event.
  const { data: pr } = await github.rest.pulls.get({ owner, repo, pull_number });
  const defaultBranch = pr.base.repo?.default_branch ?? context.payload.repository?.default_branch;

  const summary = async (text) => core.summary.addHeading('PR title', 3).addRaw(`${text}\n`).write();

  const sameRepo = !!pr.head.repo && pr.head.repo.full_name === pr.base.repo?.full_name;

  if (isExempt(pr.head.ref, defaultBranch, sameRepo)) {
    core.notice(`PR from ${pr.head.ref} is exempt from the title check.`);
    await summary('Exempt (release or merge-back PR).');
    return;
  }

  // The API lists at most 250 commits of a PR, even paginated; later commits are not checked.
  const commits = (
    await github.paginate(github.rest.pulls.listCommits, { owner, repo, pull_number, per_page: 100 })
  ).map((item) => ({
    sha: item.sha,
    message: item.commit.message,
    parents: item.parents?.length ?? 1,
  }));
  const everyCommit = checksEveryCommit(pr.base.ref, pr.head.ref, defaultBranch, sameRepo);
  const problems = titleProblems(pr.title, commits, { everyCommit });

  const lines = problems.map((problem) => `- ${problem}`).join('\n');
  await summary(problems.length ? `Not valid:\n\n${lines}` : `Valid: ${pr.title}`);
  if (problems.length) core.setFailed(`The title or commits are not valid:\n${lines}`);
}
