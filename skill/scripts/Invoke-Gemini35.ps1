# Canonical Fleet Gemini Flash visual/research wrapper via Antigravity CLI.
# Default: Gemini 3.6 Flash (Low) since 2026-07-23; 3.5 tiers remain valid fallbacks.
param(
  [Parameter(Mandatory = $true)]
  [string]$Prompt,

  [string[]]$CaptureDir = @(),

  [ValidateSet("text", "json")]
  [string]$Mode = "text",

  [ValidateRange(1, 600)]
  [int]$TimeoutSeconds = 60
)

# Emit UTF-8 on stdout/stderr regardless of console codepage (parents decode as UTF-8).
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$ErrorActionPreference = "Stop"
$ExpectedModel = "Gemini 3.6 Flash (Low)"
$fleetTerseOutputTrailer = 'OUTPUT STYLE (mandatory): terse ' + [char]0x2014 + ' drop articles, filler, pleasantries, hedging; fragments OK; technical substance exact; code, diffs, JSON, file:line references verbatim and complete. Compress prose, never evidence.'
$proc = $null
$logPath = Join-Path ([IO.Path]::GetTempPath()) ("fleet-gemini-" + [guid]::NewGuid().ToString("n") + ".log")

function Quote-Arguments {
  param([string[]]$Tokens)
  ($Tokens | ForEach-Object {
    $token = [string]$_
    if ($token.Length -eq 0) { '""' }
    elseif ($token -notmatch '[\s"]') { $token }
    else { '"' + ($token -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
  }) -join " "
}

function Stop-Tree {
  param([System.Diagnostics.Process]$Process)
  if ($null -eq $Process) { return }
  try { $processId = $Process.Id } catch { return }
  try { & taskkill.exe /PID $processId /T /F 2>$null | Out-Null } catch { }
  try { $null = $Process.WaitForExit(5000) } catch { }
}

try {
  if ([string]::IsNullOrWhiteSpace($Prompt)) { throw "Prompt is empty." }
  $Prompt = $Prompt + "`n" + $fleetTerseOutputTrailer
  $agy = Get-Command agy.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $agy) { throw "agy.exe not found on PATH." }

  $args = @("--mode", "plan", "--sandbox", "--model", $ExpectedModel, "--output-format", "json", "--print-timeout", ("{0}s" -f $TimeoutSeconds), "--log-file", $logPath)
  foreach ($dir in $CaptureDir) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "CaptureDir not found: $dir" }
    $args += @("--add-dir", (Resolve-Path -LiteralPath $dir).Path)
  }
  $args += @("-p", $Prompt)

  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = [string]$agy.Source
  $psi.Arguments = Quote-Arguments -Tokens $args
  $psi.WorkingDirectory = (Get-Location).Path
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
  $psi.RedirectStandardError = $true

  $proc = New-Object Diagnostics.Process
  $proc.StartInfo = $psi
  if (-not $proc.Start()) { throw "Failed to start Antigravity CLI." }
  $startedAt = Get-Date
  $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
  $stderrTask = $proc.StandardError.ReadToEndAsync()
  $done = $proc.WaitForExit(($TimeoutSeconds + 10) * 1000)
  if (-not $done) { Stop-Tree $proc }
  $stdout = if ($stdoutTask.Wait(5000)) { [string]$stdoutTask.Result } else { "" }
  $stderr = if ($stderrTask.Wait(5000)) { [string]$stderrTask.Result } else { "" }
  $duration = ((Get-Date) - $startedAt).TotalSeconds
  $exitCode = if ($done -and $proc.HasExited) { $proc.ExitCode } else { -1 }
  $envelope = $null
  try { $envelope = $stdout | ConvertFrom-Json -ErrorAction Stop } catch { }
  $observedModel = $null
  if (Test-Path -LiteralPath $logPath) {
    foreach ($line in [IO.File]::ReadLines($logPath)) {
      if ($line -match 'Print mode: starting .*model="([^"]+)"') { $observedModel = $matches[1] }
    }
  }

  $status = "error"
  $reason = $null
  if (-not $done) { $status = "timeout"; $reason = "Timed out; process tree killed." }
  elseif ($exitCode -ne 0) { $reason = "agy exited with code $exitCode." }
  elseif ($null -eq $envelope) { $reason = "agy returned invalid JSON." }
  elseif ([string]$envelope.status -ne "SUCCESS") { $reason = "agy status=$($envelope.status)." }
  elseif ($observedModel -ne $ExpectedModel) { $reason = "Observed Gemini model mismatch or missing evidence." }
  elseif ([string]::IsNullOrWhiteSpace([string]$envelope.response)) { $reason = "Gemini returned empty output." }
  else { $status = "ok" }

  $result = [ordered]@{
    status = $status
    model = $ExpectedModel
    observed_model = $observedModel
    model_evidence = "agy-log"
    response = if ($envelope) { [string]$envelope.response } else { "" }
    conversation_id = if ($envelope) { [string]$envelope.conversation_id } else { $null }
    duration_seconds = [math]::Round($duration, 2)
    usage = if ($envelope) { $envelope.usage } else { $null }
    timed_out = [bool](-not $done)
    exit_code = $exitCode
    fail_reason = $reason
  }
  if ($status -ne "ok") {
    $tail = @($stderr -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 30)
    if ($tail.Count) { $result.stderr_tail = $tail }
    if ($Mode -eq "json") { Write-Output ($result | ConvertTo-Json -Compress -Depth 7) }
    else { [Console]::Error.WriteLine(($result | ConvertTo-Json -Compress -Depth 7)) }
    exit 1
  }
  if ($Mode -eq "json") { Write-Output ($result | ConvertTo-Json -Compress -Depth 7) }
  else { Write-Output $result.response.Trim() }
  exit 0
}
finally {
  if ($proc -and -not $proc.HasExited) { Stop-Tree $proc }
  if ($proc) { try { $proc.Dispose() } catch { } }
  Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
}
