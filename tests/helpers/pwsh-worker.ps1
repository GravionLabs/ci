# Test helper: long-lived pwsh process that runs a script once per request line (see pwsh-worker.ts), so a describe pays the
# ~1 s pwsh cold start once instead of once per case. Request (one JSON line on stdin): { out, args, cwd, fullEnv }.
# The result { status, stdout, stderr } is written to the file `out`, then the line `@@done` is printed.
param([string]$Script)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'invoke-case.ps1')
# `| Out-Host` writes to the host, not to a stream the case can capture; in a spawned process that is stdout, so send it to the output stream.
function Out-Host { param([Parameter(ValueFromPipeline)]$InputObject) process { $InputObject } }
$params = (Get-Command $Script).Parameters
$basePath = $env:PATH
$baseCwd = (Get-Location).Path
while ($null -ne ($line = [Console]::In.ReadLine())) {
  $out = $null
  try {
    $req = $line | ConvertFrom-Json
    $out = $req.out
    $res = Invoke-ScriptCase -Script $Script -Params $params -BasePath $basePath -Case $req -FileExitCode
  } catch { $res = [pscustomobject]@{ status = 1; stdout = ''; stderr = "worker: $($_.Exception.Message)`n" } }
  try { Set-Location -LiteralPath $baseCwd; [Environment]::CurrentDirectory = $baseCwd } catch { }
  if (-not $out) { continue }
  ConvertTo-Json -InputObject $res -Compress -Depth 3 | Set-Content -LiteralPath $out -Encoding utf8
  # explicit LF: WriteLine would emit CRLF on Windows
  try { [Console]::Out.Write("@@done`n"); [Console]::Out.Flush() } catch { break }
}
