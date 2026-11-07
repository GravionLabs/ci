---
name: github-project
description: 'Bring a GitHub Project (v2) to the standard (Level, Needs, Current, nine views), sync labels, or create one from the template. Use for "/github-project apply|sync|new".'
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
| `apply <project-nr>` | Fields `Level`, `Needs` and `Current`; the five standard views plus `Current milestone`, `Needs me`, `Ready for loop`, `Blocked` (nine views). |
| `sync <project-nr>` | `apply` plus item sync (Level) and the labels `planned`, `needs-review` in the repositories linked to the project. |
| `new <repo>` | Copy the template project, link it to the repo, run `sync`. |

## apply / sync

```powershell
pwsh scripts/Set-ProjectStandard.ps1 -Owner <login> -Number <n> -DryRun          # apply: show the plan first
pwsh scripts/Set-ProjectStandard.ps1 -Owner <login> -Number <n> -Sync            # sync: also items
pwsh scripts/Set-ProjectStandard.ps1 -Owner <login> -Number <n> -Sync -RemoveDefaultViews
pwsh scripts/Set-ProjectStandard.ps1 -Owner <login> -Number <n> -RemoveInReleaseStatus -DryRun   # old standard: drop In release
```

Always run `-DryRun` first, show the actions to the user, then run without it. `-Json` prints `{actions, manualSteps}`; `-StateFile <json>` plans offline and never calls `gh`.

- Status: left as it is. Issues close when their pull request is merged into a release branch (`release-branch.yml` of GravionLabs/ci, `versioning/close-merged-issues`), so there is no Status between `In Progress` and `Done`; the built-in workflow "Item closed" sets `Done`.
- `-RemoveInReleaseStatus` (old standard): moves the items with Status `In release` to `Done` (closed) or `Todo` (open), then deletes the option; the other options keep their ids. It reads every item; an incomplete item walk fails the run. `-DryRun` lists the moves and the removal.
- Level: created (Epic, Feature, PBI, Task, Bug) only when missing.
- Sync, open and closed issues: Level from labels `epic|feature|pbi|task|bug` (first match in that order), fallback title prefix `[Epic]`, `[Feature]`, `[PBI]`, `[Task]`, only where Level is empty. The Status is never synced.
- `-Sync` also runs `scripts/Sync-ProjectNeeds.ps1` (forwards `-DryRun`; offline `-StateFile` only lists the action `syncNeeds`). A failing Needs sync is one warning, the run still exits 0. Details: `references/needs-sync.md`.
- Status reset and scope report: `Sync-ProjectNeeds.ps1` resets `In Progress` to `Todo` (open issue without an open PR head matching `(^|/)<nr>-`) or `Done` (closed issue), reports open issues without Level per repository and warns about repositories not linked to the project (`references/needs-sync.md`).
- Current: single-select with the option `Yes` (GREEN), created when missing; `Sync-ProjectNeeds.ps1` sets it on the items of the current milestone of each repository (view filter `current:Yes`).
- Needs: single-select (Planning, Decision, Review, Blocked, Ready, In progress, Release review), created when missing; an existing field keeps its option ids and gets missing options appended.
- Standard views: the five standard views (Hierarchy, Board, Backlog, Recently closed, Milestones), `Current milestone`, and the Needs views. Views are matched by name; missing ones are created, others are never touched (`references/views.md`).
- `-RemoveDefaultViews` deletes `View <n>` and `Probe` views, only when all standard views exist, and `Release next` (left the standard) under the same condition, and the views `Sprint`, `Sprint next` and `Sprint planning` of the removed sprint mode whenever they exist.
- `-RemoveSprintField` deletes the iteration field `Sprint` of the removed sprint mode (GraphQL `deleteProjectV2Field`, listed in `-DryRun` / `-Json`); without the switch the field stays.
- A second run reports `No changes.`

Finish by telling the user the printed manual UI steps (no API): "Show hierarchy" in Hierarchy, sort Recently closed by Closed descending, sort Milestones by Milestone ascending, enable the workflow "Item closed → Done" and "Auto-archive items" with `is:closed updated:<@today-14d`.

Other repositories of the project copy `templates/issue-events.yml` and `templates/project-needs.yml` (callers of the reusable `issues.yml` of GravionLabs/ci; replace `<owner>` and `<n>` in `project-url`) to `.github/workflows/` to keep Needs current; tokens: GravionLabs/ci README.

## new

1. Copy the template (`references/project-template.md`): GraphQL `copyProjectV2` with `includeDraftIssues: false`.
2. Link it with `linkProjectV2ToRepository`.
3. Run `sync` on the new project number with `-RemoveDefaultViews`.

## Rules

- Never run the script without `-DryRun` first on a project the user has not seen.
- Never run `-RemoveInReleaseStatus` without `-DryRun` first and the owner's approval.
