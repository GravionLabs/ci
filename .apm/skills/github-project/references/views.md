# Standard views

Views are matched by name. `Set-ProjectStandard.ps1` creates missing ones via REST `POST /users/<owner>/projectsV2/<n>/views` (`/orgs/<org>/...` for organizations) and never touches other views. Sorting cannot be set through the API (`sort_by` on Closed returns HTTP 400), so it is a manual step.

| View | Layout | Filter | Group | Fields | Why |
|:--|:--|:--|:--|:--|:--|
| Hierarchy | table | `is:open` | none (enable "Show hierarchy" in the UI) | Title, Level, Status, Sub-issues progress, Linked pull requests, Labels | Epic → Feature → PBI → Task tree of everything open. |
| Board | board | `-label:epic,feature -status:Done` | columns: Status | Title, Level, Linked pull requests, Sub-issues progress, Parent issue | Day-to-day work board; containers (Epic, Feature) hidden. |
| Release next | table | `status:"In release"` | rows: Milestone | Title, Parent issue, Linked pull requests, Sub-issues progress | What the next release ships: the content of `release/next`. |
| Backlog | table | `is:open -status:"In release" -label:epic,feature` | rows: Parent issue | Title, Level, Status, Labels, Sub-issues progress | Open work not yet merged, grouped by its PBI or Feature. |
| Recently closed | table | `is:closed` | none (sort by Closed descending in the UI) | Title, Level, Parent issue, Linked pull requests | Audit trail of what was done lately. |

## Needs views

Always created. They filter on the single-select field `Needs` (Planning, Decision, Review, Blocked, Ready, In progress, Release review).

| View | Layout | Filter | Group | Why |
|:--|:--|:--|:--|:--|
| Needs me | board | `is:open needs:Planning,Decision,Review,"Release review"` | columns: Needs | Everything that waits for the owner. |
| Ready for loop | table | `is:open needs:Ready -level:Epic,Feature,Task` | rows: Parent issue | PBIs and Bugs the loop may take. |
| Blocked | table | `is:open needs:Blocked` | none | Blocked items. |

A Release next view created before the Milestone grouping stays grouped by Level; set Group by Milestone by hand (manual step).

## Sprint views (opt-in `-Sprints`)

Not part of the five, so `-RemoveDefaultViews` ignores them. Field `Sprint` is an iteration field named by ISO week (`2026-W43`).

| View | Layout | Filter | Group | Why |
|:--|:--|:--|:--|:--|
| Sprint | board | `sprint:@current -level:Epic,Feature,Task` | columns: Status, rows: Repository | The week at a glance over all repositories: Todo, In release, Done. |
| Sprint next | board | `sprint:@next -level:Epic,Feature,Task` | columns: Status, rows: Repository | The coming week; assign PBIs to it with `Set-Sprint.ps1`. |

`-RemoveDefaultViews` deletes `View <n>` and `Probe` through GraphQL `deleteProjectV2View`, only when all five views above exist. It also deletes the old view `Sprint planning` (replaced by `Sprint next`), only when `Needs me`, `Ready for loop` and `Sprint next` exist or are planned; without the switch `Sprint planning` stays.

## Why `In release` mirrors `merged`

`Closes #n` fires only on the default branch, so issues merged into `release/next` stay open and carry the label `merged` (`github-release`, `references/merged-label.md`). The project needs a status for that state, otherwise they sit in `Todo`/`In progress` until the release lands.

- The label stays the source of truth: skills and CI (`mark-merged-issues`, `close-release-issues`) read and write the label.
- CI sets the Status `In release` itself (the reusable workflow `GravionLabs/ci/.github/workflows/release-branch.yml`, job `mark-merged-issues` with input `project-status`; token `PROJECT_TOKEN` or `GH_PAT`, a classic PAT with scope `project`, fine-grained tokens cannot access user-owned projects, see the GravionLabs/ci README; without it only the label is set). `github-project sync` is the repair path and mirrors the label into the Status; the reverse (`In release` without the label) goes back to `Todo`.
- On release, `close-release-issues` closes the issue and removes the label; the built-in workflow "Item closed" then sets `Done`.
