import { spawnSync } from 'child_process';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { createFakeGh } from '../helpers/fake-gh';

const SCRIPT = path.resolve(
  __dirname,
  '../../.apm/skills/github-project/scripts/Set-ProjectStandard.ps1'
);
const hasPwsh = spawnSync('pwsh', ['-NoProfile', '-Command', '1']).status === 0;

it('pwsh is installed in CI (the Set-ProjectStandard cases must not be skipped there)', () => {
  if (process.env.CI) expect(hasPwsh).toBe(true);
});

type Opt = { id: string; name: string; color: string; description: string };
const opt = (name: string, color = 'GRAY'): Opt => ({
  id: `id-${name}`,
  name,
  color,
  description: `d ${name}`,
});
const select = (name: string, options: Opt[]) => ({
  id: `F-${name}`,
  name,
  databaseId: name.length,
  dataType: 'SINGLE_SELECT',
  options,
});
const plain = (name: string, n: number) => ({
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
const DEFAULT_STATUS = ['Todo', 'In Progress', 'Done'].map((n) => opt(n));
const HELIX_STATUS = ['Backlog', 'Ready', 'In progress', 'In review', 'Done'].map((n) => opt(n));
const LEVEL = select(
  'Level',
  ['Epic', 'Feature', 'PBI', 'Task', 'Bug'].map((n) => opt(n))
);
const STANDARD_VIEWS = ['Hierarchy', 'Board', 'Release next', 'Backlog', 'Recently closed'].map(
  (name) => ({ id: `V-${name}`, name })
);

const NEEDS_NAMES = [
  'Planning',
  'Decision',
  'Review',
  'Blocked',
  'Ready',
  'In progress',
  'Release review',
];
const NEEDS = select(
  'Needs',
  NEEDS_NAMES.map((n) => opt(n))
);
const NEEDS_VIEWS = ['Needs me', 'Ready for loop', 'Blocked'].map((name) => ({
  id: `V-${name}`,
  name,
}));
const ALL_VIEWS = [...STANDARD_VIEWS, ...NEEDS_VIEWS];

type Item = {
  id: string;
  number: number;
  title: string;
  state: string;
  labels: string[];
  status?: string;
  level?: string;
};
const item = (number: number, o: Partial<Item> = {}): Item => ({
  id: `I-${number}`,
  number,
  title: `t${number}`,
  state: 'OPEN',
  labels: [],
  ...o,
});

interface State {
  fields: unknown[];
  views: { id: string; name: string }[];
  items: Item[];
}
const state = (o: Partial<State> & { status?: Opt[] } = {}): State => ({
  fields: [
    select('Status', o.status ?? DEFAULT_STATUS),
    LEVEL,
    NEEDS,
    ...PLAIN,
    ...(o.fields ?? []),
  ],
  views: o.views ?? ALL_VIEWS,
  items: o.items ?? [],
});

interface Action {
  type: string;
  [k: string]: any;
}

describe.skipIf(!hasPwsh)('Set-ProjectStandard.ps1 -StateFile', () => {
  let dir: string;
  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'projstd-'));
  });
  afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

  const plan = (s: unknown, ...flags: string[]): Action[] => {
    const file = path.join(dir, 'state.json');
    fs.writeFileSync(file, JSON.stringify({ projectId: 'P', ownerType: 'User', ...(s as object) }));
    const r = spawnSync(
      'pwsh',
      ['-NoProfile', '-File', SCRIPT, '-StateFile', file, '-DryRun', '-Json', ...flags],
      { cwd: dir, encoding: 'utf8' }
    );
    expect(r.status, r.stderr + r.stdout).toBe(0);
    return JSON.parse(r.stdout).actions;
  };
  const ofType = (a: Action[], t: string) => a.filter((x) => x.type === t);

  describe('Status', () => {
    it.each([
      ['default set', DEFAULT_STATUS, ['Todo', 'In Progress', 'In release', 'Done']],
      [
        'Helix set',
        HELIX_STATUS,
        ['Backlog', 'Ready', 'In progress', 'In review', 'In release', 'Done'],
      ],
    ])('inserts In release before Done and keeps ids (%s)', (_n, status, names) => {
      const [a] = ofType(plan(state({ status })), 'UpdateStatusOptions');
      expect(a.options.map((o: Opt) => o.name)).toEqual(names);
      for (const o of status)
        expect(a.options.find((x: Opt) => x.name === o.name)).toMatchObject(o);
      expect(a.options.find((x: Opt) => x.name === 'In release')).toMatchObject({ color: 'BLUE' });
      expect(a.options.find((x: Opt) => x.name === 'In release').id).toBeUndefined();
    });

    it('appends at the end without a Done option', () => {
      const [a] = ofType(
        plan(state({ status: [opt('Todo'), opt('Doing')] })),
        'UpdateStatusOptions'
      );
      expect(a.options.map((o: Opt) => o.name)).toEqual(['Todo', 'Doing', 'In release']);
    });

    it('is a no-op when In release exists', () => {
      const status = [opt('Todo'), opt('In release'), opt('Done')];
      expect(ofType(plan(state({ status })), 'UpdateStatusOptions')).toHaveLength(0);
    });
  });

  describe('Level', () => {
    it('creates the field with five options when missing', () => {
      const s = state();
      s.fields = s.fields.filter((f: any) => f.name !== 'Level');
      const [a] = ofType(plan(s), 'CreateField');
      expect(a.name).toBe('Level');
      expect(a.options.map((o: Opt) => `${o.name}:${o.color}`)).toEqual([
        'Epic:PURPLE',
        'Feature:GREEN',
        'PBI:BLUE',
        'Task:GRAY',
        'Bug:RED',
      ]);
    });

    it('keeps an existing field untouched', () => {
      expect(ofType(plan(state()), 'CreateField')).toHaveLength(0);
    });
  });

  describe('Needs', () => {
    const withoutNeeds = () => {
      const s = state();
      s.fields = s.fields.filter((f: any) => f.name !== 'Needs');
      return s;
    };

    it('creates the field with seven options in order when missing', () => {
      const [a] = ofType(plan(withoutNeeds()), 'CreateField');
      expect(a.name).toBe('Needs');
      expect(a.options.map((o: Opt) => `${o.name}:${o.color}`)).toEqual([
        'Planning:BLUE',
        'Decision:ORANGE',
        'Review:YELLOW',
        'Blocked:RED',
        'Ready:GREEN',
        'In progress:PURPLE',
        'Release review:PINK',
      ]);
    });

    it('adds only the missing options, keeping existing ids first', () => {
      const have = [opt('Ready', 'TEAL'), opt('Planning')];
      const s = state();
      s.fields = s.fields.map((f: any) => (f.name === 'Needs' ? select('Needs', have) : f));
      const acts = plan(s).filter((a) => a.type === 'UpdateFieldOptions');
      expect(acts).toHaveLength(1);
      const names = acts[0].options.map((o: Opt) => o.name);
      expect(names).toEqual([
        'Ready',
        'Planning',
        'Decision',
        'Review',
        'Blocked',
        'In progress',
        'Release review',
      ]);
      expect(acts[0].field).toBe('Needs');
      expect(acts[0].options[0]).toMatchObject(have[0]);
      expect(acts[0].options[1]).toMatchObject(have[1]);
      expect(acts[0].options[2].id).toBeUndefined();
      expect(ofType(plan(s), 'CreateField')).toHaveLength(0);
    });

    it('does nothing for a complete field', () => {
      const a = plan(state());
      expect(ofType(a, 'UpdateFieldOptions')).toHaveLength(0);
      expect(ofType(a, 'CreateField')).toHaveLength(0);
    });
  });

  describe('-Sync', () => {
    const sync = (items: Item[], status?: Opt[]) =>
      plan(state({ items, status }), '-Sync').filter((a) => a.type === 'SetItem');
    const set = (a: Action[], n: number, field: string) =>
      a.find((x) => x.number === n && x.field === field)?.option;

    it('derives Level from labels in order epic|feature|pbi|task|bug, then title prefix', () => {
      const a = sync([
        item(1, { labels: ['task', 'feature'] }),
        item(2, { labels: ['bug'] }),
        item(3, { title: '[PBI] something' }),
        item(4, { title: 'plain' }),
        item(5, { labels: ['epic'], level: 'Task' }),
      ]);
      expect(set(a, 1, 'Level')).toBe('Feature');
      expect(set(a, 2, 'Level')).toBe('Bug');
      expect(set(a, 3, 'Level')).toBe('PBI');
      expect(set(a, 4, 'Level')).toBeUndefined();
      expect(set(a, 5, 'Level')).toBeUndefined();
    });

    it('moves open merged issues to In release, and In release without merged back to Todo', () => {
      const a = sync([
        item(1, { labels: ['merged'], status: 'Todo', level: 'PBI' }),
        item(2, { labels: ['merged'], status: 'In release', level: 'PBI' }),
        item(3, { status: 'In release', level: 'PBI' }),
      ]);
      expect(set(a, 1, 'Status')).toBe('In release');
      expect(set(a, 2, 'Status')).toBeUndefined();
      expect(set(a, 3, 'Status')).toBe('Todo');
    });

    it('falls back to the first status option when Todo does not exist', () => {
      const a = sync(
        [item(3, { status: 'In release', level: 'PBI' })],
        [opt('Backlog'), opt('Done')]
      );
      expect(set(a, 3, 'Status')).toBe('Backlog');
    });

    it('sets Level on closed items but never their Status', () => {
      const a = sync([
        item(1, { state: 'CLOSED', labels: ['merged', 'pbi'], status: 'Done' }),
        item(2, { state: 'CLOSED', status: 'In release' }),
      ]);
      expect(set(a, 1, 'Level')).toBe('PBI');
      expect(set(a, 1, 'Status')).toBeUndefined();
      expect(set(a, 2, 'Status')).toBeUndefined();
      expect(a).toHaveLength(1);
    });

    it('does nothing without -Sync', () => {
      expect(
        ofType(plan(state({ items: [item(1, { labels: ['pbi'] })] })), 'SetItem')
      ).toHaveLength(0);
    });
  });

  describe('-Sync labels', () => {
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
    const repo = (nameWithOwner: string, labels: object[] = []) => ({ nameWithOwner, labels });
    const labels = (repositories: object[] | undefined, ...flags: string[]) =>
      ofType(plan({ ...state(), repositories }, ...flags), 'EnsureLabel');

    it('emits both labels with exact colour and description for every repository', () => {
      const a = labels([repo('o/a'), repo('o/b')], '-Sync');
      expect(a).toEqual(
        ['o/a', 'o/b'].flatMap((r) =>
          [PLANNED, NEEDS_REVIEW].map((l) => ({ type: 'EnsureLabel', repo: r, ...l }))
        )
      );
    });

    it('emits nothing for matching labels, colour compared case-insensitively', () => {
      expect(
        labels([repo('o/a', [PLANNED, { ...NEEDS_REVIEW, color: 'fbca04' }])], '-Sync')
      ).toEqual([]);
    });

    it('emits one action for a differing colour or description', () => {
      expect(
        labels([repo('o/a', [{ ...PLANNED, color: 'FFFFFF' }, NEEDS_REVIEW])], '-Sync')
      ).toEqual([{ type: 'EnsureLabel', repo: 'o/a', ...PLANNED }]);
      expect(
        labels([repo('o/a', [PLANNED, { ...NEEDS_REVIEW, description: 'x' }])], '-Sync')
      ).toEqual([{ type: 'EnsureLabel', repo: 'o/a', ...NEEDS_REVIEW }]);
    });

    it('emits nothing without -Sync', () => {
      expect(labels([repo('o/a')])).toEqual([]);
    });

    it('emits nothing for a state without repositories', () => {
      expect(labels(undefined, '-Sync')).toEqual([]);
      expect(labels([], '-Sync')).toEqual([]);
    });
  });

  describe('views', () => {
    it('creates only the missing standard views with field names and grouping', () => {
      const views = ALL_VIEWS.filter((v) => v.name !== 'Board' && v.name !== 'Backlog');
      const creates = ofType(
        plan(state({ views: [...views, { id: 'V-x', name: 'Mine' }] })),
        'CreateView'
      );
      expect(creates.map((c) => c.name)).toEqual(['Board', 'Backlog']);
      expect(creates[0]).toMatchObject({
        layout: 'board',
        filter: '-label:epic,feature -status:Done',
        verticalGroupBy: 'Status',
      });
      expect(creates[1]).toMatchObject({ layout: 'table', groupBy: 'Parent issue' });
    });

    it('creates the Needs views and groups Release next by Milestone', () => {
      const s = state({ views: [] });
      const creates = ofType(plan(s), 'CreateView');
      const by = (n: string) => creates.find((c) => c.name === n)!;
      expect(creates.map((c) => c.name)).toEqual([
        'Hierarchy',
        'Board',
        'Release next',
        'Backlog',
        'Recently closed',
        'Needs me',
        'Ready for loop',
        'Blocked',
      ]);
      expect(by('Release next')).toMatchObject({ groupBy: 'Milestone' });
      expect(by('Needs me')).toMatchObject({
        layout: 'board',
        filter: 'is:open needs:Planning,Decision,Review,"Release review"',
        groupBy: null,
        verticalGroupBy: 'Needs',
        visibleFields: ['Title', 'Repository', 'Level', 'Milestone', 'Linked pull requests'],
      });
      expect(by('Ready for loop')).toMatchObject({
        layout: 'table',
        filter: 'is:open needs:Ready -level:Epic,Feature,Task',
        groupBy: 'Parent issue',
        visibleFields: ['Title', 'Repository', 'Level', 'Milestone', 'Parent issue'],
      });
      expect(by('Blocked')).toMatchObject({
        layout: 'table',
        filter: 'is:open needs:Blocked',
        groupBy: null,
        visibleFields: ['Title', 'Repository', 'Level', 'Parent issue', 'Labels'],
      });
    });

    it('lists the Release next manual step', () => {
      const file = path.join(dir, 'm.json');
      fs.writeFileSync(file, JSON.stringify({ projectId: 'P', ownerType: 'User', ...state() }));
      const r = spawnSync('pwsh', ['-NoProfile', '-File', SCRIPT, '-StateFile', file, '-Json'], {
        encoding: 'utf8',
      });
      expect(JSON.parse(r.stdout).manualSteps).toContain(
        'Release next view (created before Milestone grouping): set Group by Milestone (existing views are not updated).'
      );
    });

    it('never deletes foreign views', () => {
      const a = plan(
        state({ views: [...ALL_VIEWS, { id: 'V-x', name: 'Mine' }] }),
        '-RemoveDefaultViews'
      );
      expect(ofType(a, 'DeleteView')).toHaveLength(0);
    });
  });

  describe('-RemoveDefaultViews', () => {
    const defaults = [
      { id: 'V1', name: 'View 1' },
      { id: 'V2', name: 'View 12' },
      { id: 'V3', name: 'Probe' },
      { id: 'V4', name: 'Probe' },
      { id: 'V5', name: 'View of mine' },
    ];

    it('deletes View <n> and Probe when all standard views exist', () => {
      const a = plan(state({ views: [...ALL_VIEWS, ...defaults] }), '-RemoveDefaultViews');
      expect(ofType(a, 'DeleteView').map((d) => d.id)).toEqual(['V1', 'V2', 'V3', 'V4']);
    });

    it('plans the missing standard view before any deletion (it counts as existing afterwards)', () => {
      const guard = plan(
        state({ views: [...ALL_VIEWS.slice(0, 4), ...ALL_VIEWS.slice(5), ...defaults] }),
        '-RemoveDefaultViews'
      );
      expect(guard.findIndex((a) => a.type === 'CreateView')).toBeLessThan(
        guard.findIndex((a) => a.type === 'DeleteView')
      );
      expect(ofType(guard, 'CreateView').map((c) => c.name)).toEqual(['Recently closed']);
      expect(ofType(guard, 'DeleteView')).toHaveLength(4);
    });

    describe('Sprint planning', () => {
      const SP = { id: 'V-sp', name: 'Sprint planning' };
      const del = (views: { id: string; name: string }[], ...flags: string[]) =>
        ofType(plan(state({ views }), '-RemoveDefaultViews', ...flags), 'DeleteView').map(
          (d) => d.id
        );

      it('is deleted when both Needs views exist', () => {
        expect(del([...ALL_VIEWS, SP], '-Sprints')).toEqual(['V-sp']);
      });

      it('is deleted when the Needs views are only planned', () => {
        expect(del([...STANDARD_VIEWS, SP], '-Sprints')).toEqual(['V-sp']);
      });

      it('is kept when Sprint next does not exist and -Sprints is absent', () => {
        expect(del([...ALL_VIEWS, SP])).toEqual([]);
      });

      it('is deleted when Sprint next already exists, without -Sprints', () => {
        expect(del([...ALL_VIEWS, { id: 'V-sn', name: 'Sprint next' }, SP])).toEqual(['V-sp']);
      });

      it('is kept without the flag', () => {
        expect(ofType(plan(state({ views: [...ALL_VIEWS, SP] })), 'DeleteView')).toHaveLength(0);
      });

      it('never deletes Backlog, Hierarchy or Release next', () => {
        const ids = del([...ALL_VIEWS, SP], '-Sprints');
        expect(ids).not.toContain('V-Backlog');
        expect(ids).not.toContain('V-Hierarchy');
        expect(ids).not.toContain('V-Release next');
      });
    });

    it('deletes nothing without the flag', () => {
      expect(
        ofType(plan(state({ views: [...ALL_VIEWS, ...defaults] })), 'DeleteView')
      ).toHaveLength(0);
    });
  });

  describe('-Sprints', () => {
    const SPRINT = { id: 'F-Sprint', name: 'Sprint', databaseId: 99, dataType: 'ITERATION' };
    const sprints = (s: unknown) => plan(s, '-Sprints', '-Today', '2026-10-22');

    it('creates 12 weekly iterations titled by ISO week, starting on this Monday', () => {
      const [a] = ofType(sprints(state()), 'CreateIterationField');
      expect(a).toMatchObject({ name: 'Sprint', startDate: '2026-10-19', duration: 7 });
      expect(a.iterations).toHaveLength(12);
      expect(a.iterations[0]).toEqual({ title: '2026-W43', startDate: '2026-10-19', duration: 7 });
      expect(a.iterations[10].title).toBe('2026-W53');
      expect(a.iterations[11].title).toBe('2027-W01');
    });

    it('titles by ISO week-year across New Year', () => {
      const file = path.join(dir, 'ny.json');
      fs.writeFileSync(file, JSON.stringify({ projectId: 'P', ownerType: 'User', ...state() }));
      const r = spawnSync(
        'pwsh',
        [
          '-NoProfile',
          '-File',
          SCRIPT,
          '-StateFile',
          file,
          '-Sprints',
          '-Today',
          '2027-01-01',
          '-Json',
        ],
        { encoding: 'utf8' }
      );
      const [a] = ofType(JSON.parse(r.stdout).actions, 'CreateIterationField');
      expect(a.iterations.slice(0, 2).map((i: any) => i.title)).toEqual(['2026-W53', '2027-W01']);
    });

    it('adds the Sprint board and the Sprint next board, behind the field', () => {
      const a = sprints(state());
      const creates = ofType(a, 'CreateView');
      expect(creates.map((c) => c.name)).toEqual(['Sprint', 'Sprint next']);
      expect(creates[0]).toMatchObject({
        layout: 'board',
        filter: 'sprint:@current -level:Epic,Feature,Task',
        groupBy: 'Repository',
        verticalGroupBy: 'Status',
      });
      expect(creates[1]).toMatchObject({
        layout: 'board',
        filter: 'sprint:@next -level:Epic,Feature,Task',
        groupBy: 'Repository',
        verticalGroupBy: 'Status',
      });
      expect(a.findIndex((x) => x.type === 'CreateIterationField')).toBeLessThan(
        a.findIndex((x) => x.type === 'CreateView')
      );
    });

    it('is idempotent and leaves an existing Sprint field and views alone', () => {
      const views = [
        ...ALL_VIEWS,
        { id: 'V-s', name: 'Sprint' },
        { id: 'V-p', name: 'Sprint next' },
      ];
      expect(
        sprints(
          state({ status: [opt('Todo'), opt('In release'), opt('Done')], fields: [SPRINT], views })
        )
      ).toEqual([]);
    });

    it('adds nothing without the flag', () => {
      const a = plan(state());
      expect(ofType(a, 'CreateIterationField')).toHaveLength(0);
      expect(ofType(a, 'CreateView').map((c) => c.name)).not.toContain('Sprint');
    });
  });

  it('is idempotent: a standard state yields no actions', () => {
    const items = [
      item(1, { labels: ['pbi'], status: 'Todo', level: 'PBI' }),
      item(2, { labels: ['merged', 'task'], status: 'In release', level: 'Task' }),
      item(3, { state: 'CLOSED', status: 'Done', level: 'Bug' }),
    ];
    const status = [opt('Todo'), opt('In release'), opt('Done')];
    expect(
      plan(state({ status, items }), '-Sync', '-RemoveDefaultViews').filter(
        (a) => a.type !== 'syncNeeds'
      )
    ).toEqual([]);
  });

  describe('Needs sync', () => {
    it('lists the syncNeeds action with -Sync', () => {
      const a = plan(state({}), '-Sync', '-Owner', 'o', '-Number', '17');
      expect(ofType(a, 'syncNeeds')).toEqual([{ type: 'syncNeeds', owner: 'o', number: 17 }]);
    });

    it('has no syncNeeds action without -Sync', () => {
      expect(ofType(plan(state({})), 'syncNeeds')).toHaveLength(0);
    });
  });
});

describe.skipIf(!hasPwsh || spawnSync('node', ['-v']).status !== 0 || process.platform === 'win32')(
  'Set-ProjectStandard.ps1 -Sync live',
  () => {
    let dir: string;
    beforeEach(() => {
      dir = fs.mkdtempSync(path.join(os.tmpdir(), 'projstd-live-'));
    });
    afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

    // Needs queries carry subIssues, the plain item/repository queries of Set-ProjectStandard do not.
    const handler = (failNeeds: boolean) => `(call) => {
      const q = call.query || '';
      if (q.includes('projectV2(number')) return { repositoryOwner: { __typename: 'User', projectV2: { id: 'P1',
        fields: { nodes: [{ __typename: 'ProjectV2SingleSelectField', id: 'F-status', name: 'Status', options: [] },
          { __typename: 'ProjectV2SingleSelectField', id: 'F-needs', name: 'Needs', options: [] }] },
        views: { nodes: [] } } } };
      if (q.includes('items(first: 100')) {
        ${failNeeds ? "if (q.includes('subIssues')) throw new Error('graphql down');" : ''}
        return { node: { items: { pageInfo: { hasNextPage: false, endCursor: null }, nodes: [] } } };
      }
      if (q.includes('repositories(first')) return { node: { repositories: { nodes: [] } } };
      return {};
    }`;
    const sync = (failNeeds: boolean) => {
      const gh = createFakeGh(dir, handler(failNeeds));
      const r = spawnSync(
        'pwsh',
        ['-NoProfile', '-File', SCRIPT, '-Owner', 'o', '-Number', '1', '-Sync', '-DryRun'],
        { cwd: dir, encoding: 'utf8', env: gh.env() }
      );
      return { r, gh };
    };

    it('runs the Needs sync after its own plan', () => {
      const { r, gh } = sync(false);
      expect(r.status, r.stderr + r.stdout).toBe(0);
      expect(r.stdout).not.toContain('Needs sync failed');
      expect(gh.calls().some((c) => c.query?.includes('subIssues'))).toBe(true);
    });

    it('a failing Needs sync is one warning and the run still exits 0', () => {
      const { r } = sync(true);
      expect(r.status, r.stderr + r.stdout).toBe(0);
      expect(r.stdout.match(/Warning: Needs sync failed/g)).toHaveLength(1);
    });
  }
);
