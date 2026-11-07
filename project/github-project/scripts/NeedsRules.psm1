#Requires -Version 7.0
<#
.SYNOPSIS
  Shared Needs rule of the project field Needs: one rule function and a read-only issue reader.
.DESCRIPTION
  Imported by Sync-ProjectNeeds.ps1 (writes the field), and the queue dry run. Get-NeedsValue is the only implementation of the rule; callers never restate it.
  Test-BlockerUnresolved is the one definition of a blocking blocker: a blocker blocks while it is open; a closed blocker counts as resolved.
  Migration (GravionLabs/ci#182): an open blocker that still carries the label merged counts as resolved until the label is gone everywhere.
  Get-IssueNeedsItem reads an issue with gh GET calls only (never a mutation) and returns an item in the Sync-ProjectNeeds -StateFile shape;
  the project Status is not readable that way, so a read item has status $null.
#>
Set-StrictMode -Version Latest

# Property of an object or hashtable-like value, $null when absent (StrictMode safe).
function Get-Prop($Obj, [string]$Name) {
  if ($null -eq $Obj) { return $null }
  $p = $Obj.PSObject.Properties[$Name]
  if ($p) { $p.Value } else { $null }
}

# Pure rule function: Needs option name, or $null to clear the field. First match wins:
# closed -> clear; label needs-decision -> Decision; needs-review -> Review; unresolved blocked-by (open) -> Blocked;
# open PR head (^|/)<nr>- or Status 'In Progress' -> In progress;
# Epic without Feature, Feature without PBI, PBI-level without Task sub-issues and without label planned -> Planning;
# else Ready for PBI-level items and clear for Epics and Features.
# True when a blocker still blocks: state OPEN (any case). A blocker without state counts as resolved.
# blockedByOpen of an item counts the unresolved blockers. The project Status of a blocker plays no part.
# Migration shim (GravionLabs/ci#182): an open blocker with the label merged (strings or {name}) was delivered to a release branch
# before issues closed on merge; it counts as resolved. Remove the shim once no open issue carries merged.
function Test-BlockerUnresolved($Blocker) {
  if ("$(Get-Prop $Blocker 'state')".ToUpperInvariant() -ne 'OPEN') { return $false }
  $labels = @(Get-Prop $Blocker 'labels' | ForEach-Object { "$(if ($_ -is [string]) { $_ } else { Get-Prop $_ 'name' })".ToLowerInvariant() })
  $labels -notcontains 'merged'
}

function Get-NeedsValue($Item) {
  if ("$(Get-Prop $Item 'state')".ToUpperInvariant() -eq 'CLOSED') { return $null }
  $labels = @(Get-Prop $Item 'labels' | ForEach-Object { "$_".ToLowerInvariant() })
  $status = "$(Get-Prop $Item 'status')"
  if ($labels -contains 'needs-decision') { return 'Decision' }
  if ($labels -contains 'needs-review') { return 'Review' }
  $blocked = Get-Prop $Item 'blockedByOpen'
  if ($blocked -is [bool] ? $blocked : ([int]("0$blocked") -gt 0)) { return 'Blocked' }
  $nr = [int](Get-Prop $Item 'number')
  $heads = @(Get-Prop $Item 'prHeads' | Where-Object { $_ })
  if ($status -eq 'In Progress' -or @($heads | Where-Object { "$_" -match "(^|/)$nr-" }).Count -gt 0) { return 'In progress' }
  $level = "$(Get-Prop $Item 'level')"
  $subs = @(Get-Prop $Item 'subIssueLevels' | ForEach-Object { "$_" })
  switch ($level) {
    'Epic' { if ($subs -notcontains 'Feature') { return 'Planning' }; return $null }
    'Feature' { if ($subs -notcontains 'PBI') { return 'Planning' }; return $null }
    default { if ($subs -notcontains 'Task' -and $labels -notcontains 'planned') { return 'Planning' }; return 'Ready' }
  }
}

function Get-IssueLevelName($TypeName, [string]$Title) {
  $known = 'Epic', 'Feature', 'PBI', 'Task', 'Bug'
  if ($TypeName -and $known -contains "$TypeName") { return "$TypeName" }
  if ($Title -match '^\[(Epic|Feature|PBI|Task|Bug)\]') { return $Matches[1] }
  $null
}

function Invoke-GhGet([string]$Endpoint) {
  $out = & gh api --method GET $Endpoint 2>&1
  if ($LASTEXITCODE -ne 0) { throw "gh api $Endpoint failed: $out" }
  ($out | Out-String) | ConvertFrom-Json -Depth 20
}

# Read-only: items (Sync-ProjectNeeds -StateFile shape, no project fields) for the given issue numbers of the current repository.
# Every call is a GET (gh api --method GET); throws when gh fails.
function Get-IssueNeedsItem {
  [CmdletBinding()]
  param([Parameter(Mandatory)][int[]]$Number)
  if (-not (Get-Command gh -CommandType Application -ErrorAction SilentlyContinue)) { throw "'gh' not found on PATH." }
  $heads = @(@(Invoke-GhGet 'repos/{owner}/{repo}/pulls?state=open&per_page=100') | ForEach-Object { $_.head.ref })
  foreach ($n in $Number) {
    $i = Invoke-GhGet "repos/{owner}/{repo}/issues/$n"
    $subs = @(Invoke-GhGet "repos/{owner}/{repo}/issues/$n/sub_issues?per_page=100")
    $blockers = @(Invoke-GhGet "repos/{owner}/{repo}/issues/$n/dependencies/blocked_by?per_page=100")
    [pscustomobject][ordered]@{
      itemId = $null; repo = $null; number = $n; state = "$($i.state)".ToUpperInvariant()
      level = Get-IssueLevelName (Get-Prop (Get-Prop $i 'type') 'name') "$($i.title)"
      labels = @($i.labels | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.name } })
      status = $null; needs = $null
      blockedByOpen = @($blockers | Where-Object { Test-BlockerUnresolved $_ }).Count
      subIssueLevels = @($subs | ForEach-Object { Get-IssueLevelName (Get-Prop (Get-Prop $_ 'type') 'name') "$($_.title)" } | Where-Object { $_ })
      prHeads = @($heads | Where-Object { "$_" -match "(^|/)$n-" }); parent = $null
    }
  }
}

# Current milestone of a repository: mirrors `github-milestone current` (Get-Milestones.ps1 of GravionLabs/skills).
# $Titles: titles of the OPEN milestones; $LatestTag: latest release tag v<x.y.z> or $null. Returns the title or $null.
# A legacy open x.y.z above the latest tag comes first (lowest first); legacy at or below the tag is stale, never current.
# Else the lowest open M<n>[.<m>...] by numeric parts (topic ignored; M2 < M3 < M3.1 < M10).
function Get-CurrentMilestone([string[]]$Titles, [string]$LatestTag) {
  $semver = '^([0-9]+)\.([0-9]+)\.([0-9]+)$'
  $floor = if ($LatestTag -and $LatestTag -match '^v?([0-9]+\.[0-9]+\.[0-9]+)$') { [version]$Matches[1] } else { [version]'0.0.0' }
  $legacy = @(@($Titles) | Where-Object { $_ -match $semver -and [version]$_ -gt $floor } | Sort-Object { [version]$_ }) | Select-Object -First 1
  if ($legacy) { return $legacy }
  $rx = '^M([0-9]{1,8}(?:\.[0-9]{1,8}){0,7})(?: ([^()]+?))?(?: \(([0-9]+\.[0-9]+\.[0-9]+)\))?$'
  $key = { param($t) $p = @($t -replace $rx, '$1' -split '\.'); (0..7 | ForEach-Object { if ($_ -lt $p.Count) { $p[$_].PadLeft(8, '0') } else { '00000000' } }) -join '' }
  @(@($Titles) | Where-Object { $_ -cmatch $rx } | Sort-Object { & $key $_ }) | Select-Object -First 1
}

Export-ModuleMember -Function Get-CurrentMilestone, Get-Prop, Get-NeedsValue, Test-BlockerUnresolved, Get-IssueNeedsItem
