// Pure rules of the persistence job: background persistence mechanisms in added lines, the ADR marker.
//
// GravionLabs apps never install background persistence (scheduled tasks, autostart, services, launch agents,
// systemd timers, cron). A scheduled task of tamias got a machine flagged by Microsoft Defender (ci#231).

/** Mechanisms found in an added line of any counted file. */
export const LINE_RULES = [
  { id: 'scheduled-task', label: 'Windows scheduled task (schtasks)', pattern: /\bschtasks(\.exe)?\b/i },
  { id: 'scheduled-task', label: 'Windows scheduled task (PowerShell)', pattern: /\b(Register|New|Set)-ScheduledTask\w*/i },
  { id: 'scheduled-task', label: 'Windows scheduled task (COM)', pattern: /\bITaskService\b|\bSchedule\.Service\b/ },
  { id: 'scheduled-task', label: 'Windows scheduled task (task XML)', pattern: /schemas\.microsoft\.com\/windows\/2004\/02\/mit\/task/i },
  { id: 'run-key', label: 'Windows Run/RunOnce registry key', pattern: /CurrentVersion[\\/]+Run(Once)?\b/i },
  { id: 'autostart', label: 'autostart library', pattern: /tauri[-_]plugin[-_]autostart|plugin-autostart|\bauto[-_]launch\b/i },
  { id: 'autostart', label: 'login item (Electron/macOS)', pattern: /\bsetLoginItemSettings\b|\bSMAppService\b|\bSMLoginItemSetEnabled\b/ },
  { id: 'service', label: 'Windows service', pattern: /\bNew-Service\b|\bsc(\.exe)?\s+create\b|\bCreateService[AW]?\s*\(/i },
  { id: 'launch-agent', label: 'macOS LaunchAgent/LaunchDaemon', pattern: /\bLaunch(Agents|Daemons)\b|\blaunchctl\s+(load|bootstrap|enable|submit)\b/i },
  { id: 'systemd-timer', label: 'systemd user unit or timer', pattern: /\bsystemctl\s+--user\s+(enable|start|link)\b|^\s*(OnCalendar|OnUnitActiveSec|OnBootSec)\s*=/i },
  { id: 'cron', label: 'cron entry', pattern: /\bcrontab\b/i },
];

/** Mechanisms found in an added line of an installer script (NSIS, WiX). */
export const INSTALLER_RULES = [
  { id: 'installer-script-host', label: 'script host started from the installer', pattern: /\b(powershell|pwsh)(\.exe)?\b|\bnsExec::|\bExecWait\b.*\b(cmd|wscript|cscript|mshta)(\.exe)?\b/i },
];

/** File names that are a persistence mechanism on their own. */
export const NAME_RULES = [
  { id: 'systemd-timer', label: 'systemd timer unit', pattern: /\.timer$/i },
  { id: 'launch-agent', label: 'macOS LaunchAgent/LaunchDaemon', pattern: /(^|\/)Launch(Agents|Daemons)\// },
];

/** A line `persistence-allowed: <path of an accepted ADR>` anywhere in the file (any comment style). */
export const MARKER = /persistence-allowed:\s*([^\s*'"`<>]+\.md)\b/i;

/** Markdown documents may describe the mechanisms (e.g. how to remove a task); they are not scanned. */
export function isIgnored(name) {
  return /\.(md|mdx)$/i.test(name);
}

export function isInstallerScript(name) {
  return /\.(nsh|nsi|wxs|wxi)$/i.test(name);
}

/** Added lines of a unified diff `patch` with their line number in the new file. */
export function addedLines(patch) {
  const lines = [];
  let next = 0;
  for (const line of (patch ?? '').split('\n')) {
    const hunk = /^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(line);
    if (hunk) {
      next = Number(hunk[1]);
      continue;
    }
    if (line.startsWith('+') && !line.startsWith('+++')) lines.push({ line: next++, text: line.slice(1) });
    else if (line.startsWith(' ')) next++;
    // '-' lines and "\ No newline at end of file" do not advance the new file
  }
  return lines;
}

/** Hits of one file: `{ file, line, id, label, match }`; `line` is null for a file name rule. */
export function findHits(file) {
  const name = file.filename;
  if (isIgnored(name) || file.status === 'removed') return [];
  const hits = [];
  if (file.status === 'added' || file.status === 'renamed' || file.status === 'copied') {
    for (const rule of NAME_RULES) {
      if (rule.pattern.test(name)) hits.push({ file: name, line: null, id: rule.id, label: rule.label, match: name });
    }
  }
  const rules = isInstallerScript(name) ? [...LINE_RULES, ...INSTALLER_RULES] : LINE_RULES;
  for (const { line, text } of addedLines(file.patch)) {
    for (const rule of rules) {
      const match = rule.pattern.exec(text);
      if (match) hits.push({ file: name, line, id: rule.id, label: rule.label, match: match[0].trim() });
    }
  }
  return hits;
}

/** The ADR path of the marker in `text`, or null. */
export function markerOf(text) {
  return MARKER.exec(text ?? '')?.[1] ?? null;
}

/** The Status word of an ADR (`Status: Accepted`, `**Status:** Accepted`, `- Status: Accepted`), or null. */
export function adrStatus(content) {
  return /^[\s>*_-]*Status\s*:?\**\s*:?\s*\**\s*([A-Za-z]+)/im.exec(content ?? '')?.[1] ?? null;
}

/** One line of the report for a hit. */
export function describe(hit) {
  const where = hit.line ? `${hit.file}:${hit.line}` : hit.file;
  return `${where}: ${hit.label} (\`${hit.match}\`)`;
}
