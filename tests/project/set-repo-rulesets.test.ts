import { spawnSync } from 'child_process';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { createFakeGh } from '../helpers/fake-gh';

const SCRIPT = path.resolve(__dirname, '../../scripts/Set-RepoRulesets.ps1');
const hasPwsh = spawnSync('pwsh', ['-NoProfile', '-Command', '1']).status === 0;

it('pwsh is installed in CI (the Set-RepoRulesets cases must not be skipped there)', () => {
  if (process.env.CI) expect(hasPwsh).toBe(true);
});

const CALLER = 'jobs:\n  pr-checks:\n    uses: GravionLabs/ci/.github/workflows/pr-checks.yml@v1\n';
const rsc = (...contexts: string[]) => ({
  type: 'required_status_checks',
  parameters: {
    strict_required_status_checks_policy: false,
    required_status_checks: contexts.map((context) => ({ context })),
  },
});
const mainRuleset = (extra: any[] = []) => ({
  id: 1, name: 'main', target: 'branch', enforcement: 'active',
  conditions: { ref_name: { include: ['~DEFAULT_BRANCH'], exclude: [] } },
  bypass_actors: [],
  rules: [{ type: 'deletion' }, { type: 'non_fast_forward' }, { type: 'pull_request', parameters: { required_approving_review_count: 0 } }, ...extra],
});
const releaseRuleset = (extra: any[] = []) => ({
  id: 2, name: 'release', target: 'branch', enforcement: 'active',
  conditions: { ref_name: { include: ['refs/heads/release/**'], exclude: [] } },
  bypass_actors: [],
  rules: [{ type: 'non_fast_forward' }, ...extra],
});

interface Repo { archived?: boolean; workflow?: string | null; rulesets: any[] }

describe.skipIf(!hasPwsh)('Set-RepoRulesets.ps1', () => {
  let dir: string;
  beforeEach(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rulesets-')); });
  afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

  const run = (repos: Record<string, Repo>, ...flags: string[]) => {
    const gh = createFakeGh(dir, `(call) => {
      const repos = ${JSON.stringify(repos)};
      const a = call.args; const url = a.find((x) => /^(repos|users)\\//.test(x));
      const m = url.match(/^repos\\/GravionLabs\\/([^/]+)(?:\\/(.*))?$/);
      if (a.includes('--method')) return { rest: {} };
      if (url.startsWith('users/')) return { rest: [Object.keys(repos).map((n) => ({ full_name: 'GravionLabs/' + n }))] };
      const r = repos[m[1]]; const sub = m[2];
      if (!sub) { console.error('gh: a warning on a successful call'); return { rest: { archived: !!r.archived } }; }
      if (sub === 'contents/.github/workflows') {
        if (r.workflow === null) throw new Error('gh: Not Found (HTTP 404)');
        return { rest: [{ name: 'ci.yml', path: '.github/workflows/ci.yml' }, { name: 'pr.yml', path: '.github/workflows/pr.yml' }] };
      }
      if (sub === 'contents/.github/workflows/ci.yml') return { rest: 'on: push' };
      if (sub === 'contents/.github/workflows/pr.yml') return { rest: r.workflow ?? '' };
      if (sub === 'rulesets') return { rest: r.rulesets.map((x) => ({ id: x.id, name: x.name })) };
      const id = Number(sub.split('/')[1]);
      return { rest: r.rulesets.find((x) => x.id === id) };
    }`);
    const r = spawnSync('pwsh', ['-NoProfile', '-File', SCRIPT, ...flags], { env: gh.env(), encoding: 'utf8' });
    const writes = gh.calls().filter((c) => c.args.includes('--method'));
    return { ...r, writes };
  };
  const checksOf = (body: any) =>
    body.rules.find((x: any) => x.type === 'required_status_checks').parameters.required_status_checks.map((c: any) => c.context);

  it('updates existing rulesets: adds the check, keeps other rules, release gets pull_request', () => {
    const r = run({ a: { workflow: CALLER, rulesets: [mainRuleset([rsc('lint')]), releaseRuleset()] } }, '-Repo', 'a', '-Apply');
    expect(r.status).toBe(0);
    expect(r.writes).toHaveLength(2);
    const [main, rel] = r.writes;
    expect(main.args).toContain('PUT');
    expect(main.args).toContain('repos/GravionLabs/a/rulesets/1');
    expect(checksOf(main.body)).toEqual(['lint', 'PR checks']);
    expect(main.body.rules.map((x: any) => x.type)).toEqual(['deletion', 'non_fast_forward', 'pull_request', 'required_status_checks']);
    expect(rel.args).toContain('repos/GravionLabs/a/rulesets/2');
    expect(rel.body.rules.map((x: any) => x.type)).toEqual(['non_fast_forward', 'pull_request', 'required_status_checks']);
    expect(checksOf(rel.body)).toEqual(['PR checks']);
  });

  it('sends bypass_actors as an array with exactly one actor, several and none', () => {
    const actor = { actor_id: 5, actor_type: 'RepositoryRole', bypass_mode: 'always' };
    const other = { actor_id: 1, actor_type: 'OrganizationAdmin', bypass_mode: 'always' };
    const one = { ...mainRuleset([rsc('lint')]), bypass_actors: [actor] };
    const two = { ...releaseRuleset(), bypass_actors: [actor, other] };
    const r = run({ a: { workflow: CALLER, rulesets: [one, two] } }, '-Repo', 'a', '-Apply');
    const n = run({ a: { workflow: CALLER, rulesets: [mainRuleset(), releaseRuleset()] } }, '-Repo', 'a', '-Apply');
    expect(r.status).toBe(0);
    expect(n.status).toBe(0);
    const bodies = [...r.writes, ...n.writes.slice(r.writes.length)].map((w) => w.body);
    expect(bodies[0].bypass_actors).toEqual([actor]);
    expect(bodies[1].bypass_actors).toEqual([actor, other]);
    expect(bodies[2].bypass_actors).toEqual([]);
    expect(bodies[3].bypass_actors).toEqual([]);
    for (const b of bodies) expect(Array.isArray(b.conditions.ref_name.include)).toBe(true);
  });

  it('creates the rulesets when missing', () => {
    const r = run({ a: { workflow: CALLER, rulesets: [] } }, '-Repo', 'a', '-Apply');
    expect(r.writes).toHaveLength(2);
    expect(r.writes.every((w) => w.args.includes('POST') && w.args.includes('repos/GravionLabs/a/rulesets'))).toBe(true);
    expect(r.writes[0].body.name).toBe('main');
    expect(r.writes[0].body.conditions.ref_name.include).toEqual(['~DEFAULT_BRANCH']);
    expect(r.writes[1].body.conditions.ref_name.include).toEqual(['refs/heads/release/**']);
    expect(checksOf(r.writes[1].body)).toEqual(['PR checks']);
    expect(r.writes[1].body.rules.map((x: any) => x.type)).toContain('pull_request');
  });

  it('-Replace removes the superseded check in the same update', () => {
    const r = run({ a: { workflow: CALLER, rulesets: [mainRuleset([rsc('ready', 'lint')]), releaseRuleset([rsc('ready')])] } },
      '-Repo', 'a', '-Replace', 'ready', '-Apply');
    expect(checksOf(r.writes[0].body)).toEqual(['lint', 'PR checks']);
    expect(checksOf(r.writes[1].body)).toEqual(['PR checks']);
  });

  it('honours -Context', () => {
    const r = run({ a: { workflow: CALLER, rulesets: [mainRuleset(), releaseRuleset()] } },
      '-Repo', 'a', '-Context', 'pr-checks / PR checks', '-Apply');
    expect(checksOf(r.writes[0].body)).toEqual(['pr-checks / PR checks']);
  });

  const prRule = (methods: string[], extra: any = {}) => ({
    type: 'pull_request',
    parameters: {
      required_approving_review_count: 0, dismiss_stale_reviews_on_push: false, require_code_owner_review: false,
      require_last_push_approval: false, required_review_thread_resolution: false, allowed_merge_methods: methods, ...extra,
    },
  });
  const prOf = (body: any) => body.rules.find((x: any) => x.type === 'pull_request').parameters;
  const withPr = (rs: any, pr: any) => ({ ...rs, rules: rs.rules.map((x: any) => (x.type === 'pull_request' ? pr : x)) });

  it('creates rulesets with merge methods: main merge, release merge and squash', () => {
    const r = run({ a: { workflow: CALLER, rulesets: [] } }, '-Repo', 'a', '-Apply');
    expect(prOf(r.writes[0].body).allowed_merge_methods).toEqual(['merge']);
    expect(prOf(r.writes[1].body).allowed_merge_methods).toEqual(['merge', 'squash']);
  });

  it('updates an existing ruleset that allows all three methods and keeps foreign rules', () => {
    const all = ['merge', 'squash', 'rebase'];
    const copilot = { type: 'copilot_code_review', parameters: { review_draft_pull_requests: true, review_on_push: true } };
    const m = withPr(mainRuleset([rsc('PR checks'), copilot]), prRule(all));
    const rel = withPr(releaseRuleset([prRule(all), rsc('PR checks')]), prRule(all));
    const r = run({ a: { workflow: CALLER, rulesets: [m, rel] } }, '-Repo', 'a', '-Apply');
    expect(r.writes).toHaveLength(2);
    expect(prOf(r.writes[0].body).allowed_merge_methods).toEqual(['merge']);
    expect(prOf(r.writes[1].body).allowed_merge_methods).toEqual(['merge', 'squash']);
    expect(r.writes[0].body.rules.map((x: any) => x.type)).toEqual(['deletion', 'non_fast_forward', 'pull_request', 'required_status_checks', 'copilot_code_review']);
    expect(r.writes[0].body.rules[4]).toEqual(copilot);
  });

  it('updates a release ruleset that is squash only', () => {
    const main = withPr(mainRuleset([rsc('PR checks')]), prRule(['merge']));
    const old = run({ a: { workflow: CALLER, rulesets: [main, releaseRuleset([prRule(['squash']), rsc('PR checks')])] } }, '-Repo', 'a', '-Apply');
    expect(old.writes).toHaveLength(1);
    expect(old.writes[0].body.name).toBe('release');
    expect(prOf(old.writes[0].body).allowed_merge_methods).toEqual(['merge', 'squash']);
  });

  it('leaves a release ruleset at merge and squash in any order unchanged', () => {
    const main = withPr(mainRuleset([rsc('PR checks')]), prRule(['merge']));
    const ok = run({ a: { workflow: CALLER, rulesets: [main, releaseRuleset([prRule(['squash', 'merge']), rsc('PR checks')])] } }, '-Repo', 'a', '-Apply');
    expect(ok.writes).toHaveLength(0);
  });

  it('does not send the parameters the API rejects on PUT', () => {
    const pr = prRule(['merge', 'squash'], { required_reviewers: [], require_extra_approval_for_unattributed_changes: false });
    const r = run({ a: { workflow: CALLER, rulesets: [withPr(mainRuleset([rsc('PR checks')]), pr), releaseRuleset()] } }, '-Repo', 'a', '-Apply');
    expect(Object.keys(prOf(r.writes[0].body)).sort()).toEqual([
      'allowed_merge_methods', 'dismiss_stale_reviews_on_push', 'require_code_owner_review', 'require_last_push_approval',
      'required_approving_review_count', 'required_review_thread_resolution']);
  });

  it.each([
    ['non-empty required_reviewers', { required_reviewers: [{ reviewer: { id: 1, type: 'Team' }, file_patterns: ['*'], minimum_approvals: 1 }] }],
  ])('writes nothing and warns for %s, other rulesets unaffected', (_n, extra) => {
    const blocked = withPr(mainRuleset([rsc('PR checks')]), prRule(['merge', 'squash'], extra));
    for (const flags of [['-Apply'], []]) {
      const r = run({ a: { workflow: CALLER, rulesets: [blocked, releaseRuleset()] } }, '-Repo', 'a', ...flags);
      expect(r.status).toBe(1);
      expect(r.stdout + r.stderr).toContain("GravionLabs/a ruleset 'main' has required_reviewers; set allowed_merge_methods by hand");
      if (flags.length) {
        expect(r.writes).toHaveLength(1);
        expect(r.writes[0].body.name).toBe('release');
      }
    }
  });

  it('ignores the unattributed-changes flag (API default true): right methods change nothing, wrong methods update without it', () => {
    const flag = { required_reviewers: [], require_extra_approval_for_unattributed_changes: true };
    const ok = [withPr(mainRuleset([rsc('PR checks')]), prRule(['merge'], flag)), releaseRuleset([prRule(['squash', 'merge'], flag), rsc('PR checks')])];
    const r = run({ a: { workflow: CALLER, rulesets: ok } }, '-Repo', 'a', '-Apply');
    expect(r.status).toBe(0);
    expect(r.writes).toHaveLength(0);
    expect(r.stdout + r.stderr).not.toContain('by hand');
    const wrong = [withPr(mainRuleset([rsc('PR checks')]), prRule(['merge', 'squash', 'rebase'], flag)), ok[1]];
    const w = run({ a: { workflow: CALLER, rulesets: wrong } }, '-Repo', 'a', '-Apply');
    expect(w.status).toBe(0);
    expect(w.writes).toHaveLength(1);
    expect(prOf(w.writes[0].body).allowed_merge_methods).toEqual(['merge']);
    expect(prOf(w.writes[0].body)).not.toHaveProperty('require_extra_approval_for_unattributed_changes');
  });

  it('is idempotent: nothing to change when the methods are right, and the dry run reports a change', () => {
    const ok = [withPr(mainRuleset([rsc('PR checks')]), prRule(['merge'], { required_reviewers: [] })),
      releaseRuleset([prRule(['squash', 'merge']), rsc('PR checks')])];
    const r = run({ a: { workflow: CALLER, rulesets: ok } }, '-Repo', 'a', '-Apply');
    expect(r.status).toBe(0);
    expect(r.writes).toHaveLength(0);
    const wrong = [withPr(mainRuleset([rsc('PR checks')]), prRule(['merge', 'squash'])), ok[1]];
    const d = run({ a: { workflow: CALLER, rulesets: wrong } }, '-Repo', 'a');
    expect(d.writes).toHaveLength(0);
    expect(d.stdout).toContain("PLAN GravionLabs/a : update ruleset 'main'");
    expect(d.stdout).toContain('merge methods: merge');
  });

  it('writes nothing when the check is already required', () => {
    const r = run({ a: { workflow: CALLER, rulesets: [withPr(mainRuleset([rsc('PR checks')]), prRule(['merge'])),
      releaseRuleset([prRule(['squash', 'merge']), rsc('PR checks')])] } }, '-Repo', 'a', '-Apply');
    expect(r.status).toBe(0);
    expect(r.writes).toHaveLength(0);
    expect(r.stdout).toContain('already requires');
  });

  it('skips a repository without a pr-checks.yml caller with a warning', () => {
    const r = run({ a: { workflow: 'jobs:\n  x:\n    uses: GravionLabs/ci/.github/workflows/nuget-package.yml@v1\n', rulesets: [mainRuleset()] } },
      '-Repo', 'a', '-Apply');
    expect(r.status).toBe(0);
    expect(r.writes).toHaveLength(0);
    expect(r.stdout + r.stderr).toContain('no caller');
  });

  const LOCAL = 'jobs:\n  pr-checks:\n    uses: ./.github/workflows/pr-checks.yml\n';

  it('recognises the local caller in GravionLabs/ci', () => {
    const r = run({ ci: { workflow: LOCAL, rulesets: [mainRuleset(), releaseRuleset()] } }, '-Repo', 'ci', '-Apply');
    expect(r.status).toBe(0);
    expect(r.writes).toHaveLength(2);
    expect(checksOf(r.writes[0].body)).toEqual(['PR checks']);
  });

  it('still skips another repository whose only caller is a local path', () => {
    const r = run({ a: { workflow: LOCAL, rulesets: [mainRuleset()] } }, '-Repo', 'a', '-Apply');
    expect(r.status).toBe(0);
    expect(r.writes).toHaveLength(0);
    expect(r.stdout + r.stderr).toContain('no caller');
  });

  it('skips a repository without a workflows directory', () => {
    const r = run({ a: { workflow: null, rulesets: [] } }, '-Repo', 'a', '-Apply');
    expect(r.status).toBe(0);
    expect(r.writes).toHaveLength(0);
    expect(r.stdout + r.stderr).toContain('no caller');
  });

  it('skips an archived repository', () => {
    const r = run({ a: { archived: true, workflow: CALLER, rulesets: [] } }, '-Repo', 'a', '-Apply');
    expect(r.status).toBe(0);
    expect(r.writes).toHaveLength(0);
    expect(r.stdout).toContain('archived');
  });

  it('dry run (no -Apply) prints the plan and makes no write call', () => {
    const r = run({ a: { workflow: CALLER, rulesets: [mainRuleset(), releaseRuleset()] } }, '-Repo', 'a');
    expect(r.status).toBe(0);
    expect(r.writes).toHaveLength(0);
    expect(r.stdout).toContain("update ruleset 'main'");
    expect(r.stdout).toContain('dry run');
    expect(r.stdout).toContain("update ruleset 'main' (id 1)");
    expect(r.stdout).toContain("update ruleset 'release' (id 2)");
  });

  it('omits the parameters key of rules without parameters', () => {
    const r = run({ a: { workflow: CALLER, rulesets: [mainRuleset(), releaseRuleset()] } }, '-Repo', 'a', '-Apply');
    expect(r.writes).toHaveLength(2);
    for (const w of r.writes) expect(JSON.stringify(w.body)).not.toContain('"parameters":null');
    expect(r.writes[0].body.rules[0]).toEqual({ type: 'deletion' });
  });

  it('-All covers every listed repository', () => {
    const r = run({ a: { workflow: CALLER, rulesets: [] }, b: { archived: true, rulesets: [] } }, '-All', '-Apply');
    expect(r.writes).toHaveLength(2);
    expect(r.writes.every((w) => w.args.some((x) => x.startsWith('repos/GravionLabs/a/')))).toBe(true);
  });

  it('fails without -Repo and -All', () => {
    const r = run({}, '-Apply');
    expect(r.status).not.toBe(0);
  });
});
