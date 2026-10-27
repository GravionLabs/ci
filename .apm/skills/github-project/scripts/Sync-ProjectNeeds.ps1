#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
  Computes the project field Needs of open issues from GitHub state (labels, sub-issues, blocked-by links, pull requests, Status).
.DESCRIPTION
  1. Resolves the project: -Owner/-Number, else .agents/project.json {owner, number} at the repository root, else
     'project-url: https://github.com/(users|orgs)/<owner>/projects/<n>' in .github/workflows/add-to-project.yml (or .yaml) first, else in the other .github/workflows/*.yml|yaml files in name order (first match).
     None found: prints 'Needs sync skipped: no project configured' and exits 0.
  2. A pure function (Get-NeedsValue) computes the value per item, first match wins:
       closed -> clear; label needs-decision -> Decision; label needs-review -> Review; open blocked-by -> Blocked;
       label merged or Status 'In release' -> Release review; open PR whose head ref matches (^|/)<nr>- or Status 'In Progress' -> In progress;
       Epic without Feature, Feature without PBI, PBI without Task sub-issues and without label planned -> Planning;
       else Ready for PBI-level items (PBI, Bug, Task, unknown level) and clear for Epics and Features.
  3. Get-NeedsPlan returns one action {issue, item, from, to} per item whose current Needs differs; unchanged items yield none.
  Live mode (no -StateFile): reads the project with batched GraphQL (items(first: 100) pages; with -Issue only the listed
  issues, aliased), then applies one updateProjectV2ItemFieldValue (clearProjectV2ItemFieldValue for a clear) per changed
  item, 4 tries with backoff (15 s * try, env SYNC_PROJECT_NEEDS_BACKOFF overrides the 15). Prints '#<nr>: <from> -> <to>'
  per change and 'Needs: <k> changed, <m> unchanged'. No Needs field: 'Needs sync skipped: field Needs missing ...', exit 0.
  Native blocked-by comes from GraphQL blockedBy; when that field is unavailable the REST dependencies endpoint is used.
  Exit 1 on an unrecoverable error (one line 'Needs sync failed: ...').
  -StateFile never calls gh.
  State file: {owner, number, projectId, needsField:{id, options:{name:id}},
               items:[{itemId, repo, number, state, level, labels[], status, needs, blockedByOpen, subIssueLevels[], prHeads[], parent}]}
  parent is a number (same repository), 'owner/repo#n' or {repo, number}. Optional blocking: [{repo, number}] lists the
  issues the item blocks (used by -IncludeDependents).
.PARAMETER Owner            User or organization login of the project (wins over the lookup).
.PARAMETER Number           Project number (wins over the lookup).
.PARAMETER Repo             Only items of this repository (owner/repo).
.PARAMETER Issue            Only these issues: 12,13 or owner/repo#12 (list or comma separated).
.PARAMETER IncludeParents   Also sync the parent of every selected -Issue item.
.PARAMETER IncludeDependents  With -Issue also sync every open issue the selected issues block (blocking links, also across repositories;
                            deduplicated with -IncludeParents). Without -Issue it changes nothing.
.PARAMETER DryRun           Print the actions, change nothing.
.PARAMETER StateFile        JSON state instead of reading from GitHub (no gh call).
.PARAMETER SetStatus        Status mode (needs exactly one -Issue): sets the project Status of that issue to this option (e.g. 'In Progress') and nothing
                            else. No project configured: silent, exit 0. Issue not in the project or option missing: one line 'Status not set: ...', exit 0.
                            With -StateFile only the action is reported ({issue, item, field: 'Status', to}); other errors: exit 1.
.PARAMETER Json             Emit {project, actions, skipped} as JSON instead of text.
#>
[CmdletBinding()]
param(
  [string]$Owner,
  [int]$Number,
  [string]$Repo,
  [string[]]$Issue,
  [switch]$IncludeParents,
  [switch]$IncludeDependents,
  [switch]$DryRun,
  [string]$StateFile,
  [string]$SetStatus,
  [switch]$Json
)
# No Mandatory: a headless run must exit non-zero with a message instead of prompting.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Usage = 'Usage: Sync-ProjectNeeds.ps1 [-Owner <login> -Number <n>] [-Repo owner/repo] [-Issue 12,13|owner/repo#12] [-IncludeParents] [-IncludeDependents] [-DryRun] [-StateFile <json>] [-SetStatus <option>] [-Json]'

# Shared rule module (Get-Prop, Get-NeedsValue), also used by the queue dry run.
$script:NeedsModule = Join-Path $PSScriptRoot 'NeedsRules.psm1'
if (-not (Test-Path -LiteralPath $script:NeedsModule -PathType Leaf)) { throw "NeedsRules.psm1 not found ($script:NeedsModule)." }
Import-Module -Name $script:NeedsModule -Global

function Resolve-ProjectRef {
  param([string]$Owner, [int]$Number, [string]$Root)
  if ($Owner -and $Number -gt 0) { return @{ owner = $Owner; number = $Number } }
  $cfg = Join-Path $Root '.agents/project.json'
  if (Test-Path -LiteralPath $cfg -PathType Leaf) {
    try { $j = Get-Content -LiteralPath $cfg -Raw | ConvertFrom-Json } catch { $j = $null }
    $o = Get-Prop $j 'owner'; $n = Get-Prop $j 'number'
    if ($o -and $n) { return @{ owner = "$o"; number = [int]$n } }
  }
  $dir = Join-Path $Root '.github/workflows'
  $files = @('add-to-project.yml', 'add-to-project.yaml') + @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in '.yml', '.yaml' -and $_.Name -notin 'add-to-project.yml', 'add-to-project.yaml' } | Sort-Object Name | ForEach-Object Name)
  foreach ($name in $files) {
    $wf = Join-Path $dir $name
    if (-not (Test-Path -LiteralPath $wf -PathType Leaf)) { continue }
    $m = [regex]::Match((Get-Content -LiteralPath $wf -Raw), 'project-url:\s*["'']?https://github\.com/(?:users|orgs)/([^/\s"'']+)/projects/(\d+)')
    if ($m.Success) { return @{ owner = $m.Groups[1].Value; number = [int]$m.Groups[2].Value } }
  }
  $null
}

# 'owner/repo#n' / number / {repo, number} -> @{ repo; number } ($repo may be $null for a bare number).
function ConvertTo-IssueRef($Value, [string]$DefaultRepo) {
  if ($null -eq $Value -or "$Value" -eq '') { return $null }
  $repo = Get-Prop $Value 'repo'; $num = Get-Prop $Value 'number'
  if ($null -ne $num) { return @{ repo = $(if ($repo) { "$repo" } else { $DefaultRepo }); number = [int]$num } }
  $s = "$Value".Trim()
  if ($s -match '^([^#\s]+)#(\d+)$') { return @{ repo = $Matches[1]; number = [int]$Matches[2] } }
  if ($s -match '^#?(\d+)$') { return @{ repo = $DefaultRepo; number = [int]$Matches[1] } }
  throw "Invalid issue reference '$s'. $script:Usage"
}

function Test-RefMatch($Ref, $Item) {
  if (-not $Ref -or [int]$Item.number -ne $Ref.number) { return $false }
  (-not $Ref.repo) -or ("$($Item.repo)" -eq $Ref.repo)
}

# Items in scope (-Repo, -Issue, parents of -Issue items) and the actions for those whose Needs differs.
function Get-NeedsPlan {
  param($State, [string]$Repo, [string[]]$Issue, [bool]$IncludeParents = $false, [bool]$IncludeDependents = $false)
  $items = @(Get-Prop $State 'items' | Where-Object { $_ })
  $refs = @(@($Issue | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) |
      ForEach-Object { ConvertTo-IssueRef $_ $null })
  $selected = [System.Collections.Generic.HashSet[object]]::new()
  foreach ($it in $items) {
    if ($Repo -and "$($it.repo)" -ne $Repo) { continue }
    if ($refs.Count -gt 0 -and -not (@($refs | Where-Object { Test-RefMatch $_ $it }).Count -gt 0)) { continue }
    [void]$selected.Add($it)
  }
  $direct = @($selected)
  if ($IncludeParents -and $refs.Count -gt 0) {
    foreach ($it in $direct) {
      $p = ConvertTo-IssueRef (Get-Prop $it 'parent') "$($it.repo)"
      foreach ($cand in $items) { if (Test-RefMatch $p $cand) { [void]$selected.Add($cand) } }
    }
  }
  if ($IncludeDependents -and $refs.Count -gt 0) {
    foreach ($it in @($direct)) {
      foreach ($b in @(Get-Prop $it 'blocking' | Where-Object { $_ })) {
        $d = ConvertTo-IssueRef $b "$($it.repo)"
        foreach ($cand in $items) { if ((Test-RefMatch $d $cand) -and "$($cand.state)" -eq 'OPEN') { [void]$selected.Add($cand) } }
      }
    }
  }
  $actions = [System.Collections.Generic.List[object]]::new()
  $skipped = [System.Collections.Generic.List[object]]::new()
  foreach ($it in $items) {
    $id = "$($it.repo)#$($it.number)"
    if (-not $selected.Contains($it)) { $skipped.Add($id); continue }
    $from = Get-Prop $it 'needs'
    if ($from -eq '') { $from = $null }
    $to = Get-NeedsValue $it
    if ("$from" -eq "$to") { continue }
    $actions.Add([ordered]@{ issue = $id; item = Get-Prop $it 'itemId'; from = $from; to = $to })
  }
  [ordered]@{ actions = @($actions); skipped = @($skipped) }
}

# ---- live mode -------------------------------------------------------------------------------------------------

function Invoke-Gh {
  param([string[]]$GhArgs, $Body)
  $out = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 20 -Compress | & gh @GhArgs --input - 2>&1 } else { & gh @GhArgs 2>&1 }
  if ($LASTEXITCODE -ne 0) { throw "gh $($GhArgs -join ' ') failed: $out" }
  ($out | Out-String) | ConvertFrom-Json -Depth 20
}
function Invoke-Graphql($Query, $Variables) { (Invoke-Gh -GhArgs @('api', 'graphql') -Body @{ query = $Query; variables = $Variables }).data }

$script:RestBlocked = $false
$script:RestBlocking = $false
$script:WantBlocking = $false
$script:FieldsQuery = @'
query($login: String!, $n: Int!) { repositoryOwner(login: $login) { ... on ProjectV2Owner { projectV2(number: $n) {
  id
  fields(first: 50) { nodes { __typename ... on ProjectV2SingleSelectField { id name options { id name } } } } } } } }
'@
$script:LevelFrag = 'status: fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } } level: fieldValueByName(name: "Level") { ... on ProjectV2ItemFieldSingleSelectValue { name } } needs: fieldValueByName(name: "Needs") { ... on ProjectV2ItemFieldSingleSelectValue { name } }'
$script:IssueFrag = '... on Issue { number title state issueType { name } repository { nameWithOwner } labels(first: 50) { nodes { name } } parent { number repository { nameWithOwner } } subIssues(first: 50) { nodes { number title issueType { name } projectItems(first: 10) { nodes { project { id } level: fieldValueByName(name: "Level") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } } } } __BLOCKED__ __BLOCKING__ closedByPullRequestsReferences(first: 10) { nodes { state headRefName } } }'

# Runs a query containing __BLOCKED__; when GraphQL lacks blockedBy the field is dropped and REST is used instead.
function Invoke-ItemsGraphql([string]$Template, $Variables) {
  $blocked = if ($script:RestBlocked) { '' } else { 'blockedBy(first: 20) { nodes { number state repository { nameWithOwner } labels(first: 20) { nodes { name } } projectItems(first: 10) { nodes { project { id } status: fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } } } }' }
  $blocking = if ($script:WantBlocking -and -not $script:RestBlocking) { 'blocking(first: 50) { nodes { number state repository { nameWithOwner } } }' } else { '' }
  try { return Invoke-Graphql ($Template -replace '__BLOCKED__', $blocked -replace '__BLOCKING__', $blocking) $Variables }
  catch {
    # a GraphQL without blockedBy / blocking: drop that field and use the REST dependencies endpoint instead
    if (-not $script:RestBlocked -and "$_" -match 'blockedBy') { $script:RestBlocked = $true }
    elseif ($script:WantBlocking -and -not $script:RestBlocking -and "$_" -match '\bblocking\b') { $script:RestBlocking = $true }
    else { throw }
    return Invoke-ItemsGraphql $Template $Variables
  }
}

function Get-LevelOf($ItemLevel, $IssueType, [string]$Title) {
  $known = 'Epic', 'Feature', 'PBI', 'Task', 'Bug'
  if ($ItemLevel -and $known -contains $ItemLevel) { return $ItemLevel }
  if ($IssueType -and $known -contains $IssueType) { return $IssueType }
  if ($Title -match '^\[(Epic|Feature|PBI|Task|Bug)\]') { return $Matches[1] }
  $null
}

# GraphQL Issue node + its project item node -> state item (prHeads/blockedByOpen are filled by the caller).
function ConvertTo-NeedsItem($Content, $ItemNode, [string]$ProjectId) {
  $subLevels = @(@($Content.subIssues.nodes | Where-Object { $_ }) | ForEach-Object {
      $lv = (Get-Prop (Get-Prop $_ 'projectItems') 'nodes') | Where-Object { $_.project.id -eq $ProjectId } | ForEach-Object { (Get-Prop $_.level 'name') } | Select-Object -First 1
      Get-LevelOf $lv (Get-Prop (Get-Prop $_ 'issueType') 'name') "$(Get-Prop $_ 'title')"
    } | Where-Object { $_ })
  # a blocker blocks only while open and not merged (label merged or Status In release in this project)
  $blocked = if ($Content.PSObject.Properties['blockedBy'] -and $Content.blockedBy) {
    @($Content.blockedBy.nodes | Where-Object { $_ } | Where-Object {
        $st = @(Get-Prop (Get-Prop $_ 'projectItems') 'nodes') | Where-Object { $_ -and $_.project.id -eq $ProjectId } | ForEach-Object { Get-Prop $_.status 'name' } | Select-Object -First 1
        Test-BlockerUnresolved ([pscustomobject]@{ state = $_.state; labels = @((Get-Prop (Get-Prop $_ 'labels') 'nodes') | Where-Object { $_ } | ForEach-Object { $_.name }); status = $st })
      }).Count
  } else { 0 }
  # a linked open PR counts as work in progress whatever its branch is called
  $nr = $Content.number
  $heads = @($Content.closedByPullRequestsReferences.nodes | Where-Object { $_.state -eq 'OPEN' } |
      ForEach-Object { if ("$($_.headRefName)" -match "(^|/)$nr-") { $_.headRefName } else { "$nr-linked-pr" } })
  $parent = if ($Content.parent) { [ordered]@{ repo = $Content.parent.repository.nameWithOwner; number = $Content.parent.number } } else { $null }
  [ordered]@{ itemId = $ItemNode.id; repo = $Content.repository.nameWithOwner; number = $Content.number; state = $Content.state
    level = Get-LevelOf (Get-Prop (Get-Prop $ItemNode 'level') 'name') (Get-Prop (Get-Prop $Content 'issueType') 'name') "$(Get-Prop $Content 'title')"
    labels = @($Content.labels.nodes | ForEach-Object { $_.name }); status = (Get-Prop (Get-Prop $ItemNode 'status') 'name'); needs = (Get-Prop (Get-Prop $ItemNode 'needs') 'name')
    blockedByOpen = $blocked; subIssueLevels = $subLevels; prHeads = $heads; parent = $parent }
}

function Get-ProjectItemNodes {
  param([string]$ProjectId)
  $tpl = 'query($id: ID!, $cursor: String) { node(id: $id) { ... on ProjectV2 { items(first: 100, after: $cursor) { pageInfo { hasNextPage endCursor } nodes { id content { __typename ' + $script:IssueFrag + ' } ' + $script:LevelFrag + ' } } } } }'
  $cursor = $null
  do {
    $page = (Invoke-ItemsGraphql $tpl @{ id = $ProjectId; cursor = $cursor }).node.items
    foreach ($n in $page.nodes) { if ($n.content.__typename -eq 'Issue') { [pscustomobject]@{ item = $n; content = $n.content } } }
    $cursor = $page.pageInfo.endCursor
  } while ($page.pageInfo.hasNextPage)
}

# Only the given {repo, number} refs, aliased per call; issues outside the project are dropped.
function Get-IssueNodes {
  param([string]$ProjectId, $Refs)
  $list = @($Refs)
  for ($i = 0; $i -lt $list.Count; $i += 50) {
    $chunk = @($list[$i..([Math]::Min($i + 49, $list.Count - 1))])
    $decl = [System.Collections.Generic.List[string]]::new(); $body = [System.Collections.Generic.List[string]]::new(); $vars = @{}
    for ($k = 0; $k -lt $chunk.Count; $k++) {
      $o, $r = $chunk[$k].repo -split '/', 2
      $decl.Add("`$o${k}: String!, `$r${k}: String!, `$n${k}: Int!")
      $vars["o$k"] = $o; $vars["r$k"] = $r; $vars["n$k"] = [int]$chunk[$k].number
      $body.Add("i${k}: repository(owner: `$o${k}, name: `$r${k}) { issue(number: `$n${k}) { " + $script:IssueFrag +
        ' projectItems(first: 20) { nodes { id project { id } ' + $script:LevelFrag + ' } } } }')
    }
    $q = "query($($decl -join ', ')) { $($body -join ' ') }"
    $d = Invoke-ItemsGraphql $q $vars
    for ($k = 0; $k -lt $chunk.Count; $k++) {
      $issue = $d."i$k".issue
      if (-not $issue) { continue }
      $it = $issue.projectItems.nodes | Where-Object { $_.project.id -eq $ProjectId } | Select-Object -First 1
      if ($it) { [pscustomobject]@{ item = $it; content = $issue } }
    }
  }
}

function Get-OpenPrHeads([string]$RepoName) {
  $o, $r = $RepoName -split '/', 2
  $q = 'query($o: String!, $r: String!, $cursor: String) { repository(owner: $o, name: $r) { pullRequests(states: OPEN, first: 100, after: $cursor) { pageInfo { hasNextPage endCursor } nodes { headRefName } } } }'
  $heads = @(); $cursor = $null
  do {
    $page = (Invoke-Graphql $q @{ o = $o; r = $r; cursor = $cursor }).repository.pullRequests
    $heads += @($page.nodes | ForEach-Object { $_.headRefName })
    $more = [bool]($page.pageInfo -and $page.pageInfo.hasNextPage)
    $cursor = if ($more) { $page.pageInfo.endCursor } else { $null }
  } while ($more)
  $heads
}

# Live state in the -StateFile shape, or $null when the project has no field Needs.
function Get-NeedsState {
  param([string]$Owner, [int]$Number, [string]$Repo, [string[]]$Issue, [bool]$IncludeParents, [bool]$IncludeDependents = $false)
  $script:WantBlocking = $IncludeDependents
  $p = (Invoke-Graphql $script:FieldsQuery @{ login = $Owner; n = $Number }).repositoryOwner.projectV2
  if (-not $p) { throw "Project $Owner/$Number not found (or scope 'project' missing: gh auth refresh -s project)." }
  $field = @($p.fields.nodes) | Where-Object { $_.PSObject.Properties['options'] -and $_.name -eq 'Needs' } | Select-Object -First 1
  if (-not $field) { return $null }
  $options = [ordered]@{}
  foreach ($o in $field.options) { $options[$o.name] = $o.id }

  $dependents = @{}
  $refs = @(@($Issue | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) | ForEach-Object {
      $defaultRepo = if ($Repo) { $Repo } else { $null }
      ConvertTo-IssueRef $_ $defaultRepo })
  if ($refs.Count -eq 0) {
    $nodes = @(Get-ProjectItemNodes -ProjectId $p.id)
  } else {
    foreach ($r in $refs) { if (-not $r.repo) { throw "Issue #$($r.number) needs -Repo or the form owner/repo#n for a live run." } }
    $nodes = @(Get-IssueNodes -ProjectId $p.id -Refs $refs)
    $selNodes = @($nodes)
    if ($IncludeParents) {
      $have = @($nodes | ForEach-Object { "$($_.content.repository.nameWithOwner)#$($_.content.number)" })
      $parents = @($nodes | Where-Object { $_.content.parent } | ForEach-Object {
          [pscustomobject]@{ repo = $_.content.parent.repository.nameWithOwner; number = $_.content.parent.number } } |
          Where-Object { $have -notcontains "$($_.repo)#$($_.number)" } | Sort-Object repo, number -Unique)
      if ($parents.Count -gt 0) { $nodes += @(Get-IssueNodes -ProjectId $p.id -Refs $parents) }
    }
    if ($IncludeDependents) {
      # open issues the selected ones block; refs already fetched (selected, parents) drop out, issues outside the project too
      foreach ($n in $selNodes) {
        $key = "$($n.content.repository.nameWithOwner)#$($n.content.number)"
        $list = if ($script:RestBlocking) { @(Invoke-Gh -GhArgs @('api', "repos/$($n.content.repository.nameWithOwner)/issues/$($n.content.number)/dependencies/blocking?per_page=100") |
              ForEach-Object { [pscustomobject]@{ number = $_.number; state = "$($_.state)".ToUpper(); repository = [pscustomobject]@{ nameWithOwner = $(if (Get-Prop $_ 'repository_url') { "$($_.repository_url)" -replace '^.*/repos/', '' } else { $n.content.repository.nameWithOwner }) } } }) }
        else { @(Get-Prop (Get-Prop $n.content 'blocking') 'nodes') }
        $dependents[$key] = @($list | Where-Object { $_ -and $_.state -eq 'OPEN' } | ForEach-Object { [ordered]@{ repo = $_.repository.nameWithOwner; number = $_.number } })
      }
      $have = @($nodes | ForEach-Object { "$($_.content.repository.nameWithOwner)#$($_.content.number)" })
      $deps = @($dependents.Values | ForEach-Object { $_ } | ForEach-Object { [pscustomobject]$_ } |
          Where-Object { $have -notcontains "$($_.repo)#$($_.number)" } | Sort-Object repo, number -Unique)
      if ($deps.Count -gt 0) { $nodes += @(Get-IssueNodes -ProjectId $p.id -Refs $deps) }
    }
  }
  $items = @($nodes | ForEach-Object { ConvertTo-NeedsItem $_.content $_.item $p.id })
  foreach ($it in $items) { $k = "$($it.repo)#$($it.number)"; if ($dependents.ContainsKey($k)) { $it['blocking'] = @($dependents[$k]) } }
  $heads = @{}
  foreach ($r in @($items | Where-Object { $_.state -eq 'OPEN' } | ForEach-Object { $_.repo } | Sort-Object -Unique)) { $heads[$r] = @(Get-OpenPrHeads $r) }
  foreach ($it in $items) {
    if ($it.state -ne 'OPEN') { continue }
    $nr = $it.number
    $it.prHeads = @($it.prHeads) + @($heads[$it.repo] | Where-Object { $_ -match "(^|/)$nr-" })
    if ($script:RestBlocked) {
      $links = @(Invoke-Gh -GhArgs @('api', "repos/$($it.repo)/issues/$nr/dependencies/blocked_by?per_page=100"))
      $it.blockedByOpen = @($links | Where-Object { Test-BlockerUnresolved $_ }).Count
    }
  }
  [pscustomobject][ordered]@{ owner = $Owner; number = $Number; projectId = $p.id; needsField = [ordered]@{ id = $field.id; options = $options }
    # objects (not dictionaries) like a -StateFile, so Get-Prop sees every property
    items = @(ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject @($items) -Depth 8)) }
}

function Set-NeedsValue($State, $Action) {
  $field = $State.needsField
  if ($Action.to) {
    $opt = $field.options[$Action.to]
    if (-not $opt) { throw "Option '$($Action.to)' not found in field Needs." }
    $q = 'mutation($i: UpdateProjectV2ItemFieldValueInput!) { updateProjectV2ItemFieldValue(input: $i) { clientMutationId } }'
    $v = @{ i = @{ projectId = $State.projectId; itemId = $Action.item; fieldId = $field.id; value = @{ singleSelectOptionId = $opt } } }
  } else {
    $q = 'mutation($i: ClearProjectV2ItemFieldValueInput!) { clearProjectV2ItemFieldValue(input: $i) { clientMutationId } }'
    $v = @{ i = @{ projectId = $State.projectId; itemId = $Action.item; fieldId = $field.id } }
  }
  # Bulk edits hit GitHub's secondary rate limit now and then: retry with backoff.
  $backoff = [double]($env:SYNC_PROJECT_NEEDS_BACKOFF ?? 15)
  foreach ($try in 1..4) {
    try { Invoke-Graphql $q $v | Out-Null; return } catch {
      if ($try -eq 4) { throw "Needs update failed for $($Action.issue): $_" }
      Start-Sleep -Seconds ($backoff * $try)
    }
  }
}

if ($MyInvocation.InvocationName -eq '.') { return }

if ($Repo -and $Repo -notmatch '^[^/\s]+/[^/\s]+$') { throw "Invalid -Repo '$Repo'. $script:Usage" }
if (($Owner -and -not $Number) -or ($Number -and -not $Owner)) { throw "-Owner and -Number go together. $script:Usage" }

$root = (& git rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $root) { $root = (Get-Location).Path }
$state = $null
if ($StateFile) {
  if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) { throw "State file not found: $StateFile" }
  $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
}
$ref = Resolve-ProjectRef -Owner $Owner -Number $Number -Root "$root"
if (-not $ref -and $state -and (Get-Prop $state 'owner') -and (Get-Prop $state 'number')) {
  $ref = @{ owner = "$($state.owner)"; number = [int]$state.number }
}
# Live run with bare issue numbers and no -Repo (loop and queue callers): the repository of the current checkout (origin remote).
if (-not $state -and -not $Repo -and @($Issue | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^#?\d+$' }).Count -gt 0) {
  $url = "$(& git -C $root config --get remote.origin.url 2>$null)".Trim()
  if ($url -match 'github\.com[:/]([^/\s]+/[^/\s]+?)(\.git)?/?\z') { $Repo = $Matches[1] }
}
if ($SetStatus) {
  $one = @(@($Issue | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }))
  if ($one.Count -ne 1) { throw "-SetStatus needs exactly one -Issue. $script:Usage" }
  if (-not $ref) { exit 0 }
  $r = ConvertTo-IssueRef $one[0] $(if ($Repo) { $Repo } else { $null })
  if ($state) {
    $it = @(Get-Prop $state 'items' | Where-Object { $_ -and (Test-RefMatch $r $_) }) | Select-Object -First 1
    if (-not $it) { Write-Output "Status not set: #$($r.number) is not in the project"; exit 0 }
    $act = [ordered]@{ issue = "$($it.repo)#$($it.number)"; item = Get-Prop $it 'itemId'; field = 'Status'; to = $SetStatus }
    if ($Json) { [ordered]@{ project = $ref; actions = @($act) } | ConvertTo-Json -Depth 6 } else { Write-Output "$($act.issue): Status -> $SetStatus" }
    exit 0
  }
  if (-not $r.repo) { throw "Issue #$($r.number) needs -Repo or the form owner/repo#n. $script:Usage" }
  try {
    $p = (Invoke-Graphql $script:FieldsQuery @{ login = $ref.owner; n = $ref.number }).repositoryOwner.projectV2
    if (-not $p) { throw "Project $($ref.owner)/$($ref.number) not found." }
    $field = @($p.fields.nodes) | Where-Object { $_.PSObject.Properties['options'] -and $_.name -eq 'Status' } | Select-Object -First 1
    $opt = if ($field) { @($field.options) | Where-Object { $_.name -eq $SetStatus } | Select-Object -First 1 }
    if (-not $opt) { Write-Output "Status not set: option '$SetStatus' missing in the project"; exit 0 }
    $node = @(Get-IssueNodes -ProjectId $p.id -Refs @($r)) | Select-Object -First 1
    if (-not $node) { Write-Output "Status not set: #$($r.number) is not in the project"; exit 0 }
    if ($DryRun) { Write-Output "#$($r.number): Status -> $SetStatus (dry run)"; exit 0 }
    $q = 'mutation($i: UpdateProjectV2ItemFieldValueInput!) { updateProjectV2ItemFieldValue(input: $i) { clientMutationId } }'
    Invoke-Graphql $q @{ i = @{ projectId = $p.id; itemId = $node.item.id; fieldId = $field.id; value = @{ singleSelectOptionId = $opt.id } } } | Out-Null
  } catch { Write-Output "Status not set: $_"; exit 1 }
  Write-Output "#$($r.number): Status -> $SetStatus"
  exit 0
}
if (-not $ref) { Write-Output 'Needs sync skipped: no project configured'; exit 0 }
$live = -not $state
if ($live) {
  try {
    $state = Get-NeedsState -Owner $ref.owner -Number $ref.number -Repo $Repo -Issue $Issue -IncludeParents ([bool]$IncludeParents) -IncludeDependents ([bool]$IncludeDependents)
  } catch { Write-Output "Needs sync failed: $_"; exit 1 }
  if (-not $state) { Write-Output 'Needs sync skipped: field Needs missing (run Set-ProjectStandard.ps1, #596)'; exit 0 }
}

$plan = Get-NeedsPlan -State $state -Repo $Repo -Issue $Issue -IncludeParents ([bool]$IncludeParents) -IncludeDependents ([bool]$IncludeDependents)
if ($Json) {
  [ordered]@{ project = [ordered]@{ owner = $ref.owner; number = $ref.number }; actions = $plan.actions; skipped = $plan.skipped } |
    ConvertTo-Json -Depth 6
  if (-not $live -or $DryRun) { exit 0 }
}
if ($live) {
  $fmt = { param($a) "#{0}: {1} -> {2}" -f ($a.issue -replace '^.*#', ''), $(if ($a.from) { $a.from } else { '(none)' }), $(if ($a.to) { $a.to } else { '(clear)' }) }
  $inScope = @($state.items).Count - @($plan.skipped).Count
  try {
    foreach ($a in $plan.actions) {
      if (-not $Json) { Write-Output (& $fmt $a) }
      if (-not $DryRun) { Set-NeedsValue $state $a }
    }
  } catch { Write-Output "Needs sync failed: $_"; exit 1 }
  if (-not $Json) { Write-Output ("Needs: {0} {1}, {2} unchanged{3}" -f @($plan.actions).Count, $(if ($DryRun) { 'to change' } else { 'changed' }), ($inScope - @($plan.actions).Count), $(if ($DryRun) { ' (dry run)' } else { '' })) }
  exit 0
}
if ($plan.actions.Count -eq 0) { Write-Output "Needs in sync ($($ref.owner)/$($ref.number)): no changes."; exit 0 }
foreach ($a in $plan.actions) { Write-Output ("{0}: Needs {1} -> {2}" -f $a.issue, $(if ($a.from) { $a.from } else { '(none)' }), $(if ($a.to) { $a.to } else { '(clear)' })) }
