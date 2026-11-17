import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import run from '../../pr-checks/retarget/run.mjs';
import { isWorkBranch, retargetDecision } from '../../pr-checks/retarget/retarget.mjs';

const decide = (headRef, extra = {}) =>
  retargetDecision({ headRef, baseRef: 'main', defaultBranch: 'main', targetExists: true, ...extra });

describe('isWorkBranch', () => {
  it('accepts <type>/<nr>-<slug> for the work types', () => {
    for (const type of ['feat', 'refactor', 'chore', 'docs', 'test', 'perf', 'build', 'ci']) {
      assert.equal(isWorkBranch(`${type}/12-thing`), true, type);
    }
  });
  it('rejects hotfix, release and other branches', () => {
    for (const ref of ['fix/12-thing', 'release/next', 'release/1.2', 'main', 'feat/thing', 'feat/x-12', null]) {
      assert.equal(isWorkBranch(ref), false, String(ref));
    }
  });
});

describe('retargetDecision', () => {
  it('retargets a work branch into the default branch', () => {
    assert.deepEqual(decide('feat/232-x'), { action: 'retarget', target: 'release/next' });
  });
  it('leaves a hotfix on main', () => {
    assert.equal(decide('fix/232-x').action, 'skip');
  });
  it('leaves a release PR alone', () => {
    assert.equal(decide('release/next').action, 'skip');
  });
  it('leaves a PR that does not target the default branch', () => {
    assert.equal(decide('feat/1-x', { baseRef: 'release/next' }).action, 'skip');
  });
  it('leaves fork PRs alone', () => {
    assert.equal(decide('feat/1-x', { sameRepo: false }).action, 'skip');
  });
  it('reports a missing release/next', () => {
    assert.deepEqual(decide('feat/1-x', { targetExists: false }), { action: 'missing', target: 'release/next' });
  });
});

function harness({ head = 'feat/232-x', base = 'main', branchExists = true }) {
  const calls = { failed: [], updates: [], comments: [], summary: '' };
  const summary = {
    addHeading: () => summary,
    addRaw: (text) => ((calls.summary += text), summary),
    write: async () => summary,
  };
  return {
    calls,
    github: {
      rest: {
        pulls: {
          get: async () => ({
            data: {
              head: { ref: head, repo: { full_name: 'o/r' } },
              base: { ref: base, repo: { full_name: 'o/r', default_branch: 'main' } },
            },
          }),
          update: async (args) => calls.updates.push(args),
        },
        repos: {
          getBranch: async () => {
            if (!branchExists) throw Object.assign(new Error('Not Found'), { status: 404 });
            return {};
          },
        },
        issues: { createComment: async (args) => calls.comments.push(args) },
      },
    },
    context: { repo: { owner: 'o', repo: 'r' }, payload: { pull_request: { number: 5 } } },
    core: { setFailed: (m) => calls.failed.push(m), notice: () => {}, summary },
    inputs: { releaseBranch: 'release/next' },
  };
}

describe('run', () => {
  it('moves a work-branch PR and comments', async () => {
    const h = harness({});
    await run(h);
    assert.deepEqual(h.calls.updates, [{ owner: 'o', repo: 'r', pull_number: 5, base: 'release/next' }]);
    assert.equal(h.calls.comments.length, 1);
    assert.match(h.calls.comments[0].body, /Retargeted from `main` to `release\/next`/);
    assert.deepEqual(h.calls.failed, []);
  });
  it('leaves a hotfix untouched', async () => {
    const h = harness({ head: 'fix/232-x' });
    await run(h);
    assert.deepEqual(h.calls.updates, []);
    assert.deepEqual(h.calls.failed, []);
  });
  it('leaves a release PR untouched', async () => {
    const h = harness({ head: 'release/next' });
    await run(h);
    assert.deepEqual(h.calls.updates, []);
  });
  it('fails with a hint when release/next is missing', async () => {
    const h = harness({ branchExists: false });
    await run(h);
    assert.deepEqual(h.calls.updates, []);
    assert.match(h.calls.failed[0], /release\/next.*does not exist/);
    assert.match(h.calls.failed[0], /gh pr edit 5 --base release\/next/);
  });
});
