import { spawnSync } from 'child_process';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { createFakeGh } from '../helpers/fake-gh';
import { PwshWorker } from '../helpers/pwsh-worker';

const itemNr = (c: { args: string[] }) => Number(c.args[3].split('/').pop());
const restPath = (c: { args: string[] }) =>
  c.args.find((a) => /^(users|orgs|repos)\//.test(a)) ?? '';
const SCRIPT = path.resolve(
  __dirname,
  '../../.apm/skills/github-project/scripts/Sync-ProjectNeeds.ps1',
);

const hasPwsh = spawnSync('pwsh', ['-NoProfile', '-Command', '1']).status === 0;
const hasNode = spawnSync('node', ['-v']).status === 0;

it('pwsh is installed in CI (the live Sync-ProjectNeeds cases must not be skipped there)', () => {
  if (process.env.CI) expect(hasPwsh).toBe(true);
});

// Canned REST answers (the script reads and writes through REST only).
// data.json: {items (REST project items), subIssues/blockedBy/blocking ({"o/r#n": list}), issueTypes ({"o/r#n": name}),
//   prs ({"o/r": [head refs]}), ownerType, noNeeds, noStatusOption, noProject, failMutation}.
const FIELDS = (d: any) => [
  ...(d.onlyNeeds ? [] : [{ id: 101, name: 'Status', data_type: 'single_select',
    options: d.noStatusOption ? [{ id: 'O-todo', name: { raw: 'Todo' } }] : [{ id: 'O-todo', name: { raw: 'Todo' } }, { id: 'O-ip', name: { raw: 'In Progress' } }, { id: 'O-done', name: { raw: 'Done' } }] }]),
  ...(d.onlyNeeds ? [] : [{ id: 102, name: 'Level', data_type: 'single_select', options: [] }]),
  ...(d.noNeeds ? [] : [{ id: 103, name: 'Needs', data_type: 'single_select',
    options: ['Planning','Ready','In progress','Blocked','Review','Decision','Release review'].map((n) => ({ id: 'O-' + n, name: { raw: n } })) }]),
  ...(d.withCurrent ? [{ id: 106, name: 'Current', data_type: 'single_select', options: [{ id: 'O-yes', name: { raw: 'Yes' } }] }] : []),
  ...(d.onlyNeeds ? [] : [{ id: 104, name: 'Parent issue', data_type: 'parent_issue', options: null },
    { id: 105, name: 'Linked pull requests', data_type: 'linked_pull_requests', options: null }]),
];
const HANDLER = `(call, ctx) => {
  const fs = require('fs');
  const d = JSON.parse(fs.readFileSync(process.env.FAKE_DATA, 'utf8'));
  const FIELDS = ${FIELDS.toString()};
  const path = call.args.find((a) => /^(users|orgs|repos)\\//.test(a)) || '';
  const slurp = call.args.includes('--slurp');
  const list = (all) => slurp ? Array.from({ length: Math.max(1, Math.ceil(all.length / 100)) }, (_, i) => all.slice(i * 100, i * 100 + 100)) : all;
  const key = (p, re) => { const m = p.match(re); return m[1] + '#' + m[2]; };
  if (call.args.includes('PATCH')) {
    if (d.archivedItem && call.args.some((a) => a.endsWith('/items/' + d.archivedItem))) throw new Error('HTTP 422: The item is archived and cannot be updated');
    if (d.failMutation && ctx.count('mut') <= d.failMutation) throw new Error('secondary rate limit');
    return { rest: {} };
  }
  if (path === 'users/o') return { rest: { login: 'o', type: d.ownerType || 'User' } };
  if (/^(users|orgs)\\/o\\/projectsV2\\/1$/.test(path)) {
    if (d.noProject) throw new Error('HTTP 404: Not Found');
    return { rest: { id: 99, number: 1 } };
  }
  if (path.includes('/projectsV2/1/fields')) return { rest: list(FIELDS(d)) };
  if (path.includes('/projectsV2/1/items')) {
    const q = (path.match(/[?&]q=repo:([^&]+)/) || [])[1];
    const all = d.items.filter((i) => !q || !i.content || i.content.repository.full_name === q);
    return { rest: list(all) };
  }
  if (path.startsWith('users/o/repos')) return { rest: list(d.repos || []) };
  let m;
  if ((m = path.match(/^repos\\/([^/]+\\/[^/]+)\\/issues\\/(\\d+)\\/(sub_issues|dependencies\\/blocked_by|dependencies\\/blocking)/))) {
    const map = { sub_issues: d.subIssues, 'dependencies/blocked_by': d.blockedBy, 'dependencies/blocking': d.blocking }[m[3]] || {};
    const dflt = m[3] === 'sub_issues' ? [{ number: 100, title: '[Task] x' }] : [];
    return { rest: list(map[m[1] + '#' + m[2]] || dflt) };
  }
  if ((m = path.match(/^repos\\/([^/]+\\/[^/]+)\\/issues\\/(\\d+)$/))) {
    const t = (d.issueTypes || {})[m[1] + '#' + m[2]];
    return { rest: { number: Number(m[2]), type: t ? { name: t } : null } };
  }
  if ((m = path.match(/^repos\\/([^/]+\\/[^/]+)\\/milestones/))) {
    return { rest: list(((d.milestones || {})[m[1]] || []).map((t) => ({ title: t }))) };
  }
  if ((m = path.match(/^repos\\/([^/]+\\/[^/]+)\\/tags/))) {
    return { rest: list(((d.tags || {})[m[1]] || []).map((n) => ({ name: n }))) };
  }
  if ((m = path.match(/^repos\\/([^/]+\\/[^/]+)\\/pulls/))) {
    return { rest: list(((d.prs || {})[m[1]] || []).map((h) => ({ head: { ref: h } }))) };
  }
  throw new Error('unexpected call ' + call.args.join(' '));
}`;

const URL = 'https://api.github.com/repos/';
// a REST project item; fields carry Status (101), Level (102), Needs (103), Parent issue (104), Linked pull requests (105)
const restItem = (nr: number, needs: string | null, o: Record<string, any> = {}) => ({
  id: nr,
  node_id: `PVTI_${nr}`,
  content_type: 'Issue',
  content: {
    number: nr,
    state: 'open',
    title: '[PBI] t',
    labels: [],
    repository: { full_name: o.repo ?? 'o/r' },
    repository_url: URL + (o.repo ?? 'o/r'),
    sub_issues_summary: { total: 1 },
    issue_dependencies_summary: { blocked_by: 0, total_blocked_by: 0, blocking: 0, total_blocking: 0 },
    ...o.content,
  },
  fields: [
    { id: 101, name: 'Status', value: o.status === null ? null : { name: { raw: o.status ?? 'Todo' } } },
    { id: 102, name: 'Level', value: o.level === null ? null : { name: { raw: o.level ?? 'PBI' } } },
    { id: 103, name: 'Needs', value: needs ? { name: { raw: needs } } : null },
    { id: 104, name: 'Parent issue', value: o.parent ? { number: o.parent.number, repository_url: URL + (o.parent.repo ?? 'o/r') } : null },
    { id: 105, name: 'Linked pull requests', value: o.linked ?? [] },
    ...(o.current !== undefined ? [{ id: 106, name: 'Current', value: o.current ? { name: { raw: o.current } } : null }] : []),
  ],
});
const dep = (nr: number, repo = 'o/r', state = 'open', labels: string[] = []) => ({
  number: nr,
  state,
  labels: labels.map((name) => ({ name })),
  repository_url: URL + repo,
});

describe.skipIf(!hasPwsh || !hasNode || process.platform === 'win32')(
  'Sync-ProjectNeeds live mode',
  () => {
    let worker: PwshWorker;
    let tmp: string;
    beforeAll(() => {
      worker = new PwshWorker(SCRIPT);
    });
    afterAll(() => worker.close());
    beforeEach(() => {
      tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'needs-live-'));
    });
    afterEach(() => fs.rmSync(tmp, { recursive: true, force: true }));

    const run = async (
      data: Record<string, any>,
      args: string[] = [],
      env: Record<string, string> = {},
    ) => {
      const gh = createFakeGh(tmp, HANDLER);
      const dataFile = path.join(tmp, 'data.json');
      fs.writeFileSync(dataFile, JSON.stringify({ prs: {}, items: [], ...data }));
      const r = await worker.run(['-Owner', 'o', '-Number', '1', ...args], {
        cwd: tmp,
        env: {
          ...gh.env(),
          FAKE_DATA: dataFile,
          SYNC_PROJECT_NEEDS_BACKOFF: '0',
          ...env,
        },
      });
      const calls = gh.calls();
      return {
        r,
        calls,
        itemCalls: calls.filter((c) => restPath(c).includes('/projectsV2/1/items') && !c.args.includes('PATCH')),
        mutations: calls.filter((c) => c.args.includes('PATCH')),
        paths: calls.map(restPath),
      };
    };

    it('reads 150 items through REST in one paginated call and mutates only the changed ones', async () => {
      // 150 PBIs with a Task sub-issue and no other signal -> Ready; 10 of them already carry Ready.
      const items = Array.from({ length: 150 }, (_, i) => restItem(i + 1, i < 10 ? 'Ready' : null));
      const { r, calls, itemCalls, mutations } = await run({ items });
      expect(r.stdout).toContain('#11: (none) -> Ready');
      expect(r.stdout).toContain('Needs: 140 changed, 10 unchanged');
      expect(r.status).toBe(0);
      expect(itemCalls).toHaveLength(1);
      expect(itemCalls[0].args).toEqual(expect.arrayContaining(['--paginate', '--slurp']));
      expect(restPath(itemCalls[0])).toMatch(/^users\/o\/projectsV2\/1\/items\?per_page=100&fields\[\]=/);
      expect(restPath(itemCalls[0])).toMatch(/fields\[\]=103/);
      expect(mutations).toHaveLength(140);
      expect(mutations[0].args).toEqual(['api', '-X', 'PATCH', 'users/o/projectsV2/1/items/11', '--input', '-']);
      expect(mutations[0].body).toEqual({ fields: [{ id: 103, value: 'O-Ready' }] });
      expect(calls.some((c) => c.args.includes('graphql'))).toBe(false);
    });

    it('works on a project that has only the field Needs (no Status, Level, Parent issue, Linked pull requests)', async () => {
      const { r, mutations, itemCalls } = await run({ onlyNeeds: true, items: [restItem(1, null)] });
      expect(r.status).toBe(0);
      expect(r.stdout).toContain('#1: (none) -> Ready');
      expect(mutations).toHaveLength(1);
      expect(restPath(itemCalls[0])).toBe('users/o/projectsV2/1/items?per_page=100&fields[]=103');
    });

    describe('field Current (#167)', () => {
      const msItem = (nr: number, milestone: string | null, current: string | null, state = 'open') =>
        restItem(nr, state === 'open' ? 'Ready' : null, { current, content: { state, milestone: milestone ? { title: milestone } : null } });

      it('reads milestones once per repository via REST, writes only the changed items, adds no GraphQL call', async () => {
        const { r, calls, mutations } = await run({
          withCurrent: true,
          milestones: { 'o/r': ['M10', 'M2'] },
          items: [msItem(1, 'M2', null), msItem(2, 'M2', 'Yes'), msItem(3, 'M10', 'Yes'), msItem(4, 'M2', null, 'closed')],
        });
        expect(r.status).toBe(0);
        const ms = calls.filter((c) => restPath(c).includes('/milestones'));
        expect(ms).toHaveLength(1);
        expect(restPath(ms[0])).toBe('repos/o/r/milestones?state=open&per_page=100');
        expect(calls.some((c) => restPath(c).includes('/tags'))).toBe(false);
        expect(calls.some((c) => c.args.includes('graphql'))).toBe(false);
        expect(mutations.map((m) => [m.args[3], m.body])).toEqual([
          ['users/o/projectsV2/1/items/1', { fields: [{ id: 106, value: 'O-yes' }] }],
          ['users/o/projectsV2/1/items/3', { fields: [{ id: 106, value: null }] }],
          ['users/o/projectsV2/1/items/4', { fields: [{ id: 106, value: 'O-yes' }] }],
        ]);
        expect(r.stdout).toContain('#3: Current Yes -> (clear)');
      });

      it('reads the tags only when a legacy x.y.z milestone is open', async () => {
        const { r, calls, mutations } = await run({
          withCurrent: true,
          milestones: { 'o/r': ['1.2.0', 'M1'] },
          tags: { 'o/r': ['v1.2.0', 'v1.1.0'] },
          items: [msItem(1, 'M1', null), msItem(2, '1.2.0', null)],
        });
        expect(r.status).toBe(0);
        expect(calls.filter((c) => restPath(c).includes('/tags'))).toHaveLength(1);
        expect(mutations.map((m) => m.args[3])).toEqual(['users/o/projectsV2/1/items/1']);
      });

      it('-DryRun lists the change and writes nothing', async () => {
        const { r, mutations } = await run({ withCurrent: true, milestones: { 'o/r': ['M1'] }, items: [msItem(1, 'M1', null)] }, ['-DryRun']);
        expect(r.stdout).toContain('#1: Current (none) -> Yes');
        expect(mutations).toHaveLength(0);
      });

      it('a project without the field Current reads no milestones', async () => {
        const { r, calls } = await run({ items: [msItem(1, 'M1', null)] });
        expect(r.status).toBe(0);
        expect(calls.some((c) => restPath(c).includes('/milestones'))).toBe(false);
      });
    });

    describe('Status reset and scope report (#169)', () => {
      it('resets stale In Progress to Todo / Done through REST, keeps the one with a PR, updates Needs', async () => {
        const { r, mutations } = await run({
          prs: { 'o/r': ['feat/2-x'] },
          items: [
            restItem(1, 'In progress', { status: 'In Progress' }),
            restItem(2, 'In progress', { status: 'In Progress' }),
            restItem(3, null, { status: 'In Progress', content: { state: 'closed' } }),
          ],
        });
        expect(r.status).toBe(0);
        expect(r.stdout).toContain('#1: Status In Progress -> Todo');
        expect(r.stdout).toContain('#3: Status In Progress -> Done');
        expect(mutations.map((m) => [m.args[3], m.body])).toEqual([
          ['users/o/projectsV2/1/items/1', { fields: [{ id: 101, value: 'O-todo' }] }],
          ['users/o/projectsV2/1/items/1', { fields: [{ id: 103, value: 'O-Ready' }] }],
          ['users/o/projectsV2/1/items/3', { fields: [{ id: 101, value: 'O-done' }] }],
        ]);
      });

      it('-DryRun lists the resets and writes nothing', async () => {
        const { r, mutations } = await run({ items: [restItem(1, 'In progress', { status: 'In Progress' })] }, ['-DryRun']);
        expect(r.stdout).toContain('#1: Status In Progress -> Todo');
        expect(mutations).toHaveLength(0);
      });

      it('reports items without Level per repository and warns about unlinked repositories, exit 0', async () => {
        const { r } = await run({
          repos: [{ full_name: 'o/r', open_issues_count: 2 }, { full_name: 'o/lonely', open_issues_count: 5 }],
          items: [restItem(1, 'Ready', { level: null, content: { title: 'plain' }, status: 'Todo' }), restItem(2, 'Ready')],
        }, ['-DryRun']);
        expect(r.status).toBe(0);
        expect(r.stdout).toContain('Without Level: o/r: 1 open');
        expect(r.stderr).toContain('o/lonely');
      });

      it('with -Repo the repository list is not read', async () => {
        const { paths } = await run({ items: [restItem(1, 'Ready')] }, ['-Repo', 'o/r', '-DryRun']);
        expect(paths.some((p) => p.startsWith('users/o/repos'))).toBe(false);
      });
    });

    it('makes no GraphQL call at all (reads and writes are REST)', async () => {
      const { r, calls } = await run({
        items: [restItem(1, null, { content: { sub_issues_summary: { total: 1 } } })],
        prs: { 'o/r': ['feat/1-x'] },
      });
      expect(r.status).toBe(0);
      expect(calls.length).toBeGreaterThan(4);
      expect(calls.some((c) => c.args.includes('graphql') || c.query !== undefined)).toBe(false);
    });

    it('clears the field of a closed item with a null value', async () => {
      const { r, mutations } = await run({
        items: [restItem(5, 'Ready', { content: { state: 'closed' } })],
      });
      expect(r.stdout).toContain('#5: Ready -> (clear)');
      expect(mutations).toHaveLength(1);
      expect(mutations[0].args[3]).toBe('users/o/projectsV2/1/items/5');
      expect(mutations[0].body).toEqual({ fields: [{ id: 103, value: null }] });
    });

    it('reads and writes /orgs/ for an organization project', async () => {
      const { r, mutations, paths } = await run({ items: [restItem(3, null)], ownerType: 'Organization' });
      expect(r.status).toBe(0);
      expect(mutations[0].args[3]).toBe('orgs/o/projectsV2/1/items/3');
      expect(paths).toContain('orgs/o/projectsV2/1');
    });

    it('fails with a clear message when the item has no database id', async () => {
      const { r } = await run({ items: [{ ...restItem(4, null), id: null }] });
      expect(r.status).toBe(1);
      expect(r.stdout).toContain('Needs sync failed');
      expect(r.stdout).toContain('has no databaseId');
    });

    it('-DryRun prints the changes and sends no mutation', async () => {
      const { r, mutations } = await run(
        { items: [restItem(1, null), restItem(2, 'Ready')] },
        ['-DryRun'],
      );
      expect(r.status).toBe(0);
      expect(r.stdout).toContain('#1: (none) -> Ready');
      expect(r.stdout).toContain('Needs: 1 to change, 1 unchanged (dry run)');
      expect(mutations).toHaveLength(0);
    });

    it('-Issue reads only the repository of the listed issues (q=repo:), never the whole project', async () => {
      const items = [restItem(7, null), restItem(9, null), restItem(5, null, { repo: 'o/x' })];
      const { r, itemCalls, mutations } = await run({ items }, ['-Issue', 'o/r#7,o/r#8']);
      expect(r.status).toBe(0);
      expect(itemCalls).toHaveLength(1);
      expect(restPath(itemCalls[0])).toContain('&q=repo:o/r');
      expect(mutations).toHaveLength(1);
      expect(itemNr(mutations[0])).toBe(7);
      expect(r.stdout).toContain('Needs: 1 changed, 0 unchanged');
    });

    it('-Issue with a bare number and no -Repo fails with one line and exit 1', async () => {
      const { r, mutations } = await run({}, ['-Issue', '7']);
      expect(r.status).toBe(1);
      expect(r.stdout).toContain('Needs sync failed:');
      expect(mutations).toHaveLength(0);
    });

    it('a bare -Issue number takes the repository from the origin remote of the checkout', async () => {
      spawnSync('git', ['init', '-q'], { cwd: tmp });
      spawnSync('git', ['remote', 'add', 'origin', 'git@github.com:o/r.git'], { cwd: tmp });
      const { r, mutations } = await run({ items: [restItem(7, null)] }, ['-Issue', '7']);
      expect(r.status).toBe(0);
      expect(r.stdout).toContain('#7: (none) -> Ready');
      expect(mutations).toHaveLength(1);
      expect(itemNr(mutations[0])).toBe(7);
    });

    it('reads every page of open PR heads', async () => {
      const prs = Array.from({ length: 120 }, (_, i) => `feat/${1000 + i}-x`);
      prs.push('feat/7-late');
      const { r, paths } = await run({ items: [restItem(7, null)], prs: { 'o/r': prs } });
      expect(r.status).toBe(0);
      expect(r.stdout).toContain('#7: (none) -> In progress');
      expect(paths.filter((p) => p.startsWith('repos/o/r/pulls?state=open'))).toHaveLength(1);
    });

    describe('-SetStatus', () => {
      const setStatus = (data: Record<string, any>, extra: string[] = []) =>
        run(data, ['-Issue', 'o/r#7', '-SetStatus', 'In Progress', ...extra]);

      it('sets the option with one REST update on the Status field', async () => {
        const { r, mutations, calls } = await setStatus({ items: [restItem(7, null)] });
        expect(r.status).toBe(0);
        expect(r.stdout).toContain('#7: Status -> In Progress');
        expect(mutations).toHaveLength(1);
        expect(mutations[0].args[3]).toBe('users/o/projectsV2/1/items/7');
        expect(mutations[0].body).toEqual({ fields: [{ id: 101, value: 'O-ip' }] });
        expect(calls.some((c) => c.args.includes('graphql'))).toBe(false);
      });

      it('-DryRun sends no mutation', async () => {
        const { r, mutations } = await setStatus({ items: [restItem(7, null)] }, ['-DryRun']);
        expect(r.status).toBe(0);
        expect(r.stdout).toContain('(dry run)');
        expect(mutations).toHaveLength(0);
      });

      it('a missing option is a note and exit 0', async () => {
        const { r, mutations } = await setStatus({ items: [restItem(7, null)], noStatusOption: true });
        expect(r.status).toBe(0);
        expect(r.stdout).toContain("option 'In Progress' missing");
        expect(mutations).toHaveLength(0);
      });

      it('an issue outside the project is a note and exit 0', async () => {
        const { r, mutations } = await setStatus({ items: [restItem(8, null)] });
        expect(r.status).toBe(0);
        expect(r.stdout).toContain('#7 is not in the project');
        expect(mutations).toHaveLength(0);
      });

      it('a failing update exits 1 with a Status not set line', async () => {
        const { r } = await setStatus({ items: [restItem(7, null)], failMutation: 99 });
        expect(r.status).toBe(1);
        expect(r.stdout).toContain('Status not set:');
      });
    });

    it('-Issue -IncludeParents also syncs the parent (Parent issue field), reading its repository', async () => {
      const items = [
        restItem(7, null, { parent: { number: 3, repo: 'o/up' } }),
        restItem(3, null, { repo: 'o/up', level: 'Feature', content: { title: '[Feature] f', sub_issues_summary: { total: 0 } } }),
      ];
      const { r, mutations, itemCalls } = await run({ items }, ['-Issue', 'o/r#7', '-IncludeParents']);
      expect(r.status).toBe(0);
      expect(mutations.map(itemNr).sort((a, b) => a - b)).toEqual([3, 7]);
      expect(r.stdout).toContain('#3: (none) -> Planning');
      expect(itemCalls.map((c) => restPath(c).match(/q=repo:(\S+)/)![1])).toEqual(['o/r', 'o/up']);
    });

    describe('-IncludeDependents', () => {
      const blocks = (n: number) => ({
        content: { issue_dependencies_summary: { blocked_by: 0, total_blocked_by: 0, blocking: n, total_blocking: n } },
      });
      const data = () => ({
        items: [
          restItem(7, null, blocks(4)),
          restItem(8, null),
          restItem(10, null, { repo: 'o/x' }),
        ],
        blocking: {
          'o/r#7': [dep(8), dep(9, 'o/r', 'closed'), dep(10, 'o/x'), dep(11)],
        },
      });
      it('syncs the open dependents, cross-repository ones included; outside-project ones drop out', async () => {
        const { r, mutations, paths } = await run(data(), ['-Issue', 'o/r#7', '-IncludeDependents']);
        expect(r.status).toBe(0);
        expect(mutations.map(itemNr).sort((a, b) => a - b)).toEqual([7, 8, 10]);
        expect(paths).toContain('repos/o/r/issues/7/dependencies/blocking?per_page=100');
      });
      it('does not ask for blocking without the switch', async () => {
        const { paths, mutations } = await run(data(), ['-Issue', 'o/r#7']);
        expect(paths.some((p) => p.includes('/dependencies/blocking'))).toBe(false);
        expect(mutations.map(itemNr)).toEqual([7]);
      });
      it('skips the blocking call of an issue that blocks nothing', async () => {
        const { paths } = await run({ ...data(), items: [restItem(7, null)] }, ['-Issue', 'o/r#7', '-IncludeDependents']);
        expect(paths.some((p) => p.includes('/dependencies/blocking'))).toBe(false);
      });
    });

    describe('-Repo without -Issue', () => {
      it('reads only the items of that repository (q=repo:)', async () => {
        const items = [
          restItem(1, null),
          restItem(2, 'Ready'),
          restItem(3, 'Ready', { content: { state: 'closed' } }),
          restItem(9, null, { repo: 'o/x' }),
        ];
        const { r, itemCalls, mutations } = await run({ items }, ['-Repo', 'o/r']);
        expect(r.status).toBe(0);
        expect(itemCalls).toHaveLength(1);
        expect(restPath(itemCalls[0])).toContain('&q=repo:o/r');
        expect(r.stdout).toContain('Needs: 2 changed, 1 unchanged');
        expect(mutations.map(itemNr).sort((a, b) => a - b)).toEqual([1, 3]);
      });
      it('pages through the items of the repository', async () => {
        const items = Array.from({ length: 130 }, (_, i) => restItem(i + 1, 'Ready'));
        const { r, itemCalls } = await run({ items }, ['-Repo', 'o/r', '-DryRun']);
        expect(r.stdout).toContain('Needs: 0 to change, 130 unchanged (dry run)');
        expect(itemCalls).toHaveLength(1);
      });
    });

    describe('project-wide sync (no -Repo, no -Issue)', () => {
      const blockedByOne = {
        content: { issue_dependencies_summary: { blocked_by: 1, total_blocked_by: 1, blocking: 0, total_blocking: 0 } },
      };
      const items = () => [
        restItem(1, null),
        restItem(2, null, { repo: 'o/x' }),
        restItem(3, null, { repo: 'o/x', ...blockedByOne }),
        restItem(4, 'Ready', { repo: 'o/y' }),
        restItem(5, 'Ready', { repo: 'o/y', content: { state: 'closed' } }),
      ];
      const data = () => ({
        items: items(),
        blockedBy: { 'o/x#3': [dep(90, 'o/x')] },
        // the PR head of #1 sits in o/x only: it must not count for #1 of o/r
        prs: { 'o/x': ['feat/2-thing', 'feat/1-other'], 'o/r': [], 'o/y': [] },
      });

      it('reads the items of every repository in one unfiltered call and syncs them all', async () => {
        const { r, itemCalls, mutations } = await run(data());
        expect(r.status).toBe(0);
        expect(itemCalls).toHaveLength(1);
        expect(restPath(itemCalls[0])).not.toContain('q=repo:');
        expect(r.stdout).toContain('#1: (none) -> Ready');
        expect(r.stdout).toContain('#2: (none) -> In progress');
        expect(r.stdout).toContain('#3: (none) -> Blocked');
        expect(r.stdout).toContain('#5: Ready -> (clear)');
        expect(r.stdout).toContain('Needs: 4 changed, 1 unchanged');
        expect(mutations.map(itemNr).sort((a, b) => a - b)).toEqual([1, 2, 3, 5]);
      });

      it('looks up PRs and blockers in the repository of each item', async () => {
        const { paths } = await run(data());
        expect(paths).toContain('repos/o/x/issues/3/dependencies/blocked_by?per_page=100');
        expect(paths.filter((p) => p.includes('/pulls')).map((p) => p.split('/')[1] + '/' + p.split('/')[2]).sort())
          .toEqual(['o/r', 'o/x', 'o/y']);
        expect(paths.filter((p) => p.startsWith('repos/o/r/issues/') && p.includes('/dependencies/'))).toEqual([]);
      });

      it('-DryRun sends no mutation', async () => {
        const { r, mutations } = await run(data(), ['-DryRun']);
        expect(r.stdout).toContain('Needs: 4 to change, 1 unchanged (dry run)');
        expect(mutations).toHaveLength(0);
      });
    });

    it('prints the skip line and exits 0 when the field Needs is missing', async () => {
      const { r, mutations, itemCalls } = await run({ noNeeds: true, items: [restItem(1, null)] });
      expect(r.stdout.trim()).toBe(
        'Needs sync skipped: field Needs missing (run Set-ProjectStandard.ps1, #596)',
      );
      expect(r.status).toBe(0);
      expect(itemCalls).toHaveLength(0);
      expect(mutations).toHaveLength(0);
    });

    it('matches open PR heads of the repository, blocked-by links and linked pull requests', async () => {
      const blockedBy = (open: number, total: number) => ({
        content: { issue_dependencies_summary: { blocked_by: open, total_blocked_by: total, blocking: 0, total_blocking: 0 } },
      });
      const items = [
        restItem(7, null),
        restItem(8, null, blockedBy(1, 2)),
        restItem(9, null, blockedBy(0, 1)),
        restItem(10, null, { linked: [{ number: 5, state: 'open', head: { ref: 'x' } }] }),
        restItem(11, null, { linked: [{ number: 6, state: 'closed', head: { ref: 'y' } }] }),
      ];
      const { r, paths } = await run({
        items,
        blockedBy: { 'o/r#8': [dep(90), dep(91, 'o/r', 'closed')] },
        prs: { 'o/r': ['feat/7-thing', 'feat/17-other'] },
      });
      expect(r.status).toBe(0);
      expect(r.stdout).toContain('#7: (none) -> In progress');
      expect(r.stdout).toContain('#8: (none) -> Blocked');
      expect(r.stdout).toContain('#9: (none) -> Ready');
      expect(r.stdout).toContain('#10: (none) -> In progress');
      expect(r.stdout).toContain('#11: (none) -> Ready');
      expect(paths.filter((p) => p.includes('/pulls'))).toHaveLength(1);
      expect(paths).not.toContain('repos/o/r/issues/9/dependencies/blocked_by?per_page=100');
    });

    const blockedBy = (n: number) => ({
      content: { issue_dependencies_summary: { blocked_by: n, total_blocked_by: n, blocking: 0, total_blocking: 0 } },
    });

    // #182: a blocker blocks while open; the Status of its item plays no part. An open blocker with the label merged
    // counts as resolved during the migration.
    it('resolves blockers from their state and the label merged, never from the Status of their item', async () => {
      const items = [
        restItem(30, null),
        restItem(31, null, { status: 'In release' }),
        restItem(32, null),
        restItem(21, null, blockedBy(1)),
        restItem(22, null, blockedBy(1)),
        restItem(23, null, blockedBy(1)),
      ];
      const { r, itemCalls } = await run({
        items,
        blockedBy: {
          'o/r#21': [dep(30, 'o/r', 'open', ['Merged'])],
          'o/r#22': [dep(31)],
          'o/r#23': [dep(32)],
        },
      });
      expect(r.status).toBe(0);
      expect(r.stdout).toContain('#21: (none) -> Ready');
      expect(r.stdout).toContain('#22: (none) -> Blocked');
      expect(r.stdout).toContain('#23: (none) -> Blocked');
      expect(itemCalls).toHaveLength(1);
    });

    it('never reads the items of a blocker repository outside the scope', async () => {
      const items = [
        restItem(1, null, { repo: 'o/other' }),
        restItem(2, null, { repo: 'o/other', status: 'In release' }),
        restItem(4, null, { repo: 'o/other' }),
        ...[41, 42, 43, 44, 45].map((n) => restItem(n, null, blockedBy(n === 45 ? 2 : 1))),
      ];
      const { r, itemCalls } = await run(
        {
          items,
          blockedBy: {
            'o/r#41': [dep(1, 'o/other', 'open', ['merged'])],
            'o/r#42': [dep(2, 'o/other')],
            'o/r#43': [dep(3, 'o/other')],
            'o/r#44': [dep(4, 'o/other')],
            'o/r#45': [dep(1, 'o/other', 'open', ['merged']), dep(9, 'o/other', 'closed')],
          },
        },
        ['-Repo', 'o/r'],
      );
      expect(r.status).toBe(0);
      expect(r.stdout).toContain('#41: (none) -> Ready');
      expect(r.stdout).toContain('#42: (none) -> Blocked');
      expect(r.stdout).toContain('#43: (none) -> Blocked');
      expect(r.stdout).toContain('#44: (none) -> Blocked');
      expect(r.stdout).toContain('#45: (none) -> Ready');
      expect(itemCalls.map((c) => restPath(c).match(/q=repo:(\S+)/)![1])).toEqual(['o/r']);
    });

    it('takes sub-issue levels from title, type or the Level of items already read', async () => {
      const feature = (nr: number) =>
        restItem(nr, null, { level: 'Feature', content: { title: '[Feature] f' } });
      const sub = (nr: number, over: object = {}) => ({ number: nr, title: 'plain', repository_url: URL + 'o/r', ...over });
      const items = [feature(1), feature(2), feature(3), feature(4), restItem(51, 'Ready')];
      const { r } = await run({
        items,
        subIssues: {
          'o/r#1': [sub(51)],
          'o/r#2': [sub(52, { title: '[PBI] x' })],
          'o/r#3': [sub(53, { type: { name: 'PBI' } })],
          'o/r#4': [sub(54)],
        },
      });
      expect(r.status).toBe(0);
      expect(r.stdout).not.toContain('#1:');
      expect(r.stdout).not.toContain('#2:');
      expect(r.stdout).not.toContain('#3:');
      expect(r.stdout).toContain('#4: (none) -> Planning');
    });

    it('reads the issue type of an open legacy issue without Level and title prefix', async () => {
      const { r, paths } = await run({
        items: [restItem(6, 'Planning', { level: null, content: { title: 'plain' } })],
        issueTypes: { 'o/r#6': 'Epic' },
        subIssues: { 'o/r#6': [{ number: 60, title: '[Feature] f' }] },
      });
      expect(r.status).toBe(0);
      expect(r.stdout).toContain('#6: Planning -> (clear)');
      expect(paths).toContain('repos/o/r/issues/6');
    });

    it('does not read sub-issues of an issue without any', async () => {
      const { paths } = await run({
        items: [restItem(1, null, { content: { sub_issues_summary: { total: 0 } } })],
      });
      expect(paths.some((p) => p.includes('/sub_issues'))).toBe(false);
    });

    it('retries a failing update and succeeds on the 3rd try', async () => {
      const { r, mutations } = await run({ items: [restItem(1, null)], failMutation: 2 });
      expect(r.status).toBe(0);
      expect(mutations).toHaveLength(3);
      expect(r.stdout).toContain('Needs: 1 changed, 0 unchanged');
    });

    it('skips an item archived before the write: warning, no retry, the others are written, exit 0', async () => {
      const { r, mutations } = await run({ items: [restItem(1, null), restItem(2, null)], archivedItem: 1 });
      expect(r.status).toBe(0);
      expect(mutations.map(itemNr)).toEqual([1, 2]);
      expect(r.stdout).toContain('skipped (archived): 1');
      expect(r.stderr + r.stdout).toContain('is archived and cannot be updated; skipped.');
    });

    it('does not plan an item that is archived at the read (archived_at set)', async () => {
      const { r, mutations } = await run({ items: [{ ...restItem(1, null), archived_at: '2026-01-01T00:00:00Z' }, restItem(2, null)] });
      expect(r.status).toBe(0);
      expect(mutations.map(itemNr)).toEqual([2]);
      expect(r.stdout).toContain('skipped (archived): 1');
    });

    it('exits 1 with one line after 4 failed tries', async () => {
      const { r, mutations } = await run({ items: [restItem(1, null)], failMutation: 99 });
      expect(r.status).toBe(1);
      expect(mutations).toHaveLength(4);
      expect(r.stdout).toMatch(/Needs sync failed: Needs update failed for o\/r#1/);
    });

    it('exits 1 when the project is not found', async () => {
      const { r } = await run({ noProject: true });
      expect(r.status).toBe(1);
      expect(r.stdout).toContain('Needs sync failed: Project o/1 not found');
    });
  },
);
