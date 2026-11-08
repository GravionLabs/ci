# Standard views

Views are matched by name. `Set-ProjectStandard.ps1` creates missing ones via REST `POST /users/<owner>/projectsV2/<n>/views` (`/orgs/<org>/...` for organizations) and never touches other views. Sorting cannot be set through the API (`sort_by` on Closed returns HTTP 400), so it is a manual step.

| View              | Layout | Filter                                             | Group                                                   | Fields                                                                  | Why                                                                                      |
| :---------------- | :----- | :------------------------------------------------- | :------------------------------------------------------ | :---------------------------------------------------------------------- | :--------------------------------------------------------------------------------------- |
| Hierarchy         | table  | `is:open`                                          | none (enable "Show hierarchy" in the UI)                | Title, Level, Status, Sub-issues progress, Linked pull requests, Labels | Epic → Feature → PBI → Task tree of everything open.                                     |
| Board             | board  | `-label:epic,feature -status:Done`                 | columns: Status                                         | Title, Level, Linked pull requests, Sub-issues progress, Parent issue   | Day-to-day work board; containers (Epic, Feature) hidden.                                |
| Backlog           | table  | `is:open -label:epic,feature`                      | rows: Parent issue                                      | Title, Level, Status, Labels, Sub-issues progress                       | Open work not yet merged, grouped by its PBI or Feature.                                 |
| Recently closed   | table  | `is:closed`                                        | none (sort by Closed descending in the UI)              | Title, Level, Parent issue, Linked pull requests                        | Audit trail of what was done lately.                                                     |
| Milestones        | table  | `has:milestone -level:Epic,Task` (open and closed) | rows: Milestone (sort by Milestone ascending in the UI) | Title, Level, Status, Repository, Linked pull requests                  | All items per milestone; closed items stay until the auto-archive workflow removes them. |
| Current milestone | board  | `current:Yes -level:Epic,Task`                     | columns: Status, rows: Repository                       | Title, Level, Milestone, Linked pull requests, Sub-issues progress      | Per repository how many items of its current milestone are Done versus all (x of y).     |

## Needs views

Always created. They filter on the single-select field `Needs` (Planning, Decision, Review, Blocked, Ready, In progress, Release review).

| View           | Layout | Filter                                                    | Group              | Why                                  |
| :------------- | :----- | :-------------------------------------------------------- | :----------------- | :----------------------------------- |
| Needs me       | board  | `is:open needs:Planning,Decision,Review,"Release review"` | columns: Needs     | Everything that waits for the owner. |
| Ready for loop | table  | `is:open needs:Ready -level:Epic,Feature,Task`            | rows: Parent issue | PBIs and Bugs the loop may take.     |
| Blocked        | table  | `is:open needs:Blocked`                                   | none               | Blocked items.                       |

`Release next` left the standard (its content is in `Needs me` as `Release review`); it is no longer created and `-RemoveDefaultViews` deletes it. Recommended workflow "Auto-archive items" with `is:closed updated:<@today-14d`: keeps the project small and the syncs fast.

## Removed sprint mode

The sprint mode no longer exists. `-RemoveDefaultViews` deletes `View <n>` and `Probe` through GraphQL `deleteProjectV2View`, only when all six views above exist, and `Release next` under the same condition, and the old views `Sprint`, `Sprint next` and `Sprint planning` whenever they exist. `-RemoveSprintField` deletes the iteration field `Sprint` (`deleteProjectV2Field`); without it the field stays.

## Closing at merge

Issues close when their pull request is merged into a release branch (`release-branch.yml` of GravionLabs/ci, `versioning/close-merged-issues`), so there is no Status between `In Progress` and `Done`; the built-in workflow "Item closed" sets `Done`. A project of the old standard drops its Status `In release` with `Set-ProjectStandard.ps1 -RemoveInReleaseStatus` (dry run first).
