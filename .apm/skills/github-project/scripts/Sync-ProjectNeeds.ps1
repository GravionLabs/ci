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
  Reads are REST only (no GraphQL, so no GraphQL budget): GET /users|orgs/<owner>/projectsV2/<n>, /fields and /items?fields[]=<id>&q=repo:<o/r>
  (Status, Level, Needs, Parent issue, Linked pull requests; paginated by gh --paginate --slurp), then per open item in scope only what its
  summaries announce: /issues/<n>/sub_issues, /dependencies/blocked_by, /dependencies/blocking (-IncludeDependents), /issues/<n> (issue type of a
  legacy issue without Level and title prefix), and /pulls?state=open per repository. The issue type is not part of a project item; sub-issue levels
  come from the sub-issue's type / title prefix or the Level of items already read. A blocker blocks while open and not merged: its labels come from
  the blocker, its Status from the items of its repository (read only when needed).
  Live mode (no -StateFile): with -Repo only that repository's items are read (q=repo:), with -Issue only the repositories of the listed issues
  (plus parents / dependents), then applies one REST update (PATCH .../projectsV2/<n>/items/<id>, value null for a clear) per changed
  item, 4 tries with backoff (15 s * try, env SYNC_PROJECT_NEEDS_BACKOFF overrides the 15). Prints '#<nr>: <from> -> <to>'
  per change and 'Needs: <k> changed, <m> unchanged'. No Needs field: 'Needs sync skipped: field Needs missing ...', exit 0.
  Exit 1 on an unrecoverable error (one line 'Needs sync failed: ...').
  -StateFile never calls gh.
  State file: {owner, number, projectId, needsField:{id, options:{name:id}},
               items:[{itemId, repo, number, state, level, labels[], status, needs, blockedByOpen, subIssueLevels[], prHeads[], parent}]}
  parent is a number (same repository), 'owner/repo#n' or {repo, number}. Optional blocking: [{repo, number}] lists the
  issues the item blocks (used by -IncludeDependents).
.PARAMETER Owner            User or organization login of the project (wins over the lookup).
.PARAMETER Number           Project number (wins over the lookup).
.PARAMETER Repo             Only items of this repository (owner/repo). Live without -Issue: reads only that repository's issues (repository.issues), not the whole project.
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

# ---- reads: REST only (no GraphQL, no GraphQL budget) -----------------------------------------------------------
# Project: GET /{users|orgs}/{owner}/projectsV2/{n}, /fields, /items?fields[]=<id>&q=repo:<o/r> (paginated by gh --paginate --slurp).
# Issues: the content of the project items (state, labels, issue_dependencies_summary, sub_issues_summary) plus the project fields
# Status/Level/Needs/Parent issue/Linked pull requests; /issues/{n}/sub_issues, /dependencies/blocked_by, /dependencies/blocking,
# /issues/{n} (issue type) only for the open issues in scope that need them; /pulls?state=open for the PR heads.
# Every datum has a REST equivalent, so no GraphQL call is left in this script (actions/add-to-project stays GraphQL; it is an external action).

# All pages of a REST list as one flat array.
function Invoke-GhList([string]$Path) {
  $pages = Invoke-Gh -GhArgs @('api', '--paginate', '--slurp', $Path)
  @($pages | ForEach-Object { $_ })
}

function Get-RepoOfUrl($Url) { if ($Url) { "$Url" -replace '^.*/repos/', '' } else { $null } }
function Get-RepoOrDefault($Obj, [string]$Default) { $r = Get-RepoOfUrl (Get-Prop $Obj 'repository_url'); if ($r) { $r } else { $Default } }
function Get-ItemNodeId($Item) { $n = Get-Prop $Item 'node_id'; if ($n) { "$n" } else { "$($Item.id)" } }
function Get-ContentRepo($Content) {
  $r = Get-Prop (Get-Prop $Content 'repository') 'full_name'
  if ($r) { "$r" } else { Get-RepoOfUrl (Get-Prop $Content 'repository_url') }
}
# Select option names are strings or {raw, html}.
function ConvertTo-OptionText($Value) {
  if ($null -eq $Value) { return $null }
  if ($Value -is [string]) { return $Value }
  $raw = Get-Prop $Value 'raw'
  if ($null -ne $raw) { "$raw" } else { $null }
}
function Get-SelectValue($Item, $FieldId) {
  if (-not $FieldId) { return $null }
  $f = @(Get-Prop $Item 'fields') | Where-Object { $_ -and "$($_.id)" -eq "$FieldId" } | Select-Object -First 1
  if (-not $f) { return $null }
  ConvertTo-OptionText (Get-Prop (Get-Prop $f 'value') 'name')
}
function Get-FieldValue($Item, $FieldId) {
  if (-not $FieldId) { return $null }
  $f = @(Get-Prop $Item 'fields') | Where-Object { $_ -and "$($_.id)" -eq "$FieldId" } | Select-Object -First 1
  if ($f) { Get-Prop $f 'value' } else { $null }
}

# Owner kind (users|orgs path segment) and the project itself.
function Get-ProjectContext([string]$Owner, [int]$Number) {
  $kind = try { "$((Invoke-Gh -GhArgs @('api', "users/$Owner")).type)" } catch { throw "Project $Owner/$Number not found (or scope 'project' missing: gh auth refresh -s project)." }
  $seg = if ($kind -eq 'Organization') { 'orgs' } else { 'users' }
  try { $p = Invoke-Gh -GhArgs @('api', "$seg/$Owner/projectsV2/$Number") } catch { throw "Project $Owner/$Number not found (or scope 'project' missing: gh auth refresh -s project)." }
  if (-not $p -or -not (Get-Prop $p 'id')) { throw "Project $Owner/$Number not found (or scope 'project' missing: gh auth refresh -s project)." }
  [pscustomobject]@{ owner = $Owner; number = $Number; seg = $seg; ownerKind = $(if ($kind -eq 'Organization') { 'Organization' } else { 'User' }) }
}

function Get-ProjectFields($Ctx) { @(Invoke-GhList "$($Ctx.seg)/$($Ctx.owner)/projectsV2/$($Ctx.number)/fields?per_page=100") }
function Get-SelectField($Fields, [string]$Name) {
  @($Fields) | Where-Object { $_ -and $_.name -eq $Name -and (Get-Prop $_ 'data_type') -eq 'single_select' } | Select-Object -First 1
}
function Get-FieldOption($Field, [string]$Name) {
  @($Field.options) | Where-Object { $_ -and (ConvertTo-OptionText $_.name) -eq $Name } | Select-Object -First 1
}

# Project items that are issues, optionally only those of one repository (q=repo:owner/repo). Cached per run in $script:Seen
# ("repo#n" -> REST item); $script:ReadRepos lists the repositories already read, $script:ReadAll the whole project.
$script:Seen = [ordered]@{}
$script:ReadRepos = @{}
$script:ReadAll = $false
function Read-ProjectItems($Ctx, $FieldIds, [string]$Repo) {
  if ($script:ReadAll -or ($Repo -and $script:ReadRepos.ContainsKey($Repo))) { return }
  $query = 'per_page=100' + (@($FieldIds.PSObject.Properties.Value | Where-Object { $_ } | ForEach-Object { "&fields[]=$_" }) -join '') + $(if ($Repo) { "&q=repo:$Repo" } else { '' })
  foreach ($it in @(Invoke-GhList "$($Ctx.seg)/$($Ctx.owner)/projectsV2/$($Ctx.number)/items?$query")) {
    if ((Get-Prop $it 'content_type') -ne 'Issue') { continue }
    $r = Get-ContentRepo $it.content
    if ($Repo -and $r -ne $Repo) { continue }
    $script:Seen["$r#$($it.content.number)"] = $it
  }
  if ($Repo) { $script:ReadRepos[$Repo] = $true } else { $script:ReadAll = $true }
}

function Get-LevelOf($ItemLevel, $IssueType, [string]$Title) {
  $known = 'Epic', 'Feature', 'PBI', 'Task', 'Bug'
  if ($ItemLevel -and $known -contains $ItemLevel) { return $ItemLevel }
  if ($IssueType -and $known -contains $IssueType) { return $IssueType }
  if ($Title -match '^\[(Epic|Feature|PBI|Task|Bug)\]') { return $Matches[1] }
  $null
}

function Get-LabelNames($Labels) { @(@($Labels) | Where-Object { $_ } | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.name } }) }

# Labels and Status of an issue that is (or may be) an item of the project; reads that repository's items when needed.
function Get-KnownInfo($Ctx, $FieldIds, [string]$Key) {
  if (-not $script:Seen.Contains($Key)) { Read-ProjectItems $Ctx $FieldIds ($Key -replace '#\d+$', '') }
  $it = $script:Seen[$Key]
  if (-not $it) { return $null }
  @{ labels = @(Get-LabelNames $it.content.labels); status = (Get-SelectValue $it $FieldIds.status) }
}

# REST project item (+ the lists fetched for it) -> state item. prHeads are filled by the caller.
function ConvertTo-NeedsItem($Ctx, $FieldIds, $Item) {
  $c = $Item.content
  $repo = Get-ContentRepo $c
  $nr = [int]$c.number
  $state = "$($c.state)".ToUpperInvariant()
  $title = "$(Get-Prop $c 'title')"
  $level = Get-LevelOf (Get-SelectValue $Item $FieldIds.level) (Get-Prop (Get-Prop $c 'type') 'name') $title
  $subs = [System.Collections.Generic.List[string]]::new()
  $blocked = 0
  $heads = [System.Collections.Generic.List[string]]::new()
  if ($state -eq 'OPEN') {
    if (-not $level) {
      # the issue type is not part of a project item: one issue read for a legacy issue without Level and title prefix
      $level = Get-LevelOf $null (Get-Prop (Get-Prop (Invoke-Gh -GhArgs @('api', "repos/$repo/issues/$nr")) 'type') 'name') $title
    }
    $sum = Get-Prop $c 'sub_issues_summary'
    if (-not $sum -or [int](Get-Prop $sum 'total') -gt 0) {
      foreach ($s in @(Invoke-GhList "repos/$repo/issues/$nr/sub_issues?per_page=100")) {
        $sr = Get-RepoOfUrl (Get-Prop $s 'repository_url')
        $lv = Get-LevelOf $null (Get-Prop (Get-Prop $s 'type') 'name') "$(Get-Prop $s 'title')"
        if (-not $lv) { $known = $script:Seen["$(if ($sr) { $sr } else { $repo })#$(Get-Prop $s 'number')"]; if ($known) { $lv = Get-SelectValue $known $FieldIds.level } }
        if ($lv) { $subs.Add($lv) }
      }
    }
    # a blocker blocks only while open and not merged (label merged or Status In release in this project)
    $dep = Get-Prop $c 'issue_dependencies_summary'
    if (-not $dep -or [int](Get-Prop $dep 'blocked_by') -gt 0) {
      foreach ($b in @(Invoke-GhList "repos/$repo/issues/$nr/dependencies/blocked_by?per_page=100")) {
        $br = Get-RepoOfUrl (Get-Prop $b 'repository_url')
        $labels = @(Get-LabelNames (Get-Prop $b 'labels'))
        $status = $null
        if ("$($b.state)".ToUpperInvariant() -eq 'OPEN' -and @($labels | ForEach-Object { "$_".ToLowerInvariant() }) -notcontains 'merged') {
          $info = Get-KnownInfo $Ctx $FieldIds "$(if ($br) { $br } else { $repo })#$($b.number)"
          if ($info) { $status = $info.status; $labels = @($labels) + @($info.labels) }
        }
        if (Test-BlockerUnresolved ([pscustomobject]@{ state = $b.state; labels = $labels; status = $status })) { $blocked++ }
      }
    }
    # a linked open PR counts as work in progress whatever its branch is called
    foreach ($pr in @(Get-FieldValue $Item $FieldIds.linked | Where-Object { $_ -and "$(Get-Prop $_ 'state')".ToLowerInvariant() -eq 'open' })) {
      $ref = "$(Get-Prop (Get-Prop $pr 'head') 'ref')"
      $heads.Add($(if ($ref -match "(^|/)$nr-") { $ref } else { "$nr-linked-pr" }))
    }
  }
  $pv = Get-FieldValue $Item $FieldIds.parent
  $parent = if ($pv -and (Get-Prop $pv 'number')) { [ordered]@{ repo = $(Get-RepoOrDefault $pv $repo); number = [int]$pv.number } } else { $null }
  [ordered]@{ itemId = $(Get-ItemNodeId $Item); itemDatabaseId = $Item.id; repo = $repo; number = $nr; state = $state
    level = $level; labels = @(Get-LabelNames $c.labels); status = (Get-SelectValue $Item $FieldIds.status); needs = (Get-SelectValue $Item $FieldIds.needs)
    blockedByOpen = $blocked; subIssueLevels = @($subs); prHeads = @($heads); parent = $parent }
}

function Get-OpenPrHeads([string]$RepoName) {
  @(@(Invoke-GhList "repos/$RepoName/pulls?state=open&per_page=100") | ForEach-Object { $_.head.ref })
}

# Live state in the -StateFile shape, or $null when the project has no field Needs.
function Get-NeedsState {
  param([string]$Owner, [int]$Number, [string]$Repo, [string[]]$Issue, [bool]$IncludeParents, [bool]$IncludeDependents = $false)
  $script:Seen = [ordered]@{}; $script:ReadRepos = @{}; $script:ReadAll = $false
  $ctx = Get-ProjectContext $Owner $Number
  $fields = Get-ProjectFields $ctx
  $field = Get-SelectField $fields 'Needs'
  if (-not $field) { return $null }
  $options = [ordered]@{}
  foreach ($o in $field.options) { $options[(ConvertTo-OptionText $o.name)] = $o.id }
  $ids = @{ needs = $field.id
    status = (Get-Prop (Get-SelectField $fields 'Status') 'id'); level = (Get-Prop (Get-SelectField $fields 'Level') 'id')
    parent = (Get-Prop (@($fields) | Where-Object { $_ -and (Get-Prop $_ 'data_type') -eq 'parent_issue' } | Select-Object -First 1) 'id')
    linked = (Get-Prop (@($fields) | Where-Object { $_ -and (Get-Prop $_ 'data_type') -eq 'linked_pull_requests' } | Select-Object -First 1) 'id') }
  $fieldIds = [pscustomobject]$ids

  $dependents = @{}
  $refs = @(@($Issue | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) | ForEach-Object {
      $defaultRepo = if ($Repo) { $Repo } else { $null }
      ConvertTo-IssueRef $_ $defaultRepo })
  if ($refs.Count -eq 0) {
    if ($Repo) { Read-ProjectItems $ctx $fieldIds $Repo; $scope = @($script:Seen.Values | Where-Object { (Get-ContentRepo $_.content) -eq $Repo }) }
    else { Read-ProjectItems $ctx $fieldIds ''; $scope = @($script:Seen.Values) }
  } else {
    foreach ($r in $refs) { if (-not $r.repo) { throw "Issue #$($r.number) needs -Repo or the form owner/repo#n for a live run." } }
    foreach ($rp in @($refs | ForEach-Object { $_.repo } | Sort-Object -Unique)) { Read-ProjectItems $ctx $fieldIds $rp }
    $scope = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $refs) { $it = $script:Seen["$($r.repo)#$($r.number)"]; if ($it -and -not $scope.Contains($it)) { $scope.Add($it) } }
    $direct = @($scope)
    if ($IncludeParents) {
      foreach ($it in $direct) {
        $pv = Get-FieldValue $it $fieldIds.parent
        if (-not ($pv -and (Get-Prop $pv 'number'))) { continue }
        $pr = Get-RepoOrDefault $pv (Get-ContentRepo $it.content)
        Read-ProjectItems $ctx $fieldIds $pr
        $p = $script:Seen["$pr#$($pv.number)"]
        if ($p -and -not $scope.Contains($p)) { $scope.Add($p) }
      }
    }
    if ($IncludeDependents) {
      # open issues the selected ones block (blocking links, also across repositories); issues outside the project drop out
      foreach ($it in $direct) {
        $repoOf = Get-ContentRepo $it.content
        $sum = Get-Prop $it.content 'issue_dependencies_summary'
        $list = if (-not $sum -or [int](Get-Prop $sum 'total_blocking') -gt 0) { @(Invoke-GhList "repos/$repoOf/issues/$($it.content.number)/dependencies/blocking?per_page=100") } else { @() }
        $dependents["$repoOf#$($it.content.number)"] = @($list | Where-Object { $_ -and "$($_.state)".ToUpperInvariant() -eq 'OPEN' } |
            ForEach-Object { [ordered]@{ repo = $(Get-RepoOrDefault $_ $repoOf); number = $_.number } })
      }
      foreach ($d in @($dependents.Values | ForEach-Object { $_ })) {
        Read-ProjectItems $ctx $fieldIds $d.repo
        $di = $script:Seen["$($d.repo)#$($d.number)"]
        if ($di -and -not $scope.Contains($di)) { $scope.Add($di) }
      }
    }
    $scope = @($scope)
  }
  $items = @($scope | ForEach-Object { ConvertTo-NeedsItem $ctx $fieldIds $_ })
  foreach ($it in $items) { $k = "$($it.repo)#$($it.number)"; if ($dependents.ContainsKey($k)) { $it['blocking'] = @($dependents[$k]) } }
  $heads = @{}
  foreach ($r in @($items | Where-Object { $_.state -eq 'OPEN' } | ForEach-Object { $_.repo } | Sort-Object -Unique)) { $heads[$r] = @(Get-OpenPrHeads $r) }
  foreach ($it in $items) {
    if ($it.state -ne 'OPEN') { continue }
    $nr = $it.number
    $it.prHeads = @($it.prHeads) + @($heads[$it.repo] | Where-Object { $_ -match "(^|/)$nr-" })
  }
  [pscustomobject][ordered]@{ owner = $Owner; number = $Number; ownerKind = $ctx.ownerKind; needsField = [ordered]@{ id = $field.id; databaseId = $field.id; options = $options }
    # objects (not dictionaries) like a -StateFile, so Get-Prop sees every property
    items = @(ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject @($items) -Depth 8)) }
}

# Writes go through the REST endpoint PATCH /{users|orgs}/{owner}/projectsV2/{number}/items/{item_id} (not GraphQL), so they
# do not use the GraphQL budget. It takes the numeric ids that the REST reads deliver (item id, field id).
# $Value: option id of a single select field, or $null to clear the field.
function Set-ProjectItemField([string]$OwnerKind, [string]$Owner, [int]$Number, $ItemDatabaseId, $FieldDatabaseId, $Value) {
  if (-not $ItemDatabaseId -or -not $FieldDatabaseId) { throw 'the project item or field has no databaseId (needed for the REST projectsV2 update)' }
  $seg = if ($OwnerKind -eq 'Organization') { 'orgs' } else { 'users' }
  Invoke-Gh -GhArgs @('api', '-X', 'PATCH', "$seg/$Owner/projectsV2/$Number/items/$ItemDatabaseId") `
    -Body @{ fields = @(@{ id = [long]$FieldDatabaseId; value = $Value }) } | Out-Null
}

function Set-NeedsValue($State, $Action) {
  $field = $State.needsField
  $opt = $null
  if ($Action.to) {
    $opt = $field.options[$Action.to]
    if (-not $opt) { throw "Option '$($Action.to)' not found in field Needs." }
  }
  $item = @($State.items | Where-Object { (Get-Prop $_ 'itemId') -eq $Action.item }) | Select-Object -First 1
  $itemDb = if ($item) { Get-Prop $item 'itemDatabaseId' } else { $null }
  # Bulk edits hit GitHub's secondary rate limit now and then: retry with backoff.
  $backoff = [double]($env:SYNC_PROJECT_NEEDS_BACKOFF ?? 15)
  foreach ($try in 1..4) {
    try { Set-ProjectItemField (Get-Prop $State 'ownerKind') $State.owner $State.number $itemDb $field.databaseId $opt; return } catch {
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
    $ctx = Get-ProjectContext $ref.owner $ref.number
    $field = Get-SelectField (Get-ProjectFields $ctx) 'Status'
    $opt = if ($field) { Get-FieldOption $field $SetStatus }
    if (-not $opt) { Write-Output "Status not set: option '$SetStatus' missing in the project"; exit 0 }
    Read-ProjectItems $ctx ([pscustomobject]@{ status = $field.id }) $r.repo
    $node = $script:Seen["$($r.repo)#$($r.number)"]
    if (-not $node) { Write-Output "Status not set: #$($r.number) is not in the project"; exit 0 }
    if ($DryRun) { Write-Output "#$($r.number): Status -> $SetStatus (dry run)"; exit 0 }
    Set-ProjectItemField $ctx.ownerKind $ref.owner $ref.number $node.id $field.id $opt.id
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
