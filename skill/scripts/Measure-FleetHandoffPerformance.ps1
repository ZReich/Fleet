# Bounded offline measure: raw UTF-8 materialization of legacy handoff bytes
# vs compact receipt validation. Local wall times only; never model latency.
# PowerShell 5.1 safe; ASCII only; no dependencies.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$LegacyInputPath,
  [Parameter(Mandatory = $true)]
  [string]$ReceiptPath,
  [ValidateRange(1, 200)]
  [int]$Iterations = 25,
  [ValidateRange(3, 30)]
  [int]$Batches = 3,
  [ValidateRange(1, 104857600)]
  [int]$MaxContextBytes = 153600,
  [ValidateRange(1, 300)]
  [int]$MaxSeconds = 30
)

$ErrorActionPreference = 'Stop'
$receiptScript = Join-Path $PSScriptRoot 'New-FleetHandoffReceipt.ps1'
if (-not (Test-Path -LiteralPath $receiptScript)) {
  throw "New-FleetHandoffReceipt.ps1 not found beside this script"
}
if (-not (Test-Path -LiteralPath $LegacyInputPath -PathType Leaf)) {
  throw "LegacyInputPath not found: $LegacyInputPath"
}
if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) {
  throw "ReceiptPath not found: $ReceiptPath"
}

function Get-SharedFileMeta([string]$Path) {
  $item = Get-Item -LiteralPath $Path
  return [pscustomobject]@{ Length = [int64]$item.Length; LastWriteTime = [datetime]$item.LastWriteTimeUtc }
}

function Assert-WithinBudget {
  param([Diagnostics.Stopwatch]$Budget, [int]$LimitSeconds, [string]$Phase, [int]$Iteration = -1)
  if ($Budget.Elapsed.TotalSeconds -ge $LimitSeconds) {
    throw "timeout after MaxSeconds=$LimitSeconds during phase='$Phase' iteration=$Iteration elapsed_ms=$([math]::Round($Budget.Elapsed.TotalMilliseconds, 3))"
  }
}

function Invoke-BoundedEncoded {
  # Child process hard-bounded by remaining MaxSeconds; Kill()/WaitForExit on expiry.
  param(
    [string]$Phase, [string]$ChildScript, [Diagnostics.Stopwatch]$Budget, [int]$LimitSeconds,
    [int]$Iteration = -1, [switch]$CaptureStdout
  )
  Assert-WithinBudget -Budget $Budget -LimitSeconds $LimitSeconds -Phase $Phase -Iteration $Iteration
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ChildScript))
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
  $proc = New-Object Diagnostics.Process
  $proc.StartInfo = $psi
  try { [void]$proc.Start() } catch { throw "failed to start bounded child for phase='$Phase': $($_.Exception.Message)" }
  $remainingMs = [int][math]::Floor(($LimitSeconds - $Budget.Elapsed.TotalSeconds) * 1000.0)
  if ($remainingMs -lt 1) { $remainingMs = 0 }
  if (-not $proc.WaitForExit($remainingMs)) {
    try { $null = & taskkill.exe /PID $proc.Id /T /F 2>&1 } catch { }
    try { $proc.Kill() } catch { try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { } }
    try { $null = $proc.WaitForExit(2000) } catch { }
    $stillAlive = -not $proc.HasExited
    $aliveNote = if ($stillAlive) { ' child_still_alive=true' } else { '' }
    throw "timeout after MaxSeconds=$LimitSeconds during phase='$Phase' iteration=$Iteration elapsed_ms=$([math]::Round($Budget.Elapsed.TotalMilliseconds, 3))$aliveNote"
  }
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $code = $proc.ExitCode
  if ($CaptureStdout) { return [pscustomobject]@{ ExitCode = $code; StdOut = $stdout; StdErr = $stderr } }
  return $code
}

function Get-BlockPreamble([string]$Phase) {
  $p = $Phase.Replace("'", "''")
  return @"
`$ErrorActionPreference = 'Stop'
`$phase = '$p'
if (`$env:FLEET_MEASURE_BLOCK_SCRIPT -and (Test-Path -LiteralPath `$env:FLEET_MEASURE_BLOCK_SCRIPT)) {
  & `$env:FLEET_MEASURE_BLOCK_SCRIPT -Phase `$phase | Out-Null
}
"@
}

function Invoke-BoundedSharedUtf8Read {
  param(
    [string]$Path, [string]$Phase, [Diagnostics.Stopwatch]$Budget, [int]$LimitSeconds,
    [int]$Iteration = -1, [ValidateSet('discard', 'text', 'lifecycle')][string]$Mode = 'discard'
  )
  $pathLiteral = $Path.Replace("'", "''")
  $tail = switch ($Mode) {
    'text' { 'Write-Output $text; exit 0' }
    'lifecycle' {
      @'
$receiptObj = $text | ConvertFrom-Json
$life = $false
if ($null -ne $receiptObj.telemetry) { try { $life = [bool]$receiptObj.telemetry.lifecycle_complete } catch { $life = $false } }
if ($life) { Write-Output 'true' } else { Write-Output 'false' }
exit 0
'@
    }
    default { 'exit 0' }
  }
  $child = (Get-BlockPreamble $Phase) + @"

`$path = '$pathLiteral'
`$utf8 = New-Object Text.UTF8Encoding `$false
`$fs = `$null; `$sr = `$null
try {
  `$fs = [IO.File]::Open(`$path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  `$sr = New-Object IO.StreamReader(`$fs, `$utf8, `$true)
  `$text = `$sr.ReadToEnd()
} catch {
  [Console]::Error.WriteLine("lock/read error opening shared read on '`$path': `$(`$_.Exception.Message)")
  exit 1
} finally {
  if (`$null -ne `$sr) { `$sr.Dispose() } elseif (`$null -ne `$fs) { `$fs.Dispose() }
}
$tail
"@
  $result = Invoke-BoundedEncoded -Phase $Phase -ChildScript $child -Budget $Budget -LimitSeconds $LimitSeconds `
    -Iteration $Iteration -CaptureStdout
  if ([int]$result.ExitCode -ne 0) {
    $msg = if ($result.StdErr) { $result.StdErr.Trim() } else { "bounded read failed phase='$Phase' code=$($result.ExitCode)" }
    throw $msg
  }
  if ($Mode -eq 'discard') { return $null }
  return [string]$result.StdOut
}

function Invoke-ReceiptValidate {
  param(
    [string]$Path, [int]$MaxBytes, [string]$Phase, [Diagnostics.Stopwatch]$Budget,
    [int]$LimitSeconds, [int]$Iteration = -1
  )
  $pathLiteral = $Path.Replace("'", "''")
  $scriptLiteral = $receiptScript.Replace("'", "''")
  $child = (Get-BlockPreamble $Phase) + @"

& '$scriptLiteral' -ReceiptPath '$pathLiteral' -MaxContextBytesValidate $MaxBytes
if (`$null -eq `$LASTEXITCODE) { exit 1 }
exit ([int]`$LASTEXITCODE)
"@
  return [int](Invoke-BoundedEncoded -Phase $Phase -ChildScript $child -Budget $Budget `
    -LimitSeconds $LimitSeconds -Iteration $Iteration)
}

# END-TO-END MaxSeconds budget starts before warmup (covers all blocking work).
$budget = [Diagnostics.Stopwatch]::StartNew()
$legacyFull = (Resolve-Path -LiteralPath $LegacyInputPath).Path
$receiptFull = (Resolve-Path -LiteralPath $ReceiptPath).Path
Assert-WithinBudget -Budget $budget -LimitSeconds $MaxSeconds -Phase 'metadata_start'
$legacyMetaStart = Get-SharedFileMeta -Path $legacyFull
$receiptMetaStart = Get-SharedFileMeta -Path $receiptFull
$inputBytes = [int64]$legacyMetaStart.Length
$receiptBytes = [int64]$receiptMetaStart.Length
if ($inputBytes -le 0) { throw 'legacy input is empty' }

# Warm once so first-hit JIT/IO is not the only sample (hard-bounded child processes).
$null = Invoke-BoundedSharedUtf8Read -Path $legacyFull -Phase 'warmup' -Budget $budget -LimitSeconds $MaxSeconds
$code = Invoke-ReceiptValidate -Path $receiptFull -MaxBytes $MaxContextBytes -Phase 'warmup' `
  -Budget $budget -LimitSeconds $MaxSeconds
if ($code -ne 0) { throw 'receipt failed validation before measure' }

$sourceStable = $true
$batchLegacyMs = New-Object System.Collections.Generic.List[double]
$batchReceiptMs = New-Object System.Collections.Generic.List[double]
$batchRatios = New-Object System.Collections.Generic.List[double]

# Independent measured batches (>=3): each batch runs full iteration loops.
# Do NOT parse legacy as one JSON object; Codex rollout artifacts are often JSONL.
for ($b = 0; $b -lt $Batches; $b++) {
  Assert-WithinBudget -Budget $budget -LimitSeconds $MaxSeconds -Phase 'batch_start' -Iteration $b
  $legacySw = [Diagnostics.Stopwatch]::StartNew()
  for ($i = 0; $i -lt $Iterations; $i++) {
    $null = Invoke-BoundedSharedUtf8Read -Path $legacyFull -Phase 'legacy_materialization' `
      -Budget $budget -LimitSeconds $MaxSeconds -Iteration $i
  }
  $legacySw.Stop()
  $lMs = [math]::Round($legacySw.Elapsed.TotalMilliseconds, 3)
  $batchLegacyMs.Add($lMs) | Out-Null

  $receiptSw = [Diagnostics.Stopwatch]::StartNew()
  for ($i = 0; $i -lt $Iterations; $i++) {
    $code = Invoke-ReceiptValidate -Path $receiptFull -MaxBytes $MaxContextBytes -Phase 'receipt_validation' `
      -Budget $budget -LimitSeconds $MaxSeconds -Iteration $i
    if ($code -ne 0) { throw "receipt validation failed on batch $b iteration $i" }
  }
  $receiptSw.Stop()
  $rMs = [math]::Round($receiptSw.Elapsed.TotalMilliseconds, 3)
  $batchReceiptMs.Add($rMs) | Out-Null
  if ($rMs -gt 0) {
    $batchRatios.Add([math]::Round([double]$lMs / [double]$rMs, 4)) | Out-Null
  }
}

Assert-WithinBudget -Budget $budget -LimitSeconds $MaxSeconds -Phase 'metadata_compare'
$legacyMetaEnd = Get-SharedFileMeta -Path $legacyFull
$receiptMetaEnd = Get-SharedFileMeta -Path $receiptFull
if (
  $legacyMetaEnd.Length -ne $legacyMetaStart.Length -or
  $legacyMetaEnd.LastWriteTime -ne $legacyMetaStart.LastWriteTime -or
  $receiptMetaEnd.Length -ne $receiptMetaStart.Length -or
  $receiptMetaEnd.LastWriteTime -ne $receiptMetaStart.LastWriteTime
) {
  $sourceStable = $false
}

# Never treat partial/unstable input as a completed-result claim.
$reductionPct = $null
$localSpeedupRatio = $null
$ratioMean = $null
$ratioMin = $null
$ratioMax = $null
$noiseBand = $null
$legacyMaterializationMs = $null
$receiptValidationMs = $null
if ($sourceStable -and $batchLegacyMs.Count -gt 0) {
  $legacyMaterializationMs = [math]::Round((($batchLegacyMs | Measure-Object -Average).Average), 3)
  $receiptValidationMs = [math]::Round((($batchReceiptMs | Measure-Object -Average).Average), 3)
  $reductionPct = [math]::Round((1.0 - ([double]$receiptBytes / [double]$inputBytes)) * 100.0, 2)
  if ($batchRatios.Count -gt 0) {
    $ratioMean = [math]::Round((($batchRatios | Measure-Object -Average).Average), 4)
    $ratioMin = [math]::Round((($batchRatios | Measure-Object -Minimum).Minimum), 4)
    $ratioMax = [math]::Round((($batchRatios | Measure-Object -Maximum).Maximum), 4)
    $noiseBand = [math]::Round(($ratioMax - $ratioMin), 4)
    $localSpeedupRatio = $ratioMean
  }
}

# Final receipt read/parse in budget-bounded child (Kill on remaining MaxSeconds expiry).
$lifeOut = Invoke-BoundedSharedUtf8Read -Path $receiptFull -Phase 'finalization' -Budget $budget `
  -LimitSeconds $MaxSeconds -Mode lifecycle
$life = ([string]$lifeOut).Trim() -eq 'true'

$result = [ordered]@{
  schema_version              = '1'
  metric_scope                = 'local_raw_materialization_and_receipt_validation'
  claims_model_latency        = $false
  iterations                  = $Iterations
  batches                     = $Batches
  max_seconds                 = $MaxSeconds
  input_bytes                 = $inputBytes
  receipt_bytes               = $receiptBytes
  source_stable               = [bool]$sourceStable
  reduction_pct               = $reductionPct
  legacy_materialization_ms   = $legacyMaterializationMs
  receipt_validation_ms       = $receiptValidationMs
  local_speedup_ratio         = $localSpeedupRatio
  local_speedup_ratio_mean    = $ratioMean
  local_speedup_ratio_min     = $ratioMin
  local_speedup_ratio_max     = $ratioMax
  noise_band                  = $noiseBand
  lifecycle_complete          = [bool]$life
  note                        = 'Times measure local UTF-8 materialization and receipt validation only; not model latency. Speedup stats are mean/min/max/noise_band across independent batches of raw handoff materialization (JSON/JSONL), not model latency.'
}
if (-not $sourceStable) {
  $result.note = 'source metadata changed during measurement; ratios unmeasured (source_stable=false). ' + $result.note
}
# Final JSON emit in budget-bounded child (Kill on remaining MaxSeconds expiry).
$owLines = New-Object System.Collections.Generic.List[string]
foreach ($entry in $result.GetEnumerator()) {
  $v = $entry.Value
  if ($null -eq $v) { $e = '$null' }
  elseif ($v -is [bool]) { $e = $(if ($v) { '$true' } else { '$false' }) }
  elseif ($v -is [string]) { $e = "'" + $v.Replace("'", "''") + "'" }
  elseif ($v -is [double] -or $v -is [float] -or $v -is [decimal]) {
    $e = $v.ToString([Globalization.CultureInfo]::InvariantCulture)
  }
  else { $e = [string]$v }
  $owLines.Add(('  {0} = {1}' -f $entry.Key, $e)) | Out-Null
}
$owChild = (Get-BlockPreamble 'output_write') + @"

`$result = [ordered]@{
$($owLines -join "`n")
}
Write-Output (`$result | ConvertTo-Json -Compress -Depth 5)
exit 0
"@
$ow = Invoke-BoundedEncoded -Phase 'output_write' -ChildScript $owChild -Budget $budget `
  -LimitSeconds $MaxSeconds -CaptureStdout
if ([int]$ow.ExitCode -ne 0) {
  throw $(if ($ow.StdErr) { $ow.StdErr.Trim() } else { "bounded output_write failed code=$($ow.ExitCode)" })
}
Write-Output ([string]$ow.StdOut).Trim()
exit 0
