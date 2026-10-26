import {
  MARKER,
  NEEDS_REFINEMENT,
  commentBody,
  expectedTitle,
  levelOf,
  missingSections,
  parseLevels,
  parseRequiredSections,
} from './conventions.mjs';

/** Fixes the "[Level] " title prefix and flags issues that miss required sections. */
export default async function run({ github, context, core, inputs }) {
  const levels = parseLevels(inputs.levels);
  const required = parseRequiredSections(inputs.requiredSections);
  const { owner, repo } = context.repo;
  const issue_number = context.payload.issue.number;
  // Re-read the issue: the payload may be older than an edit made in the meantime.
  const { data: issue } = await github.rest.issues.get({ owner, repo, issue_number });

  const level = levelOf(issue.labels, levels);
  if (!level) {
    core.info('No level label; nothing to check.');
    return;
  }

  const title = expectedTitle(issue.title, level, levels);
  if (title !== issue.title) {
    await github.rest.issues.update({ owner, repo, issue_number, title });
    core.info(`Title: "${issue.title}" -> "${title}"`);
  }

  if (!required[level]) return;
  const missing = missingSections(issue.body, level, required);
  const labeled = issue.labels.some((l) => (l.name ?? l) === NEEDS_REFINEMENT);

  const comments = await github.paginate(github.rest.issues.listComments, {
    owner,
    repo,
    issue_number,
    per_page: 100,
  });
  const previous = comments.find((c) => c.user?.type === 'Bot' && c.body?.startsWith(MARKER));
  const body = commentBody(levels[level], missing);

  if (missing.length > 0) {
    await github.rest.issues
      .createLabel({
        owner,
        repo,
        name: NEEDS_REFINEMENT,
        color: 'FBCA04',
        description: 'Misses sections required by the issue conventions',
      })
      .catch((error) => {
        if (error.status !== 422) throw error;
      });
    if (!labeled) {
      await github.rest.issues.addLabels({ owner, repo, issue_number, labels: [NEEDS_REFINEMENT] });
    }
    if (!previous) await github.rest.issues.createComment({ owner, repo, issue_number, body });
    else if (previous.body !== body) {
      await github.rest.issues.updateComment({ owner, repo, comment_id: previous.id, body });
    }
    core.warning(`Missing sections: ${missing.join(', ')}`);
  } else {
    if (labeled) {
      await github.rest.issues.removeLabel({ owner, repo, issue_number, name: NEEDS_REFINEMENT });
    }
    if (previous && previous.body !== body) {
      await github.rest.issues.updateComment({ owner, repo, comment_id: previous.id, body });
    }
  }
}
