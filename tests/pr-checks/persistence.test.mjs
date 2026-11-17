import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import run from '../../pr-checks/persistence/run.mjs';
import { addedLines, adrStatus, findHits, isIgnored, markerOf } from '../../pr-checks/persistence/persistence.mjs';

const patchOf = (...added) => `@@ -0,0 +1,${added.length} @@\n${added.map((l) => `+${l}`).join('\n')}`;
const file = (filename, added = [], status = 'modified') => ({ filename, status, changes: added.length, patch: patchOf(...added) });
const ids = (f) => findHits(f).map((h) => h.id);

// Every pattern of the issue: one line that must fail, one similar line that must pass.
const CASES = [
  ['scheduled-task', 'src/service.rs', 'const SCHTASKS: &str = "schtasks";', 'const TASKS: &str = "tasks";'],
  ['scheduled-task', 'install.ps1', 'Register-ScheduledTask -TaskName x', 'Register-PackageSource -Name x'],
  ['scheduled-task', 'install.ps1', '$a = New-ScheduledTaskAction -Execute x', '$a = New-Item -Path x'],
  ['scheduled-task', 'src/task.cs', 'var svc = new ITaskService();', 'var svc = new TaskService();'],
  ['scheduled-task', 'src/task.xml', '<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">', '<Task xmlns="urn:x">'],
  ['run-key', 'src/reg.rs', 'r"Software\\Microsoft\\Windows\\CurrentVersion\\Run"', 'r"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall"'],
  ['run-key', 'src/reg.ps1', 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce', 'HKCU:\\Software\\GravionLabs\\App'],
  ['autostart', 'src-tauri/Cargo.toml', 'tauri-plugin-autostart = "2.7.0"', 'tauri-plugin-log = "2.7.0"'],
  ['autostart', 'src-tauri/src/lib.rs', '.plugin(tauri_plugin_autostart::init(', '.plugin(tauri_plugin_log::init('],
  ['autostart', 'package.json', '"auto-launch": "^5.0.0",', '"auto-update": "^5.0.0",'],
  ['autostart', 'main.ts', 'app.setLoginItemSettings({ openAtLogin: true });', 'app.getVersion();'],
  ['service', 'install.ps1', 'New-Service -Name tamias -BinaryPathName x', 'New-Item -Name tamias'],
  ['autostart', 'src/lib.rs', 'use auto_launch::AutoLaunchBuilder;', 'use auto_update::Builder;'],
  ['service', 'install.cmd', 'sc.exe create tamias binPath= x', 'sc.exe query tamias'],
  ['service', 'install.cmd', 'sc create tamias binPath= x', 'sc delete tamias'],
  ['launch-agent', 'src/mac.rs', 'home.join("Library/LaunchAgents")', 'home.join("Library/Caches")'],
  ['launch-agent', 'install.sh', 'cp x.plist /Library/LaunchDaemons/', 'cp x.plist /Library/Preferences/'],
  ['launch-agent', 'install.sh', 'launchctl load -w x.plist', 'launchctl unload x.plist'],
  ['launch-agent', 'install.sh', 'launchctl bootstrap gui/501 x.plist', 'launchctl print gui/501'],
  ['systemd-timer', 'install.sh', 'systemctl --user enable --now tamias.timer', 'systemctl --user status'],
  ['systemd-timer', 'unit.rs', 'OnCalendar=*:0/5', 'Description=tamias'],
  ['cron', 'install.sh', '(crontab -l; echo "*/5 * * * * x") | crontab -', 'echo "*/5 * * * * x"'],
  ['installer-script-host', 'src-tauri/windows/hooks.nsh', 'nsExec::Exec `powershell -NoProfile -Command x`', 'WriteRegExpandStr HKCU "Environment" "Path" $2'],
  ['installer-script-host', 'installer/app.wxs', '<CustomAction ExeCommand="pwsh -File x.ps1" />', '<RegistryValue Root="HKCU" />'],
];

describe('rules', () => {
  for (const [id, name, bad, good] of CASES) {
    it(`${id}: fails on ${bad}`, () => assert.deepEqual(ids(file(name, [bad])), [id]));
    it(`${id}: passes ${good}`, () => assert.deepEqual(ids(file(name, [good])), []));
  }

  it('flags added timer units and LaunchAgent plists by name', () => {
    assert.deepEqual(ids(file('packaging/tamias.timer', [], 'added')), ['systemd-timer']);
    assert.deepEqual(ids(file('packaging/LaunchAgents/x.plist', [], 'added')), ['launch-agent']);
    assert.deepEqual(ids(file('packaging/tamias.service', [], 'added')), []);
  });

  it('starts a script host only counts in installer scripts', () => {
    assert.deepEqual(ids(file('scripts/build.ps1', ['pwsh -File x.ps1'])), []);
  });

  it('ignores Markdown, removed files and removed or context lines', () => {
    assert.equal(isIgnored('docs/remove.md'), true);
    assert.deepEqual(ids(file('docs/remove.md', ['schtasks /Delete /TN x /F'])), []);
    assert.deepEqual(ids(file('src/a.rs', ['schtasks'], 'removed')), []);
    const patch = '@@ -1,2 +1,2 @@\n schtasks context\n-schtasks old\n+fine';
    assert.deepEqual(findHits({ filename: 'src/a.rs', status: 'modified', patch }), []);
  });

  it('reports the line number in the new file', () => {
    const patch = '@@ -10,3 +20,4 @@\n a\n-b\n+c\n d\n+schtasks /Create';
    assert.deepEqual(addedLines(patch), [{ line: 21, text: 'c' }, { line: 23, text: 'schtasks /Create' }]);
    assert.equal(findHits({ filename: 's.rs', status: 'modified', patch })[0].line, 23);
  });
});

describe('marker and ADR status', () => {
  it('finds the marker in any comment style', () => {
    for (const text of ['// persistence-allowed: docs/adr/0010-x.md', '; persistence-allowed: docs/adr/0010-x.md', '<!-- persistence-allowed: docs/adr/0010-x.md -->']) {
      assert.equal(markerOf(text), 'docs/adr/0010-x.md', text);
    }
    assert.equal(markerOf('persistence-allowed: yes'), null);
  });
  it('reads the Status word', () => {
    assert.equal(adrStatus('# ADR\n\n**Status:** Accepted\n'), 'Accepted');
    assert.equal(adrStatus('Status: Proposed'), 'Proposed');
    assert.equal(adrStatus('# no status'), null);
  });
});

function harness({ files = [], contents = {}, filesError } = {}) {
  const calls = { failed: [], errors: [], warnings: [], summary: '', reads: [] };
  const summary = {
    addHeading: () => summary,
    addRaw(text) {
      calls.summary += text;
      return summary;
    },
    write: async () => {},
  };
  return {
    calls,
    github: {
      paginate: async () => {
        if (filesError) throw filesError;
        return files;
      },
      rest: {
        pulls: {
          get: async () => ({
            data: { base: { ref: 'release/next' }, head: { sha: 'abc', repo: { name: 'fork', owner: { login: 'f' } } } },
          }),
          listFiles: () => {},
        },
        repos: {
          getContent: async ({ owner, repo, ref, path }) => {
            const key = `${owner}/${repo}@${ref}:${path}`;
            calls.reads.push(key);
            const text = contents[key] ?? contents[path];
            if (text === undefined) throw Object.assign(new Error('Not Found'), { status: 404 });
            return { data: { content: Buffer.from(text).toString('base64') } };
          },
        },
      },
    },
    context: { repo: { owner: 'o', repo: 'r' }, payload: { pull_request: { number: 5 } } },
    core: {
      setFailed: (m) => calls.failed.push(m),
      error: (m, props) => calls.errors.push({ m, props }),
      warning: (m) => calls.warnings.push(m),
      notice: () => {},
      summary,
    },
  };
}

describe('run', () => {
  const task = file('src/service/windows.rs', ['let x = 1;', 'run("schtasks", &["/Create"]);']);

  it('passes without persistence', async () => {
    const h = harness({ files: [file('src/a.rs', ['let x = 1;'])] });
    await run(h);
    assert.deepEqual(h.calls.failed, []);
    assert.match(h.calls.summary, /No background persistence added/);
  });

  it('fails and names file, line, pattern and the rule', async () => {
    const h = harness({ files: [task], contents: { 'src/service/windows.rs': 'no marker' } });
    await run(h);
    assert.equal(h.calls.failed.length, 1);
    assert.match(h.calls.failed[0], /src\/service\/windows\.rs:2: Windows scheduled task \(schtasks\) \(`schtasks`\)/);
    assert.deepEqual(h.calls.errors[0].props, { title: 'Background persistence', file: 'src/service/windows.rs', startLine: 2 });
    assert.match(h.calls.errors[0].m, /never install background persistence/);
  });

  const marked = { 'f/fork@abc:src/service/windows.rs': '// persistence-allowed: docs/adr/0010-task.md' };

  it('passes a file (read from the head) whose marker names an ADR accepted on the base branch', async () => {
    const h = harness({ files: [task], contents: { ...marked, 'o/r@release/next:docs/adr/0010-task.md': 'Status: Accepted' } });
    await run(h);
    assert.deepEqual(h.calls.failed, []);
    assert.match(h.calls.summary, /Allowed by an accepted ADR/);
  });

  it('fails when the accepted ADR exists only on the head of the PR', async () => {
    const h = harness({ files: [task], contents: { ...marked, 'f/fork@abc:docs/adr/0010-task.md': 'Status: Accepted' } });
    await run(h);
    assert.match(h.calls.failed[0], /is missing on release\/next, not Accepted/);
  });

  it('fails with a marker whose ADR on the base is not accepted', async () => {
    const h = harness({ files: [task], contents: { ...marked, 'o/r@release/next:docs/adr/0010-task.md': 'Status: Proposed' } });
    await run(h);
    assert.match(h.calls.failed[0], /is Proposed, not Accepted/);
  });

  it('warns about files without a diff from the API', async () => {
    const h = harness({ files: [{ filename: 'big.lock', status: 'modified', changes: 9000 }] });
    await run(h);
    assert.deepEqual(h.calls.failed, []);
    assert.equal(h.calls.warnings.length, 1);
  });

  it('fails when the changed files cannot be read', async () => {
    const h = harness({ filesError: Object.assign(new Error('x'), { status: 500 }) });
    await run(h);
    assert.match(h.calls.failed[0], /500/);
  });
});
