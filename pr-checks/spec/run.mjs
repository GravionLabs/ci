import { findMissing, readSpecConfig, specOptOut } from './spec.mjs';

const status = (error) => error?.status ?? error?.message;

/** Checks that a PR changing files under a `governance.specMap` glob also changes the mapped spec. */
export default async function run({ github, context, core }) {
  const { owner, repo } = context.repo;
  const pull_number = context.payload.pull_request.number;
  const summary = async (text) => core.summary.addHeading('Spec', 3).addRaw(`${text}\n`).write();
  const skip = async (text) => {
    core.notice(text);
    await summary(text);
  };

  const { data: pr } = await github.rest.pulls.get({ owner, repo, pull_number });
  const baseRef = pr.base.ref;

  let config;
  try {
    const { data } = await github.rest.repos.getContent({ owner, repo, path: '.agents/config.json', ref: baseRef });
    config = JSON.parse(Buffer.from(data.content ?? '', 'base64').toString('utf8'));
  } catch (error) {
    if (error.status === 404) return skip(`No .agents/config.json on ${baseRef}; spec check skipped.`);
    const message = `.agents/config.json of ${baseRef} cannot be read (${status(error)})`;
    await summary(`Problems:\n\n- ${message}`);
    return core.setFailed(message);
  }
  const spec = readSpecConfig(config);
  if (!spec) return skip(`No governance.specMap in .agents/config.json of ${baseRef}; spec check skipped.`);

  let files;
  try {
    files = await github.paginate(github.rest.pulls.listFiles, { owner, repo, pull_number, per_page: 100 });
  } catch (error) {
    const message = `The changed files cannot be read (${status(error)})`;
    await summary(`Problems:\n\n- ${message}`);
    return core.setFailed(message);
  }

  const missing = findMissing(files, spec.entries);
  if (missing.length === 0) return summary('Spec up to date: no mapped file changed without its spec.');

  const lines = missing.map(
    (m) => `- \`${m.glob}\` changed (${m.files.join(', ')}) but ${m.specs.join(', ')} did not`,
  );
  const optOut = specOptOut(pr.body);
  if (spec.mode === 'warn' || optOut) {
    const reason = spec.mode === 'warn' ? 'specMode is warn' : 'the PR body says "no spec change needed"';
    for (const m of missing) {
      core.warning(`Spec not changed: ${m.files.join(', ')} under ${m.glob}; expected a change in ${m.specs.join(', ')}`);
    }
    return summary(`Spec warnings (${reason}):\n\n${lines.join('\n')}`);
  }
  await summary(`Problems:\n\n${lines.join('\n')}\n\nAdd the line "no spec change needed" to the PR body if none is required.`);
  core.setFailed(`Spec check failed:\n${lines.join('\n')}`);
}
