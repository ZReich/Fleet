# Offline tests: Measure-FleetHandoffPerformance + receipt fixtures (no live model).
$ErrorActionPreference = 'Stop'
$createScript = Join-Path $PSScriptRoot 'New-FleetHandoffReceipt.ps1'
$measureScript = Join-Path $PSScriptRoot 'Measure-FleetHandoffPerformance.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('fleet-handoff-receipt-' + [guid]::NewGuid().ToString('N'))
$passed = 0; $failed = 0
$utf8 = New-Object Text.UTF8Encoding $false
function Assert-True([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Case([string]$Name, [scriptblock]$Body) {
  try { & $Body; $script:passed++; Write-Host "PASS $Name" }
  catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}
function Invoke-Create {
  param(
    [string]$RunId = 'run-1', [string]$LaneId = 'T1', [string]$Phase = 'impl',
    [string]$Status = 'ready', [string]$NextAction = 'resume lane',
    [string[]]$ArtifactPath = @(), [double]$FirstResultSeconds = 1.5,
    [int]$TimeoutSignals = 0, [string]$LifecycleComplete = 'false',
    [int]$MaxContextBytes = 153600, [string]$OutputPath
  )
  $args = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $createScript,
    '-RunId', $RunId, '-LaneId', $LaneId, '-Phase', $Phase, '-Status', $Status,
    '-NextAction', $NextAction,
    '-FirstResultSeconds', "$FirstResultSeconds", '-TimeoutSignals', "$TimeoutSignals",
    '-LifecycleComplete', $(if ($LifecycleComplete -eq 'true' -or $LifecycleComplete -eq $true) { 'true' } else { 'false' }),
    '-MaxContextBytes', "$MaxContextBytes", '-OutputPath', $OutputPath
  )
  if ($ArtifactPath.Count -gt 0) { $args += '-ArtifactPath'; $args += $ArtifactPath }
  $old = $ErrorActionPreference
  try { $ErrorActionPreference = 'Continue'; $raw = & powershell.exe @args 2>&1; $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $old }
  return [pscustomobject]@{ ExitCode = $code; Raw = (($raw | ForEach-Object { "$_" }) -join "`n") }
}
function Write-Utf8([string]$Path, [string]$Content) {
  $parent = Split-Path -Parent $Path
  if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [IO.File]::WriteAllText($Path, $Content, $utf8)
}
function Invoke-Measure([string]$Legacy, [string]$Receipt, [int]$Iters = 5, [int]$MaxSec = 10, [int]$Batches = 3) {
  $margs = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $measureScript,
    '-LegacyInputPath', $Legacy, '-ReceiptPath', $Receipt,
    '-Iterations', "$Iters", '-Batches', "$Batches", '-MaxSeconds', "$MaxSec"
  )
  $old = $ErrorActionPreference
  try { $ErrorActionPreference = 'Continue'; $raw = & powershell.exe @margs 2>&1; $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $old }
  return [pscustomobject]@{ ExitCode = $code; Raw = (($raw | ForEach-Object { "$_" }) -join "`n") }
}
try {
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  $artPath = Join-Path $root 'delta.txt'
  Write-Utf8 $artPath 'named delta artifact body'
  Case 'performance metric meaning (local only, no model claim)' {
    $legacy = Join-Path $root 'legacy-handoff.jsonl'
    $sb = New-Object System.Text.StringBuilder
    for ($n = 1; $n -le 400; $n++) {
      [void]$sb.AppendLine((@{ seq = $n; event = "session line $n padding xxxxxxxxx"; notes = ('x' * 40) } | ConvertTo-Json -Compress))
    }
    Write-Utf8 $legacy $sb.ToString()
    $receipt = Join-Path $root 'compact-receipt.json'
    $cr = Invoke-Create -Status ready -ArtifactPath @($artPath) -OutputPath $receipt -NextAction 'resume from receipt only'
    Assert-True ($cr.ExitCode -eq 0) "receipt: $($cr.Raw)"
    $run = Invoke-Measure -Legacy $legacy -Receipt $receipt -Iters 3 -MaxSec 60 -Batches 3
    Assert-True ($run.ExitCode -eq 0) "measure exit: $($run.Raw)"
    $m = $run.Raw | ConvertFrom-Json
    Assert-True ([bool]$m.claims_model_latency -eq $false) 'must not claim model latency'
    Assert-True ([string]$m.metric_scope -eq 'local_raw_materialization_and_receipt_validation') 'scope'
    Assert-True ([bool]$m.source_stable -eq $true) 'stable fixture'
    Assert-True ([int64]$m.input_bytes -gt [int64]$m.receipt_bytes -and [double]$m.reduction_pct -gt 0) 'byte reduction'
    Assert-True ($null -ne $m.legacy_materialization_ms -and [double]$m.legacy_materialization_ms -ge 0) 'legacy_materialization_ms'
    Assert-True ($null -ne $m.receipt_validation_ms -and [double]$m.receipt_validation_ms -gt 0) 'receipt_validation_ms'
    Assert-True ($null -ne $m.local_speedup_ratio -and [double]$m.local_speedup_ratio -gt 0) 'local_speedup_ratio'
    Assert-True ($null -ne $m.lifecycle_complete) 'lifecycle field'
    Assert-True ($m.note -match 'not model latency' -and $m.note -match 'raw handoff|materialization|JSONL') 'honest note'
  }
  Case 'performance three-run mean range stats' {
    $legacy = Join-Path $root 'legacy-batches.jsonl'
    $sb = New-Object System.Text.StringBuilder
    for ($n = 1; $n -le 200; $n++) {
      [void]$sb.AppendLine((@{ seq = $n; event = "batch line $n"; pad = ('z' * 30) } | ConvertTo-Json -Compress))
    }
    Write-Utf8 $legacy $sb.ToString()
    $receipt = Join-Path $root 'batch-receipt.json'
    $cr = Invoke-Create -Status ready -ArtifactPath @($artPath) -OutputPath $receipt
    Assert-True ($cr.ExitCode -eq 0) "receipt: $($cr.Raw)"
    $run = Invoke-Measure -Legacy $legacy -Receipt $receipt -Iters 2 -MaxSec 60 -Batches 3
    Assert-True ($run.ExitCode -eq 0) "measure: $($run.Raw)"
    $m = $run.Raw | ConvertFrom-Json
    Assert-True ([int]$m.batches -ge 3) 'three-run batches'
    Assert-True ($null -ne $m.local_speedup_ratio_mean -and [double]$m.local_speedup_ratio_mean -gt 0) 'mean'
    Assert-True ($null -ne $m.local_speedup_ratio_min -and [double]$m.local_speedup_ratio_min -gt 0) 'min'
    Assert-True ($null -ne $m.local_speedup_ratio_max -and [double]$m.local_speedup_ratio_max -gt 0) 'max'
    Assert-True ($null -ne $m.noise_band -and [double]$m.noise_band -ge 0) 'noise_band range'
    Assert-True ([double]$m.local_speedup_ratio_min -le [double]$m.local_speedup_ratio_mean) 'min<=mean'
    Assert-True ([double]$m.local_speedup_ratio_mean -le [double]$m.local_speedup_ratio_max) 'mean<=max'
    Assert-True ([math]::Abs([double]$m.noise_band - ([double]$m.local_speedup_ratio_max - [double]$m.local_speedup_ratio_min)) -lt 0.0002) 'noise=max-min'
  }
  Case 'warmup hard deadline bounded elapsed' {
    $legacy = Join-Path $root 'legacy-warmup-block.jsonl'
    Write-Utf8 $legacy ((@{ seq = 1; event = 'warmup' } | ConvertTo-Json -Compress) + "`n")
    $receipt = Join-Path $root 'warmup-block-receipt.json'
    $cr = Invoke-Create -Status ready -ArtifactPath @($artPath) -OutputPath $receipt
    Assert-True ($cr.ExitCode -eq 0) "receipt: $($cr.Raw)"
    $block = Join-Path $root 'block-warmup.ps1'
    Write-Utf8 $block @'
param([string]$Phase)
if ($Phase -eq 'warmup') { Start-Sleep -Seconds 120 }
'@
    $prev = $env:FLEET_MEASURE_BLOCK_SCRIPT
    $env:FLEET_MEASURE_BLOCK_SCRIPT = $block
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
      $run = Invoke-Measure -Legacy $legacy -Receipt $receipt -Iters 1 -MaxSec 2 -Batches 3
    }
    finally {
      if ($null -eq $prev) { Remove-Item Env:FLEET_MEASURE_BLOCK_SCRIPT -ErrorAction SilentlyContinue }
      else { $env:FLEET_MEASURE_BLOCK_SCRIPT = $prev }
    }
    $sw.Stop()
    Assert-True ($run.ExitCode -ne 0 -and $run.Raw -match 'timeout|MaxSeconds|phase=') "warmup timeout: $($run.Raw)"
    Assert-True ($sw.Elapsed.TotalSeconds -lt 12) "warmup bounded elapsed=$($sw.Elapsed.TotalSeconds)"
  }
  Case 'blocking read hard deadline bounded elapsed' {
    $legacy = Join-Path $root 'legacy-block-read.jsonl'
    Write-Utf8 $legacy ((@{ seq = 1; event = 'block-read' } | ConvertTo-Json -Compress) + "`n")
    $receipt = Join-Path $root 'block-read-receipt.json'
    $cr = Invoke-Create -Status ready -ArtifactPath @($artPath) -OutputPath $receipt
    Assert-True ($cr.ExitCode -eq 0) "receipt: $($cr.Raw)"
    $block = Join-Path $root 'block-legacy.ps1'
    Write-Utf8 $block @'
param([string]$Phase)
if ($Phase -eq 'legacy_materialization') { Start-Sleep -Seconds 120 }
'@
    $prev = $env:FLEET_MEASURE_BLOCK_SCRIPT
    $env:FLEET_MEASURE_BLOCK_SCRIPT = $block
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
      $run = Invoke-Measure -Legacy $legacy -Receipt $receipt -Iters 1 -MaxSec 2 -Batches 3
    }
    finally {
      if ($null -eq $prev) { Remove-Item Env:FLEET_MEASURE_BLOCK_SCRIPT -ErrorAction SilentlyContinue }
      else { $env:FLEET_MEASURE_BLOCK_SCRIPT = $prev }
    }
    $sw.Stop()
    Assert-True ($run.ExitCode -ne 0 -and $run.Raw -match 'timeout|MaxSeconds|phase=') "blocking read timeout: $($run.Raw)"
    Assert-True ($sw.Elapsed.TotalSeconds -lt 12) "blocking read bounded elapsed=$($sw.Elapsed.TotalSeconds)"
  }
  Case 'finalization hard deadline bounded elapsed' {
    $legacy = Join-Path $root 'legacy-final-block.jsonl'
    Write-Utf8 $legacy ((@{ seq = 1; event = 'final' } | ConvertTo-Json -Compress) + "`n")
    $receipt = Join-Path $root 'final-block-receipt.json'
    $cr = Invoke-Create -Status ready -ArtifactPath @($artPath) -OutputPath $receipt
    Assert-True ($cr.ExitCode -eq 0) "receipt: $($cr.Raw)"
    $block = Join-Path $root 'block-final.ps1'
    Write-Utf8 $block @'
param([string]$Phase)
if ($Phase -eq 'finalization') { Start-Sleep -Seconds 120 }
'@
    $prev = $env:FLEET_MEASURE_BLOCK_SCRIPT
    $env:FLEET_MEASURE_BLOCK_SCRIPT = $block
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
      $run = Invoke-Measure -Legacy $legacy -Receipt $receipt -Iters 1 -MaxSec 8 -Batches 3
    }
    finally {
      if ($null -eq $prev) { Remove-Item Env:FLEET_MEASURE_BLOCK_SCRIPT -ErrorAction SilentlyContinue }
      else { $env:FLEET_MEASURE_BLOCK_SCRIPT = $prev }
    }
    $sw.Stop()
    Assert-True ($run.ExitCode -ne 0 -and $run.Raw -match 'timeout|MaxSeconds|phase=') "finalization timeout: $($run.Raw)"
    Assert-True ($sw.Elapsed.TotalSeconds -lt 20) "finalization bounded elapsed=$($sw.Elapsed.TotalSeconds)"
  }
  Case 'output_write hard deadline bounded elapsed' {
    $legacy = Join-Path $root 'legacy-output-write-block.jsonl'
    Write-Utf8 $legacy ((@{ seq = 1; event = 'output-write' } | ConvertTo-Json -Compress) + "`n")
    $receipt = Join-Path $root 'output-write-block-receipt.json'
    $cr = Invoke-Create -Status ready -ArtifactPath @($artPath) -OutputPath $receipt
    Assert-True ($cr.ExitCode -eq 0) "receipt: $($cr.Raw)"
    $marker = Join-Path $root 'output-write-alive.marker'
    $block = Join-Path $root 'block-output-write.ps1'
    $markerEsc = $marker.Replace("'", "''")
    Write-Utf8 $block @"
param([string]`$Phase)
if (`$Phase -eq 'output_write') {
  Set-Content -LiteralPath '$markerEsc' -Value `$PID -Encoding ASCII
  Start-Sleep -Seconds 120
}
"@
    $prev = $env:FLEET_MEASURE_BLOCK_SCRIPT
    $env:FLEET_MEASURE_BLOCK_SCRIPT = $block
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
      $run = Invoke-Measure -Legacy $legacy -Receipt $receipt -Iters 1 -MaxSec 20 -Batches 3
    }
    finally {
      if ($null -eq $prev) { Remove-Item Env:FLEET_MEASURE_BLOCK_SCRIPT -ErrorAction SilentlyContinue }
      else { $env:FLEET_MEASURE_BLOCK_SCRIPT = $prev }
    }
    $sw.Stop()
    Assert-True ($run.ExitCode -ne 0) "output_write must fail: $($run.Raw)"
    Assert-True ($run.Raw -match "phase='output_write'") "output_write phase: $($run.Raw)"
    Assert-True ($run.Raw -match 'timeout|MaxSeconds') "timeout evidence: $($run.Raw)"
    Assert-True ($sw.Elapsed.TotalSeconds -lt 32) "output_write bounded elapsed=$($sw.Elapsed.TotalSeconds)"
    Assert-True (Test-Path -LiteralPath $marker) "block marker written"
    $childPid = 0
    $pidParsed = [int]::TryParse(((Get-Content -Raw -LiteralPath $marker).Trim()), [ref]$childPid)
    Assert-True ($pidParsed -and $childPid -gt 0) "marker carries a valid positive child PID"
    $alive = Get-Process -Id $childPid -ErrorAction SilentlyContinue
    Assert-True ($null -eq $alive) "blocked child still alive pid=$childPid"
  }
  Case 'performance timeout bounds with MaxSeconds' {
    $legacy = Join-Path $root 'legacy-timeout.jsonl'
    $sb = New-Object System.Text.StringBuilder
    for ($n = 0; $n -lt 500; $n++) { [void]$sb.AppendLine((@{ i = $n; body = ('y' * 80) } | ConvertTo-Json -Compress)) }
    Write-Utf8 $legacy $sb.ToString()
    $receipt = Join-Path $root 'timeout-receipt.json'
    $cr = Invoke-Create -Status ready -ArtifactPath @($artPath) -OutputPath $receipt
    Assert-True ($cr.ExitCode -eq 0) "receipt: $($cr.Raw)"
    $run = Invoke-Measure -Legacy $legacy -Receipt $receipt -Iters 200 -MaxSec 1 -Batches 3
    Assert-True ($run.ExitCode -ne 0 -and $run.Raw -match 'timeout|MaxSeconds|phase=') "timeout: $($run.Raw)"
  }
  Case 'performance unstable source omits success ratios' {
    $legacy = Join-Path $root 'legacy-unstable.jsonl'
    Write-Utf8 $legacy ((@{ seq = 1; event = 'stable line' } | ConvertTo-Json -Compress) + "`n")
    $receipt = Join-Path $root 'unstable-receipt.json'
    $cr = Invoke-Create -Status ready -ArtifactPath @($artPath) -OutputPath $receipt
    Assert-True ($cr.ExitCode -eq 0) "receipt: $($cr.Raw)"
    $job = Start-Job -ScriptBlock {
      param($Path)
      Start-Sleep -Milliseconds 80
      1..60 | ForEach-Object {
        [IO.File]::AppendAllText($Path, ((@{ seq = (1000 + $_); event = 'grow' } | ConvertTo-Json -Compress) + "`n"))
        Start-Sleep -Milliseconds 25
      }
    } -ArgumentList $legacy
    try {
      $run = Invoke-Measure -Legacy $legacy -Receipt $receipt -Iters 8 -MaxSec 20 -Batches 3
      if ($run.ExitCode -eq 0) {
        $m = $run.Raw | ConvertFrom-Json
        if (-not [bool]$m.source_stable) {
          Assert-True ($null -eq $m.reduction_pct -or "$($m.reduction_pct)" -eq '') 'no reduction when unstable'
          Assert-True ($null -eq $m.local_speedup_ratio -or "$($m.local_speedup_ratio)" -eq '') 'no speedup when unstable'
          Assert-True ($null -eq $m.local_speedup_ratio_mean -or "$($m.local_speedup_ratio_mean)" -eq '') 'no mean when unstable'
          Assert-True ($m.note -match 'source_stable=false|unmeasured|changed') 'unstable note'
        }
        else { Assert-True ($null -ne $m.reduction_pct) 'stable reduction if race missed' }
      }
      else { Assert-True ($run.Raw -match 'timeout|lock/read|MaxSeconds|phase=') "honest fail: $($run.Raw)" }
    }
    finally {
      Stop-Job -Job $job -ErrorAction SilentlyContinue
      Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
  }
  Case 'source invariants (defaults and measure honesty)' {
    $c = Get-Content -Raw -LiteralPath $createScript
    $s = Get-Content -Raw -LiteralPath $measureScript
    Assert-True ($c -match 'MaxContextBytes\s*=\s*153600' -or $c -match 'MaxContextBytesValidate\s*=\s*153600') 'default max'
    Assert-True ($s -match 'MaxSeconds\s*=\s*30' -and $s -match 'ValidateRange\(1,\s*300\)') 'MaxSeconds'
    Assert-True ($s -match 'ValidateRange\(3,' -and $s -match 'local_speedup_ratio_mean' -and $s -match 'noise_band') 'batch stats'
    Assert-True ($s -match 'legacy_materialization_ms' -and $s -match 'local_speedup_ratio' -and $s -match 'source_stable') 'fields'
    Assert-True ($s -match 'FileShare\]::ReadWrite' -and $s -match "Phase 'legacy_materialization'") 'shared raw read'
    Assert-True ($s -notmatch 'legacyFull.*ConvertFrom-Json|ConvertFrom-Json.*legacyFull') 'no legacy JSON parse'
    Assert-True ($c -match 'lifecycle_complete.*-is\s+\[bool\]' -or $c -match 'lifecycle_complete -is \[bool\]') 'bool lifecycle type gate'
    Assert-True ($c -notmatch '\[long\]\$ContextBytes' -and $c -notmatch '\[int\]\$ContextBytes') 'no ContextBytes param'
    Assert-True ($c -match 'context_bytes\s*=\s*\[int64\]\$artBytesSum') 'context_bytes from artifacts'
    Assert-True ($c -match '\$artBytesSum\s*-ne\s*\$ctx') 'exact context equality'
    Assert-True ($s -match 'remaining.*MaxSeconds|MaxSeconds.*remaining' -and $s -match 'Kill\(|Stop-Process|WaitForExit\(') 'hard cancel budget'
  }
}
finally {
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
if ($failed -eq 0) { Write-Host "Test-FleetHandoffReceipt: $passed passed"; exit 0 }
Write-Host "Test-FleetHandoffReceipt: $failed failed, $passed passed"
exit 1
