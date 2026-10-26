import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  MARKER,
  NO_SECTIONS_BODY,
  commentBody,
  expectedTitle,
  levelOf,
  missingSections,
  parseLevels,
  parseRequiredSections,
} from './conventions.mjs';
import run from './run.mjs';

const LEVELS = parseLevels('epic,feature,pbi,task,bug');
const REQUIRED = { pbi: ['Acceptance criteria', 'Depends on', 'Verification'], task: ['Files', 'Done when'] };

describe('parseLevels', () => {
  it('maps known labels to display names in CSV order', () => {
    assert.deepEqual(parseLevels('epic,feature,pbi,task,bug'), {
      epic: 'Epic',
      feature: 'Feature',
      pbi: 'PBI',
      task: 'Task',
      bug: 'Bug',
    });
    assert.deepEqual(Object.keys(parseLevels('task,epic')), ['task', 'epic']);
  });

  it('capitalizes unknown labels and trims whitespace', () => {
    assert.deepEqual(parseLevels(' spike , bug'), { spike: 'Spike', bug: 'Bug' });
  });

  it('is empty for an empty CSV', () => {
    assert.deepEqual(parseLevels(''), {});
  });
});

describe('levelOf', () => {
  it('reads the level from label names or label objects', () => {
    assert.equal(levelOf(['area:bff', 'pbi'], LEVELS), 'pbi');
    assert.equal(levelOf([{ name: 'task' }, { name: 'area:infra' }], LEVELS), 'task');
  });

  it('is null for issues without a level label', () => {
    assert.equal(levelOf(['dependencies'], LEVELS), null);
    assert.equal(levelOf([], LEVELS), null);
  });

  it('uses the CSV order when several level labels are set', () => {
    assert.equal(levelOf(['task', 'pbi'], LEVELS), 'pbi');
    assert.equal(levelOf(['task', 'pbi'], parseLevels('task,pbi')), 'task');
  });

  it('supports custom levels', () => {
    assert.equal(levelOf(['spike'], parseLevels('spike')), 'spike');
  });

  it('matches label names case-insensitively', () => {
    assert.equal(levelOf(['PBI'], LEVELS), 'pbi');
    assert.equal(levelOf([{ name: 'Task' }], LEVELS), 'task');
  });

  it('is null for missing labels or an empty level list', () => {
    assert.equal(levelOf(undefined, LEVELS), null);
    assert.equal(levelOf(['pbi'], {}), null);
  });
});

describe('expectedTitle', () => {
  it('adds a missing prefix and keeps the conventional part', () => {
    assert.equal(expectedTitle('feat: board list', 'pbi', LEVELS), '[PBI] feat: board list');
    assert.equal(expectedTitle('feat(x): y', 'pbi', LEVELS), '[PBI] feat(x): y');
  });

  it('keeps a correct prefix', () => {
    assert.equal(expectedTitle('[Task] test: e2e', 'task', LEVELS), '[Task] test: e2e');
  });

  it('replaces a wrong or differently written prefix', () => {
    assert.equal(expectedTitle('[Task] feat: x', 'pbi', LEVELS), '[PBI] feat: x');
    assert.equal(expectedTitle('[pbi]feat: x', 'pbi', LEVELS), '[PBI] feat: x');
    assert.equal(expectedTitle('  [EPIC]  Identity ', 'epic', LEVELS), '[Epic] Identity');
  });

  it('strips repeated bracket prefixes', () => {
    assert.equal(expectedTitle('[PBI] [Task] x', 'task', LEVELS), '[Task] x');
  });

  it('strips legacy prefixes case-insensitively', () => {
    assert.equal(expectedTitle('Epic: Identity', 'epic', LEVELS), '[Epic] Identity');
    assert.equal(expectedTitle('feature: Login', 'feature', LEVELS), '[Feature] Login');
    assert.equal(expectedTitle('BUG: crash', 'bug', LEVELS), '[Bug] crash');
  });

  it('is idempotent', () => {
    const once = expectedTitle('Bug: [Task] feat(x): y', 'bug', LEVELS);
    assert.equal(once, '[Bug] feat(x): y');
    assert.equal(expectedTitle(once, 'bug', LEVELS), once);
  });

  it('has no trailing space when only prefixes are left', () => {
    assert.equal(expectedTitle('[Task]', 'pbi', LEVELS), '[PBI]');
    assert.equal(expectedTitle('Epic:', 'epic', LEVELS), '[Epic]');
    assert.equal(expectedTitle('', 'bug', LEVELS), '[Bug]');
  });

  it('keeps brackets that are not leading', () => {
    assert.equal(expectedTitle('fix: crash in [Board]', 'bug', LEVELS), '[Bug] fix: crash in [Board]');
  });

  it('uses the display name of custom levels', () => {
    assert.equal(expectedTitle('look into it', 'spike', parseLevels('spike')), '[Spike] look into it');
  });
});

describe('parseRequiredSections', () => {
  it('means no check for empty input and {}', () => {
    assert.deepEqual(parseRequiredSections(''), {});
    assert.deepEqual(parseRequiredSections(undefined), {});
    assert.deepEqual(parseRequiredSections('{}'), {});
  });

  it('parses a level to headings map', () => {
    assert.deepEqual(parseRequiredSections('{"task":["Files"]}'), { task: ['Files'] });
  });

  it('throws a clear message for invalid JSON or a non-object', () => {
    assert.throws(() => parseRequiredSections('{nope'), /Invalid required-sections JSON/);
    assert.throws(() => parseRequiredSections('["a"]'), /Invalid required-sections JSON/);
    assert.throws(() => parseRequiredSections('null'), /Invalid required-sections JSON/);
  });

  it('rejects a level whose headings are not an array of strings', () => {
    assert.throws(() => parseRequiredSections('{"task":"Files"}'), /"task" must be an array of heading strings/);
    assert.throws(() => parseRequiredSections('{"task":["Files",1]}'), /"task" must be an array/);
  });
});

describe('missingSections', () => {
  const pbi =
    '### Parent Feature\n\n#1\n\n## Acceptance criteria\n\n- a\n\n### Depends on\n\n- none\n\n### Verification\n\n```sh\npnpm test\n```';

  it('accepts a body with all sections, at heading levels 2 to 4', () => {
    assert.deepEqual(missingSections(pbi, 'pbi', REQUIRED), []);
  });

  it('lists what a body lacks', () => {
    assert.deepEqual(missingSections('## Acceptance criteria\n- a', 'pbi', REQUIRED), [
      'Depends on',
      'Verification',
    ]);
  });

  it('matches case-insensitively and handles a null body', () => {
    assert.deepEqual(missingSections('### files\n- x', 'task', REQUIRED), ['Done when']);
    assert.deepEqual(missingSections(null, 'task', REQUIRED), ['Files', 'Done when']);
  });

  it('does not count a heading inside a line', () => {
    assert.deepEqual(missingSections('see ### Files below\n### Done when', 'task', REQUIRED), ['Files']);
  });

  it('requires nothing of levels without an entry', () => {
    assert.deepEqual(missingSections('', 'epic', REQUIRED), []);
  });
});

describe('commentBody', () => {
  it('carries the marker and names the missing headings', () => {
    const body = commentBody('Task', ['Files']);
    assert.ok(body.startsWith(MARKER));
    assert.match(body, /`### Files`/);
    assert.match(body, /needs-refinement/);
    assert.doesNotMatch(body, /AGENTS\.md/);
  });

  it('confirms when nothing is missing', () => {
    assert.match(commentBody('PBI', []), /All required sections for a PBI are present/);
  });
});

describe('run', () => {
  // Fake GitHub API: holds the issue state, records every write, applies it, so tests check the
  // resulting state and the set of writes, not the order of calls.
  function fake({ title = 'x', labels = [], body = '', comments = [] }) {
    const state = { title, labels: labels.map((name) => ({ name })), body, comments: [...comments] };
    const writes = [];
    const write = (name, apply) => async (args) => {
      assert.equal(args.owner, 'o');
      assert.equal(args.repo, 'r');
      if (name !== 'createLabel' && name !== 'updateComment') assert.equal(args.issue_number, 7);
      writes.push({ name, args });
      apply?.(args);
      return {};
    };
    const listComments = async () => {};
    const github = {
      paginate: async (fn, args) => {
        assert.equal(fn, listComments);
        assert.equal(args.issue_number, 7);
        return state.comments;
      },
      rest: {
        issues: {
          get: async (args) => {
            assert.equal(args.issue_number, 7);
            return { data: structuredClone({ title: state.title, labels: state.labels, body: state.body }) };
          },
          listComments,
          update: write('update', (a) => (state.title = a.title)),
          createLabel: write('createLabel'),
          addLabels: write('addLabels', (a) => state.labels.push(...a.labels.map((name) => ({ name })))),
          removeLabel: write('removeLabel', (a) => (state.labels = state.labels.filter((l) => l.name !== a.name))),
          createComment: write('createComment', (a) =>
            state.comments.push({ id: 99, user: { type: 'Bot' }, body: a.body }),
          ),
          updateComment: write('updateComment', (a) => {
            state.comments.find((c) => c.id === a.comment_id).body = a.body;
          }),
        },
      },
    };
    const warnings = [];
    const core = { info: () => {}, warning: (m) => warnings.push(m) };
    const context = { repo: { owner: 'o', repo: 'r' }, payload: { issue: { number: 7 } } };
    const inputs = { levels: 'epic,feature,pbi,task,bug', requiredSections: JSON.stringify(REQUIRED) };
    const names = () => writes.map((w) => w.name).sort();
    const arg = (name) => writes.find((w) => w.name === name)?.args;
    const labelNames = () => state.labels.map((l) => l.name).sort();
    return { github, core, context, inputs, state, writes, warnings, names, arg, labelNames };
  }
  const exec = (f) => run({ github: f.github, context: f.context, core: f.core, inputs: f.inputs });
  const bot = (body, id = 5) => ({ id, user: { type: 'Bot' }, body });

  it('does nothing without a level label', async () => {
    const f = fake({ title: 'feat: x', labels: ['dependencies'] });
    await exec(f);
    assert.deepEqual(f.writes, []);
  });

  it('updates the title only when it differs', async () => {
    const same = fake({ title: '[Epic] x', labels: ['epic'] });
    await exec(same);
    assert.deepEqual(same.writes, []);

    const diff = fake({ title: 'x', labels: ['epic'] });
    await exec(diff);
    assert.deepEqual(diff.names(), ['update']);
    assert.equal(diff.state.title, '[Epic] x');
  });

  it('labels and comments once when sections are missing', async () => {
    const f = fake({ title: '[Task] x', labels: ['task'], body: '### Files' });
    await exec(f);
    assert.deepEqual(f.names(), ['addLabels', 'createComment', 'createLabel']);
    assert.deepEqual(f.labelNames(), ['needs-refinement', 'task']);
    assert.match(f.arg('createComment').body, /`### Done when`/);
    assert.deepEqual(f.warnings, ['Missing sections: Done when']);
  });

  it('does not add the label again when it is already set', async () => {
    const f = fake({ title: '[Task] x', labels: ['task', 'needs-refinement'], body: '### Files' });
    await exec(f);
    assert.deepEqual(f.names(), ['createComment']);
  });

  it('is idempotent: a second run writes nothing', async () => {
    for (const body of ['### Files', '### Files\n### Done when']) {
      const f = fake({ title: 'x', labels: ['task'], body });
      await exec(f);
      f.writes.length = 0;
      await exec(f);
      assert.deepEqual(f.writes, [], `second run for body ${JSON.stringify(body)}`);
    }
  });

  it('writes nothing for a complete issue without label or comment', async () => {
    const f = fake({ title: '[Task] x', labels: ['task'], body: '### Files\n### Done when' });
    await exec(f);
    assert.deepEqual(f.writes, []);
  });

  it('ignores a 422 on label creation but rethrows other errors', async () => {
    const f = fake({ title: '[Task] x', labels: ['task'] });
    f.github.rest.issues.createLabel = async () => {
      throw Object.assign(new Error('exists'), { status: 422 });
    };
    await exec(f);
    assert.ok(f.names().includes('createComment'));

    const g = fake({ title: '[Task] x', labels: ['task'] });
    g.github.rest.issues.createLabel = async () => {
      throw Object.assign(new Error('boom'), { status: 500 });
    };
    await assert.rejects(exec(g), /boom/);
  });

  it('updates the existing marker comment instead of creating another', async () => {
    const f = fake({
      title: '[Task] x',
      labels: ['task', 'needs-refinement'],
      body: '### Files',
      comments: [bot(`${MARKER}\nold`)],
    });
    await exec(f);
    assert.deepEqual(f.names(), ['updateComment']);
    assert.equal(f.arg('updateComment').comment_id, 5);
    assert.equal(f.state.comments.length, 1);
  });

  it('ignores marker comments written by non-bots', async () => {
    const f = fake({
      title: '[Task] x',
      labels: ['task'],
      comments: [{ id: 5, user: { type: 'User' }, body: `${MARKER}\nfake` }],
    });
    await exec(f);
    assert.ok(f.names().includes('createComment'));
    assert.ok(!f.names().includes('updateComment'));
  });

  it('removes the label and confirms when sections are complete', async () => {
    const f = fake({
      title: '[Task] x',
      labels: ['task', 'needs-refinement'],
      body: '### Files\n### Done when',
      comments: [bot(`${MARKER}\nold`)],
    });
    await exec(f);
    assert.deepEqual(f.names(), ['removeLabel', 'updateComment']);
    assert.deepEqual(f.labelNames(), ['task']);
    assert.match(f.arg('updateComment').body, /All required sections for a Task are present/);
  });

  it('tolerates a label that is already gone (404) but rethrows other errors', async () => {
    const issue = { title: '[Task] x', labels: ['task', 'needs-refinement'], body: '### Files\n### Done when' };
    const f = fake(issue);
    f.github.rest.issues.removeLabel = async () => {
      throw Object.assign(new Error('Label does not exist'), { status: 404 });
    };
    await exec(f);

    const g = fake(issue);
    g.github.rest.issues.removeLabel = async () => {
      throw Object.assign(new Error('forbidden'), { status: 403 });
    };
    await assert.rejects(exec(g), /forbidden/);
  });

  it('skips the section check for levels without required sections', async () => {
    const f = fake({ title: '[Bug] x', labels: ['bug'] });
    await exec(f);
    assert.deepEqual(f.writes, []);
  });

  it('undoes its own label when the level no longer requires sections', async () => {
    const missing = commentBody('Task', ['Done when']);
    for (const labels of [['bug', 'needs-refinement'], ['needs-refinement']]) {
      const f = fake({ title: labels[0] === 'bug' ? '[Bug] x' : 'x', labels, comments: [bot(missing)] });
      await exec(f);
      assert.deepEqual(f.names(), ['removeLabel', 'updateComment'], `labels ${labels}`);
      assert.equal(f.state.comments[0].body, NO_SECTIONS_BODY);
    }
  });

  it('keeps a needs-refinement label it did not set', async () => {
    for (const comments of [[], [bot(commentBody('Task', []))]]) {
      const f = fake({ title: '[Bug] x', labels: ['bug', 'needs-refinement'], comments });
      await exec(f);
      assert.deepEqual(f.writes, []);
    }
  });
});
