import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  MARKER,
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
  function fake({ title = 'x', labels = [], body = '', comments = [] }) {
    const calls = [];
    const rec = (name, result) => async (args) => {
      calls.push([name, args]);
      return result;
    };
    const github = {
      paginate: async () => comments,
      rest: {
        issues: {
          get: async () => ({ data: { title, labels, body } }),
          listComments: () => {},
          update: rec('update'),
          createLabel: rec('createLabel'),
          addLabels: rec('addLabels'),
          removeLabel: rec('removeLabel'),
          createComment: rec('createComment'),
          updateComment: rec('updateComment'),
        },
      },
    };
    const core = { info: () => {}, warning: () => {} };
    const context = { repo: { owner: 'o', repo: 'r' }, payload: { issue: { number: 7 } } };
    const inputs = { levels: 'epic,feature,pbi,task,bug', requiredSections: JSON.stringify(REQUIRED) };
    return { github, core, context, inputs, calls, names: () => calls.map((c) => c[0]) };
  }
  const exec = (f) => run({ github: f.github, context: f.context, core: f.core, inputs: f.inputs });

  it('does nothing without a level label', async () => {
    const f = fake({ labels: [{ name: 'dependencies' }] });
    await exec(f);
    assert.deepEqual(f.names(), []);
  });

  it('updates the title only when it differs', async () => {
    const same = fake({ title: '[Epic] x', labels: [{ name: 'epic' }] });
    await exec(same);
    assert.deepEqual(same.names(), []);

    const diff = fake({ title: 'x', labels: [{ name: 'epic' }] });
    await exec(diff);
    assert.deepEqual(diff.calls, [['update', { owner: 'o', repo: 'r', issue_number: 7, title: '[Epic] x' }]]);
  });

  it('labels and comments once when sections are missing', async () => {
    const f = fake({ title: '[Task] x', labels: [{ name: 'task' }], body: '### Files' });
    await exec(f);
    assert.deepEqual(f.names(), ['createLabel', 'addLabels', 'createComment']);
    assert.match(f.calls[2][1].body, /`### Done when`/);
  });

  it('ignores a 422 on label creation but rethrows other errors', async () => {
    const f = fake({ title: '[Task] x', labels: [{ name: 'task' }] });
    f.github.rest.issues.createLabel = async () => {
      throw Object.assign(new Error('exists'), { status: 422 });
    };
    await exec(f);
    assert.ok(f.names().includes('createComment'));

    const g = fake({ title: '[Task] x', labels: [{ name: 'task' }] });
    g.github.rest.issues.createLabel = async () => {
      throw Object.assign(new Error('boom'), { status: 500 });
    };
    await assert.rejects(exec(g), /boom/);
  });

  it('updates the existing marker comment instead of creating another', async () => {
    const f = fake({
      title: '[Task] x',
      labels: [{ name: 'task' }, { name: 'needs-refinement' }],
      body: '### Files',
      comments: [{ id: 5, user: { type: 'Bot' }, body: `${MARKER}\nold` }],
    });
    await exec(f);
    assert.deepEqual(f.names(), ['createLabel', 'updateComment']);
    assert.equal(f.calls[1][1].comment_id, 5);
  });

  it('ignores marker comments written by non-bots', async () => {
    const f = fake({
      title: '[Task] x',
      labels: [{ name: 'task' }],
      comments: [{ id: 5, user: { type: 'User' }, body: `${MARKER}\nfake` }],
    });
    await exec(f);
    assert.ok(f.names().includes('createComment'));
  });

  it('removes the label and confirms when sections are complete', async () => {
    const f = fake({
      title: '[Task] x',
      labels: [{ name: 'task' }, { name: 'needs-refinement' }],
      body: '### Files\n### Done when',
      comments: [{ id: 5, user: { type: 'Bot' }, body: `${MARKER}\nold` }],
    });
    await exec(f);
    assert.deepEqual(f.names(), ['removeLabel', 'updateComment']);
    assert.match(f.calls[1][1].body, /All required sections for a Task are present/);
  });

  it('skips the section check for levels without required sections', async () => {
    const f = fake({ title: '[Bug] x', labels: [{ name: 'bug' }] });
    await exec(f);
    assert.deepEqual(f.names(), []);
  });
});
