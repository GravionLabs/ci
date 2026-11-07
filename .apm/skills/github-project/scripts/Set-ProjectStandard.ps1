#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
  Brings a GitHub Project (v2) to the GravionLabs standard: Status 'In release', fields Level, Needs and Current, eight views, optional item and label sync.
.DESCRIPTION
  1. Reads the state (fields with options, views, issue items) via 'gh api graphql', or from -StateFile (no gh call at all).
  2. A pure function (Get-ProjectPlan) computes the action list.
  3. Executes it unless -DryRun, then prints the manual UI steps that no API covers.
  Idempotent: a second run reports no changes. Needs 'gh' with scope 'project' (gh auth refresh -s project).
  The owner may be a user or an organization.
.PARAMETER Owner               User or organization login that owns the project.
.PARAMETER Number              Project number.
.PARAMETER Sync                Also run Sync-ProjectNeeds.ps1 (field Needs; offline only the action syncNeeds) and sync items: Level from labels/title, label 'merged' <-> status 'In release' (open issues only); ensure the labels 'planned' and 'needs-review' in the repositories linked to the project.
.PARAMETER RemoveSprintField   Delete the iteration field 'Sprint' of the removed sprint mode (GraphQL deleteProjectV2Field); without the switch the field stays.
.PARAMETER RemoveDefaultViews  Delete views named 'View <n>' or 'Probe', only when all five standard views exist afterwards; also the views 'Sprint', 'Sprint next' and 'Sprint planning' of the removed sprint mode, whenever they exist.
.PARAMETER DryRun              Print the actions, change nothing.
.PARAMETER StateFile           JSON state (projectId, ownerType, fields, views, items) instead of reading from GitHub.
.PARAMETER Json                Emit {dryRun, actions, needs, manualSteps} as JSON instead of text.
#>
[CmdletBinding()]
param(
  [string]$Owner,
  [int]$Number,
  [switch]$Sync,
  [switch]$RemoveDefaultViews,
  [switch]$RemoveSprintField,
  [switch]$DryRun,
  [string]$StateFile,
  [switch]$Json
)
# No Mandatory: a headless run must exit non-zero with a message instead of prompting.
$ErrorActionPreference = 'Stop'

$script:LevelOptions = @(
  @{ name = 'Epic'; color = 'PURPLE' }, @{ name = 'Feature'; color = 'GREEN' }, @{ name = 'PBI'; color = 'BLUE' },
  @{ name = 'Task'; color = 'GRAY' }, @{ name = 'Bug'; color = 'RED' })
$script:NeedsOptions = @(
  @{ name = 'Planning'; color = 'BLUE' }, @{ name = 'Decision'; color = 'ORANGE' }, @{ name = 'Review'; color = 'YELLOW' },
  @{ name = 'Blocked'; color = 'RED' }, @{ name = 'Ready'; color = 'GREEN' }, @{ name = 'In progress'; color = 'PURPLE' },
  @{ name = 'Release review'; color = 'PINK' })
# Field Current: marks the items of the current milestone of their repository (kept by Sync-ProjectNeeds.ps1).
$script:CurrentOptions = @(@{ name = 'Yes'; color = 'GREEN' })
# Labels ensured per linked repository under -Sync; colour/description of 'planned' equal issue-planning references/publish.md § 5.
$script:StandardLabels = @(
  @{ name = 'planned'; color = '0E8A16'; description = 'Task breakdown published or single-task plan approved' },
  @{ name = 'needs-review'; color = 'FBCA04'; description = 'Waiting for an owner review' })
$script:InReleaseDescription = 'Merged into a release branch, ships with the next release (label merged)'
$script:StandardViews = @(
  @{ name = 'Hierarchy'; layout = 'table'; filter = 'is:open'; groupBy = $null; verticalGroupBy = $null
     fields = @('Title', 'Level', 'Status', 'Sub-issues progress', 'Linked pull requests', 'Labels') },
  @{ name = 'Board'; layout = 'board'; filter = '-label:epic,feature -status:Done'; groupBy = $null; verticalGroupBy = 'Status'
     fields = @('Title', 'Level', 'Linked pull requests', 'Sub-issues progress', 'Parent issue') },
  @{ name = 'Release next'; layout = 'table'; filter = 'status:"In release"'; groupBy = 'Milestone'; verticalGroupBy = $null
     fields = @('Title', 'Parent issue', 'Linked pull requests', 'Sub-issues progress') },
  @{ name = 'Backlog'; layout = 'table'; filter = 'is:open -status:"In release" -label:epic,feature'; groupBy = 'Parent issue'; verticalGroupBy = $null
     fields = @('Title', 'Level', 'Status', 'Labels', 'Sub-issues progress') },
  @{ name = 'Recently closed'; layout = 'table'; filter = 'is:closed'; groupBy = $null; verticalGroupBy = $null
     fields = @('Title', 'Level', 'Parent issue', 'Linked pull requests') })
# Views on the field Needs, always created.
$script:NeedsViews = @(
  @{ name = 'Needs me'; layout = 'board'; filter = 'is:open needs:Planning,Decision,Review,"Release review"'; groupBy = $null; verticalGroupBy = 'Needs'
     fields = @('Title', 'Repository', 'Level', 'Milestone', 'Linked pull requests') },
  @{ name = 'Ready for loop'; layout = 'table'; filter = 'is:open needs:Ready -level:Epic,Feature,Task'; groupBy = 'Parent issue'; verticalGroupBy = $null
     fields = @('Title', 'Repository', 'Level', 'Milestone', 'Parent issue') },
  @{ name = 'Blocked'; layout = 'table'; filter = 'is:open needs:Blocked'; groupBy = $null; verticalGroupBy = $null
     fields = @('Title', 'Repository', 'Level', 'Parent issue', 'Labels') })
$script:ManualSteps = @(
  'Hierarchy view: enable "Show hierarchy" (no API).',
  'Recently closed view: sort by Closed, descending (the REST API rejects sort_by with HTTP 400).',
  'Release next view (created before Milestone grouping): set Group by Milestone (existing views are not updated).',
  'Project Workflows: enable "Item closed" -> Status Done.')

function Get-ProjectPlan {
  param($State, [bool]$Sync, [bool]$RemoveDefaultViews, [bool]$RemoveSprintField = $false)
  $actions = [System.Collections.Generic.List[object]]::new()
  $status = @($State.fields) | Where-Object { $_.name -eq 'Status' } | Select-Object -First 1
  if (-not $status) { throw "Project has no 'Status' field." }

  # 1. Status: 'In release' directly before 'Done'; all existing options are sent back with their ids.
  $statusNames = @($status.options | ForEach-Object { $_.name })
  if ($statusNames -notcontains 'In release') {
    $new = [ordered]@{ name = 'In release'; color = 'BLUE'; description = $script:InReleaseDescription }
    $opts = [System.Collections.Generic.List[object]]::new()
    foreach ($o in @($status.options)) {
      if ($o.name -eq 'Done' -and $new) { $opts.Add($new); $new = $null }
      $opts.Add([ordered]@{ id = $o.id; name = $o.name; color = $o.color; description = [string]$o.description })
    }
    if ($new) { $opts.Add($new) }
    $actions.Add([ordered]@{ type = 'UpdateStatusOptions'; field = 'Status'; options = @($opts) })
    $statusNames = @($opts | ForEach-Object { $_.name })
  }

  # 2. Level: created when missing, an existing field stays untouched.
  $hasLevel = [bool](@($State.fields) | Where-Object { $_.name -eq 'Level' })
  if (-not $hasLevel) {
    $actions.Add([ordered]@{ type = 'CreateField'; name = 'Level'
        options = @($script:LevelOptions | ForEach-Object { [ordered]@{ name = $_.name; color = $_.color; description = '' } }) })
  }

  # 2a. Needs: created when missing; an existing field keeps its options and ids and gets the missing ones appended.
  $needs = @($State.fields) | Where-Object { $_.name -eq 'Needs' } | Select-Object -First 1
  if (-not $needs) {
    $actions.Add([ordered]@{ type = 'CreateField'; name = 'Needs'
        options = @($script:NeedsOptions | ForEach-Object { [ordered]@{ name = $_.name; color = $_.color; description = '' } }) })
  } else {
    $have = @($needs.options | ForEach-Object { $_.name })
    $missing = @($script:NeedsOptions | Where-Object { $have -notcontains $_.name })
    if ($missing.Count -gt 0) {
      $opts = [System.Collections.Generic.List[object]]::new()
      foreach ($o in @($needs.options)) { $opts.Add([ordered]@{ id = $o.id; name = $o.name; color = $o.color; description = [string]$o.description }) }
      foreach ($m in $missing) { $opts.Add([ordered]@{ name = $m.name; color = $m.color; description = '' }) }
      $actions.Add([ordered]@{ type = 'UpdateFieldOptions'; field = 'Needs'; options = @($opts) })
    }
  }

  # 2a2. Current: created when missing; an existing field stays untouched (keeps its option ids).
  if (-not (@($State.fields) | Where-Object { $_.name -eq 'Current' })) {
    $actions.Add([ordered]@{ type = 'CreateField'; name = 'Current'
        options = @($script:CurrentOptions | ForEach-Object { [ordered]@{ name = $_.name; color = $_.color; description = '' } }) })
  }

  # 2b. Sprint field of the removed sprint mode: deleted only on request.
  if ($RemoveSprintField) {
    $sprintField = @($State.fields) | Where-Object { $_.name -eq 'Sprint' } | Select-Object -First 1
    if ($sprintField) { $actions.Add([ordered]@{ type = 'DeleteField'; name = 'Sprint'; id = $sprintField.id }) }
  }

  # 3. Sync: Level for every issue (Recently closed shows it), Status for open issues only
  if ($Sync) {
    $todo = if ($statusNames -contains 'Todo') { 'Todo' } else { $statusNames[0] }
    $levelNames = @{ epic = 'Epic'; feature = 'Feature'; pbi = 'PBI'; task = 'Task'; bug = 'Bug' }
    foreach ($item in @($State.items)) {
      $labels = @($item.labels | ForEach-Object { "$_".ToLowerInvariant() })
      if (-not $item.level) {
        $lvl = $null
        foreach ($k in 'epic', 'feature', 'pbi', 'task', 'bug') { if ($labels -contains $k) { $lvl = $levelNames[$k]; break } }
        if (-not $lvl -and "$($item.title)" -match '^\s*\[(Epic|Feature|PBI|Task)\]') { $lvl = $Matches[1] }
        if ($lvl) { $actions.Add([ordered]@{ type = 'SetItem'; item = $item.id; number = $item.number; field = 'Level'; option = $lvl }) }
      }
      if ($item.state -ne 'OPEN') { continue }
      if ($labels -contains 'merged') {
        if ($item.status -ne 'In release') { $actions.Add([ordered]@{ type = 'SetItem'; item = $item.id; number = $item.number; field = 'Status'; option = 'In release' }) }
      } elseif ($item.status -eq 'In release') {
        $actions.Add([ordered]@{ type = 'SetItem'; item = $item.id; number = $item.number; field = 'Status'; option = $todo })
      }
    }
  }

  # 3a. Labels: standard labels per linked repository; a state without 'repositories' yields none.
  if ($Sync) {
    foreach ($repo in @($State.repositories | Where-Object { $_ })) {
      foreach ($std in $script:StandardLabels) {
        $cur = @($repo.labels) | Where-Object { $_.name -eq $std.name } | Select-Object -First 1
        if (-not $cur -or "$($cur.color)".ToUpperInvariant() -ne $std.color -or "$($cur.description)" -ne $std.description) {
          $actions.Add([ordered]@{ type = 'EnsureLabel'; repo = $repo.nameWithOwner; name = $std.name; color = $std.color; description = $std.description })
        }
      }
    }
  }

  # 4. Views, matched by name; other views are never touched.
  $existing = @($State.views | ForEach-Object { $_.name })
  foreach ($v in @($script:StandardViews) + @($script:NeedsViews)) {
    if ($existing -notcontains $v.name) {
      $actions.Add([ordered]@{ type = 'CreateView'; name = $v.name; layout = $v.layout; filter = $v.filter
          visibleFields = $v.fields; groupBy = $v.groupBy; verticalGroupBy = $v.verticalGroupBy })
    }
  }

  # 5. Default views go only when all five standard views exist afterwards.
  if ($RemoveDefaultViews) {
    $after = @($existing) + @($actions | Where-Object { $_.type -eq 'CreateView' } | ForEach-Object { $_.name })
    $allStandard = -not ($script:StandardViews | Where-Object { $after -notcontains $_.name })
    if ($allStandard) {
      foreach ($v in @($State.views)) {
        if ($v.name -match '^View \d+$' -or $v.name -eq 'Probe') { $actions.Add([ordered]@{ type = 'DeleteView'; name = $v.name; id = $v.id }) }
      }
    }
    # Views of the removed sprint mode go whenever they exist.
    foreach ($v in @($State.views)) {
      if ($v.name -in 'Sprint', 'Sprint next', 'Sprint planning') { $actions.Add([ordered]@{ type = 'DeleteView'; name = $v.name; id = $v.id }) }
    }
  }
  , @($actions)
}

function Format-Action($a) {
  switch ($a.type) {
    'UpdateFieldOptions' { "$($a.field): options -> $(($a.options | ForEach-Object { $_.name }) -join ', ')" }
    'UpdateStatusOptions' { "Status: options -> $(($a.options | ForEach-Object { $_.name }) -join ', ')" }
    'CreateField' { "Create field $($a.name): $(($a.options | ForEach-Object { $_.name }) -join ', ')" }
    'SetItem' { "#$($a.number) $($a.field) -> $($a.option)" }
    'CreateView' { "Create view $($a.name) ($($a.layout), filter: $($a.filter))" }
    'EnsureLabel' { "Label $($a.repo): $($a.name) ($($a.color))" }
    'DeleteView' { "Delete view $($a.name)" }
    'DeleteField' { "Delete field $($a.name)" }
    'syncNeeds' { "Sync Needs: Sync-ProjectNeeds.ps1 -Owner $($a.owner) -Number $($a.number)" }
  }
}

function Invoke-Gh {
  param([string[]]$GhArgs, $Body)
  $out = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 20 -Compress | & gh @GhArgs --input - 2>&1 } else { & gh @GhArgs 2>&1 }
  if ($LASTEXITCODE -ne 0) { throw "gh $($GhArgs -join ' ') failed: $out" }
  ($out | Out-String) | ConvertFrom-Json -Depth 20
}
function Invoke-Graphql($Query, $Variables) { (Invoke-Gh -GhArgs @('api', 'graphql') -Body @{ query = $Query; variables = $Variables }).data }

$FieldNodes = 'nodes { __typename
    ... on ProjectV2Field { id name databaseId dataType }
    ... on ProjectV2SingleSelectField { id name databaseId dataType options { id name color description } }
    ... on ProjectV2IterationField { id name databaseId dataType } }'
$ViewNodes = 'nodes { id name layout filter }'
$FieldsQuery = @'
query($login: String!, $n: Int!) { repositoryOwner(login: $login) { __typename ... on ProjectV2Owner { projectV2(number: $n) {
  id
  fields(first: 50) { pageInfo { hasNextPage endCursor } __FIELDS__ }
  views(first: 50) { pageInfo { hasNextPage endCursor } __VIEWS__ } } } } }
'@ -replace '__FIELDS__', $FieldNodes -replace '__VIEWS__', $ViewNodes
# Follow-up pages of a connection whose first page had hasNextPage (fields, views, labels).
$ProjectFieldsQuery = 'query($id: ID!, $cursor: String) { node(id: $id) { ... on ProjectV2 { fields(first: 50, after: $cursor) { pageInfo { hasNextPage endCursor } ' + $FieldNodes + ' } } } }'
$ProjectViewsQuery = 'query($id: ID!, $cursor: String) { node(id: $id) { ... on ProjectV2 { views(first: 50, after: $cursor) { pageInfo { hasNextPage endCursor } ' + $ViewNodes + ' } } } }'
$ReposQuery = @'
query($id: ID!, $cursor: String) { node(id: $id) { ... on ProjectV2 { repositories(first: 50, after: $cursor) {
  pageInfo { hasNextPage endCursor }
  nodes { id nameWithOwner labels(first: 100) { pageInfo { hasNextPage endCursor } nodes { name color description } } } } } } }
'@
$RepoLabelsQuery = @'
query($id: ID!, $cursor: String) { node(id: $id) { ... on Repository { labels(first: 100, after: $cursor) {
  pageInfo { hasNextPage endCursor } nodes { name color description } } } } }
'@
$ItemsQuery = @'
query($id: ID!, $cursor: String) { node(id: $id) { ... on ProjectV2 { items(first: 100, after: $cursor) {
  totalCount pageInfo { hasNextPage endCursor }
  nodes { id content { __typename ... on Issue { id number title state labels(first: 50) { pageInfo { hasNextPage endCursor } nodes { name } } } }
    status: fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
    level: fieldValueByName(name: "Level") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } } } } }
'@
$IssueLabelsQuery = @'
query($id: ID!, $cursor: String) { node(id: $id) { ... on Issue { labels(first: 100, after: $cursor) {
  pageInfo { hasNextPage endCursor } nodes { name } } } } }
'@

# All nodes of a connection: $Page is the page already read, $Connection picks the connection out of a follow-up reply.
# A page without pageInfo (or hasNextPage false) ends the loop.
function Get-AllNodes($Page, $Query, [hashtable]$Variables, [scriptblock]$Connection) {
  $nodes = [System.Collections.Generic.List[object]]::new()
  while ($true) {
    foreach ($n in @($Page.nodes)) { if ($null -ne $n) { $nodes.Add($n) } }
    if (-not $Page.pageInfo.hasNextPage) { break }
    $Page = & $Connection (Invoke-Graphql $Query ($Variables + @{ cursor = $Page.pageInfo.endCursor }))
  }
  , @($nodes)
}

# Walks the project items. GitHub sometimes ends the walk early without an error (nodes empty, hasNextPage false,
# fewer nodes than items.totalCount): such a page is retried with backoff. $script:ItemsRead / $script:ItemsTotal tell
# the caller whether the list is complete. $Fetch takes a cursor and returns the items connection.
function Read-ItemNodes([scriptblock]$Fetch, [int]$BackoffSeconds = 5) {
  $nodes = [System.Collections.Generic.List[object]]::new(); $cursor = $null; $total = 0
  while ($true) {
    foreach ($try in 1..4) {
      $page = & $Fetch $cursor
      $total = [int]$page.totalCount
      $short = @($page.nodes).Count -eq 0 -and -not $page.pageInfo.hasNextPage -and $nodes.Count -lt $total
      if (-not $short) { break }
      if ($try -lt 4 -and $BackoffSeconds -gt 0) { Start-Sleep -Seconds ($BackoffSeconds * $try) }
    }
    foreach ($n in @($page.nodes)) { if ($null -ne $n) { $nodes.Add($n) } }
    if (-not $page.pageInfo.hasNextPage) { break }
    $cursor = $page.pageInfo.endCursor
  }
  $script:ItemsRead = $nodes.Count; $script:ItemsTotal = $total
  , @($nodes)
}
# Offline (-StateFile): 'itemPages' is a queue of item connections; the last one repeats once the queue is used up.
function New-PageFetcher($Pages) {
  $st = @{ q = [System.Collections.Generic.Queue[object]]::new(@($Pages)); last = $null }
  { param($cursor) if ($st.q.Count -gt 0) { $st.last = $st.q.Dequeue() }; $st.last }.GetNewClosure()
}

function Get-ProjectState {
  param([bool]$WithItems)
  $d = Invoke-Graphql $FieldsQuery @{ login = $Owner; n = $Number }
  $p = $d.repositoryOwner.projectV2
  if (-not $p) { throw "Project $Owner/$Number not found (or scope 'project' missing: gh auth refresh -s project)." }
  $fields = Get-AllNodes $p.fields $ProjectFieldsQuery @{ id = $p.id } { param($r) $r.node.fields }
  $views = Get-AllNodes $p.views $ProjectViewsQuery @{ id = $p.id } { param($r) $r.node.views }
  $state = [ordered]@{ owner = $Owner; number = $Number; projectId = $p.id; ownerType = $d.repositoryOwner.__typename
    fields = @($fields); views = @($views); items = @(); repositories = @() }
  if ($WithItems) {
    $items = [System.Collections.Generic.List[object]]::new()
    $raw = Read-ItemNodes { param($c) (Invoke-Graphql $ItemsQuery @{ id = $p.id; cursor = $c }).node.items }
    foreach ($n in $raw) {
      if ($n.content.__typename -ne 'Issue') { continue }
      $labels = Get-AllNodes $n.content.labels $IssueLabelsQuery @{ id = $n.content.id } { param($r) $r.node.labels }
      $items.Add([ordered]@{ id = $n.id; number = $n.content.number; title = $n.content.title; state = $n.content.state
          labels = @($labels | ForEach-Object { $_.name }); status = $n.status.name; level = $n.level.name })
    }
    $state.items = @($items)
    $first = (Invoke-Graphql $ReposQuery @{ id = $p.id; cursor = $null }).node.repositories
    $repos = Get-AllNodes $first $ReposQuery @{ id = $p.id } { param($r) $r.node.repositories }
    $state.repositories = @($repos | ForEach-Object {
        $labels = Get-AllNodes $_.labels $RepoLabelsQuery @{ id = $_.id } { param($r) $r.node.labels }
        [ordered]@{ nameWithOwner = $_.nameWithOwner; labels = @($labels) } })
  }
  $state
}

function Invoke-Plan($Actions, $State) {
  $field = { param($name) (@($State.fields) | Where-Object { $_.name -eq $name } | Select-Object -First 1) }
  # Fields and views first: a failing item edit must not leave the project without its views.
  $ordered = @($Actions | Where-Object { $_.type -ne 'SetItem' }) + @($Actions | Where-Object { $_.type -eq 'SetItem' })
  $labelFailures = [System.Collections.Generic.List[string]]::new()
  foreach ($a in $ordered) {
    switch ($a.type) {
      'UpdateStatusOptions' {
        $f = & $field 'Status'
        Invoke-Graphql 'mutation($i: UpdateProjectV2FieldInput!) { updateProjectV2Field(input: $i) { clientMutationId } }' @{ i = @{ fieldId = $f.id; singleSelectOptions = $a.options } } | Out-Null
        $State.fields = @((Get-ProjectState $false).fields)
      }
      'UpdateFieldOptions' {
        $f = & $field $a.field
        Invoke-Graphql 'mutation($i: UpdateProjectV2FieldInput!) { updateProjectV2Field(input: $i) { clientMutationId } }' @{ i = @{ fieldId = $f.id; singleSelectOptions = $a.options } } | Out-Null
        $State.fields = @((Get-ProjectState $false).fields)
      }
      'CreateField' {
        Invoke-Graphql 'mutation($i: CreateProjectV2FieldInput!) { createProjectV2Field(input: $i) { clientMutationId } }' @{ i = @{ projectId = $State.projectId; dataType = 'SINGLE_SELECT'; name = $a.name; singleSelectOptions = $a.options } } | Out-Null
        $State.fields = @((Get-ProjectState $false).fields)
      }
      'SetItem' {
        $f = & $field $a.field
        $o = $f.options | Where-Object { $_.name -eq $a.option } | Select-Object -First 1
        if (-not $o) { throw "Option '$($a.option)' not found in field $($a.field)." }
        # Bulk edits hit GitHub's secondary rate limit now and then: retry with backoff.
        foreach ($try in 1..4) {
          $out = & gh project item-edit --project-id $State.projectId --id $a.item --field-id $f.id --single-select-option-id $o.id 2>&1
          if ($LASTEXITCODE -eq 0) { break }
          if ($try -eq 4) { throw "gh project item-edit failed for #$($a.number): $out" }
          Start-Sleep -Seconds (15 * $try)
        }
      }
      'CreateView' {
        $ids = { param($names) @($names | ForEach-Object { [int64](& $field $_).databaseId }) }
        $body = [ordered]@{ name = $a.name; layout = $a.layout; filter = $a.filter; visible_fields = @(& $ids $a.visibleFields) }
        if ($a.groupBy) { $body.group_by = @(& $ids @($a.groupBy)) }
        if ($a.verticalGroupBy) { $body.vertical_group_by = @(& $ids @($a.verticalGroupBy)) }
        $base = if ($State.ownerType -eq 'Organization') { "/orgs/$Owner" } else { "/users/$Owner" }
        Invoke-Gh -GhArgs @('api', '-X', 'POST', "$base/projectsV2/$Number/views") -Body $body | Out-Null
      }
      'EnsureLabel' {
        $out = & gh label create $a.name --repo $a.repo --color $a.color --description $a.description --force 2>&1
        # A repository without write access must not abort the remaining actions: warn, continue, fail at the end.
        if ($LASTEXITCODE -ne 0) { $labelFailures.Add("gh label create $($a.name) --repo $($a.repo) failed: $out"); Write-Warning $labelFailures[-1] }
      }
      'DeleteField' {
        Invoke-Graphql 'mutation($i: DeleteProjectV2FieldInput!) { deleteProjectV2Field(input: $i) { clientMutationId } }' @{ i = @{ fieldId = $a.id } } | Out-Null
        $State.fields = @((Get-ProjectState $false).fields)
      }
      'DeleteView' {
        Invoke-Graphql 'mutation($i: DeleteProjectV2ViewInput!) { deleteProjectV2View(input: $i) { clientMutationId } }' @{ i = @{ viewId = $a.id } } | Out-Null
      }
    }
  }
  if ($labelFailures.Count -gt 0) { throw "$($labelFailures.Count) label(s) could not be created; all other actions were applied." }
}

if ($StateFile) {
  $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json -Depth 20
  # Optional: 'itemPages' (item connections of the walk) replace 'items'.
  if ($state.itemPages) {
    $raw = Read-ItemNodes (New-PageFetcher $state.itemPages) 0
    $walked = @($raw | Where-Object { $_.content.__typename -eq 'Issue' } | ForEach-Object {
        [ordered]@{ id = $_.id; number = $_.content.number; title = $_.content.title; state = $_.content.state
          labels = @($_.content.labels.nodes | ForEach-Object { $_.name }); status = $_.status.name; level = $_.level.name } })
    $state | Add-Member -NotePropertyName items -NotePropertyValue $walked -Force
  }
  $DryRun = $true  # a state file never reaches GitHub
} else {
  if (-not $Owner -or $Number -lt 1) { throw 'Usage: Set-ProjectStandard.ps1 -Owner <login> -Number <n> [-Sync] [-RemoveDefaultViews] [-RemoveSprintField] [-DryRun] [-StateFile <json>] [-Json]' }
  $state = Get-ProjectState $Sync.IsPresent
}
# -Sync: the plan is only as good as the item list. Log both counts; an incomplete list fails the run (never 'No changes.', never a partial apply).
$incomplete = $Sync -and $null -ne $script:ItemsTotal -and $script:ItemsRead -lt $script:ItemsTotal
if ($Sync -and $null -ne $script:ItemsTotal -and -not $Json) { "Read $($script:ItemsRead) of $($script:ItemsTotal) project items." }
$actions = Get-ProjectPlan -State $state -Sync $Sync.IsPresent -RemoveDefaultViews $RemoveDefaultViews.IsPresent -RemoveSprintField $RemoveSprintField.IsPresent
if ($incomplete) {
  [Console]::Error.WriteLine("Project item walk ended early: read $($script:ItemsRead) of $($script:ItemsTotal) items; nothing applied and no 'No changes.' reported. Run again later.")
  exit 1
}
if (-not $DryRun -and $actions.Count -gt 0) { Invoke-Plan $actions $state }

# -Sync also sets the field Needs. Offline (-StateFile) the call is only listed; a failing Needs sync is one warning, never a failed run.
$needsOutput = @()
if ($Sync) {
  if ($StateFile) {
    $actions = @($actions) + [pscustomobject]@{ type = 'syncNeeds'; owner = $Owner; number = $Number }
  } else {
    $needsArgs = @{ Owner = $Owner; Number = $Number }
    if ($DryRun) { $needsArgs.DryRun = $true }
    try {
      $needsOutput = @(& (Join-Path $PSScriptRoot 'Sync-ProjectNeeds.ps1') @needsArgs *>&1 | ForEach-Object { "$_" })
      if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw "exit code $LASTEXITCODE" }
    } catch {
      $needsOutput = @("Warning: Needs sync failed: $($_.Exception.Message)")
      $global:LASTEXITCODE = 0
    }
  }
}

if ($Json) {
  [ordered]@{ dryRun = $DryRun.IsPresent; itemsRead = $script:ItemsRead; itemsTotal = $script:ItemsTotal; actions = @($actions); needs = @($needsOutput); manualSteps = $script:ManualSteps } | ConvertTo-Json -Depth 20
} else {
  $verb = if ($DryRun) { 'Planned' } else { 'Applied' }
  if ($actions.Count -eq 0) { 'No changes.' } else { "$verb $($actions.Count) action(s):"; $actions | ForEach-Object { "  - $(Format-Action $_)" } }
  if ($needsOutput.Count -gt 0) { ''; $needsOutput }
  ''; 'Manual steps (UI only):'; $script:ManualSteps | ForEach-Object { "  - $_" }
}
