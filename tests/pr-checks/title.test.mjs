import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import run from '../../pr-checks/title/run.mjs';
import {
  checksEveryCommit,
  isBreaking,
  isExempt,
  parseConventional,
  titleProblems,
} from '../../pr-checks/title/title.mjs';

describe('parseConventional', () => {
  it('accepts every type, scope and bang', () => {
    for (const type of ['build', 'chore', 'ci', 'docs', 'feat', 'fix', 'perf', 'refactor', 'revert', 'style', 'test']) {
      assert.equal(parseConventional(`${type}: x`).type, type);
    }
    assert.deepEqual(parseConventional('feat(api)!: drop v1'), { type: 'feat', breaking: true });
    assert.deepEqual(parseConventional('fix(a b): x'), { type: 'fix', breaking: false });
  });

  it('rejects other titles', () => {
    for (const title of ['Update stuff', 'feature: x', 'feat:x', 'feat: ', 'Feat: x', 'feat(): x', '', null]) {
      assert.equal(parseConventional(title), null, String(title));
    }
  });
});

describe('isBreaking', () => {
  it('detects the bang and the footer', () => {
    assert.equal(isBreaking('feat!: x'), true);
    assert.equal(isBreaking('fix: x\n\nBREAKING CHANGE: gone'), true);
    assert.equal(isBreaking('fix: x\n\nBREAKING-CHANGE: gone'), true);
  });
  it('ignores plain commits and a footer-like subject', () => {
    assert.equal(isBreaking('fix: x\n\nmentions BREAKING CHANGE in prose'), false);
    assert.equal(isBreaking('BREAKING CHANGE: x'), false);
  });
});

describe('exemptions', () => {
  it('exempts release and merge-back PRs', () => {
    assert.equal(isExempt('release/next', 'main'), true);
    assert.equal(isExempt('main', 'main'), true);
    assert.equal(isExempt('feat/1-x', 'main'), false);
  });
  it('checks every commit only for non-release PRs into the default branch', () => {
    assert.equal(checksEveryCommit('main', 'fix/3-x', 'main'), true);
    assert.equal(checksEveryCommit('release/next', 'feat/1-x', 'main'), false);
    assert.equal(checksEveryCommit('main', 'release/next', 'main'), false);
  });
});

const commit = (message, parents = 1) => ({ sha: 'abcdef1234', message, parents });

describe('titleProblems', () => {
  it('passes a valid title with consistent commits', () => {
    assert.deepEqual(titleProblems('feat: add', [commit('feat: a'), commit('fix: b')]), []);
  });
  it('fails an invalid title', () => {
    const [problem] = titleProblems('Add thing', []);
    assert.match(problem, /not a Conventional Commit/);
  });
  it('fails a breaking commit without ! in the title', () => {
    const problems = titleProblems('feat: add', [commit('feat!: a')]);
    assert.equal(problems.length, 1);
    assert.match(problems[0], /needs `!`/);
    assert.deepEqual(titleProblems('feat!: add', [commit('feat!: a')]), []);
  });
  it('fails a BREAKING CHANGE footer without ! in the title', () => {
    assert.equal(titleProblems('fix: x', [commit('fix: a\n\nBREAKING CHANGE: b')]).length, 1);
  });
  it('fails a feat commit under a fix title', () => {
    const problems = titleProblems('fix: x', [commit('feat: a')]);
    assert.equal(problems.length, 1);
    assert.match(problems[0], /must be `feat`/);
  });
  it('ignores non-conventional commits unless every commit is checked', () => {
    assert.deepEqual(titleProblems('fix: x', [commit('wip')]), []);
    const problems = titleProblems('fix: x', [commit('wip')], { everyCommit: true });
    assert.match(problems[0], /Commit abcdef1 "wip"/);
  });
  it('ignores merge commits', () => {
    assert.deepEqual(titleProblems('fix: x', [commit('Merge branch main', 2)], { everyCommit: true }), []);
  });
});

function harness({ title, head = 'feat/1-x', base = 'release/next', commits = [] }) {
  const calls = { failed: [], notices: [], summary: '' };
  const summary = {
    addHeading: () => summary,
    addRaw: (text) => ((calls.summary += text), summary),
    write: async () => summary,
  };
  const listCommits = () => {};
  return {
    calls,
    github: {
      rest: {
        pulls: {
          get: async () => ({
            data: { title, head: { ref: head }, base: { ref: base, repo: { default_branch: 'main' } } },
          }),
          listCommits,
        },
      },
      paginate: async (fn) => {
        assert.equal(fn, listCommits);
        return commits.map((message, i) => ({ sha: `sha${i}0000`, commit: { message }, parents: [{}] }));
      },
    },
    context: { repo: { owner: 'o', repo: 'r' }, payload: { pull_request: { number: 5 } } },
    core: {
      setFailed: (message) => calls.failed.push(message),
      notice: (message) => calls.notices.push(message),
      summary,
    },
  };
}

describe('run', () => {
  it('passes a valid title', async () => {
    const h = harness({ title: 'feat: x', commits: ['feat: a'] });
    await run(h);
    assert.deepEqual(h.calls.failed, []);
    assert.match(h.calls.summary, /Valid: feat: x/);
  });
  it('fails an invalid title read through the API', async () => {
    const h = harness({ title: 'nope' });
    await run(h);
    assert.equal(h.calls.failed.length, 1);
  });
  it('exempts a release PR even with a bad title', async () => {
    const h = harness({ title: 'release: 1.1', head: 'release/next', base: 'main', commits: ['wip'] });
    await run(h);
    assert.deepEqual(h.calls.failed, []);
    assert.equal(h.calls.notices.length, 1);
  });
  it('exempts a merge-back PR', async () => {
    const h = harness({ title: 'Merge main', head: 'main' });
    await run(h);
    assert.deepEqual(h.calls.failed, []);
  });
  it('checks every commit of a hotfix into main', async () => {
    const h = harness({ title: 'fix: x', head: 'fix/9-x', base: 'main', commits: ['fix: a', 'oops'] });
    await run(h);
    assert.equal(h.calls.failed.length, 1);
    assert.match(h.calls.failed[0], /"oops" is not a Conventional Commit/);
  });
  it('does not require conventional commits into a release branch', async () => {
    const h = harness({ title: 'fix: x', commits: ['oops'] });
    await run(h);
    assert.deepEqual(h.calls.failed, []);
  });
});
