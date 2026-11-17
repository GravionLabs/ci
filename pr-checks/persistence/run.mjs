import { adrStatus, describe, findHits, markerOf } from './persistence.mjs';

const status = (error) => error?.status ?? error?.message;

const RULE =
  'GravionLabs apps never install background persistence (scheduled tasks, Run keys, autostart, services, ' +
  'LaunchAgents, systemd timers, cron) and installers never start a script host. ' +
  'Exception only with an ADR accepted on the base branch, referenced in the file as `persistence-allowed: <path of the ADR>`.';

/** Fails a PR whose added lines install background persistence, unless the file references an accepted ADR. */
export default async function run({ github, context, core }) {
  const { owner, repo } = context.repo;
  const pull_number = context.payload.pull_request.number;
  const summary = async (text) => core.summary.addHeading('Persistence', 3).addRaw(`${text}\n`).write();

  const { data: pr } = await github.rest.pulls.get({ owner, repo, pull_number });
  const head = { owner: pr.head.repo?.owner?.login ?? owner, repo: pr.head.repo?.name ?? repo, ref: pr.head.sha };

  let files;
  try {
    files = await github.paginate(github.rest.pulls.listFiles, { owner, repo, pull_number, per_page: 100 });
  } catch (error) {
    const message = `The changed files cannot be read (${status(error)})`;
    await summary(`Problems:\n\n- ${message}`);
    return core.setFailed(message);
  }

  // The file with the marker is read from the head; the ADR from the base, so a PR cannot accept its own exception.
  const base = { owner, repo, ref: pr.base.ref };
  const read = async (path, at = head) => {
    const { data } = await github.rest.repos.getContent({ ...at, path });
    return Buffer.from(data.content ?? '', 'base64').toString('utf8');
  };

  const problems = [];
  const allowed = [];
  const unscanned = [];
  for (const file of files) {
    if (file.status !== 'removed' && file.patch === undefined && file.changes > 0) unscanned.push(file.filename);
    const hits = findHits(file);
    if (hits.length === 0) continue;

    let content = '';
    try {
      content = await read(file.filename);
    } catch {
      // without the content no marker can be found; the hits stay problems
    }
    const adr = markerOf(content);
    if (adr) {
      let adrState;
      try {
        adrState = adrStatus(await read(adr, base));
      } catch (error) {
        adrState = error.status === 404 ? `missing on ${base.ref}` : `unreadable (${status(error)})`;
      }
      if (adrState && adrState.toLowerCase() === 'accepted') {
        allowed.push(`${file.filename} (${adr})`);
        continue;
      }
      problems.push(...hits.map((hit) => ({ hit, note: `marker ADR ${adr} is ${adrState ?? 'without Status'}, not Accepted` })));
      continue;
    }
    problems.push(...hits.map((hit) => ({ hit })));
  }

  for (const name of unscanned) core.warning(`Not scanned for persistence (no diff from the API, binary or too large): ${name}`);
  const notes = [
    allowed.length ? `Allowed by an accepted ADR:\n\n${allowed.map((a) => `- ${a}`).join('\n')}` : '',
    unscanned.length ? `Not scanned (no diff from the API):\n\n${unscanned.map((n) => `- ${n}`).join('\n')}` : '',
  ].filter(Boolean);

  if (problems.length === 0) {
    return summary(['No background persistence added.', ...notes].join('\n\n'));
  }

  const lines = problems.map(({ hit, note }) => `- ${describe(hit)}${note ? `; ${note}` : ''}`);
  for (const { hit, note } of problems) {
    core.error(`${hit.label} (${hit.match})${note ? `; ${note}` : ''}. ${RULE}`, {
      title: 'Background persistence',
      file: hit.file,
      ...(hit.line ? { startLine: hit.line } : {}),
    });
  }
  await summary([`Problems:\n\n${lines.join('\n')}`, RULE, ...notes].join('\n\n'));
  core.setFailed(`Persistence check failed:\n${lines.join('\n')}`);
}
