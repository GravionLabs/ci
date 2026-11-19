#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
  Sets and checks the security settings of GravionLabs repositories (project standard, docs/project-standard.md).
.DESCRIPTION
  Per repository (archived repositories are skipped), through 'gh api' only:
    all repositories      Dependabot alerts (vulnerability-alerts).
    public repositories   Secret scanning and push protection (security_and_analysis), private vulnerability reporting,
                          approval of fork pull requests from all outside contributors (fork-pr-contributor-approval),
                          the tag ruleset 'version tags' on refs/tags/v*.*.* (rules deletion, update, non_fast_forward; no bypass actor).
    named repositories    Immutable releases (-ImmutableReleases), a switch per repository that is off by default: a release workflow that
                          uploads assets after it published the release breaks with it (tauri-app.yml uploads before it publishes).
  A second run changes nothing. A private repository gets a line 'SKIP ... needs a public repository' for each setting that needs one.
  Without -Apply it is a dry run: it prints 'PLAN' lines and makes no write call. Exit 1 when a repository failed.
  Not set here: 'require actions to be pinned to a full-length commit SHA' (open decision of GravionLabs/ci#239).
  Token: a classic PAT with 'repo' (administration of the repository), or a fine-grained token with Administration: write.
  Rollback: switch the setting off under Settings > Code security or Settings > General; delete the ruleset 'version tags' under Settings > Rules.
.PARAMETER Repo               Repository names ('name' or 'owner/name').
.PARAMETER All                Every non-archived repository of -Owner.
.PARAMETER Owner              Account that owns the repositories (default GravionLabs).
.PARAMETER ImmutableReleases  Repositories that get immutable releases ('name' or 'owner/name'); every other repository keeps its setting.
.PARAMETER Apply              Write the changes; without it nothing is changed.
#>
[CmdletBinding()]
param(
  [string[]]$Repo,
  [switch]$All,
  [string]$Owner = 'GravionLabs',
  [string[]]$ImmutableReleases = @(),
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'

function Invoke-Gh {
  param([string[]]$GhArgs, $Body)
  $errFile = [System.IO.Path]::GetTempFileName()
  try {
    $out = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 20 -Compress | & gh @GhArgs --input - 2>$errFile }
           else { & gh @GhArgs 2>$errFile }
    if ($LASTEXITCODE -ne 0) { throw "gh $($GhArgs -join ' ') failed: $((Get-Content -Raw $errFile) ?? '')$($out -join "`n")" }
  } finally { Remove-Item $errFile -ErrorAction SilentlyContinue }
  ($out -join "`n")
}
function Get-Json { param([string[]]$GhArgs, [switch]$AsHashtable) $t = Invoke-Gh $GhArgs; if ($t.Trim()) { $t | ConvertFrom-Json -Depth 20 -AsHashtable:$AsHashtable } }

# GET of a setting that answers 204 (on) or 404 (off): true when the call succeeds.
function Test-Enabled204 {
  param([string[]]$GhArgs)
  try { Invoke-Gh $GhArgs | Out-Null; $true }
  catch { if ($_.Exception.Message -match 'HTTP 404|Not Found') { $false } else { throw } }
}

$script:Mode = if ($Apply) { 'apply' } else { 'dry run' }

# Prints OK or PLAN for one setting and writes through $Write when -Apply is set.
function Update-Setting {
  param([string]$Full, [string]$Name, [bool]$Current, [scriptblock]$Write)
  if ($Current) { Write-Host "OK   $Full : $Name already set"; return }
  Write-Host "PLAN $Full : set $Name [$script:Mode]"
  if ($Apply) { & $Write }
}

$VersionTags = @{ Name = 'version tags'; Include = 'refs/tags/v*.*.*'; Rules = @('deletion', 'update', 'non_fast_forward') }
function Get-VersionTagsBody {
  [ordered]@{
    name = $VersionTags.Name; target = 'tag'; enforcement = 'active'
    conditions = @{ ref_name = @{ include = @($VersionTags.Include); exclude = @() } }
    bypass_actors = @()
    rules = @($VersionTags.Rules | ForEach-Object { @{ type = $_ } })
  }
}
function Test-VersionTagsCurrent {
  param($Ruleset)
  if (-not $Ruleset) { return $false }
  $types = @($Ruleset.rules | ForEach-Object { $_.type } | Sort-Object) -join ','
  $include = @($Ruleset.conditions.ref_name.include) -join ','
  $exclude = @($Ruleset.conditions.ref_name.exclude | Where-Object { $_ })
  $Ruleset.target -eq 'tag' -and $Ruleset.enforcement -eq 'active' -and $include -eq $VersionTags.Include -and $exclude.Count -eq 0 `
    -and $types -eq (@($VersionTags.Rules | Sort-Object) -join ',') -and @($Ruleset.bypass_actors | Where-Object { $_ }).Count -eq 0
}

$targets = @()
if ($All) {
  # user/repos lists the private repositories too (users/<owner>/repos lists the public ones only); the token's account must be -Owner.
  $raw = Invoke-Gh @('api', '--paginate', '--slurp', 'user/repos?per_page=100&affiliation=owner&visibility=all')
  $targets = @($raw | ConvertFrom-Json -Depth 20 | ForEach-Object { $_ } | ForEach-Object { $_ } | Where-Object { $_.owner.login -eq $Owner } | ForEach-Object { $_.full_name })
} elseif ($Repo) {
  $targets = @($Repo | ForEach-Object { if ($_ -match '/') { $_ } else { "$Owner/$_" } })
} else {
  throw 'Pass -Repo <name>... or -All.'
}
$immutable = @($ImmutableReleases | ForEach-Object { if ($_ -match '/') { $_ } else { "$Owner/$_" } })

$failed = 0
foreach ($full in $targets) {
  try {
    $info = Get-Json @('api', "repos/$full")
    if ($info.archived) { Write-Host "SKIP $full : archived"; continue }
    $public = -not $info.private

    # all repositories
    $alerts = Test-Enabled204 @('api', "repos/$full/vulnerability-alerts")
    Update-Setting $full 'Dependabot alerts' $alerts { Invoke-Gh @('api', '--method', 'PUT', "repos/$full/vulnerability-alerts") | Out-Null }

    if ($public) {
      $sa = $info.security_and_analysis
      $scan = $sa -and $sa.secret_scanning.status -eq 'enabled'
      $push = $sa -and $sa.secret_scanning_push_protection.status -eq 'enabled'
      Update-Setting $full 'secret scanning and push protection' ($scan -and $push) {
        Invoke-Gh @('api', '--method', 'PATCH', "repos/$full") @{ security_and_analysis = @{
            secret_scanning = @{ status = 'enabled' }; secret_scanning_push_protection = @{ status = 'enabled' } } } | Out-Null }

      $pvr = Get-Json @('api', "repos/$full/private-vulnerability-reporting")
      Update-Setting $full 'private vulnerability reporting' ([bool]$pvr.enabled) { Invoke-Gh @('api', '--method', 'PUT', "repos/$full/private-vulnerability-reporting") | Out-Null }

      $fork = Get-Json @('api', "repos/$full/actions/permissions/fork-pr-contributor-approval")
      Update-Setting $full 'fork pull request approval for all outside contributors' ($fork.approval_policy -eq 'all_external_contributors') {
        Invoke-Gh @('api', '--method', 'PUT', "repos/$full/actions/permissions/fork-pr-contributor-approval") @{ approval_policy = 'all_external_contributors' } | Out-Null }

      $list = @(Get-Json @('api', "repos/$full/rulesets"))
      $hit = $list | Where-Object { $_.name -eq $VersionTags.Name } | Select-Object -First 1
      $existing = if ($hit) { Get-Json @('api', "repos/$full/rulesets/$($hit.id)") -AsHashtable } else { $null }
      $current = Test-VersionTagsCurrent $existing
      Update-Setting $full "tag ruleset '$($VersionTags.Name)' on $($VersionTags.Include)" $current {
        if ($existing) { Invoke-Gh @('api', '--method', 'PUT', "repos/$full/rulesets/$($hit.id)") (Get-VersionTagsBody) | Out-Null }
        else { Invoke-Gh @('api', '--method', 'POST', "repos/$full/rulesets") (Get-VersionTagsBody) | Out-Null } }
    } else {
      foreach ($s in 'secret scanning and push protection', 'private vulnerability reporting', 'fork pull request approval', "tag ruleset '$($VersionTags.Name)'") {
        Write-Host "SKIP $full : $s needs a public repository (private)"
      }
    }

    # a switch per repository
    if ($immutable -contains $full) {
      $imm = Get-Json @('api', "repos/$full/immutable-releases")
      Update-Setting $full 'immutable releases' ([bool]$imm.enabled) { Invoke-Gh @('api', '--method', 'PUT', "repos/$full/immutable-releases") | Out-Null }
    } else {
      Write-Host "SKIP $full : immutable releases not requested (-ImmutableReleases), setting left as it is"
    }
  } catch {
    $failed++
    Write-Error "$full : $($_.Exception.Message)" -ErrorAction Continue
  }
}
if ($failed) { exit 1 }
