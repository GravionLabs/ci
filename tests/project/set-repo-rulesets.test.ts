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

const CALLER = 'jobs:\n  pr-checks:\n    uses: GravionLabs/ci/.github/workflows/pr-checks.yml@main\n';
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
      if (!sub) return { rest: { archived: !!r.archived } };
      if (sub === 'contents/.github/workflows') {
        if (r.workflow === null) throw new Error('Not Found');
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

  it('writes nothing when the check is already required', () => {
    const r = run({ a: { workflow: CALLER, rulesets: [mainRuleset([rsc('PR checks')]),
      releaseRuleset([{ type: 'pull_request', parameters: {} }, rsc('PR checks')])] } }, '-Repo', 'a', '-Apply');
    expect(r.status).toBe(0);
    expect(r.writes).toHaveLength(0);
    expect(r.stdout).toContain('already requires');
  });

  it('skips a repository without a pr-checks.yml caller with a warning', () => {
    const r = run({ a: { workflow: 'jobs:\n  x:\n    uses: GravionLabs/ci/.github/workflows/nuget-package.yml@main\n', rulesets: [mainRuleset()] } },
      '-Repo', 'a', '-Apply');
    expect(r.status).toBe(0);
    expect(r.writes).toHaveLength(0);
    expect(r.stdout + r.stderr).toContain('no caller');
  });

  it('skips a repository without a workflows directory', () => {
    const r = run({ a: { workflow: null, rulesets: [] } }, '-Repo', 'a', '-Apply');
    expect(r.writes).toHaveLength(0);
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
