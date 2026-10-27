import { spawnSync } from 'child_process';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { PwshWorker } from '../helpers/pwsh-worker';

const SCRIPT = path.resolve(
  __dirname,
  '../../.apm/skills/github-project/scripts/Sync-ProjectNeeds.ps1'
);

const hasPwsh = spawnSync('pwsh', ['-NoProfile', '-Command', '1']).status === 0;

it('pwsh is installed in CI (the Sync-ProjectNeeds cases must not be skipped there)', () => {
  if (process.env.CI) expect(hasPwsh).toBe(true);
});

type Item = Record<string, unknown>;
const base = (over: Item): Item => ({
  itemId: `I-${over.number}`,
  repo: 'o/r',
  number: 1,
  state: 'OPEN',
  level: 'PBI',
  labels: [],
  status: 'Todo',
  needs: null,
  blockedByOpen: 0,
  subIssueLevels: ['Task'],
  prHeads: [],
  parent: null,
  ...over,
});

describe.skipIf(!hasPwsh)('Sync-ProjectNeeds', () => {
  let worker: PwshWorker;
  let tmp: string;
  beforeAll(() => {
    worker = new PwshWorker(SCRIPT);
  });
  afterAll(() => worker.close());
  beforeEach(() => {
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'needs-'));
  });
  afterEach(() => fs.rmSync(tmp, { recursive: true, force: true }));

  const run = async (items: Item[], args: string[] = [], cwd = tmp) => {
    const file = path.join(tmp, 'state.json');
    fs.writeFileSync(file, JSON.stringify({ owner: 'o', number: 1, items }));
    const r = await worker.run(['-StateFile', file, '-Json', ...args], { cwd });
    expect(r.stderr).toBe('');
    expect(r.status).toBe(0);
    return JSON.parse(r.stdout) as {
      project: { owner: string; number: number };
      actions: { issue: string; item: string; from: string | null; to: string | null }[];
      skipped: string[];
    };
  };

  const rules: [string, Item, string | null][] = [
    ['closed clears', { state: 'CLOSED', labels: ['needs-decision'] }, null],
    ['needs-decision', { labels: ['needs-decision'] }, 'Decision'],
    ['needs-review', { labels: ['needs-review'] }, 'Review'],
    ['open blocked-by', { blockedByOpen: 2 }, 'Blocked'],
    ['blockedByOpen true', { blockedByOpen: true }, 'Blocked'],
    ['label merged', { labels: ['merged'] }, 'Release review'],
    ['status In release', { status: 'In release' }, 'Release review'],
    ['PR head with number', { number: 7, prHeads: ['feat/7-x'] }, 'In progress'],
    ['PR head at start', { number: 7, prHeads: ['7-x'] }, 'In progress'],
    ['PR head of another issue', { number: 7, prHeads: ['feat/17-x'] }, 'Ready'],
    ['status In Progress', { status: 'In Progress' }, 'In progress'],
    ['Epic without Features', { level: 'Epic', subIssueLevels: [] }, 'Planning'],
    ['Epic with Features', { level: 'Epic', subIssueLevels: ['Feature'] }, null],
    ['Feature without PBIs', { level: 'Feature', subIssueLevels: [] }, 'Planning'],
    ['Feature with PBIs', { level: 'Feature', subIssueLevels: ['PBI'] }, null],
    ['PBI without Tasks', { subIssueLevels: [] }, 'Planning'],
    ['PBI without Tasks but planned', { subIssueLevels: [], labels: ['planned'] }, 'Ready'],
    ['PBI with Tasks', { subIssueLevels: ['Task'] }, 'Ready'],
    ['Bug is PBI-level', { level: 'Bug', subIssueLevels: ['Task'] }, 'Ready'],
    ['unknown level is PBI-level', { level: null, subIssueLevels: ['Task'] }, 'Ready'],
    // precedence
    ['decision beats blocked', { labels: ['needs-decision'], blockedByOpen: 1 }, 'Decision'],
    ['decision beats review', { labels: ['needs-review', 'needs-decision'] }, 'Decision'],
    ['blocked beats merged', { blockedByOpen: 1, labels: ['merged'] }, 'Blocked'],
    ['merged beats in progress', { labels: ['merged'], status: 'In Progress' }, 'Release review'],
    ['in progress beats planning', { status: 'In Progress', subIssueLevels: [] }, 'In progress'],
    ['Epic with needs-review', { level: 'Epic', labels: ['needs-review'] }, 'Review'],
  ];

  it.each(rules)('%s', async (_n, over, expected) => {
    const from = expected === null ? 'Ready' : null;
    const { actions } = await run([base({ number: 1, ...over, needs: from })]);
    if (expected === 'Ready' && from === null) {
      expect(actions).toEqual([
        {
          issue: 'o/r#' + (over.number ?? 1),
          item: `I-${over.number ?? 1}`,
          from: null,
          to: 'Ready',
        },
      ]);
    } else {
      expect(actions).toHaveLength(1);
      expect(actions[0].to).toBe(expected);
    }
  });

  it('unchanged items and empty-string needs yield no action', async () => {
    const { actions } = await run([
      base({ number: 1, needs: 'Ready' }),
      base({ number: 2, level: 'Epic', subIssueLevels: ['Feature'], needs: '' }),
      base({ number: 3, state: 'CLOSED', needs: null }),
    ]);
    expect(actions).toEqual([]);
  });

  it('reports from and clears a closed item', async () => {
    const { actions } = await run([base({ number: 4, state: 'CLOSED', needs: 'Blocked' })]);
    expect(actions).toEqual([{ issue: 'o/r#4', item: 'I-4', from: 'Blocked', to: null }]);
  });

  describe('scope', () => {
    const items = [
      base({ number: 1, repo: 'o/a', needs: 'Blocked' }),
      base({ number: 2, repo: 'o/a', needs: 'Blocked' }),
      base({ number: 1, repo: 'o/b', needs: 'Blocked' }),
      base({
        number: 9,
        repo: 'o/a',
        level: 'Feature',
        subIssueLevels: ['PBI'],
        needs: 'Planning',
      }),
    ];
    const withParent = [
      base({ number: 2, repo: 'o/a', parent: 9, needs: 'Blocked' }),
      base({ number: 3, repo: 'o/a', parent: { repo: 'o/b', number: 5 }, needs: 'Blocked' }),
      base({
        number: 9,
        repo: 'o/a',
        level: 'Feature',
        subIssueLevels: ['PBI'],
        needs: 'Planning',
      }),
      base({
        number: 5,
        repo: 'o/b',
        level: 'Feature',
        subIssueLevels: ['PBI'],
        needs: 'Planning',
      }),
    ];
    const ids = (a: { issue: string }[]) => a.map((x) => x.issue).sort();

    it('-Repo limits to one repository and lists the rest as skipped', async () => {
      const r = await run(items, ['-Repo', 'o/b']);
      expect(ids(r.actions)).toEqual(['o/b#1']);
      expect(r.skipped.sort()).toEqual(['o/a#1', 'o/a#2', 'o/a#9']);
    });
    it('-Issue with bare numbers matches every repository', async () => {
      expect(ids((await run(items, ['-Issue', '1'])).actions)).toEqual(['o/a#1', 'o/b#1']);
    });
    it('-Issue list and owner/repo#n', async () => {
      expect(ids((await run(items, ['-Issue', '2,o/b#1'])).actions)).toEqual(['o/a#2', 'o/b#1']);
    });
    it('-Issue with -Repo combine', async () => {
      expect(ids((await run(items, ['-Issue', '1', '-Repo', 'o/a'])).actions)).toEqual(['o/a#1']);
    });
    it('-IncludeParents adds the parent of a selected issue', async () => {
      expect(ids((await run(withParent, ['-Issue', '2', '-IncludeParents'])).actions)).toEqual([
        'o/a#2',
        'o/a#9',
      ]);
    });
    it('-IncludeParents follows a parent in another repository', async () => {
      expect(ids((await run(withParent, ['-Issue', '3', '-IncludeParents'])).actions)).toEqual([
        'o/a#3',
        'o/b#5',
      ]);
    });
    it('without -IncludeParents the parent stays out', async () => {
      expect(ids((await run(withParent, ['-Issue', '2'])).actions)).toEqual(['o/a#2']);
    });
    describe('-IncludeDependents', () => {
      const ref = (repo: string, number: number) => ({ repo, number });
      const dep = [
        base({
          number: 5,
          repo: 'o/a',
          needs: 'Blocked',
          blocking: [ref('o/a', 6), ref('o/a', 7), ref('o/b', 8)],
        }),
        base({ number: 6, repo: 'o/a', needs: 'Blocked' }),
        base({ number: 7, repo: 'o/a', state: 'CLOSED', needs: 'Blocked' }),
        base({ number: 8, repo: 'o/b', needs: 'Blocked' }),
        base({ number: 9, repo: 'o/a', needs: 'Blocked' }),
      ];
      it('adds the open issues #5 blocks, skips closed ones and follows another repository', async () => {
        const r = await run(dep, ['-Issue', 'o/a#5', '-IncludeDependents']);
        expect(ids(r.actions)).toEqual(['o/a#5', 'o/a#6', 'o/b#8']);
        expect(r.skipped.sort()).toEqual(['o/a#7', 'o/a#9']);
      });
      it('without the switch the dependents stay out', async () => {
        expect(ids((await run(dep, ['-Issue', 'o/a#5'])).actions)).toEqual(['o/a#5']);
      });
      it('without -Issue the switch changes nothing', async () => {
        const plain = await run(dep);
        const withSwitch = await run(dep, ['-IncludeDependents']);
        expect(withSwitch).toEqual(plain);
      });
      it('a dependent that is also the parent is synced once with -IncludeParents', async () => {
        const items = [
          base({ number: 5, repo: 'o/a', parent: 9, needs: 'Blocked', blocking: [ref('o/a', 9)] }),
          base({
            number: 9,
            repo: 'o/a',
            level: 'Feature',
            subIssueLevels: ['PBI'],
            needs: 'Planning',
          }),
        ];
        const r = await run(items, ['-Issue', '5', '-IncludeParents', '-IncludeDependents']);
        expect(ids(r.actions)).toEqual(['o/a#5', 'o/a#9']);
        expect(r.actions).toHaveLength(2);
      });
      it('does not follow the dependents of a dependent', async () => {
        const items = [
          base({ number: 5, repo: 'o/a', needs: 'Blocked', blocking: [ref('o/a', 6)] }),
          base({ number: 6, repo: 'o/a', needs: 'Blocked', blocking: [ref('o/a', 9)] }),
          base({ number: 9, repo: 'o/a', needs: 'Blocked' }),
        ];
        const r = await run(items, ['-Issue', '5', '-IncludeDependents']);
        expect(ids(r.actions)).toEqual(['o/a#5', 'o/a#6']);
      });
    });
    it('rejects an invalid issue reference', async () => {
      const file = path.join(tmp, 's.json');
      fs.writeFileSync(file, JSON.stringify({ owner: 'o', number: 1, items: [] }));
      const r = await worker.run(['-StateFile', file, '-Issue', 'abc'], { cwd: tmp });
      expect(r.status).not.toBe(0);
      expect(r.stderr).toContain('Invalid issue reference');
    });
  });

  describe('project reference', () => {
    const git = (dir: string) => {
      fs.mkdirSync(path.join(dir, '.git'));
    };
    const noState = (extra: string[] = []) => ['-StateFile', path.join(tmp, 'none.json'), ...extra];

    it('-Owner and -Number win', async () => {
      fs.mkdirSync(path.join(tmp, '.agents'));
      fs.writeFileSync(
        path.join(tmp, '.agents/project.json'),
        JSON.stringify({ owner: 'x', number: 9 })
      );
      const r = await run([], ['-Owner', 'ow', '-Number', '5']);
      expect(r.project).toEqual({ owner: 'ow', number: 5 });
    });
    it('reads .agents/project.json at the repository root', async () => {
      git(tmp);
      fs.mkdirSync(path.join(tmp, '.agents'));
      fs.writeFileSync(
        path.join(tmp, '.agents/project.json'),
        JSON.stringify({ owner: 'cfg', number: 3 })
      );
      const file = path.join(tmp, 'state.json');
      fs.writeFileSync(file, JSON.stringify({ items: [] }));
      const r = await worker.run(['-StateFile', file, '-Json'], { cwd: tmp });
      expect(JSON.parse(r.stdout).project).toEqual({ owner: 'cfg', number: 3 });
    });
    it.each(['add-to-project.yml', 'add-to-project.yaml'])(
      'parses project-url from %s',
      async (name) => {
        git(tmp);
        fs.mkdirSync(path.join(tmp, '.github/workflows'), { recursive: true });
        fs.writeFileSync(
          path.join(tmp, '.github/workflows', name),
          'jobs:\n  a:\n    steps:\n      - with:\n          project-url: https://github.com/orgs/GravionLabs/projects/17\n'
        );
        const file = path.join(tmp, 'state.json');
        fs.writeFileSync(file, JSON.stringify({ items: [] }));
        const r = await worker.run(['-StateFile', file, '-Json'], { cwd: tmp });
        expect(JSON.parse(r.stdout).project).toEqual({ owner: 'GravionLabs', number: 17 });
      }
    );
    const projectOf = async (files: Record<string, string>) => {
      git(tmp);
      fs.mkdirSync(path.join(tmp, '.github/workflows'), { recursive: true });
      for (const [n, c] of Object.entries(files))
        fs.writeFileSync(path.join(tmp, '.github/workflows', n), c);
      const file = path.join(tmp, 'state.json');
      fs.writeFileSync(file, JSON.stringify({ items: [] }));
      const r = await worker.run(['-StateFile', file, '-Json'], { cwd: tmp });
      return r.stdout.startsWith('Needs sync skipped') ? null : JSON.parse(r.stdout).project;
    };
    const url = (o: string, n: number) =>
      `jobs:\n  a:\n    with:\n      project-url: https://github.com/orgs/${o}/projects/${n}\n`;
    it('parses project-url from a reusable-workflow caller such as issue-events.yml', async () => {
      expect(await projectOf({ 'issue-events.yml': url('GravionLabs', 17) })).toEqual({
        owner: 'GravionLabs',
        number: 17,
      });
    });
    it('add-to-project.yml wins over another workflow file', async () => {
      expect(
        await projectOf({ 'a-first.yml': url('Other', 2), 'add-to-project.yml': url('Mine', 5) })
      ).toEqual({ owner: 'Mine', number: 5 });
    });
    it('other workflow files are scanned in name order', async () => {
      expect(await projectOf({ 'b.yml': url('B', 2), 'a.yaml': url('A', 1) })).toEqual({
        owner: 'A',
        number: 1,
      });
    });
    it('a placeholder project-url is not a match', async () => {
      expect(
        await projectOf({
          'issue-events.yml':
            'with:\n  project-url: https://github.com/orgs/<owner>/projects/<n>\n',
        })
      ).toBeNull();
    });
    it('prints the skip line and exits 0 when no project is configured', async () => {
      git(tmp);
      const file = path.join(tmp, 'state.json');
      fs.writeFileSync(file, JSON.stringify({ items: [] }));
      const r = await worker.run(['-StateFile', file], { cwd: tmp });
      expect(r.status).toBe(0);
      expect(r.stdout.trim()).toBe('Needs sync skipped: no project configured');
    });
    it('rejects -Owner without -Number', async () => {
      const r = await worker.run(noState(['-Owner', 'x']), { cwd: tmp });
      expect(r.status).not.toBe(0);
      expect(r.stderr).toContain('go together');
    });
  });

  it('prints text actions without -Json', async () => {
    const file = path.join(tmp, 's.json');
    fs.writeFileSync(
      file,
      JSON.stringify({
        owner: 'o',
        number: 1,
        items: [base({ number: 4, labels: ['needs-review'] })],
      })
    );
    const r = await worker.run(['-StateFile', file, '-DryRun'], { cwd: tmp });
    expect(r.stdout.trim()).toBe('o/r#4: Needs (none) -> Review');
  });
  describe('-SetStatus', () => {
    const state = (items: Item[]) => {
      const file = path.join(tmp, 'state.json');
      fs.writeFileSync(file, JSON.stringify({ owner: 'o', number: 1, items }));
      return file;
    };
    it('with -StateFile only reports the action', async () => {
      const file = state([base({ number: 7 })]);
      const r = await worker.run(
        ['-StateFile', file, '-Issue', 'o/r#7', '-SetStatus', 'In Progress', '-Json'],
        { cwd: tmp }
      );
      expect(r.status).toBe(0);
      expect(JSON.parse(r.stdout).actions).toEqual([
        { issue: 'o/r#7', item: 'I-7', field: 'Status', to: 'In Progress' },
      ]);
    });
    it('an issue outside the project is one line, exit 0', async () => {
      const file = state([base({ number: 7 })]);
      const r = await worker.run(
        ['-StateFile', file, '-Issue', 'o/r#8', '-SetStatus', 'In Progress'],
        { cwd: tmp }
      );
      expect(r.status).toBe(0);
      expect(r.stdout.trim()).toBe('Status not set: #8 is not in the project');
    });
    it('needs exactly one -Issue', async () => {
      const file = state([base({ number: 7 })]);
      const r = await worker.run(
        ['-StateFile', file, '-Issue', 'o/r#7,o/r#8', '-SetStatus', 'In Progress'],
        { cwd: tmp }
      );
      expect(r.status).not.toBe(0);
      expect(r.stderr).toContain('exactly one -Issue');
    });
  });
});
