import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import run from '../../pr-checks/readiness/run.mjs';
import {
  closingRefs,
  isReleaseBranch,
  parseLabels,
  readinessProblems,
} from '../../pr-checks/readiness/readiness.mjs';

describe('closingRefs', () => {
  it('finds every closing keyword form, once per issue', () => {
    const body = 'Closes #407, closes #408\nFixes: #12 and resolved #13. Close #407 again.';
    assert.deepEqual(closingRefs(body), [407, 408, 12, 13]);
  });

  it('ignores mentions without a keyword and empty bodies', () => {
    assert.deepEqual(closingRefs('Relates to #5, see #6'), []);
    assert.deepEqual(closingRefs(null), []);
  });

  it('does not match inside other words', () => {
    assert.deepEqual(closingRefs('prefixes #3 and unclosed #4'), []);
  });
});

describe('readinessProblems', () => {
  const issue = (labels) => ({ number: 7, labels });

  it('is empty for a ready issue', () => {
    assert.deepEqual(readinessProblems(issue(['pbi']), [{ number: 3, state: 'closed' }]), []);
  });

  it('names both default not-ready labels', () => {
    assert.deepEqual(
      readinessProblems(issue([{ name: 'needs-refinement' }, 'needs-decision']), []),
      ['#7 has the label `needs-refinement`', '#7 has the label `needs-decision`'],
    );
  });

  it('names open blockers only', () => {
    const blockers = [
      { number: 3, state: 'open' },
      { number: 4, state: 'closed' },
    ];
    assert.deepEqual(readinessProblems(issue(['pbi']), blockers), [
      '#7 is blocked by #3, which is still open',
    ]);
  });

  it('uses the given not-ready labels instead of the defaults', () => {
    const labels = parseLabels('on-hold');
    assert.deepEqual(readinessProblems(issue(['needs-refinement', 'on-hold']), [], labels), [
      '#7 has the label `on-hold`',
    ]);
  });
});

describe('parseLabels', () => {
  it('trims and drops empty entries', () => {
    assert.deepEqual(parseLabels(' a, b ,,c '), ['a', 'b', 'c']);
  });

  it('falls back to the defaults when empty', () => {
    assert.deepEqual(parseLabels(''), ['needs-refinement', 'needs-decision']);
    assert.deepEqual(parseLabels(undefined), ['needs-refinement', 'needs-decision']);
  });
});

describe('isReleaseBranch', () => {
  it('matches release/** only', () => {
    assert.equal(isReleaseBranch('release/next'), true);
    assert.equal(isReleaseBranch('release/1.2'), true);
    assert.equal(isReleaseBranch('feat/release/x'), false);
    assert.equal(isReleaseBranch('releases'), false);
    assert.equal(isReleaseBranch(undefined), false);
  });
});

/** A fake of the github-script objects: one PR, issues by number, blockers by number. */
function harness({ body, head = 'feat/1-x', issues = {}, blockers = {} }) {
  const calls = { failed: [], notices: [], summary: '' };
  const summary = {
    addHeading: () => summary,
    addRaw: (text) => ((calls.summary += text), summary),
    write: async () => summary,
  };
  return {
    calls,
    github: {
      rest: {
        pulls: { get: async () => ({ data: { body, head: { ref: head } } }) },
        issues: {
          get: async ({ issue_number }) => {
            if (!issues[issue_number]) throw Object.assign(new Error('Not Found'), { status: 404 });
            return { data: { number: issue_number, ...issues[issue_number] } };
          },
        },
      },
      request: async (_route, { issue_number }) => ({ data: blockers[issue_number] ?? [] }),
    },
    context: { repo: { owner: 'o', repo: 'r' }, payload: { pull_request: { number: 5 } } },
    core: {
      setFailed: (message) => calls.failed.push(message),
      notice: (message) => calls.notices.push(message),
      summary,
    },
  };
}

const inputs = (over = {}) => ({ notReadyLabels: '', requireIssue: true, ...over });

describe('run', () => {
  it('passes a PR that closes a ready issue', async () => {
    const h = harness({ body: 'Closes #1', issues: { 1: { labels: ['pbi'] } } });
    await run({ ...h, inputs: inputs() });
    assert.deepEqual(h.calls.failed, []);
    assert.match(h.calls.summary, /Ready: #1/);
  });

  it('lists every problem of every closed issue', async () => {
    const h = harness({
      body: 'Closes #1, fixes #2',
      issues: { 1: { labels: ['needs-decision'] }, 2: { labels: [] } },
      blockers: { 2: [{ number: 9, state: 'open' }] },
    });
    await run({ ...h, inputs: inputs() });
    assert.equal(h.calls.failed.length, 1);
    assert.match(h.calls.failed[0], /#1 has the label `needs-decision`/);
    assert.match(h.calls.failed[0], /#2 is blocked by #9/);
    assert.match(h.calls.summary, /Not ready/);
  });

  it('fails a PR without a closing issue when an issue is required', async () => {
    const h = harness({ body: 'No issue here' });
    await run({ ...h, inputs: inputs() });
    assert.equal(h.calls.failed.length, 1);
    assert.match(h.calls.failed[0], /closes no issue/);
  });

  it('passes a PR without a closing issue when require-issue is off', async () => {
    const h = harness({ body: '' });
    await run({ ...h, inputs: inputs({ requireIssue: false }) });
    assert.deepEqual(h.calls.failed, []);
    assert.equal(h.calls.notices.length, 1);
  });

  it('exempts release PRs from require-issue', async () => {
    const h = harness({ body: '', head: 'release/next' });
    await run({ ...h, inputs: inputs() });
    assert.deepEqual(h.calls.failed, []);
  });

  it('skips references that are pull requests or missing', async () => {
    const h = harness({ body: 'Closes #1, closes #2', issues: { 1: { labels: [], pull_request: {} } } });
    await run({ ...h, inputs: inputs() });
    assert.deepEqual(h.calls.failed, []);
  });
});
