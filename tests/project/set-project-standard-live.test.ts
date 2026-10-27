import { spawnSync } from 'child_process';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { createFakeGh, GhCall } from '../helpers/fake-gh';
import { PwshWorker } from '../helpers/pwsh-worker';

const SCRIPT = path.resolve(
  __dirname,
  '../../.apm/skills/github-project/scripts/Set-ProjectStandard.ps1'
);
const hasPwsh = spawnSync('pwsh', ['-NoProfile', '-Command', '1']).status === 0;

it('pwsh is installed in CI (the Set-ProjectStandard live cases must not be skipped there)', () => {
  if (process.env.CI) expect(hasPwsh).toBe(true);
});

type Opt = { id: string; name: string; color: string; description: string };
const opt = (name: string): Opt => ({ id: `id-${name}`, name, color: 'GRAY', description: '' });
const select = (name: string, options: string[]) => ({
  __typename: 'ProjectV2SingleSelectField',
  id: `F-${name}`,
  name,
  databaseId: 100 + name.length,
  dataType: 'SINGLE_SELECT',
  options: options.map(opt),
});
const plain = (name: string, n: number) => ({
  __typename: 'ProjectV2Field',
  id: `F-${name}`,
  name,
  databaseId: n,
  dataType: 'TEXT',
});
const PLAIN = [
  'Title',
  'Labels',
  'Linked pull requests',
  'Parent issue',
  'Sub-issues progress',
  'Repository',
  'Milestone',
].map((n, i) => plain(n, i + 1));
const STATUS = select('Status', ['Todo', 'In release', 'Done']);
const LEVEL = select('Level', ['Epic', 'Feature', 'PBI', 'Task', 'Bug']);
const NEEDS_ALL = [
  'Planning',
  'Decision',
  'Review',
  'Blocked',
  'Ready',
  'In progress',
  'Release review',
];
const NEEDS = select('Needs', NEEDS_ALL);
const VIEWS = [
  'Hierarchy',
  'Board',
  'Release next',
  'Backlog',
  'Recently closed',
  'Needs me',
  'Ready for loop',
  'Blocked',
].map((name) => ({ id: `V-${name}`, name, layout: 'TABLE_LAYOUT', filter: '' }));
const PLANNED = {
  name: 'planned',
  color: '0E8A16',
  description: 'Task breakdown published or single-task plan approved',
};
const NEEDS_REVIEW = {
  name: 'needs-review',
  color: 'FBCA04',
  description: 'Waiting for an owner review',
};

type Label = { name: string; color?: string; description?: string };
type Item = { number: number; status: string | null; labels: Label[][] }; // label pages, cursor `l<i>`
type Config = {
  fields: object[][]; // pages; page i > 0 is answered for cursor `f<i>`
  views: object[][]; // cursor `v<i>`
  items?: Item[]; // one item page
  itemPages?: Item[][]; // item pages (cursor `i<i>`), instead of items
  repos?: { name: string; labels: Label[][] }[][]; // repository pages (cursor `c<i>`), label pages per repo (cursor `l<i>`)
  labelFail?: string[]; // `<name> <repo>` of `gh label create` calls that fail
};

// One fake gh for all reads of Set-ProjectStandard.ps1 and Sync-ProjectNeeds.ps1 (subIssues: no items, so it changes nothing).
const handler = (c: Config) => `(call) => {
  const C = ${JSON.stringify(c)};
  const q = call.query || '';
  const v = call.variables || {};
  const page = (pages, cursor, prefix) => {
    const i = cursor ? Number(cursor.slice(prefix.length)) : 0;
    const more = i < pages.length - 1;
    return { pageInfo: { hasNextPage: more, endCursor: more ? prefix + (i + 1) : null }, nodes: pages[i] };
  };
  if (call.args[0] === 'label') {
    if ((C.labelFail || []).includes(call.args[2] + ' ' + call.args[4])) throw new Error('HTTP 403: no write access');
    return { rest: {} };
  }
  if (!call.query) return { rest: {} };
  if (q.includes('mutation')) return {};
  if (q.includes('subIssues')) return { node: { items: { pageInfo: { hasNextPage: false, endCursor: null }, nodes: [] } } };
  if (q.includes('projectV2(number')) return { repositoryOwner: { __typename: 'User', projectV2: { id: 'P1',
    fields: page(C.fields, null, 'f'), views: page(C.views, null, 'v') } } };
  if (q.includes('fields(first: 50, after')) return { node: { fields: page(C.fields, v.cursor, 'f') } };
  if (q.includes('views(first: 50, after')) return { node: { views: page(C.views, v.cursor, 'v') } };
  const itemPages = C.itemPages || [C.items || []];
  const items = itemPages.flat();
  if (q.includes('items(first: 100')) {
    const p = page(itemPages, v.cursor, 'i');
    return { node: { items: { pageInfo: p.pageInfo,
      nodes: p.nodes.map((it) => ({ id: 'PVTI-' + it.number, content: { __typename: 'Issue', id: 'I-' + it.number, number: it.number,
        title: 'issue ' + it.number, state: 'OPEN', labels: page(it.labels, null, 'l') },
        status: it.status ? { name: it.status } : null, level: { name: 'PBI' } })) } } };
  }
  if (q.includes('... on Issue { labels')) {
    const it = items.find((x) => 'I-' + x.number === v.id);
    return { node: { labels: page(it.labels, v.cursor, 'l') } };
  }
  const repos = C.repos || [[]];
  const repoNode = (r) => ({ id: 'R-' + r.name, nameWithOwner: r.name, labels: page(r.labels, null, 'l') });
  if (q.includes('repositories(first')) {
    const p = page(repos, v.cursor, 'c');
    return { node: { repositories: { pageInfo: p.pageInfo, nodes: p.nodes.map(repoNode) } } };
  }
  if (q.includes('... on Repository { labels')) {
    const r = repos.flat().find((x) => 'R-' + x.name === v.id);
    return { node: { labels: page(r.labels, v.cursor, 'l') } };
  }
  throw new Error('unexpected gh call: ' + JSON.stringify(call));
}`;

const BASE: Config = { fields: [[STATUS, LEVEL, NEEDS, ...PLAIN]], views: [VIEWS] };
type Action = { type: string; [k: string]: unknown };

describe.skipIf(!hasPwsh || spawnSync('node', ['-v']).status !== 0 || process.platform === 'win32')(
  'Set-ProjectStandard.ps1 live reads and executor (fake gh)',
  () => {
    let worker: PwshWorker;
    let dir: string;
    beforeAll(() => {
      worker = new PwshWorker(SCRIPT);
    });
    afterAll(() => worker.close());
    beforeEach(() => {
      dir = fs.mkdtempSync(path.join(os.tmpdir(), 'projstd-live2-'));
    });
    afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

    const run = async (c: Config | string, args: string[]) => {
      const gh = createFakeGh(dir, typeof c === 'string' ? c : handler(c));
      const r = await worker.run(['-Owner', 'o', '-Number', '1', ...args], {
        cwd: dir,
        env: gh.env(),
      });
      return { r, calls: gh.calls() };
    };
    // Own process: the worker drops the warnings of a script that ends in a throw; a real `pwsh -File` prints them (to stdout).
    const spawnRun = (c: Config, args: string[]) => {
      const gh = createFakeGh(dir, handler(c));
      const r = spawnSync(
        'pwsh',
        ['-NoProfile', '-File', SCRIPT, '-Owner', 'o', '-Number', '1', ...args],
        {
          cwd: dir,
          encoding: 'utf8',
          env: gh.env(),
        }
      );
      return { r, calls: gh.calls() };
    };
    const planned = async (c: Config | string, sync = true) => {
      const { r, calls } = await run(c, [...(sync ? ['-Sync'] : []), '-DryRun', '-Json']);
      expect(r.status, r.stderr + r.stdout).toBe(0);
      return { actions: JSON.parse(r.stdout).actions as Action[], calls };
    };
    const ofType = (a: Action[], t: string) => a.filter((x) => x.type === t);
    const queries = (calls: GhCall[], needle: string) =>
      calls.filter((c) => c.query?.includes(needle) && !c.query.includes('subIssues'));

    describe('pagination', () => {
      it('follows the repositories cursor and plans labels for repositories on every page', async () => {
        const { actions, calls } = await planned({
          ...BASE,
          repos: [[{ name: 'o/a', labels: [[]] }], [{ name: 'o/b', labels: [[]] }]],
        });
        expect(ofType(actions, 'EnsureLabel').map((a) => `${a.repo} ${a.name}`)).toEqual([
          'o/a planned',
          'o/a needs-review',
          'o/b planned',
          'o/b needs-review',
        ]);
        expect(queries(calls, 'repositories(first').map((c) => c.variables?.cursor)).toEqual([
          null,
          'c1',
        ]);
      });

      it('reads the further label pages of a repository and plans no label that is there', async () => {
        const { actions, calls } = await planned({
          ...BASE,
          repos: [
            [
              {
                name: 'o/a',
                labels: [[{ name: 'bug', color: 'D73A4A' }], [PLANNED, NEEDS_REVIEW]],
              },
            ],
          ],
        });
        expect(ofType(actions, 'EnsureLabel')).toEqual([]);
        expect(queries(calls, '... on Repository { labels').map((c) => c.variables)).toEqual([
          { id: 'R-o/a', cursor: 'l1' },
        ]);
      });

      it('reads the further field pages and plans no CreateField for Level or Needs found there', async () => {
        const { actions, calls } = await planned(
          {
            ...BASE,
            fields: [
              [STATUS, ...PLAIN],
              [LEVEL, NEEDS],
            ],
          },
          false
        );
        expect(ofType(actions, 'CreateField')).toEqual([]);
        expect(ofType(actions, 'UpdateFieldOptions')).toEqual([]);
        expect(queries(calls, 'fields(first: 50, after').map((c) => c.variables)).toEqual([
          { id: 'P1', cursor: 'f1' },
        ]);
      });

      it('reads the further view pages and plans no CreateView for a standard view found there', async () => {
        const { actions, calls } = await planned(
          { ...BASE, views: [VIEWS.slice(0, 3), VIEWS.slice(3)] },
          false
        );
        expect(ofType(actions, 'CreateView')).toEqual([]);
        expect(queries(calls, 'views(first: 50, after').map((c) => c.variables)).toEqual([
          { id: 'P1', cursor: 'v1' },
        ]);
      });

      it('plans CreateView only for a standard view missing on all pages', async () => {
        const { actions } = await planned(
          { ...BASE, views: [VIEWS.slice(0, 3), VIEWS.slice(4)] },
          false
        );
        expect(ofType(actions, 'CreateView').map((a) => a.name)).toEqual(['Backlog']);
      });

      it('reads the further label pages of an issue: merged on page 2 moves it to In release', async () => {
        const { actions, calls } = await planned({
          ...BASE,
          items: [{ number: 7, status: 'Todo', labels: [[{ name: 'pbi' }], [{ name: 'merged' }]] }],
        });
        expect(ofType(actions, 'SetItem')).toEqual([
          { type: 'SetItem', item: 'PVTI-7', number: 7, field: 'Status', option: 'In release' },
        ]);
        expect(queries(calls, '... on Issue { labels').map((c) => c.variables)).toEqual([
          { id: 'I-7', cursor: 'l1' },
        ]);
      });

      it('pairs the issue label cursor with its issue across item pages', async () => {
        const { actions, calls } = await planned({
          ...BASE,
          itemPages: [
            [{ number: 7, status: 'Todo', labels: [[{ name: 'pbi' }], [{ name: 'merged' }]] }],
            [{ number: 8, status: 'Todo', labels: [[{ name: 'task' }], [], [{ name: 'merged' }]] }],
          ],
        });
        expect(queries(calls, 'items(first: 100').map((c) => c.variables)).toEqual([
          { id: 'P1', cursor: null },
          { id: 'P1', cursor: 'i1' },
        ]);
        expect(queries(calls, '... on Issue { labels').map((c) => c.variables)).toEqual([
          { id: 'I-7', cursor: 'l1' },
          { id: 'I-8', cursor: 'l1' },
          { id: 'I-8', cursor: 'l2' },
        ]);
        expect(
          ofType(actions, 'SetItem').map((a) => `#${a.number} ${a.field} ${a.option}`)
        ).toEqual(['#7 Status In release', '#8 Status In release']);
      });

      // Replies without pageInfo, with null nodes or without a nested connection end the paging instead of failing.
      const sparse = `(call) => {
        const q = call.query || '';
        if (!call.query) return { rest: {} };
        if (q.includes('subIssues')) return { node: { items: { pageInfo: { hasNextPage: false, endCursor: null }, nodes: [] } } };
        if (q.includes('projectV2(number')) return { repositoryOwner: { __typename: 'User', projectV2: { id: 'P1',
          fields: { nodes: [...${JSON.stringify(BASE.fields[0])}, null] }, views: { nodes: ${JSON.stringify(VIEWS)} } } } };
        if (q.includes('items(first: 100')) return { node: { items: { pageInfo: { hasNextPage: false, endCursor: null },
          nodes: [{ id: 'PVTI-9', content: { __typename: 'Issue', id: 'I-9', number: 9, title: 'issue 9', state: 'OPEN', labels: null },
            status: { name: 'In release' }, level: { name: 'PBI' } }] } } };
        if (q.includes('repositories(first')) return { node: { repositories: { nodes: [{ id: 'R-o/a', nameWithOwner: 'o/a' }, null] } } };
        throw new Error('unexpected gh call: ' + q);
      }`;

      it('a reply without pageInfo, with a null node or without the labels connection ends the paging', async () => {
        const { actions, calls } = await planned(sparse);
        expect(ofType(actions, 'CreateField')).toEqual([]);
        expect(ofType(actions, 'EnsureLabel').map((a) => `${a.repo} ${a.name}`)).toEqual([
          'o/a planned',
          'o/a needs-review',
        ]);
        expect(
          ofType(actions, 'SetItem').map((a) => `#${a.number} ${a.field} ${a.option}`)
        ).toEqual(['#9 Status Todo']);
        expect(queries(calls, 'repositories(first')).toHaveLength(1);
        const followUps = [
          'fields(first: 50, after',
          'views(first: 50, after',
          '... on Repository { labels',
          '... on Issue { labels',
        ];
        expect(followUps.flatMap((n) => queries(calls, n))).toEqual([]);
      });
    });

    describe('executor', () => {
      it('UpdateFieldOptions sends the existing option ids plus the missing options, then re-reads the fields', async () => {
        const { r, calls } = await run(
          { ...BASE, fields: [[STATUS, LEVEL, select('Needs', ['Planning', 'Review']), ...PLAIN]] },
          []
        );
        expect(r.status, r.stderr + r.stdout).toBe(0);
        const idx = calls.findIndex((c) => c.query?.includes('updateProjectV2Field'));
        expect(calls.filter((c) => c.query?.includes('updateProjectV2Field'))).toHaveLength(1);
        expect(calls[idx].variables).toEqual({
          i: {
            fieldId: 'F-Needs',
            singleSelectOptions: [
              { id: 'id-Planning', name: 'Planning', color: 'GRAY', description: '' },
              { id: 'id-Review', name: 'Review', color: 'GRAY', description: '' },
              { name: 'Decision', color: 'ORANGE', description: '' },
              { name: 'Blocked', color: 'RED', description: '' },
              { name: 'Ready', color: 'GREEN', description: '' },
              { name: 'In progress', color: 'PURPLE', description: '' },
              { name: 'Release review', color: 'PINK', description: '' },
            ],
          },
        });
        expect(calls.slice(idx + 1).some((c) => c.query?.includes('projectV2(number'))).toBe(true);
      });

      const labelCalls = (calls: GhCall[]) => calls.filter((c) => c.args[0] === 'label');
      const twoRepos = {
        ...BASE,
        repos: [
          [
            { name: 'o/a', labels: [[]] },
            { name: 'o/b', labels: [[PLANNED]] },
          ],
        ],
      };

      it('EnsureLabel runs gh label create per missing label', async () => {
        const { r, calls } = await run(twoRepos, ['-Sync']);
        expect(r.status, r.stderr + r.stdout).toBe(0);
        expect(labelCalls(calls).map((c) => c.args)).toEqual([
          [
            'label',
            'create',
            'planned',
            '--repo',
            'o/a',
            '--color',
            PLANNED.color,
            '--description',
            PLANNED.description,
            '--force',
          ],
          [
            'label',
            'create',
            'needs-review',
            '--repo',
            'o/a',
            '--color',
            NEEDS_REVIEW.color,
            '--description',
            NEEDS_REVIEW.description,
            '--force',
          ],
          [
            'label',
            'create',
            'needs-review',
            '--repo',
            'o/b',
            '--color',
            NEEDS_REVIEW.color,
            '--description',
            NEEDS_REVIEW.description,
            '--force',
          ],
        ]);
      });

      it('a failing gh label create is reported, the remaining actions still run, and the run exits 1', async () => {
        const { r, calls } = spawnRun(
          {
            ...twoRepos,
            items: [{ number: 7, status: 'Todo', labels: [[{ name: 'merged' }]] }],
            labelFail: ['planned o/a'],
          },
          ['-Sync']
        );
        const out = r.stdout + r.stderr;
        expect(r.status, out).toBe(1);
        // the failing label and gh's own error are named; the other labels are not reported as failed
        const failed = out.split('\n').filter((l) => l.includes('HTTP 403'));
        expect(failed.length, out).toBeGreaterThan(0);
        expect(failed.every((l) => l.includes('planned') && l.includes('o/a'))).toBe(true);
        expect(out).not.toMatch(/needs-review[^\n]*HTTP 403/);
        expect(out).toContain('1 label(s) could not be created; all other actions were applied.');
        expect(labelCalls(calls).map((c) => `${c.args[2]} ${c.args[4]}`)).toEqual([
          'planned o/a',
          'needs-review o/a',
          'needs-review o/b',
        ]);
        expect(
          calls
            .filter((c) => c.args[0] === 'project' && c.args[1] === 'item-edit')
            .map((c) => c.args)
        ).toEqual([
          [
            'project',
            'item-edit',
            '--project-id',
            'P1',
            '--id',
            'PVTI-7',
            '--field-id',
            'F-Status',
            '--single-select-option-id',
            'id-In release',
          ],
        ]);
      });
    });
  }
);
