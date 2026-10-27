import { spawnSync } from 'child_process';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';

const SCRIPT = path.resolve(
  __dirname,
  '../../.apm/skills/github-project/scripts/Set-Sprint.ps1'
);
const hasPwsh = spawnSync('pwsh', ['-NoProfile', '-Command', '1']).status === 0;

it('pwsh is installed in CI (the Set-Sprint cases must not be skipped there)', () => {
  if (process.env.CI) expect(hasPwsh).toBe(true);
});

const W43 = '2026-W43';
const ITERATIONS = ['2026-W42', W43, '2026-W44'].map((title) => ({ id: `it-${title}`, title }));
interface Item {
  id: string;
  repo: string;
  number: number;
  state: string;
  level?: string;
  status?: string;
  sprint?: string;
  blockedBy?: { repo: string; number: number; state: string }[];
}
let n = 0;
const item = (repo: string, o: Partial<Item> = {}): Item => ({
  id: `I-${++n}`,
  repo,
  number: n,
  state: 'OPEN',
  level: 'PBI',
  status: 'Todo',
  ...o,
});
const many = (count: number, repo: string, o: Partial<Item> = {}) =>
  Array.from({ length: count }, () => item(repo, o));
const ref = (i: Item) => `${i.repo}#${i.number}`;

describe.skipIf(!hasPwsh)('Set-Sprint.ps1 -StateFile', () => {
  let dir: string;
  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sprint-'));
  });
  afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

  const run = (items: Item[], targets: string[], ...flags: string[]) => {
    const file = path.join(dir, 'state.json');
    fs.writeFileSync(
      file,
      JSON.stringify({
        projectId: 'P',
        sprintField: { id: 'F-Sprint', iterations: ITERATIONS },
        items,
      })
    );
    const r = spawnSync(
      'pwsh',
      [
        '-NoProfile',
        '-File',
        SCRIPT,
        '-StateFile',
        file,
        '-Today',
        '2026-10-22',
        '-Json',
        '-Issue',
        targets.join(','),
        ...flags,
      ],
      { cwd: dir, encoding: 'utf8' }
    );
    return { status: r.status, out: r.stdout.trim() ? JSON.parse(r.stdout) : null, err: r.stderr };
  };
  const types = (r: ReturnType<typeof run>) => r.out.violations.map((v: any) => v.type);

  it('assigns to the current ISO week by default and reports the iteration id', () => {
    const a = item('o/a');
    const r = run([a], [ref(a)]);
    expect(r.status, r.err).toBe(0);
    expect(r.out.sprint).toBe(W43);
    expect(r.out.assign).toEqual([
      { item: a.id, issue: ref(a), iteration: `it-${W43}`, sprint: W43, previous: null },
    ]);
  });

  it('takes an explicit sprint and a default repository for #n', () => {
    const a = item('o/a');
    const r = run([a], [`#${a.number}`], '-Repo', 'o/a', '-Sprint', '2026-W44');
    expect(r.out.assign[0]).toMatchObject({
      issue: ref(a),
      iteration: 'it-2026-W44',
      sprint: '2026-W44',
    });
  });

  it('skips an item that is already in the sprint', () => {
    const a = item('o/a', { sprint: W43 });
    expect(run([a], [ref(a)]).out.assign).toEqual([]);
  });

  describe('limits', () => {
    it('allows exactly 30 per sprint (3 repos x 10) and refuses the 31st', () => {
      const items = [
        ...many(10, 'o/a', { sprint: W43 }),
        ...many(10, 'o/b', { sprint: W43 }),
        ...many(9, 'o/c', { sprint: W43 }),
      ];
      const c = item('o/c');
      expect(run([...items, c], [ref(c)]).status).toBe(0);
      const d = item('o/d');
      const r = run([...items, item('o/c', { sprint: W43 }), d], [ref(d)]);
      expect(r.status).toBe(1);
      expect(types(r)).toEqual(['SprintFull']);
      expect(r.out.violations[0].message).toContain('limit 30');
    });

    it('refuses an 11th PBI of one repository per sprint', () => {
      const a = item('o/a');
      const r = run([...many(10, 'o/a', { sprint: W43 }), a], [ref(a)]);
      expect(r.status).toBe(1);
      expect(types(r)).toEqual(['RepoFull']);
    });

    it('refuses a repository with 10 PBIs In release, whatever their sprint', () => {
      const a = item('o/a');
      const r = run(
        [...many(10, 'o/a', { status: 'In release', sprint: '2026-W42' }), a],
        [ref(a)]
      );
      expect(r.status).toBe(1);
      expect(types(r)).toEqual(['ReleaseFull']);
      expect(r.out.violations[0].message).toContain('github-release');
    });

    it('counts only open PBIs and Bugs, not Tasks, Features or closed items', () => {
      const a = item('o/a');
      const noise = [
        ...many(3, 'o/a', { sprint: W43, level: 'Task' }),
        ...many(3, 'o/a', { sprint: W43, state: 'CLOSED' }),
        ...many(10, 'o/a', { status: 'In release', level: 'Task' }),
      ];
      expect(run([...noise, ...many(8, 'o/a', { sprint: W43 }), a], [ref(a)]).status).toBe(0);
      const bug = item('o/a', { level: 'Bug' });
      expect(run([...many(10, 'o/a', { sprint: W43 }), bug], [ref(bug)]).status).toBe(1);
    });

    it('is all or nothing: one violation assigns none of the targets', () => {
      const ok = item('o/b');
      const full = item('o/a');
      const r = run([...many(10, 'o/a', { sprint: W43 }), full, ok], [ref(ok), ref(full)]);
      expect(r.status).toBe(1);
      expect(r.out.violations).toHaveLength(1);
    });

    it('-Force overrides the limits but still reports them', () => {
      const a = item('o/a');
      const r = run([...many(10, 'o/a', { sprint: W43 }), a], [ref(a)], '-Force');
      expect(r.status).toBe(0);
      expect(types(r)).toEqual(['RepoFull']);
      expect(r.out.assign).toHaveLength(1);
    });

    it('limits are parameters', () => {
      const a = item('o/a');
      expect(types(run([item('o/a', { sprint: W43 }), a], [ref(a)], '-MaxPerRepo', '1'))).toEqual([
        'RepoFull',
      ]);
      expect(types(run([item('o/a', { sprint: W43 }), a], [ref(a)], '-MaxPerSprint', '1'))).toEqual(
        ['SprintFull']
      );
    });
  });

  // Native blocked-by links; the live run reads them per target, the state file carries them as items[].blockedBy.
  describe('dependency order', () => {
    const blockedBy = (...blockers: Item[]) =>
      blockers.map((b) => ({ repo: b.repo, number: b.number, state: b.state }));

    it('refuses a PBI whose open blocker is in no sprint and names the blocker', () => {
      const blocker = item('o/a');
      const a = item('o/a', { blockedBy: blockedBy(blocker) });
      const r = run([blocker, a], [ref(a)]);
      expect(r.status).toBe(1);
      expect(types(r)).toEqual(['Blocked']);
      expect(r.out.violations[0]).toMatchObject({ issue: ref(a), blocker: ref(blocker) });
      expect(r.out.violations[0].message).toContain('no sprint');
    });

    it('refuses a blocker planned for a later sprint', () => {
      const blocker = item('o/a', { sprint: '2026-W44' });
      const a = item('o/a', { blockedBy: blockedBy(blocker) });
      const r = run([blocker, a], [ref(a)]);
      expect(types(r)).toEqual(['Blocked']);
      expect(r.out.violations[0].message).toContain('sprint 2026-W44');
    });

    it('allows blockers in the same or an earlier sprint, assigned in the same run, closed, or of another repository', () => {
      const same = item('o/a', { sprint: W43 });
      const earlier = item('o/a', { sprint: '2026-W42' });
      const together = item('o/a');
      const closed = item('o/a', { state: 'CLOSED' });
      const foreign = item('o/b', { sprint: W43 });
      const a = item('o/a', { blockedBy: blockedBy(same, earlier, together, closed, foreign) });
      const r = run([same, earlier, together, closed, foreign, a], [ref(a), ref(together)]);
      expect(r.status, r.err).toBe(0);
      expect(r.out.assign.map((x: any) => x.issue)).toEqual([ref(a), ref(together)]);
    });

    it('a blocker that is no project item still blocks (REST state is lower case)', () => {
      const a = item('o/a', { blockedBy: [{ repo: 'o/a', number: 999, state: 'open' }] });
      expect(types(run([a], [ref(a)]))).toEqual(['Blocked']);
    });
  });

  describe('input errors', () => {
    it('refuses an issue that is not an item of the project', () => {
      const r = run([item('o/a')], ['o/a#999']);
      expect(r.status).toBe(1);
      expect(types(r)).toEqual(['NotInProject']);
    });

    it('refuses closed items and levels other than PBI/Bug', () => {
      const closed = item('o/a', { state: 'CLOSED' });
      const feature = item('o/a', { level: 'Feature' });
      const none = item('o/a', { level: undefined });
      const r = run([closed, feature, none], [ref(closed), ref(feature), ref(none)]);
      expect(types(r)).toEqual(['Closed', 'NotAPbi', 'NotAPbi']);
      expect(r.out.assign).toEqual([]);
    });

    it('refuses a sprint that is not in the project and assigns nothing', () => {
      const a = item('o/a');
      const r = run([a], [ref(a)], '-Sprint', '2030-W01');
      expect(r.status).toBe(1);
      expect(types(r)).toEqual(['NoSuchSprint']);
      expect(r.out.assign).toEqual([]);
    });

    it('rejects a malformed sprint title', () => {
      const a = item('o/a');
      expect(run([a], [ref(a)], '-Sprint', 'Sprint 43').status).not.toBe(0);
    });
  });
});

describe('GraphQL here-strings in the project scripts', () => {
  const dir = path.resolve(
    __dirname,
    '../../.apm/skills/github-project/scripts'
  );
  const queries = ['Set-Sprint.ps1', 'Set-ProjectStandard.ps1'].flatMap((file) => {
    const text = fs.readFileSync(path.join(dir, file), 'utf8');
    return [...text.matchAll(/\$(\w+) = @'\r?\n([\s\S]*?)\r?\n'@/g)].map(
      (m) => [`${file} $${m[1]}`, m[2]] as const
    );
  });

  it('finds the queries', () => {
    expect(queries.length).toBeGreaterThanOrEqual(4);
  });

  // The live queries never run offline (-StateFile): an unbalanced brace only fails against GitHub (#507).
  it.each(queries)('%s has balanced braces and parentheses', (_name, query) => {
    const count = (c: string) => query.split(c).length - 1;
    expect(count('{')).toBe(count('}'));
    expect(count('(')).toBe(count(')'));
  });
});
