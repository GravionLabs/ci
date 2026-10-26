import {
  MARKER,
  NEEDS_REFINEMENT,
  NO_SECTIONS_BODY,
  commentBody,
  expectedTitle,
  levelOf,
  missingSections,
  parseLevels,
  parseRequiredSections,
} from './conventions.mjs';

/** Awaits a request and ignores the given HTTP status (e.g. a label that exists or is already gone). */
async function ignoring(status, request) {
  try {
    await request;
  } catch (error) {
    if (error.status !== status) throw error;
  }
}

/** Fixes the "[Level] " title prefix and flags issues that miss required sections. */
export default async function run({ github, context, core, inputs }) {
  const levels = parseLevels(inputs.levels);
  const required = parseRequiredSections(inputs.requiredSections);
  const { owner, repo } = context.repo;
  const issue_number = context.payload.issue.number;
  // Re-read the issue: the payload may be older than an edit made in the meantime.
  const { data: issue } = await github.rest.issues.get({ owner, repo, issue_number });

  const level = levelOf(issue.labels, levels);
  if (!level) core.info('No level label; title unchanged.');
  else {
    const title = expectedTitle(issue.title, level, levels);
    if (title !== issue.title) {
      await github.rest.issues.update({ owner, repo, issue_number, title });
      core.info(`Title: "${issue.title}" -> "${title}"`);
    }
  }

  const sections = level ? required[level] : undefined;
  const labeled = issue.labels.some((l) => (l.name ?? l) === NEEDS_REFINEMENT);
  if (!sections && !labeled) return;

  const comments = await github.paginate(github.rest.issues.listComments, {
    owner,
    repo,
    issue_number,
    per_page: 100,
  });
  const previous = comments.find((c) => c.user?.type === 'Bot' && c.body?.startsWith(MARKER));
  const removeLabel = () =>
    ignoring(404, github.rest.issues.removeLabel({ owner, repo, issue_number, name: NEEDS_REFINEMENT }));

  if (!sections) {
    // The level no longer requires sections: undo the label only when our comment shows we set it.
    if (previous?.body.includes(`labeled \`${NEEDS_REFINEMENT}\``)) {
      await removeLabel();
      await github.rest.issues.updateComment({ owner, repo, comment_id: previous.id, body: NO_SECTIONS_BODY });
    }
    return;
  }

  const missing = missingSections(issue.body, level, required);
  const body = commentBody(levels[level], missing);

  if (missing.length > 0) {
    if (!labeled) {
      // creates the repository label on first use; 422 = it exists already
      await ignoring(
        422,
        github.rest.issues.createLabel({
          owner,
          repo,
          name: NEEDS_REFINEMENT,
          color: 'FBCA04',
          description: 'Misses sections required by the issue conventions',
        }),
      );
      await github.rest.issues.addLabels({ owner, repo, issue_number, labels: [NEEDS_REFINEMENT] });
    }
    if (!previous) await github.rest.issues.createComment({ owner, repo, issue_number, body });
    else if (previous.body !== body) {
      await github.rest.issues.updateComment({ owner, repo, comment_id: previous.id, body });
    }
    core.warning(`Missing sections: ${missing.join(', ')}`);
  } else {
    if (labeled) await removeLabel();
    if (previous && previous.body !== body) {
      await github.rest.issues.updateComment({ owner, repo, comment_id: previous.id, body });
    }
  }
}
