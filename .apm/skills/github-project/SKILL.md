---
name: github-project
description: 'Bring a GitHub Project (v2) to the standard (In release, Level, Needs, eight views), sync labels, or create one from the template. Use for "/github-project apply|sync|new".'
disable-model-invocation: true
metadata:
  opencode/autoinvoke: 'false'
---

One reproducible project standard for all GravionLabs repos. Paths are relative to this skill's directory.

## Prerequisite

`gh` with scope `project`: `gh auth refresh -s project`. Owner is a user or an organization.

## Modes

| Invocation | Does |
|:--|:--|
| `apply <project-nr>` | Status gets `In release` before `Done`; fields `Level` and `Needs`; the five standard views plus `Needs me`, `Ready for loop`, `Blocked`. |
| `sync <project-nr>` | `apply` plus item sync (Level, `merged` ⇄ `In release`) and the labels `planned`, `needs-review` in the repositories linked to the project. |
| `new <repo>` | Copy the template project, link it to the repo, run `sync`. |
| `sprints <project-nr>` | `apply` plus the weekly iteration field `Sprint` and the views `Sprint` and `Sprint next` (opt-in, `-Sprints`). |
| `sprint <project-nr> <owner/repo#n>...` | Put PBIs of any repository into a sprint and check the limits. |

## apply / sync

```powershell
pwsh scripts/Set-ProjectStandard.ps1 -Owner <login> -Number <n> -DryRun          # apply: show the plan first
pwsh scripts/Set-ProjectStandard.ps1 -Owner <login> -Number <n> -Sync            # sync: also items
pwsh scripts/Set-ProjectStandard.ps1 -Owner <login> -Number <n> -Sync -RemoveDefaultViews
```

Always run `-DryRun` first, show the actions to the user, then run without it. `-Json` prints `{actions, manualSteps}`; `-StateFile <json>` plans offline and never calls `gh`.

- Status: option `In release` (BLUE) goes directly before `Done`; every existing option keeps its id, so item values survive.
- Level: created (Epic, Feature, PBI, Task, Bug) only when missing.
- Sync, open issues only: Level from labels `epic|feature|pbi|task|bug` (first match in that order), fallback title prefix `[Epic]`, `[Feature]`, `[PBI]`, `[Task]`, only where Level is empty. Label `merged` → `In release`; `In release` without `merged` → `Todo`. Closed items are untouched.
- `-Sync` also runs `scripts/Sync-ProjectNeeds.ps1` (forwards `-DryRun`; offline `-StateFile` only lists the action `syncNeeds`). A failing Needs sync is one warning, the run still exits 0. Details: `references/needs-sync.md`.
- Needs: single-select (Planning, Decision, Review, Blocked, Ready, In progress, Release review), created when missing; an existing field keeps its option ids and gets missing options appended.
- Views are matched by name; missing ones are created, others are never touched (`references/views.md`).
- `-RemoveDefaultViews` deletes `View <n>` and `Probe` views, only when all five standard views exist; `Sprint planning` (old) only when `Needs me`, `Ready for loop` and `Sprint next` exist or are planned.
- A second run reports `No changes.`

Finish by telling the user the printed manual UI steps (no API): "Show hierarchy" in Hierarchy, sort Recently closed by Closed descending, enable the workflow "Item closed → Done".

Other repositories of the project copy `templates/issue-events.yml` and `templates/project-needs.yml` (callers of the reusable `issues.yml` of GravionLabs/ci; replace `<owner>` and `<n>` in `project-url`) to `.github/workflows/` to keep Needs current; tokens: GravionLabs/ci README.

## sprints

One project for all repositories, one weekly sprint for all of them. Titles are ISO weeks `YYYY-Www` (`2026-W43`; the ISO year, so 2027-01-01 is `2026-W53`). `-Sprints` creates 12 iterations from this week (Monday start, 7 days) and the views `Sprint` (board, `sprint:@current`, no Epic/Feature/Task, rows per repository) and `Sprint next` (same for `sprint:@next`). Pick PBIs for `Set-Sprint.ps1` from `Backlog` or `Ready for loop`. An existing field or view is never touched; more iterations are added in the project settings.

```powershell
pwsh scripts/Set-ProjectStandard.ps1 -Owner <login> -Number <n> -Sprints -DryRun
pwsh scripts/Set-Sprint.ps1 -Owner <login> -Number <n> -Issue 'org/a#12,org/b#7' [-Sprint 2026-W44] [-DryRun] [-Force]
```

`Set-Sprint.ps1` is all or nothing (exit 1, nothing assigned) and counts open PBIs and Bugs only:

| Limit | Default | Parameter |
|:--|:--|:--|
| per sprint, all repositories | 30 | `-MaxPerSprint` |
| per sprint and repository | 10 | `-MaxPerRepo` |
| `In release` per repository, any sprint | 10 | `-MaxInRelease` (full: cut the release first, `github-release`) |

The issues must already be items of the project with Level PBI or Bug (`sync` sets it). `-Force` assigns despite a violation and still reports it.

Dependency order: a PBI with an open native blocked-by link (the links `orchestrator next` reads) enters only when the blocker is already in this sprint or an earlier one, or is assigned in the same run (violation `Blocked`). A `Blocked by #n` line in the body alone is not seen: set the native link (`issue-planning` `references/publish.md` § 3).

## new

1. Copy the template (`references/project-template.md`): GraphQL `copyProjectV2` with `includeDraftIssues: false`.
2. Link it with `linkProjectV2ToRepository`.
3. Run `sync` on the new project number with `-RemoveDefaultViews`.

## Rules

- Never run the script without `-DryRun` first on a project the user has not seen.
- The label `merged` stays the source of truth; the project mirrors it.
