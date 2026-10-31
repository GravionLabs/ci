#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
  Requires the check 'PR checks' (reusable workflow pr-checks.yml) in the rulesets 'main' and 'release' of GravionLabs repositories.
.DESCRIPTION
  Per repository: skips archived repositories and repositories without a caller of
  GravionLabs/ci/.github/workflows/pr-checks.yml under .github/workflows (a required check that never runs blocks every PR; warning).
  Otherwise adds -Context to the required_status_checks rule of the rulesets 'main' (default branch) and 'release' (release/**),
  creating the rule, or the ruleset, when missing. 'release' also gets the pull_request rule so the check applies to PRs into release
  branches. Other rules and other required checks stay; -Replace removes superseded checks in the same update.
  Without -Apply it is a dry run: it prints the planned change and makes no write call. Uses 'gh api' only (token scopes: repo plus
  administration, i.e. a classic PAT with 'repo', or a fine-grained token with Administration: write).
  Rollback: delete the ruleset (Settings > Rules > Rulesets, or 'gh api -X DELETE repos/<owner>/<repo>/rulesets/<id>').
.PARAMETER Repo     Repository names ('name' or 'owner/name').
.PARAMETER All      Every non-archived repository of -Owner.
.PARAMETER Owner    Account that owns the repositories (default GravionLabs).
.PARAMETER Context  Required check context (default 'PR checks'). GitHub names the check of a reusable-workflow job
                    '<caller job id> / <job name>'; with the caller job id 'pr-checks' the context is 'pr-checks / PR checks', so pass
                    -Context 'pr-checks / PR checks' when the callers use that job id and the check list shows that name.
.PARAMETER Replace  Check contexts to remove from the required checks (e.g. 'ready').
.PARAMETER Apply    Write the changes; without it nothing is changed.
#>
[CmdletBinding()]
param(
  [string[]]$Repo,
  [switch]$All,
  [string]$Owner = 'GravionLabs',
  [string]$Context = 'PR checks',
  [string[]]$Replace = @(),
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'

function Invoke-Gh {
  param([string[]]$GhArgs, $Body)
  $out = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 20 -Compress | & gh @GhArgs --input - 2>&1 }
         else { & gh @GhArgs 2>&1 }
  if ($LASTEXITCODE -ne 0) { throw "gh $($GhArgs -join ' ') failed: $($out -join "`n")" }
  ($out -join "`n")
}
function Get-Json { param([string[]]$GhArgs, [switch]$AsHashtable) $t = Invoke-Gh $GhArgs; if ($t.Trim()) { $t | ConvertFrom-Json -Depth 20 -AsHashtable:$AsHashtable } }

function Test-HasCaller {
  param($Full)
  $files = @(Get-Json @('api', "repos/$Full/contents/.github/workflows") | Where-Object { $_.name -match '\.ya?ml$' })
  foreach ($f in $files) {
    $text = Invoke-Gh @('api', "repos/$Full/contents/$($f.path)", '-H', 'Accept: application/vnd.github.raw')
    if ($text -match '(?m)^\s*(-\s*)?uses:\s*[''"]?GravionLabs/ci/\.github/workflows/pr-checks\.yml(@|[''"\s]|$)') { return $true }
  }
  $false
}

function Get-RuleParams {
  param([string]$Type)
  switch ($Type) {
    'pull_request' { @{ required_approving_review_count = 0; dismiss_stale_reviews_on_push = $false; require_code_owner_review = $false
        require_last_push_approval = $false; required_review_thread_resolution = $false } }
    'required_status_checks' { @{ strict_required_status_checks_policy = $false; required_status_checks = @() } }
    default { $null }
  }
}

# Returns the new ruleset body and whether it differs from $Existing ($null = create). $Existing is a hashtable.
function Get-RulesetPlan {
  param($Existing, [string]$Name, [string]$Include, [string[]]$ExtraRules)
  $changed = -not $Existing
  $rules = [System.Collections.Generic.List[object]]::new()
  if ($Existing) { foreach ($r in $Existing.rules) { $rules.Add(@{ type = $r.type; parameters = $r.parameters }) } }
  else { foreach ($t in $ExtraRules) { $rules.Add(@{ type = $t; parameters = (Get-RuleParams $t) }) } }
  if ($Existing -and $Name -eq 'release' -and -not ($rules | Where-Object { $_.type -eq 'pull_request' })) {
    $rules.Add(@{ type = 'pull_request'; parameters = (Get-RuleParams 'pull_request') }); $changed = $true
  }
  $rsc = $rules | Where-Object { $_.type -eq 'required_status_checks' } | Select-Object -First 1
  if (-not $rsc) {
    $rsc = @{ type = 'required_status_checks'; parameters = (Get-RuleParams 'required_status_checks') }
    $rules.Add($rsc); $changed = $true
  }
  if (-not $rsc.parameters) { $rsc.parameters = Get-RuleParams 'required_status_checks' }
  $before = @($rsc.parameters.required_status_checks | Where-Object { $_ })
  $checks = @($before | Where-Object { $_.context -notin $Replace })
  if ($checks.Count -ne $before.Count) { $changed = $true }
  if (-not ($checks | Where-Object { $_.context -eq $Context })) { $checks += @{ context = $Context }; $changed = $true }
  $rsc.parameters.required_status_checks = @($checks)

  $body = [ordered]@{
    name = $Name; target = 'branch'
    enforcement = $(if ($Existing) { $Existing.enforcement } else { 'active' })
    conditions = $(if ($Existing) { $Existing.conditions } else { @{ ref_name = @{ include = @($Include); exclude = @() } } })
    bypass_actors = $(if ($Existing -and $Existing.bypass_actors) { @($Existing.bypass_actors) } else { @() })
    rules = @($rules)
  }
  [pscustomobject]@{ Body = $body; Changed = $changed }
}

$targets = @()
if ($All) {
  $raw = Invoke-Gh @('api', '--paginate', '--slurp', "users/$Owner/repos?per_page=100&type=owner")
  $targets = @($raw | ConvertFrom-Json -Depth 20 | ForEach-Object { $_ } | ForEach-Object { $_ } | ForEach-Object { $_.full_name })
} elseif ($Repo) {
  $targets = @($Repo | ForEach-Object { if ($_ -match '/') { $_ } else { "$Owner/$_" } })
} else {
  throw 'Pass -Repo <name>... or -All.'
}

$specs = @(
  @{ Name = 'main';    Include = '~DEFAULT_BRANCH';    Extra = @('deletion', 'non_fast_forward', 'pull_request') },
  @{ Name = 'release'; Include = 'refs/heads/release/**'; Extra = @('non_fast_forward', 'pull_request') }
)
$mode = if ($Apply) { 'apply' } else { 'dry run' }
$failed = 0
foreach ($full in $targets) {
  try {
    $info = Get-Json @('api', "repos/$full")
    if ($info.archived) { Write-Host "SKIP $full : archived"; continue }
    if (-not (Test-HasCaller $full)) {
      Write-Warning "$full has no caller of GravionLabs/ci/.github/workflows/pr-checks.yml under .github/workflows; skipped (the required check would never run)"
      continue
    }
    $list = @(Get-Json @('api', "repos/$full/rulesets"))
    foreach ($s in $specs) {
      $hit = $list | Where-Object { $_.name -eq $s.Name } | Select-Object -First 1
      $existing = if ($hit) { Get-Json @('api', "repos/$full/rulesets/$($hit.id)") -AsHashtable } else { $null }
      $plan = Get-RulesetPlan -Existing $existing -Name $s.Name -Include $s.Include -ExtraRules $s.Extra
      $verb = if ($existing) { 'update' } else { 'create' }
      if (-not $plan.Changed) { Write-Host "OK   $full : ruleset '$($s.Name)' already requires '$Context'"; continue }
      $checks = (($plan.Body.rules | Where-Object { $_.type -eq 'required_status_checks' }).parameters.required_status_checks | ForEach-Object { $_.context }) -join ', '
      Write-Host "PLAN $full : $verb ruleset '$($s.Name)' ($(($plan.Body.rules | ForEach-Object { $_.type }) -join ', ')); required checks: $checks [$mode]"
      if ($Apply) {
        if ($existing) { Invoke-Gh @('api', '--method', 'PUT', "repos/$full/rulesets/$($hit.id)") $plan.Body | Out-Null }
        else { Invoke-Gh @('api', '--method', 'POST', "repos/$full/rulesets") $plan.Body | Out-Null }
      }
    }
  } catch {
    $failed++
    Write-Error "$full : $($_.Exception.Message)" -ErrorAction Continue
  }
}
if ($failed) { exit 1 }
