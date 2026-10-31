import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import run from '../../pr-checks/adr/run.mjs';
import {
  adrNumber,
  classifyFiles,
  globToRegExp,
  isAdrFile,
  matchPaths,
  numberProblems,
  readGovernance,
  statusProblem,
} from '../../pr-checks/adr/adr.mjs';

describe('globs', () => {
  it('matches ** across directories and the root', () => {
    assert.deepEqual(matchPaths(['src/a.cs', 'src/x/y/b.cs', 'docs/a.md'], ['src/**']), ['src/a.cs', 'src/x/y/b.cs']);
    assert.deepEqual(matchPaths(['a.proto', 'x/b.proto'], ['**/*.proto']), ['a.proto', 'x/b.proto']);
  });

  it('keeps * inside one segment and escapes dots', () => {
    assert.equal(globToRegExp('src/*.cs').test('src/a.cs'), true);
    assert.equal(globToRegExp('src/*.cs').test('src/x/a.cs'), false);
    assert.equal(globToRegExp('a.cs').test('abcs'), false);
    assert.equal(globToRegExp('a?.cs').test('ab.cs'), true);
  });
});

describe('ADR file rules', () => {
  it('accepts <adrDir>/*.md directly in the directory only', () => {
    assert.equal(isAdrFile('docs/adr/0001-x.md', 'docs/adr'), true);
    assert.equal(isAdrFile('docs/adr/', 'docs/adr/'), false);
    assert.equal(isAdrFile('docs/adr/sub/0001-x.md', 'docs/adr'), false);
    assert.equal(isAdrFile('docs/adr/0001-x.txt', 'docs/adr'), false);
    assert.equal(isAdrFile('docs/adr/0001-x.md', './docs/adr/'), true);
  });

  it('reads the number of the file name', () => {
    assert.equal(adrNumber('docs/adr/0007-use-x.md'), 7);
    assert.equal(adrNumber('docs/adr/readme.md'), null);
  });

  it('counts a rename by its new name and ignores a deleted ADR', () => {
    const files = [
      { filename: 'docs/adr/0002-b.md', status: 'renamed', previous_filename: 'old/0002-b.md' },
      { filename: 'docs/adr/0003-c.md', status: 'renamed', previous_filename: 'docs/adr/0003-x.md' },
      { filename: 'docs/adr/0001-a.md', status: 'removed' },
      { filename: 'src/a.cs', status: 'modified' },
    ];
    const result = classifyFiles(files, 'docs/adr');
    assert.deepEqual(result.adrFiles, ['docs/adr/0002-b.md', 'docs/adr/0003-c.md']);
    assert.deepEqual(result.newAdrFiles, ['docs/adr/0002-b.md']);
    assert.deepEqual(result.touched, ['docs/adr/0002-b.md', 'docs/adr/0003-c.md', 'docs/adr/0001-a.md', 'src/a.cs']);
  });
});

describe('statusProblem', () => {
  it('accepts the four statuses in common spellings', () => {
    for (const line of ['Status: Proposed', '**Status:** accepted', '- Status: Superseded', 'Status: Deprecated']) {
      assert.equal(statusProblem('a.md', `# T\n\n${line}\n`), null, line);
    }
  });

  it('rejects a missing line and an unknown status', () => {
    assert.match(statusProblem('a.md', '# T\n'), /no `Status:` line/);
    assert.match(statusProblem('a.md', 'Status: Draft'), /status `Draft`/);
  });
});

describe('numberProblems', () => {
  const base = ['docs/adr/0001-a.md', 'docs/adr/0002-b.md'];

  it('accepts a free number', () => {
    assert.deepEqual(numberProblems(['docs/adr/0003-c.md'], base), []);
  });

  it('names the duplicate and the next free number', () => {
    assert.deepEqual(numberProblems(['docs/adr/0002-z.md'], base), [
      'docs/adr/0002-z.md duplicates the number 2 of docs/adr/0002-b.md on the base branch; the next free number is 3',
    ]);
  });

  it('rejects duplicates inside the PR and names without a number', () => {
    const problems = numberProblems(['docs/adr/0005-a.md', 'docs/adr/0005-b.md', 'docs/adr/x.md'], base);
    assert.match(problems[0], /0005-b\.md duplicates the number 5 of docs\/adr\/0005-a\.md in this PR/);
    assert.match(problems[1], /x\.md has no number prefix; the next free number is 3/);
  });
});

describe('readGovernance', () => {
  it('is null without governance or adrPaths', () => {
    assert.equal(readGovernance({}), null);
    assert.equal(readGovernance({ governance: {} }), null);
    assert.equal(readGovernance({ governance: { adrPaths: [] } }), null);
  });

  it('defaults skipLabels', () => {
    assert.deepEqual(readGovernance({ governance: { adrPaths: ['src/**'], adrDir: 'd' } }).skipLabels, ['skip-adr']);
    assert.deepEqual(
      readGovernance({ governance: { adrPaths: ['x'], adrDir: 'd', skipLabels: ['no-adr'] } }).skipLabels,
      ['no-adr'],
    );
  });
});

const b64 = (text) => ({ content: Buffer.from(text).toString('base64') });
const notFound = () => Object.assign(new Error('Not Found'), { status: 404 });
const CONFIG = { governance: { adrPaths: ['src/**'], adrDir: 'docs/adr' } };

/** Fake github-script objects. `contents` maps `ref:path` to text, a directory listing array, or an Error. */
function harness({ config = CONFIG, labels = [], body = '', files = [], contents = {}, issues = {}, filesError } = {}) {
  const calls = { failed: [], notices: [], summary: '' };
  const summary = {
    addHeading: () => summary,
    addRaw: (text) => ((calls.summary += text), summary),
    write: async () => summary,
  };
  const all = { 'base:.agents/config.json': config === null ? notFound() : JSON.stringify(config), ...contents };
  return {
    calls,
    github: {
      paginate: async () => {
        if (filesError) throw filesError;
        return files;
      },
      rest: {
        pulls: {
          get: async () => ({
            data: { body, labels: labels.map((name) => ({ name })), base: { ref: 'base' }, head: { sha: 'sha', repo: { name: 'r', owner: { login: 'o' } } } },
          }),
          listFiles: () => {},
        },
        issues: {
          get: async ({ issue_number }) => {
            if (!issues[issue_number]) throw notFound();
            return { data: { number: issue_number, ...issues[issue_number] } };
          },
        },
        repos: {
          getContent: async ({ ref, path }) => {
            const value = all[ref === 'sha' ? `sha:${path}` : `${ref}:${path}`];
            if (value === undefined) throw notFound();
            if (value instanceof Error) throw value;
            return { data: Array.isArray(value) ? value : b64(value) };
          },
        },
      },
    },
    context: { repo: { owner: 'o', repo: 'r' }, payload: { pull_request: { number: 5 } } },
    core: { setFailed: (m) => calls.failed.push(m), notice: (m) => calls.notices.push(m), summary },
  };
}
const file = (filename, status = 'modified', extra = {}) => ({ filename, status, ...extra });
const adrDirListing = { 'base:docs/adr': [{ name: '0001-a.md' }, { name: '0002-b.md' }] };

describe('run', () => {
  it('skips green with a notice without config or governance', async () => {
    for (const config of [null, {}, { governance: {} }]) {
      const h = harness({ config });
      await run(h);
      assert.deepEqual(h.calls.failed, []);
      assert.equal(h.calls.notices.length, 1);
    }
  });

  it('skips with a summary line on a skip label, default and configured', async () => {
    const h = harness({ labels: ['skip-adr'], files: [file('src/a.cs')] });
    await run(h);
    assert.deepEqual(h.calls.failed, []);
    assert.match(h.calls.summary, /Skipped by the label `skip-adr`/);

    const custom = harness({
      config: { governance: { ...CONFIG.governance, skipLabels: ['no-adr'] } },
      labels: ['no-adr'],
      files: [file('src/a.cs')],
    });
    await run(custom);
    assert.deepEqual(custom.calls.failed, []);
  });

  it('fails a matched path without an ADR and names the files', async () => {
    const h = harness({ files: [file('src/a.cs'), file('README.md')] });
    await run(h);
    assert.match(h.calls.failed[0], /src\/a\.cs/);
    assert.doesNotMatch(h.calls.failed[0], /README\.md/);
  });

  it('passes when nothing matches and no decision issue is closed', async () => {
    const h = harness({ files: [file('README.md')] });
    await run(h);
    assert.deepEqual(h.calls.failed, []);
  });

  it('does not count a deleted ADR', async () => {
    const h = harness({ files: [file('src/a.cs'), file('docs/adr/0001-a.md', 'removed')] });
    await run(h);
    assert.equal(h.calls.failed.length, 1);
  });

  it('passes a changed existing ADR next to a matched path', async () => {
    const h = harness({ files: [file('src/a.cs'), file('docs/adr/0001-a.md')] });
    await run(h);
    assert.deepEqual(h.calls.failed, []);
  });

  it('requires an ADR for a closed needs-decision issue whatever the paths', async () => {
    const issues = { 7: { labels: [{ name: 'needs-decision' }] } };
    const h = harness({ body: 'Closes #7', files: [file('README.md')], issues });
    await run(h);
    assert.match(h.calls.failed[0], /#7 has the label `needs-decision`/);

    const ok = harness({ body: 'Closes #7', files: [file('docs/adr/0001-a.md')], issues });
    await run(ok);
    assert.deepEqual(ok.calls.failed, []);
  });

  it('accepts a new ADR with a status and a free number', async () => {
    const h = harness({
      files: [file('src/a.cs'), file('docs/adr/0003-c.md', 'added')],
      contents: { ...adrDirListing, 'sha:docs/adr/0003-c.md': '# C\n\nStatus: Proposed\n' },
    });
    await run(h);
    assert.deepEqual(h.calls.failed, []);
  });

  it('fails a new ADR with a duplicate number and a bad status', async () => {
    const h = harness({
      files: [file('docs/adr/0002-z.md', 'added')],
      contents: { ...adrDirListing, 'sha:docs/adr/0002-z.md': 'Status: Maybe\n' },
    });
    await run(h);
    assert.match(h.calls.failed[0], /status `Maybe`/);
    assert.match(h.calls.failed[0], /duplicates the number 2/);
  });

  it('treats a missing adrDir on the base branch as empty', async () => {
    const h = harness({
      files: [file('docs/adr/0001-a.md', 'added')],
      contents: { 'sha:docs/adr/0001-a.md': 'Status: Accepted\n' },
    });
    await run(h);
    assert.deepEqual(h.calls.failed, []);
  });

  it('reports API errors as problems', async () => {
    const forbidden = Object.assign(new Error('Forbidden'), { status: 403 });
    const cfg = harness({ contents: { 'base:.agents/config.json': forbidden } });
    await run(cfg);
    assert.match(cfg.calls.failed[0], /config\.json of base cannot be read \(403\)/);

    const bad = harness({ contents: { 'base:.agents/config.json': '{not json' } });
    await run(bad);
    assert.match(bad.calls.failed[0], /cannot be read/);

    const list = harness({ filesError: forbidden });
    await run(list);
    assert.match(list.calls.failed[0], /changed files cannot be read \(403\)/);

    const issue = harness({ body: 'Closes #9', files: [file('docs/adr/0001-a.md')] });
    await run(issue);
    assert.match(issue.calls.failed[0], /#9 cannot be read \(404\)/);
  });

  it('fails when governance.adrDir is missing', async () => {
    const h = harness({ config: { governance: { adrPaths: ['src/**'] } } });
    await run(h);
    assert.match(h.calls.failed[0], /adrDir is missing/);
  });
});
