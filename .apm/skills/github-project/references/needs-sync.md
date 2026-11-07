# Needs sync

`Set-ProjectStandard.ps1 -Sync` calls `Sync-ProjectNeeds.ps1 -Owner <o> -Number <n>` after its own plan, so `sync` sets `Needs` of all open items.

```powershell
pwsh scripts/Sync-ProjectNeeds.ps1 [-Owner <login> -Number <n>] [-Repo owner/repo] [-Issue 12,13] [-IncludeParents] [-IncludeDependents] [-DryRun] [-Json]
```

`-IncludeDependents` (with `-Issue`) also syncs every open issue the selected issues block, so a blocker that closes or merges releases its dependents; without `-Issue` it changes nothing.

Project lookup without `-Owner`/`-Number`: `.agents/project.json` (`{"owner": "...", "number": 17}`) at the repository root, else `project-url:` in `.github/workflows/add-to-project.yml`, else in the first other `.github/workflows/*.yml|yaml` (name order) that has one, e.g. `issue-events.yml`. None found: `Needs sync skipped: no project configured`, exit 0.

Rule order, first match wins: closed (clear), label `needs-decision` (Decision), label `needs-review` (Review), blocked-by link to an open, unmerged blocker (Blocked; a closed blocker, label `merged` or Status `In release` counts as resolved), label `merged` or Status `In release` (Release review), open PR for the issue or Status `In Progress` (In progress), Epic without Feature / Feature without PBI / PBI without Task and without label `planned` (Planning), else Ready (Epics and Features: cleared).

## Status reset and scope report

The sync also resets stale Status values (project with a Status field): an open issue with Status `In Progress`, no open pull request whose head ref matches `(^|/)<nr>-` (or linked to the issue) and without the label `merged` goes back to `Todo`; a closed issue with Status `In Progress` goes to `Done`. An issue with such a pull request keeps `In Progress`. `-DryRun` lists the resets as `#<nr>: Status In Progress -> Todo|Done`; Needs is computed from the new Status. Cause (analysis of #169): `deliver` sets `In Progress` via `-SetStatus` and the built-in workflows may not move closed issues to `Done` (issues closed by `close-release-issues` with the `GITHUB_TOKEN`), so closed issues kept `In Progress`.

The run also prints `Without Level: <repo>: <n> open` for the open issues in scope without the project field Level (JSON key `noLevel`) and, when the whole project is in scope (no `-Repo`/`-Issue`), warns about repositories of the owner with open issues that have no item in the project, probably not linked (JSON key `unlinked`). Both are reports: exit code stays 0.

## Field Current

`Sync-ProjectNeeds.ps1` also keeps the single-select field `Current` (option `Yes`, created by `Set-ProjectStandard.ps1`): `Yes` on every item (issues open and closed, any level) whose milestone is the current milestone of its repository, cleared on every other item that has it. Only changed items are written; a project without the field skips this step. `-DryRun` lists the changes (`#n: Current (none) -> Yes`). The events `milestoned` and `demilestoned` of the caller update a single item without waiting for the nightly run.

The current milestone mirrors `github-milestone current` (`Get-Milestones.ps1` in GravionLabs/skills): the lowest open `M<n>[.<m>]` by numeric parts (M2 before M10, M3.1 after M3, topic ignored); legacy: an open `x.y.z` title above the latest tag `v<x.y.z>` comes first; open milestones at or below the latest tag are stale and never current. No current milestone: no item of that repository is marked. Milestones are read once per repository (`GET repos/<o>/<r>/milestones?state=open`, plus `tags` only when a legacy `x.y.z` is open), the item's milestone comes from the project item itself, so the sync adds no GraphQL call.

REST only: the script makes no GraphQL call and so uses no GraphQL budget. It reads `GET /users|orgs/<owner>/projectsV2/<n>/fields` and `/items?fields[]=<id>&q=repo:<owner/repo>` (Status, Level, Needs, Parent issue, Linked pull requests; paginated with `gh api --paginate --slurp`), then, for open items in scope only, what the summaries announce: `issues/<n>/sub_issues`, `dependencies/blocked_by` (open blockers only; `dependencies/blocking` with `-IncludeDependents`), `issues/<n>` (issue type of a legacy issue without Level and title prefix) and `pulls?state=open` per repository. `-Repo` without `-Issue` reads only the items of that repository; `-Issue` reads the repositories of the listed issues (plus parents and dependents), so `mode: full` means the calling repository. Sub-issue levels come from the sub-issue's type / title prefix or the Level of items already read; a blocker is judged by its own labels and the Status of its project item (the blocker's repository is read only when needed). A project without the field `Parent issue` or `Linked pull requests` gets no parents / linked-PR signal. Writes are `PATCH .../projectsV2/<n>/items/<id>`.
