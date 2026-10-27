# Project standard

One reproducible GitHub Project (v2) layout for all GravionLabs repositories. `pwsh scripts/Set-ProjectStandard.ps1` of the [github-project skill](../.apm/skills/github-project/SKILL.md) applies it (`/github-project apply|sync <nr>`); always run `-DryRun` first. A second run reports `No changes.`

## Status and fields

| Field | Values | Meaning |
|:--|:--|:--|
| Status | `Todo`, `In progress`, `In release`, `Done` | `In release` (BLUE) sits before `Done` and mirrors the label `merged`: merged into `release/next`, ships with the next release. |
| Level | Epic, Feature, PBI, Task, Bug | Hierarchy level. `-Sync` fills an empty Level from the labels, fallback the title prefix. |
| Needs | see below | What the item waits for. Created when missing; an existing field keeps its options and ids and only gets missing options appended. |
| Sprint | ISO weeks `YYYY-Www` | Weekly iteration field, only with `-Sprints` (12 weeks from the current one). |

### Needs

| Option | Colour | Means for the owner and the loop |
|:--|:--|:--|
| Planning | BLUE | The item has to be planned (`issue-planning`) before work starts. Owner action. |
| Decision | ORANGE | An owner decision is open (the planner marks such items with the label `needs-decision`, which `issue-planning` creates on publish; this script does not sync it). Owner action. |
| Review | YELLOW | A pull request or result waits for an owner review (label `needs-review`). Owner action. |
| Blocked | RED | Cannot proceed; the loop skips it. |
| Ready | GREEN | Planned and unblocked: the loop may pick it up. |
| In progress | PURPLE | A runner or person is working on it. |
| Release review | PINK | The release content waits for an owner review. Owner action. |

`-Sync` also runs `Sync-ProjectNeeds.ps1`, which sets Needs of every open item. Rule order, first match wins:

1. Closed: Needs is cleared.
2. Label `needs-decision`: Decision.
3. Label `needs-review`: Review.
4. Open native blocked-by link: Blocked.
5. Label `merged` or Status `In release`: Release review.
6. Open pull request for the issue or Status `In Progress`: In progress.
7. Epic without Feature, Feature without PBI, PBI without Task and without label `planned`: Planning.
8. Otherwise Ready (Epics and Features: cleared).

The project comes from `-Owner`/`-Number`, else `.agents/project.json` (`{"owner": "...", "number": 17}`), else `project-url:` in `.github/workflows/add-to-project.yml`, else in the first other `.github/workflows/*.yml|yaml` (name order) that has one, e.g. `issue-events.yml`. A failing Needs sync prints one warning; the run still exits 0.

`issue-events.yml` (reusable `issues.yml` of GravionLabs/ci) adds new issues to the project and syncs Needs on label, close and pull request events and `release-branch.yml` (reusable `release-branch.yml`) syncs the issues it sets to `In release`; `project-needs.yml` is the hourly full sync (reusable `issues.yml`, mode `full`).

### Needs sync in other repositories

Other repositories of the project keep Needs current with the two callers of the reusable `issues.yml` of GravionLabs/ci in `.apm/skills/github-project/templates/`:

1. Copy `issue-events.yml` (label, close and pull request events, `needs: true`) and `project-needs.yml` (hourly full sync, `mode: full`) to `.github/workflows/`.
2. Replace `<owner>` and `<n>` in `project-url` (`https://github.com/users/<owner>/projects/<n>`).
3. Store a classic PAT with scopes `repo`, `workflow` and `project` as the secret `GH_PAT` (optional `PROJECT_TOKEN` with scope `project`); a fine-grained token or the `GITHUB_TOKEN` cannot write a user-owned project. Inputs and tokens: GravionLabs/ci README (`issues.yml`).

## Views

Views are matched by name. Missing ones are created, existing ones are never touched. Sorting cannot be set through the API.

| View | Layout | Filter | Group | Purpose |
|:--|:--|:--|:--|:--|
| Hierarchy | table | `is:open` | none | Epic to Task tree of everything open. |
| Board | board | `-label:epic,feature -status:Done` | columns: Status | Day-to-day board. |
| Release next | table | `status:"In release"` | rows: Milestone | Content of `release/next`, per milestone. |
| Backlog | table | `is:open -status:"In release" -label:epic,feature` | rows: Parent issue | Open work not yet merged. |
| Recently closed | table | `is:closed` | none | Audit trail. |
| Needs me | board | `is:open needs:Planning,Decision,Review,"Release review"` | columns: Needs | Everything that waits for the owner. |
| Ready for loop | table | `is:open needs:Ready -level:Epic,Feature,Task` | rows: Parent issue | PBIs and Bugs the loop may take. |
| Blocked | table | `is:open needs:Blocked` | none | Blocked items. |
| Sprint | board | `sprint:@current -level:Epic,Feature,Task` | columns: Status, rows: Repository | `-Sprints` only: the current week. |
| Sprint next | board | `sprint:@next -level:Epic,Feature,Task` | columns: Status, rows: Repository | `-Sprints` only: the next week. |

`-Sprints` adds the field `Sprint` and the two sprint views. Pick PBIs for `Set-Sprint.ps1` from `Backlog` or `Ready for loop`. The earlier view `Sprint planning` is replaced by `Sprint next`. With `-RemoveDefaultViews` the script deletes `View <n>` and `Probe` (only when all five standard views exist) and `Sprint planning` (only when `Needs me`, `Ready for loop` and `Sprint next` exist or are created in the same run). Without that switch `Sprint planning` stays.

### Manual steps

The script prints them; the API cannot do them:

- Hierarchy: enable "Show hierarchy".
- Recently closed: sort by Closed, descending.
- Release next, when it was created before the Milestone grouping: set Group by Milestone (existing views are not updated).
- Project Workflows: enable "Item closed" to Status `Done`.

## Labels

| Label | Colour | Description | Set by |
|:--|:--|:--|:--|
| `planned` | `0E8A16` | Task breakdown published or single-task plan approved | `issue-planning` (`references/publish.md` § 5) on the PBI when Tasks are published or a single-task plan is approved. Nothing removes it. |
| `needs-review` | `FBCA04` | Waiting for an owner review | Set by hand or by a skill when an item waits for review. |
| `merged` | n/a | Merged into a release branch | CI (`mark-merged-issues`); removed by `close-release-issues` on release. |

With `-Sync` the script ensures `planned` and `needs-review` (colour and description as above) in every repository linked to the project via `gh label create --force`. `merged` is managed by CI and the release skill, not by this script.
