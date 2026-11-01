import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import run from '../../pr-checks/spec/run.mjs';
import { findMissing, isIgnored, readSpecConfig, specOptOut } from '../../pr-checks/spec/spec.mjs';

const file = (filename, status = 'modified') => ({ filename, status });
const entries = [{ glob: 'src/**', specs: ['docs/spec.md'] }];

describe('ignored files', () => {
  it('ignores Markdown and tests', () => {
    for (const name of ['src/README.md', 'src/a.test.ts', 'src/a_test.go', 'src/tests/a.cs', 'src/A.Test/a.cs', 'src/A.Tests.cs']) {
      assert.equal(isIgnored(name), true, name);
    }
  });
  it('counts source files', () => {
    for (const name of ['src/a.cs', 'src/latest/a.cs', 'src/b.mjs']) assert.equal(isIgnored(name), false, name);
  });
});

describe('opt-out line', () => {
  it('accepts the line plain, as list item or ticked checkbox, with a reason', () => {
    for (const body of ['no spec change needed', '- no spec change needed: refactor', 'x\n- [x] No spec change needed\ny']) {
      assert.equal(specOptOut(body), true, body);
    }
  });
  it('rejects an unticked box, other words and empty bodies', () => {
    for (const body of ['- [ ] no spec change needed', 'we think no spec change needed here', '', null]) {
      assert.equal(specOptOut(body), false, String(body));
    }
  });
});

describe('config', () => {
  it('returns null without a usable map', () => {
    for (const c of [null, {}, { governance: {} }, { governance: { specMap: [] } }, { governance: { specMap: {} } }]) {
      assert.equal(readSpecConfig(c), null);
    }
  });
  it('defaults the mode to warn and accepts a list of specs', () => {
    const c = readSpecConfig({ governance: { specMap: { 'a/**': ['s1.md', 's2.md'] }, specMode: 'bogus' } });
    assert.deepEqual(c, { entries: [{ glob: 'a/**', specs: ['s1.md', 's2.md'] }], mode: 'warn' });
    assert.equal(readSpecConfig({ governance: { specMap: { a: 's' }, specMode: 'require' } }).mode, 'require');
  });
});

describe('findMissing', () => {
  it('reports a changed file without its spec', () => {
    assert.deepEqual(findMissing([file('src/a.cs')], entries), [
      { glob: 'src/**', specs: ['docs/spec.md'], files: ['src/a.cs'] },
    ]);
  });
  it('passes when the spec changed, also when removed', () => {
    assert.deepEqual(findMissing([file('src/a.cs'), file('docs/spec.md')], entries), []);
    assert.deepEqual(findMissing([file('src/a.cs'), file('docs/spec.md', 'removed')], entries), []);
  });
  it('does not count tests and Markdown under the glob', () => {
    assert.deepEqual(findMissing([file('src/a.test.ts'), file('src/README.md')], entries), []);
  });
  it('checks each entry on its own', () => {
    const two = [...entries, { glob: 'api/**', specs: ['docs/api.md'] }];
    const out = findMissing([file('src/a.cs'), file('api/b.cs'), file('docs/api.md')], two);
    assert.deepEqual(out.map((m) => m.glob), ['src/**']);
  });
});

function harness({ config = { governance: { specMap: { 'src/**': 'docs/spec.md' } } }, body = '', files = [], filesError } = {}) {
  const calls = { failed: [], notices: [], warnings: [], summary: '' };
  const notFound = () => Object.assign(new Error('Not Found'), { status: 404 });
  const summary = {
    addHeading() {
      return summary;
    },
    addRaw(text) {
      calls.summary += text;
      return summary;
    },
    write: async () => {},
  };
  return {
    calls,
    github: {
      paginate: async () => {
        if (filesError) throw filesError;
        return files;
      },
      rest: {
        pulls: { get: async () => ({ data: { body, base: { ref: 'base' } } }), listFiles: () => {} },
        repos: {
          getContent: async () => {
            if (config === null) throw notFound();
            return { data: { content: Buffer.from(JSON.stringify(config)).toString('base64') } };
          },
        },
      },
    },
    context: { repo: { owner: 'o', repo: 'r' }, payload: { pull_request: { number: 5 } } },
    core: {
      setFailed: (m) => calls.failed.push(m),
      notice: (m) => calls.notices.push(m),
      warning: (m) => calls.warnings.push(m),
      summary,
    },
  };
}

describe('run', () => {
  it('skips green with a notice without config or map', async () => {
    for (const config of [null, {}, { governance: {} }]) {
      const h = harness({ config, files: [file('src/a.cs')] });
      await run(h);
      assert.deepEqual(h.calls.failed, []);
      assert.equal(h.calls.notices.length, 1);
    }
  });

  it('warns and passes in the default mode', async () => {
    const h = harness({ files: [file('src/a.cs')] });
    await run(h);
    assert.deepEqual(h.calls.failed, []);
    assert.equal(h.calls.warnings.length, 1);
    assert.match(h.calls.summary, /src\/a\.cs/);
  });

  it('fails in require mode and names the files', async () => {
    const config = { governance: { specMap: { 'src/**': 'docs/spec.md' }, specMode: 'require' } };
    const h = harness({ config, files: [file('src/a.cs')] });
    await run(h);
    assert.match(h.calls.failed[0], /src\/a\.cs/);
    assert.deepEqual(h.calls.warnings, []);
  });

  it('turns a require failure into a warning on the opt-out line and says so', async () => {
    const config = { governance: { specMap: { 'src/**': 'docs/spec.md' }, specMode: 'require' } };
    const h = harness({ config, body: '- no spec change needed', files: [file('src/a.cs')] });
    await run(h);
    assert.deepEqual(h.calls.failed, []);
    assert.equal(h.calls.warnings.length, 1);
    assert.match(h.calls.summary, /no spec change needed/);
  });

  it('passes with the spec changed or only tests and Markdown touched', async () => {
    for (const files of [[file('src/a.cs'), file('docs/spec.md')], [file('src/a.test.ts'), file('src/x.md')]]) {
      const h = harness({ files });
      await run(h);
      assert.deepEqual(h.calls.failed, []);
      assert.deepEqual(h.calls.warnings, []);
    }
  });

  it('fails when the changed files cannot be read', async () => {
    const h = harness({ filesError: Object.assign(new Error('x'), { status: 500 }) });
    await run(h);
    assert.match(h.calls.failed[0], /500/);
  });
});
