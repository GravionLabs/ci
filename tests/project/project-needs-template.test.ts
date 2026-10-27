import * as fs from 'fs';
import * as path from 'path';
import { parse } from 'yaml';

const root = path.resolve(__dirname, '../..');
const tplDir = path.join(root, '.apm/skills/github-project/templates');
const read = (p: string) => fs.readFileSync(p, 'utf-8');

type Wf = { jobs: Record<string, { with?: Record<string, unknown> }> };
// Parsed YAML drops comments; the project URL, the workflow name and the local `uses` of ci's own workflow differ.
const strip = (w: Wf) =>
  JSON.parse(
    JSON.stringify(w, (k, v) =>
      k === 'project-url' || k === 'name'
        ? undefined
        : k === 'uses' && v === './.github/workflows/issues.yml'
          ? 'GravionLabs/ci/.github/workflows/issues.yml@main'
          : v
    )
  ) as Record<string, unknown>;

describe.each([
  ['issue-events.yml', 'issues'],
  ['project-needs.yml', 'needs'],
])('template %s (#519)', (file, jobName) => {
  const text = read(path.join(tplDir, file));
  const tpl = parse(text) as Wf;
  const own = parse(read(path.join(root, '.github/workflows', file))) as Wf;

  it('equals the own workflow except comments and the project URL', () => {
    expect(strip(tpl)).toEqual(strip(own));
  });

  it('calls issues.yml of GravionLabs/ci with the project URL placeholder', () => {
    const job = tpl.jobs[jobName] as { uses?: string; with?: Record<string, unknown> };
    expect(job.uses).toBe('GravionLabs/ci/.github/workflows/issues.yml@main');
    expect(job.with?.['project-url']).toBe('https://github.com/users/<owner>/projects/<n>');
  });

  it('has no leftover placeholders of the old inline workflow', () => {
    for (const p of ['__OWNER__', '__PROJECT_NUMBER__', '__TOKEN__']) expect(text).not.toContain(p);
  });

  it('names the ci README and passes the secrets explicitly', () => {
    expect(text).toMatch(/GravionLabs\/ci README/);
    expect(text).not.toContain('secrets: inherit\n');
    expect(text).toContain('GH_PAT: ${{ secrets.GH_PAT }}');
  });
});
