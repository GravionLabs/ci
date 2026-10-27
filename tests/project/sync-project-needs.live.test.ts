import { spawnSync } from 'child_process';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { createFakeGh } from '../helpers/fake-gh';
import { PwshWorker } from '../helpers/pwsh-worker';

const SCRIPT = path.resolve(
  __dirname,
  '../../.apm/skills/github-project/scripts/Sync-ProjectNeeds.ps1'
);

const hasPwsh = spawnSync('pwsh', ['-NoProfile', '-Command', '1']).status === 0;
const hasNode = spawnSync('node', ['-v']).status === 0;

it('pwsh is installed in CI (the live Sync-ProjectNeeds cases must not be skipped there)', () => {
  if (process.env.CI) expect(hasPwsh).toBe(true);
});

// Canned GraphQL answers. data.json: {fields, items (project item nodes), issues ({"o/r#n": project item + content}), prs, noNeeds}.
const HANDLER = `(call, ctx) => {
  const fs = require('fs');
  const d = JSON.parse(fs.readFileSync(process.env.FAKE_DATA, 'utf8'));
  const q = call.query || '';
  if (call.args[0] === 'api' && call.args[1] !== 'graphql' && String(call.args[1]).includes('/dependencies/blocking')) {
    return { rest: (d.restBlocking || {})[call.args[1].split('/dependencies')[0]] || [] };
  }
  if (call.args[0] === 'api' && call.args[1] !== 'graphql') {
    return { rest: d.rest || [] };
  }
  if (q.includes('blocking(') && d.noBlocking) throw new Error("Field 'blocking' doesn't exist on type 'Issue'");
  if (q.includes('blockedBy') && d.noBlockedBy) throw new Error("Field 'blockedBy' doesn't exist on type 'Issue'");
  if (q.includes('mutation')) {
    if (d.failMutation && ctx.count('mut') <= d.failMutation) throw new Error('secondary rate limit');
    return {};
  }
  if (q.includes('projectV2(number')) {
    const status = { __typename: 'ProjectV2SingleSelectField', id: 'F-status', name: 'Status',
      options: d.noStatusOption ? [{ id: 'O-todo', name: 'Todo' }] : [{ id: 'O-todo', name: 'Todo' }, { id: 'O-ip', name: 'In Progress' }] };
    const nodes = d.noNeeds ? [status] : [status, { __typename: 'ProjectV2SingleSelectField', id: 'F-needs', name: 'Needs',
      options: ['Planning','Ready','In progress','Blocked','Review','Decision','Release review'].map((n) => ({ id: 'O-' + n, name: n })) }];
    return { repositoryOwner: { projectV2: { id: 'P1', fields: { nodes } } } };
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

const issueNode = (over: Record<string, any> = {}) => ({
  number: 1,
  title: '[PBI] t',
  state: 'OPEN',
  issueType: null,
  repository: { nameWithOwner: 'o/r' },
  labels: { nodes: [] },
  parent: null,
  subIssues: { nodes: [{ number: 100, title: '[Task] x', projectItems: { nodes: [] } }] },
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
      env: Record<string, string> = {}
    ) => {
      const gh = createFakeGh(tmp, HANDLER);
      const dataFile = path.join(tmp, 'data.json');
      fs.writeFileSync(dataFile, JSON.stringify({ prs: {}, issues: {}, items: [], ...data }));
      const r = await worker.run(['-Owner', 'o', '-Number', '1', ...args], {
        cwd: tmp,
        env: { ...gh.env(), FAKE_DATA: dataFile, SYNC_PROJECT_NEEDS_BACKOFF: '0', ...env },
      });
      const calls = gh.calls();
      return {
        r,
        calls,
        itemQueries: calls.filter((c) => c.query?.includes('items(first: 100')),
        mutations: calls.filter((c) => c.query?.includes('mutation')),
      };
    };

    it('pages 150 items in 2 queries and mutates only the changed ones', async () => {
      // 150 PBIs with a Task sub-issue and no other signal -> Ready; 10 of them already carry Ready.
      const items = Array.from({ length: 150 }, (_, i) =>
        projectItem(i + 1, i < 10 ? 'Ready' : null)
      );
      const { r, itemQueries, mutations } = await run({ items });
      expect(r.stdout).toContain('#11: (none) -> Ready');
      expect(r.stdout).toContain('Needs: 140 changed, 10 unchanged');
      expect(r.status).toBe(0);
      expect(itemQueries).toHaveLength(2);
      expect(itemQueries[1].variables!.cursor).toBe('100');
      expect(mutations).toHaveLength(140);
      const first = mutations[0].variables!.i;
      expect(first).toEqual({
        projectId: 'P1',
        itemId: 'I11',
        fieldId: 'F-needs',
        value: { singleSelectOptionId: 'O-Ready' },
      });
      expect(mutations[0].query).toContain('updateProjectV2ItemFieldValue');
    });

    it('clears the field of a closed item with clearProjectV2ItemFieldValue', async () => {
      const { r, mutations } = await run({ items: [projectItem(5, 'Ready', { state: 'CLOSED' })] });
      expect(r.stdout).toContain('#5: Ready -> (clear)');
      expect(mutations).toHaveLength(1);
      expect(mutations[0].query).toContain('clearProjectV2ItemFieldValue');
      expect(mutations[0].variables!.i).toEqual({
        projectId: 'P1',
        itemId: 'I5',
        fieldId: 'F-needs',
      });
    });

    it('-DryRun prints the changes and sends no mutation', async () => {
      const { r, mutations } = await run(
        { items: [projectItem(1, null), projectItem(2, 'Ready')] },
        ['-DryRun']
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
            nodes: [{ id: 'I8', project: { id: 'OTHER' }, status: null, level: null, needs: null }],
          },
        },
      };
      const { r, calls, itemQueries, mutations } = await run({ issues }, ['-Issue', 'o/r#7,o/r#8']);
      expect(r.status).toBe(0);
      expect(itemQueries).toHaveLength(0);
      expect(calls.filter((c) => c.variables?.n0 !== undefined)).toHaveLength(1);
      expect(mutations).toHaveLength(1);
      expect(mutations[0].variables!.i.itemId).toBe('I7');
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
      expect(mutations[0].variables!.i.itemId).toBe('I7');
    });

    it('reads every page of open PR heads', async () => {
      const prs = Array.from({ length: 120 }, (_, i) => `feat/${1000 + i}-x`);
      prs.push('feat/7-late');
      const { r, calls } = await run({ items: [projectItem(7, null)], prs: { 'o/r': prs } });
      expect(r.status).toBe(0);
      expect(r.stdout).toContain('#7: (none) -> In progress');
      expect(calls.filter((c) => c.query?.includes('pullRequests'))).toHaveLength(2);
    });

    describe('-SetStatus', () => {
      const statusIssues = (project = 'P1') => ({
        'o/r#7': {
          ...issueNode({ number: 7 }),
          projectItems: {
            nodes: [{ id: 'I7', project: { id: project }, status: null, level: null, needs: null }],
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
        expect(mutations[0].variables!.i).toEqual({
          projectId: 'P1',
          itemId: 'I7',
          fieldId: 'F-status',
          value: { singleSelectOptionId: 'O-ip' },
        });
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
        'o/r#7': pItem(7, { parent: { number: 3, repository: { nameWithOwner: 'o/r' } } }),
        'o/r#3': pItem(3, { title: '[Feature] f', subIssues: { nodes: [] } }),
      };
      issues['o/r#3'].projectItems.nodes[0].level = { name: 'Feature' };
      const { r, mutations } = await run({ issues }, ['-Issue', 'o/r#7', '-IncludeParents']);
      expect(r.status).toBe(0);
      expect(mutations.map((m) => m.variables!.i.itemId).sort()).toEqual(['I3', 'I7']);
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
          blocking: { nodes: [dep(8), dep(9, 'o/r', 'CLOSED'), dep(10, 'o/x'), dep(11)] },
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
        expect(mutations.map((m) => m.variables!.i.itemId).sort()).toEqual(['I10', 'I7', 'I8']);
        const first = calls.find((c) => c.query?.includes('repository(owner'))!;
        expect(first.query).toContain('blocking(first: 50)');
      });
      it('does not ask for blocking without the switch', async () => {
        const { calls, mutations } = await run({ issues: issues() }, ['-Issue', 'o/r#7']);
        expect(calls.some((c) => c.query?.includes('blocking('))).toBe(false);
        expect(mutations.map((m) => m.variables!.i.itemId)).toEqual(['I7']);
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
          ['-Issue', 'o/r#7', '-IncludeDependents']
        );
        expect(r.status).toBe(0);
        expect(mutations.map((m) => m.variables!.i.itemId).sort()).toEqual(['I7', 'I8']);
        expect(calls.some((c) => c.args.join(' ').includes('/dependencies/blocking'))).toBe(true);
      });
    });

    it('prints the skip line and exits 0 when the field Needs is missing', async () => {
      const { r, calls } = await run({ noNeeds: true, items: [projectItem(1, null)] });
      expect(r.stdout.trim()).toBe(
        'Needs sync skipped: field Needs missing (run Set-ProjectStandard.ps1, #596)'
      );
      expect(r.status).toBe(0);
      expect(calls).toHaveLength(1);
    });

    it('matches open PR heads of the repository and blocked-by links from GraphQL', async () => {
      const items = [
        projectItem(7, null),
        projectItem(8, null, { blockedBy: { nodes: [{ state: 'OPEN' }, { state: 'CLOSED' }] } }),
        projectItem(9, null, { blockedBy: { nodes: [{ state: 'CLOSED' }] } }),
        projectItem(10, null, {
          closedByPullRequestsReferences: { nodes: [{ state: 'OPEN', headRefName: 'x' }] },
        }),
      ];
      const { r, calls } = await run({ items, prs: { 'o/r': ['feat/7-thing', 'feat/17-other'] } });
      expect(r.status).toBe(0);
      expect(r.stdout).toContain('#7: (none) -> In progress');
      expect(r.stdout).toContain('#8: (none) -> Blocked');
      expect(r.stdout).toContain('#9: (none) -> Ready');
      expect(r.stdout).toContain('#10: (none) -> In progress');
      expect(calls.filter((c) => c.query?.includes('pullRequests'))).toHaveLength(1);
    });

    it('treats merged blockers (label, Status In release) as resolved and open cross-repo ones as blocking', async () => {
      const inRelease = { project: { id: 'P1' }, status: { name: 'In release' } };
      const items = [
        projectItem(21, null, {
          blockedBy: { nodes: [{ state: 'OPEN', labels: { nodes: [{ name: 'merged' }] } }] },
        }),
        projectItem(22, null, {
          blockedBy: { nodes: [{ state: 'OPEN', projectItems: { nodes: [inRelease] } }] },
        }),
        projectItem(23, null, {
          blockedBy: {
            nodes: [
              { state: 'OPEN', repository: { nameWithOwner: 'o/other' }, labels: { nodes: [] } },
            ],
          },
        }),
        projectItem(24, null, {
          blockedBy: {
            nodes: [
              {
                state: 'OPEN',
                projectItems: {
                  nodes: [{ project: { id: 'P2' }, status: { name: 'In release' } }],
                },
              },
            ],
          },
        }),
      ];
      const { r, calls } = await run({ items });
      expect(r.status).toBe(0);
      expect(r.stdout).toContain('#21: (none) -> Ready');
      expect(r.stdout).toContain('#22: (none) -> Ready');
      expect(r.stdout).toContain('#23: (none) -> Blocked');
      expect(r.stdout).toContain('#24: (none) -> Blocked');
      const q = calls.find((c) => c.query?.includes('items(first: 100'))!.query!;
      expect(q).toMatch(/blockedBy\(first: 20\) \{ nodes \{ number state repository/);
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
        calls.some((c) => c.args.join(' ').includes('repos/o/r/issues/4/dependencies/blocked_by'))
      ).toBe(true);
    });

    it('retries a failing mutation and succeeds on the 3rd try', async () => {
      const { r, mutations } = await run({ items: [projectItem(1, null)], failMutation: 2 });
      expect(r.status).toBe(0);
      expect(mutations).toHaveLength(3);
      expect(r.stdout).toContain('Needs: 1 changed, 0 unchanged');
    });

    it('exits 1 with one line after 4 failed tries', async () => {
      const { r, mutations } = await run({ items: [projectItem(1, null)], failMutation: 99 });
      expect(r.status).toBe(1);
      expect(mutations).toHaveLength(4);
      expect(r.stdout).toMatch(/Needs sync failed: Needs update failed for o\/r#1/);
    });

    it('exits 1 when the project is not found', async () => {
      const gh = createFakeGh(tmp, '() => ({ repositoryOwner: { projectV2: null } })');
      const r = await worker.run(['-Owner', 'o', '-Number', '1'], { cwd: tmp, env: gh.env() });
      expect(r.status).toBe(1);
      expect(r.stdout).toContain('Needs sync failed: Project o/1 not found');
    });
  }
);
