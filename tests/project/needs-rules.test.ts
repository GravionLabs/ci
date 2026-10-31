import { spawnSync } from 'child_process';
import * as fs from 'fs';
import * as os from 'os';
import * as path from 'path';

const MODULE = path.resolve(
  __dirname,
  '../../.apm/skills/github-project/scripts/NeedsRules.psm1'
);
const hasPwsh = spawnSync('pwsh', ['-NoProfile', '-Command', '1']).status === 0;

// One pwsh process for all cases: input is a JSON array of blockers, output the JSON array of Test-BlockerUnresolved results
// plus the Needs value of an item per blockedByOpen count.
const run = (blockers: unknown[]) => {
  const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'needs-rules-')), 'b.json');
  fs.writeFileSync(file, JSON.stringify(blockers));
  const script = `Import-Module '${MODULE}' -Force
$b = Get-Content -Raw '${file}' | ConvertFrom-Json
ConvertTo-Json -InputObject @($b | ForEach-Object { [bool](Test-BlockerUnresolved $_) }) -Compress`;
  const r = spawnSync('pwsh', ['-NoProfile', '-Command', script], { encoding: 'utf8' });
  fs.rmSync(path.dirname(file), { recursive: true, force: true });
  expect(r.status, r.stderr).toBe(0);
  return JSON.parse(r.stdout) as boolean[];
};

describe.skipIf(!hasPwsh)('Test-BlockerUnresolved', () => {
  it('blocks only for an open blocker that is not merged', () => {
    const out = run([
      { state: 'open', labels: [{ name: 'bug' }] },
      { state: 'OPEN', labels: ['merged'] },
      { state: 'open', labels: [{ name: 'Merged' }] },
      { state: 'OPEN', status: 'In release' },
      { state: 'OPEN', status: 'In Progress' },
      { state: 'closed', labels: [] },
      { state: 'CLOSED', labels: ['merged'] },
      { state: 'OPEN' },
      {},
    ]);
    expect(out).toEqual([true, false, false, false, true, false, false, true, false]);
  });
});
