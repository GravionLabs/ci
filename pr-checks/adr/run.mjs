import { closingRefs } from '../readiness/readiness.mjs';
import {
  classifyFiles,
  matchPaths,
  numberProblems,
  readGovernance,
  statusProblem,
} from './adr.mjs';

const status = (error) => error?.status ?? error?.message;

/** Checks that a PR touching `governance.adrPaths` (or closing a `needs-decision` issue) carries an ADR. */
export default async function run({ github, context, core }) {
  const { owner, repo } = context.repo;
  const pull_number = context.payload.pull_request.number;
  const summary = async (text) => core.summary.addHeading('ADR', 3).addRaw(`${text}\n`).write();
  const skip = async (text) => {
    core.notice(text);
    await summary(text);
  };
  const decode = (data) => Buffer.from(data.content ?? '', 'base64').toString('utf8');

  const { data: pr } = await github.rest.pulls.get({ owner, repo, pull_number });
  const baseRef = pr.base.ref;

  let config;
  try {
    const { data } = await github.rest.repos.getContent({ owner, repo, path: '.agents/config.json', ref: baseRef });
    config = JSON.parse(decode(data));
  } catch (error) {
    if (error.status === 404) return skip(`No .agents/config.json on ${baseRef}; ADR check skipped.`);
    const message = `.agents/config.json of ${baseRef} cannot be read (${status(error)})`;
    await summary(`Problems:\n\n- ${message}`);
    return core.setFailed(message);
  }
  const governance = readGovernance(config);
  if (!governance) return skip(`No governance.adrPaths in .agents/config.json of ${baseRef}; ADR check skipped.`);

  const labels = (pr.labels ?? []).map((label) => (typeof label === 'string' ? label : label.name));
  const skipped = governance.skipLabels.filter((name) => labels.includes(name));
  if (skipped.length) return skip(`Skipped by the label \`${skipped[0]}\`.`);

  const problems = [];
  const fail = async () => {
    const lines = problems.map((problem) => `- ${problem}`).join('\n');
    await summary(`Problems:\n\n${lines}`);
    core.setFailed(`ADR check failed:\n${lines}`);
  };
  if (!governance.adrDir) {
    problems.push('governance.adrDir is missing in .agents/config.json');
    return fail();
  }

  let files;
  try {
    files = await github.paginate(github.rest.pulls.listFiles, { owner, repo, pull_number, per_page: 100 });
  } catch (error) {
    problems.push(`The changed files cannot be read (${status(error)})`);
    return fail();
  }
  const { touched, adrFiles, newAdrFiles } = classifyFiles(files, governance.adrDir);
  const matched = matchPaths(touched, governance.adrPaths);

  const decisions = [];
  for (const issue_number of closingRefs(pr.body)) {
    try {
      const { data: issue } = await github.rest.issues.get({ owner, repo, issue_number });
      const names = (issue.labels ?? []).map((label) => (typeof label === 'string' ? label : label.name));
      if (!issue.pull_request && names.includes('needs-decision')) decisions.push(issue_number);
    } catch (error) {
      problems.push(`#${issue_number} cannot be read (${status(error)})`);
    }
  }

  if (adrFiles.length === 0) {
    if (matched.length) {
      problems.push(
        `No added or changed ${governance.adrDir}/*.md although the PR touches ${governance.adrPaths.join(', ')}: ${matched.join(', ')}`,
      );
    }
    if (decisions.length) {
      problems.push(
        `${decisions.map((n) => `#${n}`).join(', ')} ${decisions.length > 1 ? 'have' : 'has'} the label \`needs-decision\` and need an ADR in ${governance.adrDir}/*.md`,
      );
    }
  }

  if (newAdrFiles.length) {
    const head = pr.head.repo ?? { owner: { login: owner }, name: repo };
    for (const name of newAdrFiles) {
      try {
        const { data } = await github.rest.repos.getContent({
          owner: head.owner.login,
          repo: head.name,
          path: name,
          ref: pr.head.sha,
        });
        const problem = statusProblem(name, decode(data));
        if (problem) problems.push(problem);
      } catch (error) {
        problems.push(`${name} cannot be read (${status(error)})`);
      }
    }
    try {
      const { data } = await github.rest.repos.getContent({ owner, repo, path: governance.adrDir, ref: baseRef });
      problems.push(...numberProblems(newAdrFiles, data.map((entry) => `${governance.adrDir}/${entry.name}`)));
    } catch (error) {
      if (error.status === 404) problems.push(...numberProblems(newAdrFiles, []));
      else problems.push(`${governance.adrDir} of ${baseRef} cannot be read (${status(error)})`);
    }
  }

  if (problems.length) return fail();
  if (adrFiles.length) return summary(`ADR present: ${adrFiles.join(', ')}`);
  return summary('No ADR required: no matched path, no closed issue with `needs-decision`.');
}
