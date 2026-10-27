# Test helper, dot-sourced by pwsh-worker.ps1: runs one script invocation (a "case") inside the current pwsh process.
# case: { key, args: string[], cwd, path?, env?: { NAME: string | null }, fullEnv?: { NAME: string } }
#   env      per-case overrides on top of the queue clean slate (QUEUE_*, OPENCODE_PERMISSION removed, QUEUE_POLL_SECONDS=0)
#   fullEnv  replaces the whole environment (exactly what a spawn with that env would see); no queue clean slate
# Returns { status, stdout, stderr } like a spawned `pwsh -File`; the environment is restored afterwards.
function Invoke-ScriptCase {
  # -FileExitCode: report the code like `pwsh -File`
  param([string]$Script, $Params, [string]$BasePath, $Case, [switch]$FileExitCode)
  $c = $Case
  $saved = $null
  if ($c.PSObject.Properties['fullEnv'] -and $c.fullEnv) {
    $saved = [ordered]@{}
    Get-ChildItem Env: | Where-Object { -not $_.Name.StartsWith('=') } | ForEach-Object { $saved[$_.Name] = $_.Value }
    $want = [ordered]@{}
    foreach ($p in $c.fullEnv.PSObject.Properties) { $want[$p.Name] = [string]$p.Value }
    foreach ($name in @($saved.Keys)) { if (-not $want.Contains($name)) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue } }
    foreach ($name in $want.Keys) { Set-Item "Env:$name" -Value $want[$name] }
  } else {
    # clean slate per case: the runner reads QUEUE_*, OPENCODE_PERMISSION and PATH
    Get-ChildItem Env: | Where-Object { $_.Name -like 'QUEUE_*' -or $_.Name -eq 'OPENCODE_PERMISSION' } | ForEach-Object { Remove-Item "Env:$($_.Name)" }
    $env:QUEUE_POLL_SECONDS = '0'
    $env:PATH = if ($c.PSObject.Properties['path'] -and $c.path) { $c.path } else { $BasePath }
  }
  Set-Location -LiteralPath $c.cwd
  [Environment]::CurrentDirectory = $c.cwd
  $Error.Clear()
  # optional per-case env map: a string sets the variable, null removes it; restored after the case
  $touched = [ordered]@{}
  if ($c.PSObject.Properties['env'] -and $c.env) {
    foreach ($p in $c.env.PSObject.Properties) {
      $touched[$p.Name] = [Environment]::GetEnvironmentVariable($p.Name)
      if ($null -eq $p.Value) { Remove-Item "Env:$($p.Name)" -ErrorAction SilentlyContinue } else { Set-Item "Env:$($p.Name)" -Value ([string]$p.Value) }
    }
  }
  $global:LASTEXITCODE = $null
  $stdout = [System.Collections.Generic.List[string]]::new()
  $stderr = [System.Collections.Generic.List[string]]::new()
  $code = 0
  try {
    # '-Name' tokens become named parameters (switches take no value), everything else is a positional argument
    $named = @{}; $positional = [System.Collections.Generic.List[string]]::new()
    $tokens = @($c.args)
    for ($i = 0; $i -lt $tokens.Count; $i++) {
      $t = [string]$tokens[$i]
      if ($t -cmatch '^-([A-Za-z]+)$') {
        $name = $Matches[1]
        if (-not $Params.ContainsKey($name)) { throw "case '$($c.key)': unknown parameter -$name" }
        if ($Params[$name].SwitchParameter) { $named[$name] = $true } else { $i++; $named[$name] = [string]$tokens[$i] }
      } else { $positional.Add($t) }
    }
    $items = & { Set-StrictMode -Off; $ErrorActionPreference = 'Continue'; & $Script @named @positional; $global:CaseOk = $? } *>&1
    # -FileExitCode: only a script that failed (`exit N`) reports N; a native command that failed earlier does not leak
    if ($FileExitCode) { if (-not $global:CaseOk -and $null -ne $global:LASTEXITCODE) { $code = $global:LASTEXITCODE } }
    elseif ($null -ne $global:LASTEXITCODE) { $code = $global:LASTEXITCODE }
    foreach ($i in $items) { if ($i -is [System.Management.Automation.ErrorRecord] -or $i -is [System.Management.Automation.WarningRecord]) { $stderr.Add("$i") } else { $stdout.Add("$i") } }
  } catch { $code = 1; $stderr.Add($_.Exception.Message) }
  foreach ($name in $touched.Keys) { if ($null -eq $touched[$name]) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue } else { Set-Item "Env:$name" -Value $touched[$name] } }
  if ($null -ne $saved) {
    foreach ($e in @(Get-ChildItem Env: | Where-Object { -not $_.Name.StartsWith('=') })) { if (-not $saved.Contains($e.Name)) { Remove-Item "Env:$($e.Name)" -ErrorAction SilentlyContinue } }
    foreach ($name in $saved.Keys) { Set-Item "Env:$name" -Value $saved[$name] }
  }
  $global:CaseOk = $null
  [pscustomobject]@{ status = $code; stdout = (($stdout | ForEach-Object { "$_`n" }) -join ''); stderr = (($stderr | ForEach-Object { "$_`n" }) -join '') }
}
