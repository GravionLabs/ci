#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
  Assigns PBIs of any repository to a weekly sprint (iteration 'YYYY-Www') of a GitHub Project (v2) and enforces the sprint limits.
.DESCRIPTION
  1. Reads the state (Sprint iterations, items with repository, Level, Status, Sprint) via 'gh api graphql', or from -StateFile.
  2. A pure function (Get-SprintPlan) checks the limits and computes the assignments. All or nothing: one violation assigns nothing.
  3. Executes unless -DryRun. Exit 0 = assigned, 1 = limit violated or input error.
  Limits (open PBIs and Bugs only): per sprint in total, per sprint and repository, and 'In release' per repository
  (a repository with a full release branch takes no new PBI until it is released).
  Dependency order: a target with an open native blocked-by link enters only when the blocker is in this sprint or an
  earlier one, or is assigned in the same run. A 'Blocked by #n' line in the body alone is not read.
.PARAMETER Owner         User or organization login that owns the project.
.PARAMETER Number        Project number.
.PARAMETER Issue         Issues to assign, comma separated: 'owner/repo#n' (or '#n' with -Repo). They must already be items of the project.
.PARAMETER Repo          Default repository 'owner/repo' for '#n'.
.PARAMETER Sprint        Sprint title, default the current ISO week ('2026-W43').
.PARAMETER MaxPerSprint  Open PBIs per sprint over all repositories (default 30).
.PARAMETER MaxPerRepo    Open PBIs per sprint and repository (default 10).
.PARAMETER MaxInRelease  Open PBIs in status 'In release' per repository (default 10).
.PARAMETER Force         Assign despite violated limits.
.PARAMETER DryRun        Print the plan, change nothing.
.PARAMETER Today         Date for the default sprint; only for tests.
.PARAMETER StateFile     JSON state (projectId, sprintField, items with optional blockedBy [{repo, number, state}]) instead of reading from GitHub.
.PARAMETER Json          Emit {sprint, assign, violations} as JSON.
#>
[CmdletBinding()]
param(
  [string]$Owner,
  [int]$Number,
  [string[]]$Issue,
  [string]$Repo,
  [string]$Sprint,
  [int]$MaxPerSprint = 30,
  [int]$MaxPerRepo = 10,
  [int]$MaxInRelease = 10,
  [switch]$Force,
  [switch]$DryRun,
  [datetime]$Today = (Get-Date),
  [string]$StateFile,
  [switch]$Json
)
# No Mandatory: a headless run must exit non-zero with a message instead of prompting.
$ErrorActionPreference = 'Stop'

# ISO 8601 week title 'YYYY-Www' (week-year, not calendar year: 2027-01-01 is 2026-W53).
function Get-SprintTitle([datetime]$Date) { '{0}-W{1:00}' -f [System.Globalization.ISOWeek]::GetYear($Date), [System.Globalization.ISOWeek]::GetWeekOfYear($Date) }

function ConvertTo-Target([string]$Ref, [string]$DefaultRepo) {
  if ($Ref -match '^(?<r>[\w.-]+/[\w.-]+)?#(?<n>\d+)$') {
    $r = if ($Matches.r) { $Matches.r } else { $DefaultRepo }
    if (-not $r) { throw "Issue '$Ref' has no repository: use owner/repo#n or -Repo." }
    return @{ repo = $r; number = [int]$Matches.n }
  }
  throw "Cannot read issue '$Ref' (expected owner/repo#n or #n)."
}

function Get-SprintPlan {
  param($State, $Targets, [string]$SprintTitle, [int]$MaxPerSprint, [int]$MaxPerRepo, [int]$MaxInRelease)
  $violations = [System.Collections.Generic.List[object]]::new()
  $assign = [System.Collections.Generic.List[object]]::new()
  $iteration = @($State.sprintField.iterations) | Where-Object { $_.title -eq $SprintTitle } | Select-Object -First 1
  if (-not $iteration) { $violations.Add([ordered]@{ type = 'NoSuchSprint'; message = "Sprint $SprintTitle does not exist in the project (extend the iterations of field Sprint)." }) }

  $open = @($State.items | Where-Object { $_.state -eq 'OPEN' -and $_.level -in 'PBI', 'Bug' })
  $inSprint = @($open | Where-Object { $_.sprint -eq $SprintTitle })
  $newItems = [System.Collections.Generic.List[object]]::new()

  foreach ($t in $Targets) {
    $item = @($State.items) | Where-Object { $_.repo -eq $t.repo -and $_.number -eq $t.number } | Select-Object -First 1
    $ref = "$($t.repo)#$($t.number)"
    if (-not $item) { $violations.Add([ordered]@{ type = 'NotInProject'; issue = $ref; message = "$ref is not an item of the project." }); continue }
    if ($item.state -ne 'OPEN') { $violations.Add([ordered]@{ type = 'Closed'; issue = $ref; message = "$ref is closed." }); continue }
    if ($item.level -notin 'PBI', 'Bug') { $violations.Add([ordered]@{ type = 'NotAPbi'; issue = $ref; message = "$ref has Level '$($item.level)': only PBI and Bug enter a sprint." }); continue }
    if ($item.sprint -eq $SprintTitle) { continue }
    $newItems.Add($item)
    if ($iteration) { $assign.Add([ordered]@{ item = $item.id; issue = $ref; iteration = $iteration.id; sprint = $SprintTitle; previous = $item.sprint }) }
  }

  # Dependency order from the native blocked-by links (the source 'orchestrator next' reads): an open blocker must be in
  # this sprint (already, or assigned in this run) or in an earlier one. Sprint titles 'YYYY-Www' compare as strings.
  foreach ($item in $newItems) {
    $ref = "$($item.repo)#$($item.number)"
    foreach ($b in @($item.blockedBy | Where-Object { $_.state -eq 'OPEN' })) {
      if (@($newItems | Where-Object { $_.repo -eq $b.repo -and $_.number -eq $b.number }).Count -gt 0) { continue }
      $blocker = @($State.items) | Where-Object { $_.repo -eq $b.repo -and $_.number -eq $b.number } | Select-Object -First 1
      if ($blocker.sprint -and $blocker.sprint -le $SprintTitle) { continue }
      $where = if ($blocker.sprint) { "sprint $($blocker.sprint)" } else { 'no sprint' }
      $bRef = "$($b.repo)#$($b.number)"
      $violations.Add([ordered]@{ type = 'Blocked'; issue = $ref; blocker = $bRef; message = "$ref is blocked by open $bRef ($where): assign the blocker to $SprintTitle or an earlier sprint first, or together." })
    }
  }

  $total = $inSprint.Count + $newItems.Count
  if ($newItems.Count -gt 0 -and $total -gt $MaxPerSprint) { $violations.Add([ordered]@{ type = 'SprintFull'; message = "Sprint $SprintTitle would hold $total PBIs (limit $MaxPerSprint)." }) }
  foreach ($repo in @($newItems | ForEach-Object { $_.repo } | Select-Object -Unique)) {
    $n = @($inSprint | Where-Object { $_.repo -eq $repo }).Count + @($newItems | Where-Object { $_.repo -eq $repo }).Count
    if ($n -gt $MaxPerRepo) { $violations.Add([ordered]@{ type = 'RepoFull'; repo = $repo; message = "$repo would have $n PBIs in $SprintTitle (limit $MaxPerRepo)." }) }
    $rel = @($open | Where-Object { $_.repo -eq $repo -and $_.status -eq 'In release' }).Count
    if ($rel -ge $MaxInRelease) { $violations.Add([ordered]@{ type = 'ReleaseFull'; repo = $repo; message = "$repo has $rel PBIs In release (limit $MaxInRelease): cut the release first (github-release)." }) }
  }
  [ordered]@{ sprint = $SprintTitle; assign = @($assign); violations = @($violations) }
}

function Invoke-Gh {
  param([string[]]$GhArgs, $Body)
  $out = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 20 -Compress | & gh @GhArgs --input - 2>&1 } else { & gh @GhArgs 2>&1 }
  if ($LASTEXITCODE -ne 0) { throw "gh $($GhArgs -join ' ') failed: $out" }
  ($out | Out-String) | ConvertFrom-Json -Depth 20
}
function Invoke-Graphql($Query, $Variables) { (Invoke-Gh -GhArgs @('api', 'graphql') -Body @{ query = $Query; variables = $Variables }).data }

$StateQuery = @'
query($login: String!, $n: Int!) { repositoryOwner(login: $login) { ... on ProjectV2Owner { projectV2(number: $n) {
  id
  fields(first: 50) { nodes { __typename
    ... on ProjectV2IterationField { id name configuration { iterations { id title } completedIterations { id title } } } } } } } } }
'@
$ItemsQuery = @'
query($id: ID!, $cursor: String) { node(id: $id) { ... on ProjectV2 { items(first: 100, after: $cursor) {
  pageInfo { hasNextPage endCursor }
  nodes { id content { __typename ... on Issue { number state repository { nameWithOwner } } }
    status: fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
    level: fieldValueByName(name: "Level") { ... on ProjectV2ItemFieldSingleSelectValue { name } }
    sprint: fieldValueByName(name: "Sprint") { ... on ProjectV2ItemFieldIterationValue { title } } } } } } }
'@

function Get-SprintState {
  param($Targets)
  $p = (Invoke-Graphql $StateQuery @{ login = $Owner; n = $Number }).repositoryOwner.projectV2
  if (-not $p) { throw "Project $Owner/$Number not found (or scope 'project' missing: gh auth refresh -s project)." }
  $f = @($p.fields.nodes) | Where-Object { $_.name -eq 'Sprint' -and $_.configuration } | Select-Object -First 1
  if (-not $f) { throw "Project has no iteration field 'Sprint': run Set-ProjectStandard.ps1 -Sprints first." }
  $items = [System.Collections.Generic.List[object]]::new(); $cursor = $null
  do {
    $page = (Invoke-Graphql $ItemsQuery @{ id = $p.id; cursor = $cursor }).node.items
    foreach ($n in $page.nodes) {
      if ($n.content.__typename -ne 'Issue') { continue }
      $items.Add([ordered]@{ id = $n.id; repo = $n.content.repository.nameWithOwner; number = $n.content.number; state = $n.content.state
          status = $n.status.name; level = $n.level.name; sprint = $n.sprint.title })
    }
    $cursor = $page.pageInfo.endCursor
  } while ($page.pageInfo.hasNextPage)
  # Native blocked-by links of the targets only (one REST call each); a blocker may live in another repository.
  foreach ($t in $Targets) {
    $item = $items | Where-Object { $_.repo -eq $t.repo -and $_.number -eq $t.number } | Select-Object -First 1
    if (-not $item) { continue }
    $links = @(Invoke-Gh -GhArgs @('api', "repos/$($t.repo)/issues/$($t.number)/dependencies/blocked_by?per_page=100"))
    $item.blockedBy = @($links | ForEach-Object {
        $r = if ($_.repository_url -match '/repos/(?<r>[^/]+/[^/]+)$') { $Matches.r } else { $t.repo }
        [ordered]@{ repo = $r; number = $_.number; state = $_.state }
      })
  }
  [ordered]@{ projectId = $p.id; sprintField = [ordered]@{ id = $f.id; iterations = @($f.configuration.iterations) + @($f.configuration.completedIterations) }; items = @($items) }
}

if (-not $Sprint) { $Sprint = Get-SprintTitle $Today }
if ($Sprint -notmatch '^\d{4}-W\d{2}$') { throw "Sprint '$Sprint' does not match YYYY-Www." }
# 'pwsh -File' passes 'a,b' as one string: accept a comma separated list as well as an array.
$targets = @($Issue | ForEach-Object { $_ -split '\s*,\s*' } | Where-Object { $_ } | ForEach-Object { ConvertTo-Target $_ $Repo })
if ($StateFile) {
  $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json -Depth 20
  $DryRun = $true  # a state file never reaches GitHub
} else {
  if (-not $Owner -or $Number -lt 1 -or $targets.Count -eq 0) { throw 'Usage: Set-Sprint.ps1 -Owner <login> -Number <n> -Issue <owner/repo#n>... [-Repo <owner/repo>] [-Sprint 2026-W43] [-MaxPerSprint 30] [-MaxPerRepo 10] [-MaxInRelease 10] [-Force] [-DryRun] [-StateFile <json>] [-Json]' }
  $state = Get-SprintState -Targets $targets
}
$plan = Get-SprintPlan -State $state -Targets $targets -SprintTitle $Sprint -MaxPerSprint $MaxPerSprint -MaxPerRepo $MaxPerRepo -MaxInRelease $MaxInRelease
$blocked = $plan.violations.Count -gt 0 -and -not $Force
if (-not $DryRun -and -not $blocked) {
  foreach ($a in $plan.assign) {
    # Bulk edits hit GitHub's secondary rate limit now and then: retry with backoff.
    foreach ($try in 1..4) {
      $out = & gh project item-edit --project-id $state.projectId --id $a.item --field-id $state.sprintField.id --iteration-id $a.iteration 2>&1
      if ($LASTEXITCODE -eq 0) { break }
      if ($try -eq 4) { throw "gh project item-edit failed for $($a.issue): $out" }
      Start-Sleep -Seconds (15 * $try)
    }
  }
}

if ($Json) {
  $plan | ConvertTo-Json -Depth 20
} else {
  $verb = if ($DryRun) { 'Planned' } else { 'Applied' }
  if ($plan.violations.Count -gt 0) { 'Limits:'; $plan.violations | ForEach-Object { "  - $($_.message)" } }
  if ($blocked) { 'Nothing assigned (use -Force to override).' }
  elseif ($plan.assign.Count -eq 0) { 'No changes.' }
  else { "$verb $($plan.assign.Count) assignment(s) to ${Sprint}:"; $plan.assign | ForEach-Object { "  - $($_.issue)" } }
}
if ($blocked) { exit 1 }
