import { spawnSync } from 'child_process';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';
import { createFakeGh } from '../helpers/fake-gh';

const SCRIPT = path.resolve(__dirname, '../../scripts/Set-RepoSecurity.ps1');
const hasPwsh = spawnSync('pwsh', ['-NoProfile', '-Command', '1']).status === 0;

it('pwsh is installed in CI (the Set-RepoSecurity cases must not be skipped there)', () => {
  if (process.env.CI) expect(hasPwsh).toBe(true);
});

interface Repo {
  private?: boolean;
  archived?: boolean;
  alerts?: boolean;
  scan?: boolean;
  push?: boolean;
  pvr?: boolean;
  fork?: string;
  immutable?: boolean;
  rulesets?: any[];
  fail?: boolean;
}

const versionTags = (over: any = {}) => ({
  id: 7, name: 'version tags', target: 'tag', enforcement: 'active',
  conditions: { ref_name: { include: ['refs/tags/v*.*.*'], exclude: [] } },
  bypass_actors: [],
  rules: [{ type: 'deletion' }, { type: 'update' }, { type: 'non_fast_forward' }],
  ...over,
});
const allSet = (over: Repo = {}): Repo => ({
  alerts: true, scan: true, push: true, pvr: true, fork: 'all_external_contributors', rulesets: [versionTags()], ...over,
});

describe.skipIf(!hasPwsh)('Set-RepoSecurity.ps1', () => {
  let dir: string;
  beforeEach(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), 'security-')); });
  afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

  const run = (repos: Record<string, Repo>, ...flags: string[]) => {
    const gh = createFakeGh(fs.mkdtempSync(path.join(dir, 'run-')), `(call) => {
      const repos = ${JSON.stringify(repos)};
      const a = call.args; const url = a.find((x) => /^(repos|user)\\//.test(x));
      if (url.startsWith('user/repos')) return { rest: [[...Object.keys(repos).map((n) => ({ full_name: 'GravionLabs/' + n, owner: { login: 'GravionLabs' } })), { full_name: 'someone/else', owner: { login: 'someone' } }]] };
      const m = url.match(/^repos\\/GravionLabs\\/([^/]+)(?:\\/(.*))?$/);
      const r = repos[m[1]]; const sub = m[2];
      if (r.fail && !sub) throw new Error('gh: boom (HTTP 500)');
      if (a.includes('--method')) return { rest: {} };
      if (!sub) return { rest: { archived: !!r.archived, private: !!r.private, security_and_analysis: r.private ? null : {
        secret_scanning: { status: r.scan ? 'enabled' : 'disabled' }, secret_scanning_push_protection: { status: r.push ? 'enabled' : 'disabled' } } } };
      if (sub === 'vulnerability-alerts') { if (!r.alerts) throw new Error('gh: Not Found (HTTP 404)'); return { rest: '' }; }
      if (sub === 'private-vulnerability-reporting') return { rest: { enabled: !!r.pvr } };
      if (sub === 'actions/permissions/fork-pr-contributor-approval') return { rest: { approval_policy: r.fork ?? 'first_time_contributors' } };
      if (sub === 'immutable-releases') return { rest: { enabled: !!r.immutable, enforced_by_owner: false } };
      if (sub === 'rulesets') return { rest: (r.rulesets ?? []).map((x) => ({ id: x.id, name: x.name })) };
      const id = Number(sub.split('/')[1]);
      return { rest: (r.rulesets ?? []).find((x) => x.id === id) };
    }`);
    const r = spawnSync('pwsh', ['-NoProfile', '-File', SCRIPT, ...flags], { env: gh.env(), encoding: 'utf8' });
    const calls = gh.calls();
    const writes = calls.filter((c) => c.args.includes('--method'));
    const target = (w: any) => w.args.find((x: string) => x.startsWith('repos/'));
    return { ...r, calls, writes, target };
  };

  it('dry run prints a PLAN per missing setting of a public repository and writes nothing', () => {
    const r = run({ a: { rulesets: [] } }, '-Repo', 'a');
    expect(r.status).toBe(0);
    expect(r.writes).toHaveLength(0);
    for (const s of ['Dependabot alerts', 'secret scanning and push protection', 'private vulnerability reporting',
      'fork pull request approval', "tag ruleset 'version tags'"]) {
      expect(r.stdout).toMatch(new RegExp(`PLAN GravionLabs/a : set ${s}.*\\[dry run\\]`));
    }
  });

  it('-Apply sets every setting of a public repository', () => {
    const r = run({ a: { rulesets: [] } }, '-Repo', 'a', '-Apply');
    expect(r.status).toBe(0);
    expect(r.writes.map((w) => [w.args[w.args.indexOf('--method') + 1], r.target(w)])).toEqual([
      ['PUT', 'repos/GravionLabs/a/vulnerability-alerts'],
      ['PATCH', 'repos/GravionLabs/a'],
      ['PUT', 'repos/GravionLabs/a/private-vulnerability-reporting'],
      ['PUT', 'repos/GravionLabs/a/actions/permissions/fork-pr-contributor-approval'],
      ['POST', 'repos/GravionLabs/a/rulesets'],
    ]);
    expect(r.writes[1].body).toEqual({ security_and_analysis: {
      secret_scanning: { status: 'enabled' }, secret_scanning_push_protection: { status: 'enabled' } } });
    expect(r.writes[3].body).toEqual({ approval_policy: 'all_external_contributors' });
  });

  it('creates the tag ruleset: tag target, v*.*.*, deletion/update/non_fast_forward, no bypass actor', () => {
    const r = run({ a: allSet({ rulesets: [] }) }, '-Repo', 'a', '-Apply');
    expect(r.writes).toHaveLength(1);
    const body = r.writes[0].body;
    expect(body.name).toBe('version tags');
    expect(body.target).toBe('tag');
    expect(body.enforcement).toBe('active');
    expect(body.conditions.ref_name.include).toEqual(['refs/tags/v*.*.*']);
    expect(body.bypass_actors).toEqual([]);
    expect(Array.isArray(body.bypass_actors)).toBe(true);
    expect(body.rules.map((x: any) => x.type)).toEqual(['deletion', 'update', 'non_fast_forward']);
  });

  it('a second run changes nothing', () => {
    const r = run({ a: allSet() }, '-Repo', 'a', '-Apply');
    expect(r.status).toBe(0);
    expect(r.writes).toHaveLength(0);
    expect(r.stdout).not.toMatch(/PLAN/);
    expect(r.stdout.match(/^OK /gm)).toHaveLength(5);
  });

  it('repairs a tag ruleset with a bypass actor or a missing rule (PUT on its id)', () => {
    const bypass = versionTags({ bypass_actors: [{ actor_id: 5, actor_type: 'RepositoryRole', bypass_mode: 'always' }] });
    const fewer = versionTags({ rules: [{ type: 'deletion' }] });
    for (const rs of [bypass, fewer]) {
      const r = run({ a: allSet({ rulesets: [rs] }) }, '-Repo', 'a', '-Apply');
      expect(r.writes).toHaveLength(1);
      expect(r.writes[0].args).toContain('PUT');
      expect(r.target(r.writes[0])).toBe('repos/GravionLabs/a/rulesets/7');
      expect(r.writes[0].body.bypass_actors).toEqual([]);
      expect(r.writes[0].body.rules).toHaveLength(3);
    }
  });

  it('a private repository gets Dependabot alerts only; the settings that need a public repository are skipped with a line', () => {
    const r = run({ p: { private: true, rulesets: [] } }, '-Repo', 'p', '-Apply');
    expect(r.status).toBe(0);
    expect(r.writes).toHaveLength(1);
    expect(r.target(r.writes[0])).toBe('repos/GravionLabs/p/vulnerability-alerts');
    expect(r.stdout.match(/needs a public repository/g)).toHaveLength(4);
    expect(r.calls.some((c) => c.args.some((x) => /fork-pr-contributor-approval|private-vulnerability-reporting|rulesets/.test(x)))).toBe(false);
  });

  it('skips an archived repository', () => {
    const r = run({ x: { archived: true } }, '-Repo', 'x', '-Apply');
    expect(r.status).toBe(0);
    expect(r.stdout).toContain('SKIP GravionLabs/x : archived');
    expect(r.writes).toHaveLength(0);
  });

  it('immutable releases are a switch: not requested = untouched, requested = enabled once', () => {
    const none = run({ a: allSet() }, '-Repo', 'a', '-Apply');
    expect(none.stdout).toContain('immutable releases not requested');
    expect(none.calls.some((c) => c.args.some((x) => x.endsWith('/immutable-releases')))).toBe(false);

    const on = run({ a: allSet({ immutable: false }) }, '-Repo', 'a', '-ImmutableReleases', 'a', '-Apply');
    expect(on.writes).toHaveLength(1);
    expect(on.target(on.writes[0])).toBe('repos/GravionLabs/a/immutable-releases');
    expect(on.writes[0].args).toContain('PUT');

    const already = run({ a: allSet({ immutable: true }) }, '-Repo', 'a', '-ImmutableReleases', 'a', '-Apply');
    expect(already.writes).toHaveLength(0);
    expect(already.stdout).toContain('OK   GravionLabs/a : immutable releases already set');
  });

  it('-All takes the repositories of the owner; one failing repository sets exit 1 and the others still run', () => {
    const r = run({ bad: { fail: true }, good: { alerts: false, scan: true, push: true, pvr: true, fork: 'all_external_contributors', rulesets: [versionTags()] } }, '-All', '-Apply');
    expect(r.status).toBe(1);
    expect(r.stderr).toContain('GravionLabs/bad');
    expect(r.writes).toHaveLength(1);
    expect(r.target(r.writes[0])).toBe('repos/GravionLabs/good/vulnerability-alerts');
  });

  it('needs -Repo or -All', () => {
    const r = run({}, '-Apply');
    expect(r.status).not.toBe(0);
    expect(r.stderr).toContain('Pass -Repo');
  });
});
