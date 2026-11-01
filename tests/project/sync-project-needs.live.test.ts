import { spawnSync } from 'child_process';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { createFakeGh } from '../helpers/fake-gh';
import { PwshWorker } from '../helpers/pwsh-worker';

const itemNr = (c: { args: string[] }) => Number(c.args[3].split('/').pop());
const SCRIPT = path.resolve(
  __dirname,
  '../../.apm/skills/github-project/scripts/Sync-ProjectNeeds.ps1',
);

const hasPwsh = spawnSync('pwsh', ['-NoProfile', '-Command', '1']).status === 0;
const hasNode = spawnSync('node', ['-v']).status === 0;

it('pwsh is installed in CI (the live Sync-ProjectNeeds cases must not be skipped there)', () => {
  if (process.env.CI) expect(hasPwsh).toBe(true);
});

// Canned GraphQL answers. data.json: {fields, items (project item nodes), issues ({"o/r#n": project item + content}), prs, noNeeds}.
const INNER = `(call, ctx) => {
  const fs = require('fs');
  const d = JSON.parse(fs.readFileSync(process.env.FAKE_DATA, 'utf8'));
  const q = call.query || '';
  if (call.args.includes('PATCH')) {
    if (d.failMutation && ctx.count('mut') <= d.failMutation) throw new Error('secondary rate limit');
    return { rest: {} };
  }
  if (call.args[0] === 'api' && call.args[1] !== 'graphql' && String(call.args[1]).includes('/dependencies/blocking')) {
    return { rest: (d.restBlocking || {})[call.args[1].split('/dependencies')[0]] || [] };
  }
  if (call.args[0] === 'api' && call.args[1] !== 'graphql') {
    return { rest: d.rest || [] };
  }
  if (q.includes('blocking(') && d.noBlocking) throw new Error("Field 'blocking' doesn't exist on type 'Issue'");
  if (q.includes('blockedBy') && d.noBlockedBy) throw new Error("Field 'blockedBy' doesn't exist on type 'Issue'");
  if (q.includes('projectV2(number')) {
    const status = { __typename: 'ProjectV2SingleSelectField', id: 'F-status', databaseId: 51, name: 'Status',
      options: d.noStatusOption ? [{ id: 'O-todo', name: 'Todo' }] : [{ id: 'O-todo', name: 'Todo' }, { id: 'O-ip', name: 'In Progress' }] };
    const nodes = d.noNeeds ? [status] : [status, { __typename: 'ProjectV2SingleSelectField', id: 'F-needs', databaseId: 52, name: 'Needs',
      options: ['Planning','Ready','In progress','Blocked','Review','Decision','Release review'].map((n) => ({ id: 'O-' + n, name: n })) }];
    return { repositoryOwner: { __typename: d.ownerType || 'User', projectV2: { id: 'P1', fields: { nodes } } } };
  }
  if (q.includes('issues(first: 100')) {
    const all = (d.repoIssues || {})[call.variables.o + '/' + call.variables.r] || [];
    const start = call.variables.cursor ? Number(call.variables.cursor) : 0;
    return { repository: { issues: { pageInfo: { hasNextPage: start + 100 < all.length, endCursor: String(start + 100) },
      nodes: all.slice(start, start + 100) } } };
  }
  if (q.includes('items(first: 100')) {
    const start = call.variables.cursor ? Number(call.variables.cursor) : 0;
    const nodes = d.items.slice(start, start + 100);
    const more = start + 100 < d.items.length;
    return { node: { items: { pageInfo: { hasNextPage: more, endCursor: String(start + 100) }, nodes } } };
  }
  if (q.includes('pullRequests')) {
    const key = call.variables.o + '/' + call.variables.r;
    const all = d.prs[key] || [];
    const start = call.variables.cursor ? Number(call.variables.cursor) : 0;
    return { repository: { pullRequests: { pageInfo: { hasNextPage: start + 100 < all.length, endCursor: String(start + 100) },
      nodes: all.slice(start, start + 100).map((h) => ({ headRefName: h })) } } };
  }
  const out = {};
  for (const k of Object.keys(call.variables || {}).filter((x) => x[0] === 'n')) {
    const i = k.slice(1);
    out['i' + i] = { issue: d.issues[call.variables['o' + i] + '/' + call.variables['r' + i] + '#' + call.variables[k]] || null };
  }
  return out;
}`;

// rateLimit: d.rateLimit = {cost, remaining}; every read query answers it and remaining shrinks by cost per query.
const HANDLER = `(call, ctx) => {
  const out = (${INNER})(call, ctx);
  const fs = require('fs');
  const d = JSON.parse(fs.readFileSync(process.env.FAKE_DATA, 'utf8'));
  if (d.rateLimit && out && call.query && !call.query.includes('mutation') && call.query.includes('rateLimit { cost remaining }')) {
    out.rateLimit = { cost: d.rateLimit.cost, remaining: d.rateLimit.remaining - d.rateLimit.cost * (ctx.count('rl') - 1) };
  }
  return out;
}`;

const issueNode = (over: Record<string, any> = {}) => ({
  number: 1,
  title: '[PBI] t',
  state: 'OPEN',
  issueType: null,
  repository: { nameWithOwner: 'o/r' },
  labels: { nodes: [] },
  parent: null,
  subIssues: {
    nodes: [{ number: 100, title: '[Task] x', projectItems: { nodes: [] } }],
  },
  blockedBy: { nodes: [] },
  closedByPullRequestsReferences: { nodes: [] },
  ...over,
});
const projectItem = (nr: number, needs: string | null, content: Record<string, any> = {}) => ({
  id: `I${nr}`,
  content: { __typename: 'Issue', ...issueNode({ number: nr, ...content }) },
  status: { name: 'Todo' },
  level: { name: 'PBI' },
  needs: needs ? { name: needs } : null,
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
      // project items 'I<n>' carry the numeric databaseId <n>, which the REST update addresses
      fs.writeFileSync(
        dataFile,
        JSON.stringify({ prs: {}, issues: {}, items: [], ...data }, (k, v) =>
          v && typeof v.id === 'string' && /^I\d+$/.test(v.id)
            ? { ...v, databaseId: Number(v.id.slice(1)) }
            : v,
        ),
      );
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
        itemQueries: calls.filter((c) => c.query?.includes('items(first: 100')),
        mutations: calls.filter((c) => c.args.includes('PATCH')),
      };
    };

    it('pages 150 items in 2 queries and mutates only the changed ones', async () => {
      // 150 PBIs with a Task sub-issue and no other signal -> Ready; 10 of them already carry Ready.
      const items = Array.from({ length: 150 }, (_, i) =>
        projectItem(i + 1, i < 10 ? 'Ready' : null),
      );
      const { r, calls, itemQueries, mutations } = await run({ items });
      expect(r.stdout).toContain('#11: (none) -> Ready');
      expect(r.stdout).toContain('Needs: 140 changed, 10 unchanged');
      expect(r.status).toBe(0);
      expect(itemQueries).toHaveLength(2);
      expect(itemQueries[1].variables!.cursor).toBe('100');
      expect(mutations).toHaveLength(140);
      expect(mutations[0].args).toEqual(['api', '-X', 'PATCH', 'users/o/projectsV2/1/items/11', '--input', '-']);
      expect(mutations[0].body).toEqual({ fields: [{ id: 52, value: 'O-Ready' }] });
      expect(calls.some((c) => c.query?.includes('mutation'))).toBe(false);
    });

    it('clears the field of a closed item with a null value', async () => {
      const { r, mutations } = await run({
        items: [projectItem(5, 'Ready', { state: 'CLOSED' })],
      });
      expect(r.stdout).toContain('#5: Ready -> (clear)');
      expect(mutations).toHaveLength(1);
      expect(mutations[0].args[3]).toBe('users/o/projectsV2/1/items/5');
      expect(mutations[0].body).toEqual({ fields: [{ id: 52, value: null }] });
    });

    it('writes to /orgs/ for an organization project', async () => {
      const { r, mutations } = await run({ items: [projectItem(3, null)], ownerType: 'Organization' });
      expect(r.status).toBe(0);
      expect(mutations[0].args[3]).toBe('orgs/o/projectsV2/1/items/3');
    });

    it('fails with a clear message when the item has no databaseId', async () => {
      const { r } = await run({ items: [{ ...projectItem(4, null), id: 'X4' }] });
      expect(r.status).toBe(1);
      expect(r.stdout).toContain('Needs sync failed');
      expect(r.stdout).toContain('has no databaseId');
    });

    it('-DryRun prints the changes and sends no mutation', async () => {
      const { r, mutations } = await run(
        { items: [projectItem(1, null), projectItem(2, 'Ready')] },
        ['-DryRun'],
      );
      expect(r.status).toBe(0);
      expect(r.stdout).toContain('#1: (none) -> Ready');
      expect(r.stdout).toContain('Needs: 1 to change, 1 unchanged (dry run)');
      expect(mutations).toHaveLength(0);
    });

    it('-Issue queries only the listed issues, never the whole project', async () => {
      const issues = {
        'o/r#7': {
          ...issueNode({ number: 7 }),
          projectItems: {
            nodes: [
              {
                id: 'I7',
                project: { id: 'P1' },
                status: { name: 'Todo' },
                level: { name: 'PBI' },
                needs: null,
              },
            ],
          },
        },
        'o/r#8': {
          ...issueNode({ number: 8 }),
          projectItems: {
            nodes: [
              {
                id: 'I8',
                project: { id: 'OTHER' },
                status: null,
                level: null,
                needs: null,
              },
            ],
          },
        },
      };
      const { r, calls, itemQueries, mutations } = await run({ issues }, ['-Issue', 'o/r#7,o/r#8']);
      expect(r.status).toBe(0);
      expect(itemQueries).toHaveLength(0);
      expect(calls.filter((c) => c.variables?.n0 !== undefined)).toHaveLength(1);
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
      spawnSync('git', ['remote', 'add', 'origin', 'git@github.com:o/r.git'], {
        cwd: tmp,
      });
      const issues = {
        'o/r#7': {
          ...issueNode({ number: 7 }),
          projectItems: {
            nodes: [
              {
                id: 'I7',
                project: { id: 'P1' },
                status: null,
                level: { name: 'PBI' },
                needs: null,
              },
            ],
          },
        },
      };
      const { r, mutations } = await run({ issues }, ['-Issue', '7']);
      expect(r.status).toBe(0);
      expect(r.stdout).toContain('#7: (none) -> Ready');
      expect(mutations).toHaveLength(1);
      expect(itemNr(mutations[0])).toBe(7);
    });

    it('reads every page of open PR heads', async () => {
      const prs = Array.from({ length: 120 }, (_, i) => `feat/${1000 + i}-x`);
      prs.push('feat/7-late');
      const { r, calls } = await run({
        items: [projectItem(7, null)],
        prs: { 'o/r': prs },
      });
      expect(r.status).toBe(0);
      expect(r.stdout).toContain('#7: (none) -> In progress');
      expect(calls.filter((c) => c.query?.includes('pullRequests'))).toHaveLength(2);
    });

    describe('-SetStatus', () => {
      const statusIssues = (project = 'P1') => ({
        'o/r#7': {
          ...issueNode({ number: 7 }),
          projectItems: {
            nodes: [
              {
                id: 'I7',
                project: { id: project },
                status: null,
                level: null,
                needs: null,
              },
            ],
          },
        },
      });

      it('sets the option with one mutation on the Status field', async () => {
        const { r, mutations } = await run({ issues: statusIssues() }, [
          '-Issue',
          'o/r#7',
          '-SetStatus',
          'In Progress',
        ]);
        expect(r.status).toBe(0);
        expect(r.stdout).toContain('#7: Status -> In Progress');
        expect(mutations).toHaveLength(1);
        expect(mutations[0].args[3]).toBe('users/o/projectsV2/1/items/7');
        expect(mutations[0].body).toEqual({ fields: [{ id: 51, value: 'O-ip' }] });
      });

      it('-DryRun sends no mutation', async () => {
        const { r, mutations } = await run({ issues: statusIssues() }, [
          '-Issue',
          'o/r#7',
          '-SetStatus',
          'In Progress',
          '-DryRun',
        ]);
        expect(r.status).toBe(0);
        expect(r.stdout).toContain('(dry run)');
        expect(mutations).toHaveLength(0);
      });

      it('a missing option is a note and exit 0', async () => {
        const { r, mutations } = await run({ issues: statusIssues(), noStatusOption: true }, [
          '-Issue',
          'o/r#7',
          '-SetStatus',
          'In Progress',
        ]);
        expect(r.status).toBe(0);
        expect(r.stdout).toContain("option 'In Progress' missing");
        expect(mutations).toHaveLength(0);
      });

      it('an issue outside the project is a note and exit 0', async () => {
        const { r, mutations } = await run({ issues: statusIssues('OTHER') }, [
          '-Issue',
          'o/r#7',
          '-SetStatus',
          'In Progress',
        ]);
        expect(r.status).toBe(0);
        expect(r.stdout).toContain('#7 is not in the project');
        expect(mutations).toHaveLength(0);
      });

      it('a failing mutation exits 1 with a Status not set line', async () => {
        const { r } = await run({ issues: statusIssues(), failMutation: 99 }, [
          '-Issue',
          'o/r#7',
          '-SetStatus',
          'In Progress',
        ]);
        expect(r.status).toBe(1);
        expect(r.stdout).toContain('Status not set:');
      });
    });

    it('-Issue -IncludeParents also syncs the parent in a second query', async () => {
      const pItem = (nr: number, content: object) => ({
        ...issueNode({ number: nr, ...content }),
        projectItems: {
          nodes: [
            {
              id: `I${nr}`,
              project: { id: 'P1' },
              status: { name: 'Todo' },
              level: { name: 'PBI' },
              needs: null,
            },
          ],
        },
      });
      const issues = {
        'o/r#7': pItem(7, {
          parent: { number: 3, repository: { nameWithOwner: 'o/r' } },
        }),
        'o/r#3': pItem(3, { title: '[Feature] f', subIssues: { nodes: [] } }),
      };
      issues['o/r#3'].projectItems.nodes[0].level = { name: 'Feature' };
      const { r, mutations } = await run({ issues }, ['-Issue', 'o/r#7', '-IncludeParents']);
      expect(r.status).toBe(0);
      expect(mutations.map(itemNr).sort((a, b) => a - b)).toEqual([3, 7]);
      expect(r.stdout).toContain('#3: (none) -> Planning');
    });

    describe('-IncludeDependents', () => {
      const pItem = (nr: number, content: object) => ({
        ...issueNode({ number: nr, ...content }),
        projectItems: {
          nodes: [
            {
              id: `I${nr}`,
              project: { id: 'P1' },
              status: { name: 'Todo' },
              level: { name: 'PBI' },
              needs: null,
            },
          ],
        },
      });
      const dep = (nr: number, repo = 'o/r', state = 'OPEN') => ({
        number: nr,
        state,
        repository: { nameWithOwner: repo },
      });
      const issues = () => ({
        'o/r#7': pItem(7, {
          blocking: {
            nodes: [dep(8), dep(9, 'o/r', 'CLOSED'), dep(10, 'o/x'), dep(11)],
          },
        }),
        'o/r#8': pItem(8, {}),
        'o/x#10': pItem(10, { repository: { nameWithOwner: 'o/x' } }),
      });
      it('syncs the open dependents, cross-repository ones included; outside-project ones drop out', async () => {
        const { r, mutations, calls } = await run({ issues: issues() }, [
          '-Issue',
          'o/r#7',
          '-IncludeDependents',
        ]);
        expect(r.status).toBe(0);
        expect(mutations.map(itemNr).sort((a, b) => a - b)).toEqual([7, 8, 10]);
        const first = calls.find((c) => c.query?.includes('repository(owner'))!;
        expect(first.query).toContain('blocking(first: 50)');
      });
      it('does not ask for blocking without the switch', async () => {
        const { calls, mutations } = await run({ issues: issues() }, ['-Issue', 'o/r#7']);
        expect(calls.some((c) => c.query?.includes('blocking('))).toBe(false);
        expect(mutations.map(itemNr)).toEqual([7]);
      });
      it('falls back to the REST blocking endpoint when GraphQL has no blocking field', async () => {
        const restBlocking = {
          'repos/o/r/issues/7': [
            { number: 8, state: 'open' },
            { number: 9, state: 'closed' },
          ],
        };
        const { r, mutations, calls } = await run(
          { issues: issues(), noBlocking: true, restBlocking },
          ['-Issue', 'o/r#7', '-IncludeDependents'],
        );
        expect(r.status).toBe(0);
        expect(mutations.map(itemNr).sort((a, b) => a - b)).toEqual([7, 8]);
        expect(calls.some((c) => c.args.join(' ').includes('/dependencies/blocking'))).toBe(true);
      });
    });

    describe('-Repo without -Issue', () => {
      const repoIssue = (nr: number, needs: string | null, over: object = {}) => ({
        ...issueNode({ number: nr, ...over }),
        projectItems: {
          nodes: [
            {
              id: `I${nr}`,
              project: { id: 'P1' },
              status: null,
              level: { name: 'PBI' },
              needs: needs ? { name: needs } : null,
            },
            { id: 'X', project: { id: 'P2' } },
          ],
        },
      });
      it('reads only the issues of that repository, never the project items', async () => {
        const repoIssues = {
          'o/r': [
            repoIssue(1, null),
            repoIssue(2, 'Ready'),
            repoIssue(3, 'Ready', { state: 'CLOSED' }),
          ],
        };
        const { r, calls, itemQueries, mutations } = await run(
          { repoIssues, items: [projectItem(9, null)] },
          ['-Repo', 'o/r'],
        );
        expect(r.status).toBe(0);
        expect(itemQueries).toHaveLength(0);
        expect(calls.filter((c) => c.query?.includes('issues(first: 100'))).toHaveLength(1);
        expect(r.stdout).toContain('Needs: 2 changed, 1 unchanged');
        expect(mutations.map(itemNr).sort((a, b) => a - b)).toEqual([1, 3]);
      });
      it('pages through the issues of the repository', async () => {
        const repoIssues = {
          'o/r': Array.from({ length: 130 }, (_, i) => repoIssue(i + 1, 'Ready')),
        };
        const { r, calls } = await run({ repoIssues }, ['-Repo', 'o/r', '-DryRun']);
        expect(r.stdout).toContain('Needs: 0 to change, 130 unchanged (dry run)');
        expect(calls.filter((c) => c.query?.includes('issues(first: 100'))).toHaveLength(2);
      });
    });

    describe('GraphQL budget', () => {
      it('asks for rateLimit and prints the total cost of the run', async () => {
        const items = Array.from({ length: 150 }, (_, i) => projectItem(i + 1, 'Ready'));
        const { r, itemQueries } = await run({
          items,
          rateLimit: { cost: 3, remaining: 4000 },
        });
        expect(r.status).toBe(0);
        expect(itemQueries[0].query).toContain('rateLimit { cost remaining }');
        // fields query + 2 item pages + open PR heads = 4 reads
        expect(r.stdout).toContain('GraphQL cost: 12 points (remaining 3991)');
      });
      it('stops before any write when remaining does not cover the next page', async () => {
        const items = Array.from({ length: 150 }, (_, i) => projectItem(i + 1, null));
        const { r, mutations, itemQueries } = await run({
          items,
          rateLimit: { cost: 5, remaining: 8 },
        });
        expect(r.status).toBe(1);
        expect(r.stdout).toMatch(
          /Needs sync failed: GraphQL budget too low: 3 points remaining, the next page of items would need about 5/,
        );
        expect(itemQueries).toHaveLength(1);
        expect(mutations).toHaveLength(0);
      });
      it('updates cost no GraphQL points: no mutation query is sent', async () => {
        const { r, calls, mutations } = await run({
          items: [projectItem(1, null), projectItem(2, null)],
          rateLimit: { cost: 1, remaining: 4000 },
        });
        expect(r.status).toBe(0);
        expect(mutations).toHaveLength(2);
        expect(calls.some((c) => c.query?.includes('mutation'))).toBe(false);
      });
    });

    it('prints the skip line and exits 0 when the field Needs is missing', async () => {
      const { r, calls } = await run({
        noNeeds: true,
        items: [projectItem(1, null)],
      });
      expect(r.stdout.trim()).toBe(
        'Needs sync skipped: field Needs missing (run Set-ProjectStandard.ps1, #596)',
      );
      expect(r.status).toBe(0);
      expect(calls).toHaveLength(1);
    });

    it('matches open PR heads of the repository and blocked-by links from GraphQL', async () => {
      const items = [
        projectItem(7, null),
        projectItem(8, null, {
          blockedBy: {
            nodes: [
              { number: 90, state: 'OPEN' },
              { number: 91, state: 'CLOSED' },
            ],
          },
        }),
        projectItem(9, null, {
          blockedBy: { nodes: [{ number: 91, state: 'CLOSED' }] },
        }),
        projectItem(10, null, {
          closedByPullRequestsReferences: {
            nodes: [{ state: 'OPEN', headRefName: 'x' }],
          },
        }),
      ];
      const { r, calls } = await run({
        items,
        prs: { 'o/r': ['feat/7-thing', 'feat/17-other'] },
      });
      expect(r.status).toBe(0);
      expect(r.stdout).toContain('#7: (none) -> In progress');
      expect(r.stdout).toContain('#8: (none) -> Blocked');
      expect(r.stdout).toContain('#9: (none) -> Ready');
      expect(r.stdout).toContain('#10: (none) -> In progress');
      expect(calls.filter((c) => c.query?.includes('pullRequests'))).toHaveLength(1);
    });

    const blocker = (nr: number, repo = 'o/r', state = 'OPEN') => ({
      number: nr,
      state,
      repository: { nameWithOwner: repo },
    });

    it('resolves blockers from the labels and Status of items already read (no nested connections)', async () => {
      const items = [
        projectItem(30, null, { labels: { nodes: [{ name: 'merged' }] } }),
        { ...projectItem(31, null), status: { name: 'In release' } },
        projectItem(32, null),
        projectItem(21, null, { blockedBy: { nodes: [blocker(30)] } }),
        projectItem(22, null, { blockedBy: { nodes: [blocker(31)] } }),
        projectItem(23, null, { blockedBy: { nodes: [blocker(32)] } }),
      ];
      const { r, calls } = await run({ items });
      expect(r.status).toBe(0);
      expect(r.stdout).toContain('#21: (none) -> Ready');
      expect(r.stdout).toContain('#22: (none) -> Ready');
      expect(r.stdout).toContain('#23: (none) -> Blocked');
      const q = calls.find((c) => c.query?.includes('items(first: 100'))!.query!;
      expect(q).toContain(
        'blockedBy(first: 20) { nodes { number state repository { nameWithOwner } } }',
      );
      expect(q).not.toMatch(/subIssues\(first: 50\) \{ nodes \{[^}]*projectItems/);
      expect(calls.filter((c) => c.variables?.n0 !== undefined)).toHaveLength(0);
    });

    it('looks up blockers outside the read set in one batched query', async () => {
      const lookup = (labels: string[], status: string | null, project = 'P1') => ({
        labels: { nodes: labels.map((name) => ({ name })) },
        projectItems: {
          nodes: [
            {
              project: { id: project },
              status: status ? { name: status } : null,
            },
          ],
        },
      });
      const issues = {
        'o/other#1': lookup(['merged'], null),
        'o/other#2': lookup([], 'In release'),
        'o/other#3': lookup([], 'In release', 'P2'),
        'o/other#4': lookup([], null),
      };
      const items = [1, 2, 3, 4].map((n) =>
        projectItem(40 + n, null, {
          blockedBy: { nodes: [blocker(n, 'o/other')] },
        }),
      );
      items.push(
        projectItem(45, null, {
          blockedBy: {
            nodes: [blocker(1, 'o/other'), blocker(9, 'o/other', 'CLOSED')],
          },
        }),
      );
      const { r, calls } = await run({ items, issues });
      expect(r.status).toBe(0);
      expect(r.stdout).toContain('#41: (none) -> Ready');
      expect(r.stdout).toContain('#42: (none) -> Ready');
      expect(r.stdout).toContain('#43: (none) -> Blocked');
      expect(r.stdout).toContain('#44: (none) -> Blocked');
      expect(r.stdout).toContain('#45: (none) -> Ready');
      const lookups = calls.filter((c) => c.variables?.n0 !== undefined);
      expect(lookups).toHaveLength(1);
      expect(Object.keys(lookups[0].variables!).filter((k) => k[0] === 'n')).toHaveLength(4);
    });

    it('takes sub-issue levels from title, issueType or the Level of items already read', async () => {
      const feature = (nr: number, subs: object[]) => ({
        ...projectItem(nr, null, {
          title: '[Feature] f',
          subIssues: { nodes: subs },
        }),
        level: { name: 'Feature' },
      });
      const sub = (nr: number, over: object = {}) => ({
        number: nr,
        title: 'plain',
        repository: { nameWithOwner: 'o/r' },
        ...over,
      });
      const items = [
        feature(1, [sub(51)]),
        feature(2, [sub(52, { title: '[PBI] x' })]),
        feature(3, [sub(53, { issueType: { name: 'PBI' } })]),
        feature(4, [sub(54, { number: 999 })]),
        { ...projectItem(51, 'Ready'), level: { name: 'PBI' } },
      ];
      const { r, calls } = await run({ items });
      expect(r.status).toBe(0);
      expect(r.stdout).not.toContain('#1:');
      expect(r.stdout).not.toContain('#2:');
      expect(r.stdout).not.toContain('#3:');
      expect(r.stdout).toContain('#4: (none) -> Planning');
      expect(
        calls.some(
          (c) =>
            c.query?.includes('Level') && /subIssues[^]*projectItems\(first: 10\)/.test(c.query),
        ),
      ).toBe(false);
    });

    it('REST fallback: merged-label blocker is resolved, open unmerged blocks', async () => {
      const merged = await run({
        noBlockedBy: true,
        items: [projectItem(5, null)],
        rest: [{ number: 2, state: 'open', labels: [{ name: 'Merged' }] }],
      });
      expect(merged.r.stdout).toContain('#5: (none) -> Ready');
      const open = await run({
        noBlockedBy: true,
        items: [projectItem(5, null)],
        rest: [
          { number: 2, state: 'open', labels: [{ name: 'merged' }] },
          { number: 3, state: 'open', labels: [{ name: 'bug' }] },
        ],
      });
      expect(open.r.stdout).toContain('#5: (none) -> Blocked');
    });

    it('falls back to the REST dependencies endpoint when GraphQL has no blockedBy', async () => {
      const { r, calls } = await run({
        noBlockedBy: true,
        items: [projectItem(4, null)],
        rest: [
          { number: 2, state: 'open' },
          { number: 3, state: 'closed' },
        ],
      });
      expect(r.status).toBe(0);
      expect(r.stdout).toContain('#4: (none) -> Blocked');
      expect(
        calls.some((c) => c.args.join(' ').includes('repos/o/r/issues/4/dependencies/blocked_by')),
      ).toBe(true);
    });

    it('retries a failing mutation and succeeds on the 3rd try', async () => {
      const { r, mutations } = await run({
        items: [projectItem(1, null)],
        failMutation: 2,
      });
      expect(r.status).toBe(0);
      expect(mutations).toHaveLength(3);
      expect(r.stdout).toContain('Needs: 1 changed, 0 unchanged');
    });

    it('exits 1 with one line after 4 failed tries', async () => {
      const { r, mutations } = await run({
        items: [projectItem(1, null)],
        failMutation: 99,
      });
      expect(r.status).toBe(1);
      expect(mutations).toHaveLength(4);
      expect(r.stdout).toMatch(/Needs sync failed: Needs update failed for o\/r#1/);
    });

    it('exits 1 when the project is not found', async () => {
      const gh = createFakeGh(tmp, '() => ({ repositoryOwner: { projectV2: null } })');
      const r = await worker.run(['-Owner', 'o', '-Number', '1'], {
        cwd: tmp,
        env: gh.env(),
      });
      expect(r.status).toBe(1);
      expect(r.stdout).toContain('Needs sync failed: Project o/1 not found');
    });
  },
);
